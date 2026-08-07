/*
  TRGatewayClient.mm - 内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）
  协议（宪法 7.1/7.3）：
    -> {"type":"register","deviceId":"<uuid>","name":"<真实设备名>","vncPort":5901,
        "capabilities":[...],"configs":{...},"screen":{"width":..,"height":..},"httpPort":..}
    <- {"type":"ack","deviceId":"...","name":"..."}
    -> {"type":"hello"}   每 30s
  断线退避重连（2s 起，上限 30s）；设置变更时重发 register 保持能力清单新鲜。
*/
#import "TRGatewayClient.h"
#import "Logging.h"
#import <UIKit/UIKit.h>

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static NSString *const kDeviceUUIDKey = @"DeviceUUID";
static NSString *const kGatewayHostKey = @"GatewayHost";
static NSString *const kGatewayPortKey = @"GatewayPort";
static NSString *const kDesktopNameKey = @"DesktopName";
static NSString *const kPortKey = @"Port";

static const NSTimeInterval kHelloInterval = 30.0;
static const NSTimeInterval kReadTimeout = 5.0;
static const NSTimeInterval kMinRetryDelay = 2.0;
static const NSTimeInterval kMaxRetryDelay = 30.0;

// 预置读取：未显式设置时回退 Root.plist 默认值（避免 boolForKey 无法区分“未设置/显式 NO”）
static BOOL TVNCBoolPref(NSUserDefaults *d, NSString *key, BOOL def) {
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
static NSInteger TVNCIntPref(NSUserDefaults *d, NSString *key, NSInteger def) {
    id v = [d objectForKey:key];
    return v ? [v integerValue] : def;
}
static double TVNCDoublePref(NSUserDefaults *d, NSString *key, double def) {
    id v = [d objectForKey:key];
    return v ? [v doubleValue] : def;
}
static NSString *TVNCStrPref(NSUserDefaults *d, NSString *key, NSString *def) {
    id v = [d objectForKey:key];
    if (!v) return def;
    NSString *str = [v description];
    return str.length ? str : def;
}

@interface TRGatewayClient () {
    NSUserDefaults *_defaults;
    NSThread *_workerThread;
    BOOL _started;
    BOOL _needsReregister;      // 设置变更后由 worker 线程重发 register（保持清单新鲜）
    NSTimeInterval _retryDelay;
    NSString *_deviceId;
    NSString *_deviceName;
    NSInteger _vncPort;
}

- (NSString *)_gatewayHost;
- (NSInteger)_gatewayPort;
- (NSString *)_deviceId;
- (NSString *)_deviceName;
- (NSInteger)_vncPort;
- (NSInteger)_httpPort;
- (void)_workerMain;
- (BOOL)_connectAndRun;
- (void)_sendHello:(int)fd;
- (void)_handleServerLine:(NSString *)line fd:(int)fd;
- (void)_sendAck:(NSDictionary *)ack fd:(int)fd;
- (NSData *)_registerData;
- (NSArray<NSString *> *)_capabilities;
- (NSDictionary *)_configs;
- (NSDictionary *)_screenInfo;
- (void)_defaultsChanged;

@end

@implementation TRGatewayClient

+ (instancetype)sharedClient {
    static TRGatewayClient *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TRGatewayClient alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _retryDelay = kMinRetryDelay;
        // 设置变化（app 内设置页 / Managed.plist）→ 标记重发 register
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_defaultsChanged)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 配置

- (NSString *)_gatewayHost {
    NSString *host = [_defaults stringForKey:kGatewayHostKey];
    return host.length ? host : nil;
}

- (NSInteger)_gatewayPort {
    NSInteger port = [_defaults integerForKey:kGatewayPortKey];
    return (port > 0 && port < 65536) ? port : 18081;
}

- (NSString *)_deviceId {
    if (_deviceId) return _deviceId;
    NSString *uuid = [_defaults stringForKey:kDeviceUUIDKey];
    if (!uuid.length) {
        uuid = [[NSUUID UUID] UUIDString];
        [_defaults setObject:uuid forKey:kDeviceUUIDKey];
        [_defaults synchronize];
        TVLog(@"[gw] generated DeviceUUID: %@", uuid);
    }
    _deviceId = uuid;
    return _deviceId;
}

- (NSString *)_deviceName {
    if (_deviceName) return _deviceName;
    // 优先使用设备真实名称（如“张三的 iPhone”），保证注册名/桌面名一致
    NSString *realName = [[UIDevice currentDevice] name];
    NSString *dn = [_defaults stringForKey:kDesktopNameKey];
    if (dn.length && ![dn isEqualToString:@"TrollVNC"]) {
        _deviceName = dn;
    } else if (realName.length) {
        _deviceName = realName;
        // 同步到 DesktopName，使 mDNS/Bonjour 与 VNC 桌面名也是真实名称
        [_defaults setObject:realName forKey:kDesktopNameKey];
        [_defaults synchronize];
    } else {
        _deviceName = @"TrollVNC";
    }
    return _deviceName;
}

- (NSInteger)_vncPort {
    if (_vncPort == 0) {
        NSInteger port = [_defaults integerForKey:kPortKey];
        _vncPort = (port > 0 && port < 65536) ? port : 5901;
    }
    return _vncPort;
}

- (NSInteger)_httpPort {
    NSInteger http = [_defaults integerForKey:@"HttpPort"];
    return (http > 0 && http < 65536) ? http : 0;
}

#pragma mark - 能力清单（宪法 7.3，v1 只上报不下发）

- (NSArray<NSString *> *)_capabilities {
    // 固定枚举：仅 RFB 可注入的操作；适配/全屏/断开是控制台本地操作，不入清单
    return @[ @"home", @"power", @"volup", @"voldn", @"mute", @"briup", @"bridn", @"keyboard", @"clipboard" ];
}

- (NSDictionary *)_configs {
    // 白名单 = Root.plist 现有键的子集；密码只报存在性，不上报明文
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    cfg[@"scale"] = @(TVNCDoublePref(_defaults, @"Scale", 1.0));
    cfg[@"frameRateSpec"] = TVNCStrPref(_defaults, @"FrameRateSpec", @"60");
    cfg[@"port"] = @([self _vncPort]);
    cfg[@"httpPort"] = @([self _httpPort]);
    cfg[@"bonjourEnabled"] = @(TVNCBoolPref(_defaults, @"BonjourEnabled", YES));
    cfg[@"orientationSync"] = @(TVNCBoolPref(_defaults, @"OrientationSync", YES));
    cfg[@"orientationPadFix"] = @(TVNCIntPref(_defaults, @"OrientationPadFix", 0));
    cfg[@"naturalScroll"] = @(TVNCBoolPref(_defaults, @"NaturalScroll", NO));
    cfg[@"keepAliveSec"] = @(TVNCDoublePref(_defaults, @"KeepAliveSec", 0.0));
    cfg[@"clipboardEnabled"] = @(TVNCBoolPref(_defaults, @"ClipboardEnabled", YES));
    cfg[@"viewOnly"] = @(TVNCBoolPref(_defaults, @"ViewOnly", NO));
    cfg[@"modifierMap"] = TVNCStrPref(_defaults, @"ModifierMap", @"std");
    cfg[@"wheelStepPx"] = @(TVNCDoublePref(_defaults, @"WheelStepPx", 48.0));
    cfg[@"serverCursor"] = @(TVNCBoolPref(_defaults, @"ServerCursor", NO));
    cfg[@"reverseMode"] = TVNCStrPref(_defaults, @"ReverseMode", @"none");
    NSString *fullPw = [_defaults stringForKey:@"FullPassword"];
    NSString *viewPw = [_defaults stringForKey:@"ViewOnlyPassword"];
    cfg[@"hasPassword"] = @(fullPw.length > 0);
    cfg[@"hasViewOnlyPassword"] = @(viewPw.length > 0);
    return cfg;
}

- (NSDictionary *)_screenInfo {
    // 原生像素：UIScreen bounds(点) × nativeScale（如 1170×2532）；连接后控制台以真实 RFB 帧缓冲为准
    UIScreen *s = [UIScreen mainScreen];
    CGFloat scale = [s respondsToSelector:@selector(nativeScale)] ? [s nativeScale] : [s scale];
    if (scale <= 0) scale = 1.0;
    long w = (long)(s.bounds.size.width * scale + 0.5);
    long h = (long)(s.bounds.size.height * scale + 0.5);
    return @{ @"width": @(w), @"height": @(h) };
}

- (NSData *)_registerData {
    NSMutableDictionary *reg = [NSMutableDictionary dictionary];
    reg[@"type"] = @"register";
    reg[@"deviceId"] = [self _deviceId];
    reg[@"name"] = [self _deviceName];
    reg[@"vncPort"] = @([self _vncPort]);
    reg[@"capabilities"] = [self _capabilities];
    reg[@"configs"] = [self _configs];
    reg[@"screen"] = [self _screenInfo];
    reg[@"httpPort"] = @([self _httpPort]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:reg options:0 error:NULL];
    if (!json) return nil;
    NSMutableData *md = [json mutableCopy];
    const char nl = '\n';
    [md appendBytes:&nl length:1];
    return md;
}

#pragma mark - 生命周期

- (void)start {
    if (_started) return;
    if (![self _gatewayHost]) {
        TVLog(@"[gw] no gateway host configured, registration disabled");
        return;
    }
    _started = YES;
    _workerThread = [[NSThread alloc] initWithTarget:self selector:@selector(_workerMain) object:nil];
    [_workerThread setName:@"com.82flex.trollvnc.gateway-client"];
    [_workerThread start];
    TVLog(@"[gw] registration worker started -> %@:%ld", [self _gatewayHost], (long)[self _gatewayPort]);
}

- (void)stop {
    _started = NO;
    if (_workerThread) {
        // 线程内阻塞在 socket 读，最多 kReadTimeout 后退出
        [_workerThread cancel];
        _workerThread = nil;
    }
}

- (void)_defaultsChanged {
    @synchronized(self) {
        _needsReregister = YES;
        _deviceName = nil;  // 允许下次 register 读取新名称
        _vncPort = 0;       // 允许下次 register 读取新端口（deviceId 保持稳定）
    }
}

- (void)_workerMain {
    while (_started && ![[NSThread currentThread] isCancelled]) {
        @autoreleasepool {
            BOOL ok = [self _connectAndRun];
            if (!ok && _started) {
                TVLog(@"[gw] connection lost, retry in %.0fs", _retryDelay);
                usleep((useconds_t)(_retryDelay * 1e6));
                _retryDelay = MIN(_retryDelay * 2, kMaxRetryDelay);
            }
        }
    }
}

- (BOOL)_connectAndRun {
    NSString *host = [self _gatewayHost];
    if (!host.length) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct hostent *he = gethostbyname(host.UTF8String);
    if (!he) {
        close(fd);
        return NO;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)[self _gatewayPort]);
    memcpy(&addr.sin_addr, he->h_addr, he->h_length);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }
    TVLog(@"[gw] connected to %@:%ld", host, (long)[self _gatewayPort]);

    // register（含能力清单）
    NSData *regData = [self _registerData];
    if (!regData) {
        close(fd);
        return NO;
    }
    if (write(fd, regData.bytes, regData.length) < 0) {
        close(fd);
        return NO;
    }

    _retryDelay = kMinRetryDelay;

    // 读线程循环：读 ack/任意数据；每 kHelloInterval 发 hello；select 超时检测
    // 命令通道行缓冲：接收网关注册通道下发的 JSON 行（cmd 命令，宪法 7.4）
    char inBuf[1024];
    size_t inLen = 0;
    time_t lastHello = time(NULL);
    while (_started && ![[NSThread currentThread] isCancelled]) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        tv.tv_sec = (time_t)kReadTimeout;
        tv.tv_usec = 0;
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            close(fd);
            return NO;
        }
        if (sel == 0) {
            // 超时：设置变更 → 重发 register（读最新 NSUserDefaults）；否则按间隔发 hello
            time_t now = time(NULL);
            BOOL rereg = NO;
            @synchronized(self) {
                rereg = _needsReregister;
                _needsReregister = NO;
            }
            if (rereg) {
                NSData *fresh = [self _registerData];
                if (fresh && write(fd, fresh.bytes, fresh.length) < 0) {
                    close(fd);
                    return NO;
                }
                lastHello = now;
                continue;
            }
            if (now - lastHello >= (time_t)kHelloInterval) {
                [self _sendHello:fd];
                lastHello = now;
            }
            continue;
        }
        ssize_t n = read(fd, inBuf + inLen, sizeof(inBuf) - inLen - 1);
        if (n <= 0) {
            close(fd);
            return NO;
        }
        inLen += (size_t)n;
        inBuf[inLen] = '\0';
        // 逐行处理下发的 JSON 消息
        size_t start = 0;
        for (size_t i = 0; i < inLen; i++) {
            if (inBuf[i] == '\n') {
                inBuf[i] = '\0';
                [self _handleServerLine:[NSString stringWithUTF8String:inBuf + start] fd:fd];
                start = i + 1;
            }
        }
        if (start > 0) {
            memmove(inBuf, inBuf + start, inLen - start);
            inLen -= start;
            inBuf[inLen] = '\0';
        } else if (inLen >= sizeof(inBuf) - 1) {
            // 超长无换行数据：丢弃整段，防止阻塞
            inLen = 0;
            inBuf[0] = '\0';
        }
    }

    close(fd);
    return YES;
}

#pragma mark - 命令通道（宪法 7.4，v1 仅 ping）

// 处理网关注册通道下发的 JSON 行：cmd 命令 → 回 ack
- (void)_handleServerLine:(NSString *)line fd:(int)fd {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![msg isKindOfClass:[NSDictionary class]]) return;
    NSString *type = [msg[@"type"] description];
    if (![type isEqualToString:@"cmd"]) return;
    NSString *cmd = msg[@"cmd"] ? [msg[@"cmd"] description] : @"";
    NSString *cid = msg[@"id"] ? [msg[@"id"] description] : @"";
    if ([cmd isEqualToString:@"ping"]) {
        [self _sendAck:@{ @"type": @"ack", @"cmd": cmd, @"id": cid, @"ok": @YES } fd:fd];
    } else {
        // v1 仅支持 ping；set 等命令明确拒绝（宪法 1.3/7.4，B4 决策点）
        [self _sendAck:@{ @"type": @"ack", @"cmd": cmd, @"id": cid, @"ok": @NO, @"error": @"unsupported command" } fd:fd];
    }
}

- (void)_sendAck:(NSDictionary *)ack fd:(int)fd {
    NSData *json = [NSJSONSerialization dataWithJSONObject:ack options:0 error:NULL];
    if (!json) return;
    NSMutableData *md = [json mutableCopy];
    const char nl = '\n';
    [md appendBytes:&nl length:1];
    if (write(fd, md.bytes, md.length) < 0) {
        // 写失败说明连接已断，read 循环会尽快退出
    }
}

- (void)_sendHello:(int)fd {
    const char *hello = "{\"type\":\"hello\"}\n";
    ssize_t n = write(fd, hello, strlen(hello));
    if (n < 0) {
        // 写失败说明连接已断，read 循环会尽快退出
    }
}

@end
