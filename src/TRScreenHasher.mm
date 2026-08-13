/*
  TRScreenHasher.mm - 屏幕感知哈希模块实现（Phase 11.4）
  pHash 计算管线（Accelerate framework）：
    01 取帧（ScreenCapturer.captureSingleFrameBuffer，跳过 JPEG）
    02 缩放 32×32（vImageScale_ARGB8888 → ARGB 缓冲区 4KB）
    03 转灰度（手写 Rec.601 加权，0.299R+0.587G+0.114B → 8bit Gray 1KB）
    04 DCT-II（手写可分离 2D DCT-II → 32×32 频域系数；theos SDK 无 vDSP_DCT API）
    05 取左上 8×8 低频（排除 DC [0][0]）+ 求均值 + 逐位比较 → uint64_t
*/

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Accelerate/Accelerate.h>
#import <mach/mach_time.h>
#import <math.h>

#import "Logging.h"
#import "ScreenCapturer.h"
#import "TRScreenHasher.h"

/** pHash 管线常量 */
static const vImagePixelCount kHashSize = 32;        // 缩放尺寸 32×32
static const int kLowFreqSize = 8;                    // 取左上 8×8 低频
static const int kDCTLength = 32 * 32;                // DCT 输入长度 1024
static const int kHashBits = 64;                      // 哈希位数

@implementation TRScreenHasher {
    // 串行队列：串行化帧访问，避免并发取帧冲突
    dispatch_queue_t _queue;
    // 缓冲区（init 时分配，复用，避免每帧 malloc/free）
    vImage_Buffer _argbBuffer;      // 32×32 ARGB（4KB）
    vImage_Buffer _grayBuffer;      // 32×32 Gray（1KB）
    uint8_t *_argbData;             // ARGB 缓冲区数据指针
    uint8_t *_grayData;             // 灰度缓冲区数据指针
    float *_dctInput;               // DCT 输入（1024 floats）
    float *_dctOutput;              // DCT 输出（1024 floats）
}

#pragma mark - 单例与初始化

/** 返回共享单例实例 */
+ (instancetype)sharedHasher {
    static TRScreenHasher *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[TRScreenHasher alloc] init];
    });
    return _inst;
}

/**
 * 初始化 pHash 计算管线。
 * 功能：分配固定缓冲区（4KB ARGB + 1KB Gray + 8KB DCT）；DCT 为手写实现，无需 setup。
 * 参数：无
 * 返回值：TRScreenHasher* - 初始化后的实例
 */
- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

    // 串行队列：串行化帧访问
    _queue = dispatch_queue_create("com.trollvnc.screenHasher", DISPATCH_QUEUE_SERIAL);

    // 分配固定缓冲区（复用，避免每帧 malloc/free）
    // ARGB 缓冲区：32×32×4 = 4096 bytes
    _argbData = (uint8_t *)malloc(kHashSize * kHashSize * 4);
    _argbBuffer.data = _argbData;
    _argbBuffer.width = kHashSize;
    _argbBuffer.height = kHashSize;
    _argbBuffer.rowBytes = kHashSize * 4;

    // 灰度缓冲区：32×32×1 = 1024 bytes
    _grayData = (uint8_t *)malloc(kHashSize * kHashSize);
    _grayBuffer.data = _grayData;
    _grayBuffer.width = kHashSize;
    _grayBuffer.height = kHashSize;
    _grayBuffer.rowBytes = kHashSize;

    // DCT 输入/输出：1024 floats × 2 = 8KB
    _dctInput = (float *)malloc(kDCTLength * sizeof(float));
    _dctOutput = (float *)malloc(kDCTLength * sizeof(float));

    TVLog(@"[TRScreenHasher] 初始化完成（ARGB=%zuB, Gray=%zuB, DCT=%zuB）",
          (size_t)(kHashSize * kHashSize * 4), (size_t)(kHashSize * kHashSize),
          (size_t)(kDCTLength * sizeof(float) * 2));

    return self;
}

/**
 * 析构：释放缓冲区。
 */
- (void)dealloc {
    free(_argbData);
    free(_grayData);
    free(_dctInput);
    free(_dctOutput);
}

#pragma mark - 核心哈希计算

/**
 * 计算当前屏幕帧的 pHash（5 步管线核心实现）。
 * 功能：从 ScreenCapturer 取帧 → 缩放 32×32 → 灰度 → DCT-II → 8×8 低频哈希。
 * 参数：无
 * 返回值：uint64_t — 64bit pHash；取帧失败返回 0
 */
- (uint64_t)computeHashForCurrentFrame {
    __block uint64_t hash = 0;
    dispatch_sync(_queue, ^{
        hash = [self _computeHashUnsafe];
    });
    return hash;
}

/**
 * pHash 计算内部实现（无锁，需在 _queue 内调用）。
 * 功能：执行 5 步管线，返回 64bit 哈希。
 * 参数：无
 * 返回值：uint64_t - 64bit pHash
 */
- (uint64_t)_computeHashUnsafe {
    // ===== 步骤 01：取帧（跳过 JPEG，直接 CVPixelBufferRef）=====
    CVPixelBufferRef pixelBuffer = [[ScreenCapturer sharedCapturer] captureSingleFrameBuffer];
    if (!pixelBuffer) {
        TVLog(@"[TRScreenHasher] 取帧失败，返回 0");
        return 0;
    }

    uint64_t hash = 0;
    @try {
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        void *baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t srcWidth = CVPixelBufferGetWidth(pixelBuffer);
        size_t srcHeight = CVPixelBufferGetHeight(pixelBuffer);
        size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
        OSType srcFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

        if (!baseAddr || srcWidth == 0 || srcHeight == 0) {
            TVLog(@"[TRScreenHasher] CVPixelBuffer 数据无效（baseAddr=%p, %zux%zu）", baseAddr, srcWidth, srcHeight);
            return 0;
        }

        // 构建源 vImage_Buffer（只读视图，不拷贝）
        vImage_Buffer srcBuffer;
        srcBuffer.data = baseAddr;
        srcBuffer.width = srcWidth;
        srcBuffer.height = srcHeight;
        srcBuffer.rowBytes = srcRowBytes;

        // ===== 步骤 02：缩放 32×32（vImageScale_ARGB8888）=====
        // vImageScale_ARGB8888 对 ARGB/BGRA 均适用（每通道独立插值，不关心通道顺序），
        // 通道顺序在步骤 03 灰度化时按源格式区分。
        // 'ARGB' = 0x42475241，'BGRA' = 0x41524742
        if (srcFormat != 0x42475241 /* 'ARGB' */ && srcFormat != 0x41524742 /* 'BGRA' */) {
            TVLog(@"[TRScreenHasher] 不支持的像素格式 0x%08X，仅支持 ARGB/BGRA", (unsigned)srcFormat);
            return 0;
        }
        vImage_Error scaleErr = vImageScale_ARGB8888(&srcBuffer, &_argbBuffer, NULL, kvImageNoFlags);
        if (scaleErr != kvImageNoError) {
            TVLog(@"[TRScreenHasher] vImageScale 失败（err=%zd）", scaleErr);
            return 0;
        }

        // ===== 步骤 03：转灰度（手写 Rec.601 加权，0.299R+0.587G+0.114B）=====
        // g = (77·R + 150·G + 29·B) >> 8；与 vImageMatrixMultiply 系数一致，
        // 且兼容 ARGB/BGRA 通道顺序，避免 theos SDK 中 ARGB8888ToPlanar8 的签名差异。
        // 同时直接生成 DCT 输入的 float 灰度值，避免额外 uint8→float 转换 API。
        const BOOL isBGRA = (srcFormat == 0x41524742 /* 'BGRA' */);
        {
            const uint8_t *pix = _argbData;
            for (int i = 0; i < kDCTLength; i++, pix += 4) {
                uint8_t r, g, b;
                if (isBGRA) {
                    b = pix[0]; g = pix[1]; r = pix[2];
                } else {
                    r = pix[1]; g = pix[2]; b = pix[3]; // ARGB：A=0, R=1, G=2, B=3
                }
                const uint8_t gray = (uint8_t)((77 * r + 150 * g + 29 * b) >> 8);
                _grayData[i] = gray;
                _dctInput[i] = (float)gray;
            }
        }

        // ===== 步骤 04：DCT-II（手写可分离 2D DCT-II，32×32 频域系数）=====
        // theos SDK（iPhoneOS16.5 头文件）不含 vDSP_DCT_* API，改为手写实现。
        // 公式：X[k] = Σ x[n]·cos((2n+1)kπ/2N)，k=0..N-1；归一化系数 2/N 为常数，
        //       不影响「低频 vs 均值」比较，省略以省计算。
        {
            const int N = (int)kHashSize; // 32
            static const float kPi = 3.14159265358979f;
            // cos 查找表：cosTable[n][k] = cos((2n+1)kπ/2N)，N×N = 1024 项
            float cosTable[32][32];
            for (int n = 0; n < N; n++) {
                const float base = (float)(2 * n + 1) * kPi / (float)(2 * N);
                for (int k = 0; k < N; k++) {
                    cosTable[n][k] = cosf(base * (float)k);
                }
            }
            // 行变换：对每行 32 点做 1D DCT-II → rowTemp（1024）
            float rowTemp[32 * 32];
            for (int row = 0; row < N; row++) {
                const float *srcRow = _dctInput + row * N;
                float *dstRow = rowTemp + row * N;
                for (int k = 0; k < N; k++) {
                    float sum = 0.0f;
                    for (int n = 0; n < N; n++) {
                        sum += srcRow[n] * cosTable[n][k];
                    }
                    dstRow[k] = sum;
                }
            }
            // 列变换：对每列 32 点做 1D DCT-II（转置读取 rowTemp）→ _dctOutput（行优先）
            for (int col = 0; col < N; col++) {
                for (int k = 0; k < N; k++) {
                    float sum = 0.0f;
                    for (int m = 0; m < N; m++) {
                        sum += rowTemp[m * N + col] * cosTable[m][k];
                    }
                    _dctOutput[k * N + col] = sum;
                }
            }
        }

        // ===== 步骤 05：取左上 8×8 低频 + 求均值（排除 DC [0][0]）+ 逐位比较 =====
        // DCT 输出是行优先 32×32 矩阵，取左上 8×8（index 0..7, 32..39, ..., 7*32..7*32+7）
        // 排除 DC 分量 [0][0]（index 0），剩余 63 个系数参与均值计算
        float lowFreq[kHashBits]; // 64 个低频系数
        float sum = 0.0f;
        int idx = 0;
        for (int row = 0; row < kLowFreqSize; row++) {
            for (int col = 0; col < kLowFreqSize; col++) {
                float coef = _dctOutput[row * kHashSize + col];
                lowFreq[idx] = coef;
                if (!(row == 0 && col == 0)) { // 排除 DC [0][0]
                    sum += coef;
                }
                idx++;
            }
        }
        // 均值 = sum / 63（排除 DC 后 63 个系数）
        float mean = sum / (float)(kHashBits - 1);

        // 逐位比较：coef > mean → 置位
        hash = 0;
        for (int i = 0; i < kHashBits; i++) {
            if (lowFreq[i] > mean) {
                hash |= ((uint64_t)1 << i);
            }
        }
    } @finally {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(pixelBuffer);
    }

    return hash;
}

/**
 * 计算当前屏幕帧的 pHash 并返回 hex 字符串。
 * 功能：调用 computeHashForCurrentFrame 后转为 16 字符 hex 字符串。
 * 参数：无
 * 返回值：NSString* — 16 字符 hex 字符串；失败返回 @"0"
 */
- (NSString *)computeHashHexForCurrentFrame {
    uint64_t hash = [self computeHashForCurrentFrame];
    return [self hexStringFromHash:hash];
}

#pragma mark - 汉明距离与格式转换

/**
 * 计算两个 pHash 的汉明距离。
 * 功能：XOR + popcount 计算两个 64bit 哈希的差异位数。
 * 参数：a - 第一个 pHash
 *      b - 第二个 pHash
 * 返回值：NSInteger - 汉明距离（0-64），0 表示完全相同
 */
- (NSInteger)hammingDistanceBetweenHash:(uint64_t)a andHash:(uint64_t)b {
    return (NSInteger)__builtin_popcountll(a ^ b);
}

/**
 * 将 16 字符 hex 字符串转为 uint64_t。
 * 功能：解析 hex 字符串为 64bit 哈希值。
 * 参数：hex - 16 字符 hex 字符串
 * 返回值：uint64_t - 解析结果；格式错误返回 0
 */
- (uint64_t)hashFromHexString:(NSString *)hex {
    if (hex.length == 0 || hex.length > 16) {
        return 0;
    }
    // 使用 NSScanner 解析 hex
    uint64_t result = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner setScanLocation:0];
    if (![scanner scanHexLongLong:&result]) {
        return 0;
    }
    return result;
}

/**
 * 将 uint64_t 哈希转为 16 字符 hex 字符串。
 * 功能：格式化哈希值为 16 字符 hex 字符串（小写，补零）。
 * 参数：hash - 64bit 哈希值
 * 返回值：NSString* - 16 字符 hex 字符串
 */
- (NSString *)hexStringFromHash:(uint64_t)hash {
    return [NSString stringWithFormat:@"%016llx", hash];
}

#pragma mark - screen.diff 实现

/**
 * 与基线哈希比较，返回差异信息。
 * 功能：计算当前帧 pHash，与 baselineHash 比较汉明距离，判断是否发生变化。
 * 参数：baselineHash - 基线哈希（16 字符 hex 字符串）
 *      threshold   - 汉明距离阈值（超过则 changed=true），传 0 使用默认值 5
 *      currentHash - 输出参数，当前帧哈希 hex 字符串
 * 返回值：NSDictionary* - {distance, threshold, changed, currentHash}；失败返回 nil
 */
- (nullable NSDictionary *)diffWithBaselineHash:(NSString *)baselineHash
                                      threshold:(NSInteger)threshold
                                    currentHash:(NSString *_Nullable *_Nullable)currentHash {
    if (baselineHash.length == 0) {
        return nil;
    }
    if (threshold <= 0) {
        threshold = TRScreenHashDiffDefaultThreshold;
    }

    uint64_t baseline = [self hashFromHexString:baselineHash];
    uint64_t current = [self computeHashForCurrentFrame];
    NSString *currentHex = [self hexStringFromHash:current];

    if (currentHash) {
        *currentHash = currentHex;
    }

    NSInteger distance = [self hammingDistanceBetweenHash:baseline andHash:current];
    BOOL changed = distance > threshold;

    return @{
        @"distance": @(distance),
        @"threshold": @(threshold),
        @"changed": @(changed),
        @"currentHash": currentHex
    };
}

#pragma mark - screen.waitStable 实现

/**
 * 轮询等待画面稳定。
 * 功能：每 intervalMs 采集一帧计算 pHash，比较相邻帧汉明距离，
 *      连续 N=stableMs/intervalMs 帧均 < threshold 则判定稳定。
 *      注意：比较相邻帧（非与基线），因页面加载是渐变的。
 * 参数：maxMs       - 最大等待毫秒（超时返回 stable=false），传 0 使用默认值 3000
 *      stableMs    - 稳定判定窗口毫秒，传 0 使用默认值 500
 *      intervalMs  - 轮询间隔毫秒，传 0 使用默认值 200
 *      threshold   - 汉明距离阈值，传 0 使用默认值 3
 *      frameCount  - 输出参数，实际采集帧数
 *      durationMs  - 输出参数，实际耗时毫秒
 *      lastHash    - 输出参数，最后一帧哈希 hex 字符串
 * 返回值：BOOL - YES 表示画面已稳定，NO 表示超时未稳定
 */
- (BOOL)waitStableWithMaxMs:(NSTimeInterval)maxMs
                   stableMs:(NSTimeInterval)stableMs
                 intervalMs:(NSTimeInterval)intervalMs
                  threshold:(NSInteger)threshold
                 frameCount:(NSInteger *_Nullable)frameCount
                 durationMs:(NSTimeInterval *_Nullable)durationMs
                   lastHash:(NSString *_Nullable *_Nullable)lastHash {
    // 应用默认值
    if (maxMs <= 0) maxMs = TRScreenWaitStableDefaultMaxMs;
    if (stableMs <= 0) stableMs = TRScreenWaitStableDefaultStableMs;
    if (intervalMs <= 0) intervalMs = TRScreenWaitStableDefaultIntervalMs;
    if (threshold <= 0) threshold = TRScreenWaitStableDefaultThreshold;

    // 稳定判定所需的连续帧数：ceil(stableMs / intervalMs)
    // 如 stableMs=500, intervalMs=200 → N=3（ceil(2.5)）
    NSInteger requiredConsecutive = (NSInteger)ceil(stableMs / intervalMs);
    if (requiredConsecutive < 1) requiredConsecutive = 1;

    uint64_t startMs = [self _machTimeToMs:mach_absolute_time()];
    uint64_t deadlineMs = startMs + (uint64_t)maxMs;

    NSInteger frames = 0;
    NSInteger consecutiveStable = 0;
    uint64_t prevHash = 0;
    BOOL hasPrev = NO;
    NSString *finalHash = @"0";

    while (YES) {
        uint64_t nowMs = [self _machTimeToMs:mach_absolute_time()];
        if (nowMs >= deadlineMs) {
            // 超时
            break;
        }

        uint64_t currentHash = [self computeHashForCurrentFrame];
        frames++;
        finalHash = [self hexStringFromHash:currentHash];

        if (hasPrev) {
            NSInteger dist = [self hammingDistanceBetweenHash:prevHash andHash:currentHash];
            if (dist < threshold) {
                consecutiveStable++;
                if (consecutiveStable >= requiredConsecutive) {
                    // 连续 N 帧稳定，判定成功
                    if (frameCount) *frameCount = frames;
                    if (durationMs) *durationMs = (NSTimeInterval)(nowMs - startMs);
                    if (lastHash) *lastHash = finalHash;
                    return YES;
                }
            } else {
                // 中断，重新计数
                consecutiveStable = 0;
            }
        }

        prevHash = currentHash;
        hasPrev = YES;

        // 等待下一帧（不阻塞 _queue，用 usleep）
        useconds_t sleepUs = (useconds_t)(intervalMs * 1000);
        usleep(sleepUs);
    }

    // 超时未稳定
    if (frameCount) *frameCount = frames;
    if (durationMs) *durationMs = (NSTimeInterval)([self _machTimeToMs:mach_absolute_time()] - startMs);
    if (lastHash) *lastHash = finalHash;
    return NO;
}

#pragma mark - 工具方法

/**
 * mach_absolute_time 转毫秒。
 * 功能：将 Mach 绝对时间转为毫秒数（自系统启动）。
 * 参数：machTime - mach_absolute_time() 返回值
 * 返回值：uint64_t - 毫秒时间戳
 */
- (uint64_t)_machTimeToMs:(uint64_t)machTime {
    static mach_timebase_info_data_t sTimebaseInfo;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&sTimebaseInfo);
    });
    // machTime * numer / denom → 纳秒，/ 1000000 → 毫秒
    uint64_t nanos = machTime * sTimebaseInfo.numer / sTimebaseInfo.denom;
    return nanos / 1000000ULL;
}

@end
