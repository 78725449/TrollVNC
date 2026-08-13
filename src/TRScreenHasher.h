/*
  TRScreenHasher.h - 屏幕感知哈希模块（Phase 11.4）
  功能：基于 Accelerate framework（vImage + vDSP）实现 pHash 计算管线，
       为 AI 自动化提供轻量级屏幕变化检测原语（screen.hash/diff/waitStable）。
  设计依据：IPA改造计划 v2.0 Phase 11.4.2
    - 32×32 DCT 取 8×8 低频（排除 DC [0][0]）
    - 单次 pHash ≈0.3ms（vs JPEG 8ms，快 26 倍）
    - 60fps 持续计算 CPU <1%，内存 4KB
  架构位置：trollvncserver 进程内，直接访问 ScreenCapturer，通过 5901 RFB 扩展消息暴露
*/
#ifndef TRScreenHasher_h
#define TRScreenHasher_h

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 默认参数（v2.0 文档 11.4.3 确认值） */
/** screen.diff 默认汉明距离阈值：<3 基本相同 / 3-8 轻微变化 / 8-15 明显变化 / >15 完全不同 */
static const NSInteger TRScreenHashDiffDefaultThreshold = 5;
/** screen.waitStable 默认最大等待毫秒 */
static const NSTimeInterval TRScreenWaitStableDefaultMaxMs = 3000;
/** screen.waitStable 默认稳定判定窗口毫秒（连续 N 帧无变化即稳定） */
static const NSTimeInterval TRScreenWaitStableDefaultStableMs = 500;
/** screen.waitStable 默认轮询间隔毫秒 */
static const NSTimeInterval TRScreenWaitStableDefaultIntervalMs = 200;
/** screen.waitStable 默认汉明距离阈值（<3 视为无变化） */
static const NSInteger TRScreenWaitStableDefaultThreshold = 3;

/**
 * TRScreenHasher - pHash 计算核心模块（单例）
 * 功能：封装 5 步 pHash 计算管线（取帧→缩放 32×32→灰度→DCT-II→8×8 低频哈希），
 *      提供 screen.hash/diff/waitStable 三项能力的底层实现。
 * 线程安全：所有方法线程安全，内部使用串行队列串行化帧访问。
 * 生命周期：单例，随 trollvncserver 进程生命周期。
 */
@interface TRScreenHasher : NSObject

/** 返回共享单例实例 */
+ (instancetype)sharedHasher;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - 核心哈希计算

/**
 * 计算当前屏幕帧的 pHash。
 * 功能：从 ScreenCapturer 取当前帧（跳过 JPEG），经 32×32 DCT 计算得到 64bit 感知哈希。
 * 参数：无
 * 返回值：uint64_t — 64bit pHash；取帧失败返回 0
 */
- (uint64_t)computeHashForCurrentFrame;

/**
 * 计算当前屏幕帧的 pHash 并返回 hex 字符串。
 * 功能：调用 computeHashForCurrentFrame 后转为 16 字符 hex 字符串（JSON 友好）。
 * 参数：无
 * 返回值：NSString* — 16 字符 hex 字符串（如 "a1b2c3d4e5f6a7b8"）；失败返回 @"0"
 */
- (NSString *)computeHashHexForCurrentFrame;

#pragma mark - 汉明距离与差异检测

/**
 * 计算两个 pHash 的汉明距离。
 * 功能：XOR + popcount 计算两个 64bit 哈希的差异位数。
 * 参数：a - 第一个 pHash
 *      b - 第二个 pHash
 * 返回值：NSInteger - 汉明距离（0-64），0 表示完全相同
 */
- (NSInteger)hammingDistanceBetweenHash:(uint64_t)a andHash:(uint64_t)b;

/**
 * 将 16 字符 hex 字符串转为 uint64_t。
 * 功能：解析 hex 字符串为 64bit 哈希值。
 * 参数：hex - 16 字符 hex 字符串
 * 返回值：uint64_t - 解析结果；格式错误返回 0
 */
- (uint64_t)hashFromHexString:(NSString *)hex;

/**
 * 将 uint64_t 哈希转为 16 字符 hex 字符串。
 * 功能：格式化哈希值为 hex 字符串。
 * 参数：hash - 64bit 哈希值
 * 返回值：NSString* - 16 字符 hex 字符串（小写）
 */
- (NSString *)hexStringFromHash:(uint64_t)hash;

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
                                    currentHash:(NSString *_Nullable *_Nullable)currentHash;

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
                   lastHash:(NSString *_Nullable *_Nullable)lastHash;

@end

NS_ASSUME_NONNULL_END

#endif /* TRScreenHasher_h */
