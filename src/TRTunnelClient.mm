/*
  TRTunnelClient.mm - 设备侧隧道客户端（BSD socket / TCP + 帧封装）
  协议：
    握手阶段（JSON 行）：
      -> {"type":"tunnel_hello","deviceId":"<uuid>","token":"<可选>"}
      <- {"type":"tunnel_ack","ok":true}
    握手成功后进入帧封装透传模式（type:1B + length:4B BE + payload）：
      DATA(0x01)    双向 RFB 透传（隧道 ↔ 本地 127.0.0.1:5901）
      PING(0x02)    心跳请求（设备→网关，每 30s）
      PONG(0x03)    心跳响应（网关→设备 / 设备回网关）
      CMD(0x04)     命令 JSON（网关→设备，复用 sendDeviceCmd 通道）
      CMDACK(0x05)  命令 ack JSON（设备→网关）
  帧封装是为了让 RFB 裸字节透传与 JSON 心跳/命令在同一隧道上共存而不互相污染。
  心跳：每 30s 发 PING；断线退避重连（2s 起，上限 30s），与 TRGatewayClient 一致。
  独立线程运行（NSThread），select() 多路复用隧道与本地 RFB 双向数据流。
*/
#import "TRTunnelClient.h"
#import "Logging.h"

#import <stdio.h>
#import <stdarg.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

// 帧类型常量
static const uint8_t kFrameTypeData    = 0x01;  // RFB 透传数据
static const uint8_t kFrameTypePing    = 0x02;  // 心跳请求（设备→网关）
static const uint8_t kFrameTypePong    = 0x03;  // 心跳响应（网关→设备）
static const uint8_t kFrameTypeCmd     = 0x04;  // 命令 JSON（网关→设备）
static const uint8_t kFrameTypeCmdAck  = 0x05;  // 命令 ack JSON（设备→网关）

// 心跳/超时/重连参数
static const NSTimeInterval kTunnelPingInterval  = 30.0;   // 心跳间隔（秒）
static const NSTimeInterval kTunnelSelectTimeout = 5.0;    // select 超时（秒，用于触发心跳与重检）
static const NSTimeInterval kTunnelMinRetryDelay = 2.0;    // 最小重连退避（秒）
static const NSTimeInterval kTunnelMaxRetryDelay = 30.0;   // 最大重连退避（秒）

static const uint16_t kLocalRfbPort     = 5901;            // 本地 RFB server 端口
static const NSInteger kDefaultTunnelPort = 18181;         // 默认隧道端口
static const size_t kFrameHeaderSize    = 5;               // 帧头大小：1(type)+4(length)
static const size_t kMaxFramePayload    = 16 * 1024 * 1024; // 单帧 payload 上限（16MB，防损坏帧耗尽内存）
static const size_t kReadBufSize        = 64 * 1024;       // 单次 read 缓冲（64KB）
static const NSTimeInterval kHandshakeTimeout = 10.0;      // 握手 ack 超时（秒）

// DIAG: file log for tunnel passthrough debugging (Filza at /tmp)
static void TRTunnelLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FILE *f = fopen("/tmp/trollvnc-tunnel.log", "a");
    if (f) {
        fprintf(f, "[%.0f] %s\n", [[NSDate date] timeIntervalSince1970], buf);
        fclose(f);
    }
}

@interface TRTunnelClient () {
    NSString *_host;           // 网关主机
    NSInteger _port;           // 网关隧道端口（默认 18181）
    NSString *_deviceId;       // 设备 ID（握手鉴权）
    NSString *_token;          // 网关鉴权 token（可为 nil）
    NSThread *_workerThread;   // 工作线程
    BOOL _started;             // 是否已启动
    BOOL _connected;           // 是否已连接（含握手成功）
    NSTimeInterval _retryDelay;   // 当前重连退避（秒）
    // 隧道帧解析缓冲（动态扩容）
    uint8_t *_frameBuf;
    size_t _frameBufLen;
    size_t _frameBufCap;
    BOOL _restartLocal;
    int _localFd;
}
@end

@implementation TRTunnelClient

#pragma mark - 单例与生命周期

/**
 * 获取共享单例（dispatch_once 保证线程安全一次性初始化）
 * @return TRTunnelClient 全局唯一实例
 */
+ (instancetype)sharedClient {
    static TRTunnelClient *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TRTunnelClient alloc] init];
    });
    return inst;
}

/**
 * 初始化隧道客户端，设置默认重连退避与端口
 * @return 实例对象
 */
- (instancetype)init {
    self = [super init];
    if (self) {
        _retryDelay = kTunnelMinRetryDelay;
        _port = kDefaultTunnelPort;
    }
    return self;
}

/**
 * 析构：释放帧缓冲内存
 */
- (void)dealloc {
    if (_frameBuf) {
        free(_frameBuf);
        _frameBuf = nil;
    }
}

/**
 * 启动隧道客户端，建立到网关 18181 的连接（异步，在工作线程内完成）
 * @param gatewayHost 网关主机地址
 * @param gatewayPort 网关隧道端口（默认 18181，传 0 或越界用默认值）
 * @param deviceId 设备 ID（用于鉴权握手）
 * @param token 网关鉴权 token（可为 nil）
 * @return YES 表示参数有效并已启动工作线程（异步连接）；NO 表示参数无效
 */
- (BOOL)startWithHost:(NSString *)gatewayHost
                 port:(NSInteger)gatewayPort
             deviceId:(NSString *)deviceId
                token:(NSString *)token {
    if (!gatewayHost.length || !deviceId.length) {
        TVLog(@"[tunnel] start rejected: invalid host/deviceId");
        return NO;
    }
    if (_started) {
        // 已启动：参数变化时先停止再重启，参数一致则幂等返回
        BOOL same = [_host isEqualToString:gatewayHost]
                    && _port == (gatewayPort > 0 ? gatewayPort : kDefaultTunnelPort)
                    && [_deviceId isEqualToString:deviceId];
        if (same) return YES;
        [self stop];
    }
    _host = [gatewayHost copy];
    _port = (gatewayPort > 0 && gatewayPort < 65536) ? gatewayPort : kDefaultTunnelPort;
    _deviceId = [deviceId copy];
    _token = [token copy];
    _retryDelay = kTunnelMinRetryDelay;
    _started = YES;
    _workerThread = [[NSThread alloc] initWithTarget:self selector:@selector(_workerMain) object:nil];
    [_workerThread setName:@"com.82flex.trollvnc.tunnel-client"];
    [_workerThread start];
    TVLog(@"[tunnel] client started -> %@:%ld deviceId=%@", _host, (long)_port, _deviceId);
    return YES;
}

/**
 * 停止隧道客户端，断开连接并退出工作线程
 */
- (void)stop {
    _started = NO;
    if (_workerThread) {
        [_workerThread cancel];
        _workerThread = nil;
    }
    _connected = NO;
    TVLog(@"[tunnel] client stopped");
}

/**
 * 隧道是否已连接（含握手成功）
 * @return YES 表示隧道已建立并完成握手
 */
- (BOOL)isConnected {
    return _connected;
}

#pragma mark - 工作线程主循环

/**
 * 工作线程主循环：反复连接网关并运行透传，失败按退避策略重连
 */
- (void)_workerMain {
    while (_started && ![[NSThread currentThread] isCancelled]) {
        @autoreleasepool {
            BOOL ok = [self _connectAndRun];
            if (!ok && _started) {
                TVLog(@"[tunnel] connection lost, retry in %.0fs", _retryDelay);
                usleep((useconds_t)(_retryDelay * 1e6));
                _retryDelay = MIN(_retryDelay * 2, kTunnelMaxRetryDelay);
            }
        }
    }
}

/**
 * 建立到网关的隧道连接并运行透传循环
 * 流程：TCP 连接 → 发 tunnel_hello → 收 tunnel_ack → 连本地 5901 → select 双向透传
 * @return YES 表示因 stop 正常退出（无需重连）；NO 表示连接异常断开（需重连）
 */
- (BOOL)_connectAndRun {
    _connected = NO;
    [self _resetFrameBuf];

    // 1. TCP 连接到网关隧道端口
    int tunnelFd = socket(AF_INET, SOCK_STREAM, 0);
    if (tunnelFd < 0) return NO;

    struct hostent *he = gethostbyname(_host.UTF8String);
    if (!he) { close(tunnelFd); return NO; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)_port);
    memcpy(&addr.sin_addr, he->h_addr, he->h_length);

    if (connect(tunnelFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(tunnelFd);
        return NO;
    }
    TVLog(@"[tunnel] connected to %@:%ld", _host, (long)_port);
    TRTunnelLog("tunnel connected %@:%ld", _host, (long)_port);

    // 2. 发送 tunnel_hello 握手
    if (![self _sendHandshakeHello:tunnelFd]) {
        close(tunnelFd);
        return NO;
    }

    // 3. 接收 tunnel_ack（JSON 行，握手阶段用行缓冲）
    BOOL ackOk = NO;
    if (![self _recvHandshakeAck:tunnelFd okOut:&ackOk]) {
        close(tunnelFd);
        return NO;
    }
    if (!ackOk) {
        TVLog(@"[tunnel] handshake rejected by gateway");
        close(tunnelFd);
        return NO;
    }
    TVLog(@"[tunnel] handshake ok, entering passthrough mode");
    _retryDelay = kTunnelMinRetryDelay;

    // 4. local RFB connected on demand (rfb.start); standby after handshake
    _localFd = -1;
    _connected = YES;
    TRTunnelLog("handshake ok, standby (local RFB on rfb.start)");

    // 5. select passthrough (standby: tunnel only)
    BOOL normalExit = [self _passthroughLoop:tunnelFd];

    // 6. cleanup
    _connected = NO;
    if (_localFd >= 0) { close(_localFd); _localFd = -1; }
    close(tunnelFd);
    [self _resetFrameBuf];
    return normalExit;
}

#pragma mark - 握手（JSON 行）

/**
 * 发送 tunnel_hello 握手 JSON 行
 * @param fd 隧道 socket fd
 * @return YES 表示发送成功
 */
- (BOOL)_sendHandshakeHello:(int)fd {
    NSMutableDictionary *hello = [NSMutableDictionary dictionary];
    hello[@"type"] = @"tunnel_hello";
    hello[@"deviceId"] = _deviceId;
    if (_token.length) hello[@"token"] = _token;
    NSData *json = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
    if (!json) return NO;
    NSMutableData *md = [json mutableCopy];
    const char nl = '\n';
    [md appendBytes:&nl length:1];
    ssize_t n = write(fd, md.bytes, md.length);
    return n == (ssize_t)md.length;
}

/**
 * 接收 tunnel_ack 握手响应（阻塞读直到 \n 或超时）
 * @param fd    隧道 socket fd
 * @param okOut 输出参数，接收 ack.ok 布尔值
 * @return YES 表示成功收到并解析 ack 行；NO 表示读取失败/超时/解析失败
 */
- (BOOL)_recvHandshakeAck:(int)fd okOut:(BOOL *)okOut {
    char buf[512];
    size_t len = 0;
    time_t deadline = time(NULL) + (time_t)kHandshakeTimeout;
    while (time(NULL) < deadline) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel <= 0) continue;  // 超时或中断，继续等
        ssize_t n = read(fd, buf + len, sizeof(buf) - len - 1);
        if (n <= 0) return NO;
        len += (size_t)n;
        buf[len] = '\0';
        char *nl = strchr(buf, '\n');
        if (nl) {
            *nl = '\0';
            NSData *data = [NSData dataWithBytes:buf length:strlen(buf)];
            NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![msg isKindOfClass:[NSDictionary class]]) return NO;
            if (![msg[@"type"] isEqualToString:@"tunnel_ack"]) return NO;
            *okOut = [msg[@"ok"] boolValue];
            // 换行后剩余字节可能是首个帧数据，追加到帧缓冲
            size_t consumed = (size_t)((nl - buf) + 1);
            if (len > consumed) {
                [self _appendFrameData:(const uint8_t *)(buf + consumed) length:(len - consumed)];
            }
            return YES;
        }
        if (len >= sizeof(buf) - 1) return NO;  // 超长无换行，异常
    }
    return NO;  // 超时
}

#pragma mark - 本地 RFB 连接

/**
 * 建立到本地 RFB server（127.0.0.1:5901）的 TCP 连接
 * @return 连接成功的 fd（>=0）；失败返回 -1
 */
- (int)_connectLocalRfb {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLocalRfbPort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

#pragma mark - 透传主循环（select 多路复用）

/**
 * select 多路复用双向透传循环
 * 隧道可读 → 帧解析 → DATA 写本地 5901 / PONG 重置心跳 / CMD 调 commandHandler 回 CMDACK
 * 本地 5901 可读 → 封装 DATA 帧写隧道
 * 每 30s 发 PING 心跳帧
 * @param tunnelFd 隧道 socket fd
 * @param localFd  本地 RFB socket fd
 * @return YES 表示因 stop 正常退出；NO 表示连接异常断开（需重连）
 */
- (BOOL)_passthroughLoop:(int)tunnelFd {
    uint8_t *readBuf = (uint8_t *)malloc(kReadBufSize);
    if (!readBuf) return NO;
    time_t lastPing = time(NULL);

    while (_started && ![[NSThread currentThread] isCancelled]) {
        // rfb.start/stop 已在命令解析处同步执行（关旧 fd/connect 5901 并回 ack），
        // 此处直接进入 select，避免标记驱动的延迟与重复重建。
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(tunnelFd, &rfds);
        int maxFd = tunnelFd;
        if (_localFd >= 0) { FD_SET(_localFd, &rfds); if (_localFd > maxFd) maxFd = _localFd; }
        struct timeval tv;
        tv.tv_sec = (time_t)kTunnelSelectTimeout;
        tv.tv_usec = 0;
        int sel = select(maxFd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            free(readBuf);
            return NO;
        }
        if (sel == 0) {
            // timeout: heartbeat
            time_t now = time(NULL);
            if (now - lastPing >= (time_t)kTunnelPingInterval) {
                if (![self _writeFrame:tunnelFd type:kFrameTypePing data:NULL length:0]) {
                    free(readBuf);
                    return NO;
                }
                lastPing = now;
            }
            continue;
        }
        // tunnel readable
        if (FD_ISSET(tunnelFd, &rfds)) {
            ssize_t n = read(tunnelFd, readBuf, kReadBufSize);
            if (n <= 0) { free(readBuf); return NO; }
            [self _appendFrameData:readBuf length:(size_t)n];
            TRTunnelLog("tunnel readable, read %zd bytes, frameBufLen=%zu", n, _frameBufLen);
            if (![self _processFramesTunnel:tunnelFd]) {
                TRTunnelLog("processFrames returned NO");
                free(readBuf);
                return NO;
            }
        }
        // local 5901 readable
        if (_localFd >= 0 && FD_ISSET(_localFd, &rfds)) {
            ssize_t n = read(_localFd, readBuf, kReadBufSize);
            if (n <= 0) {
                // 本地 5901 连接关闭（rfb.stop 或服务端断开）是正常事件：
                // 仅清理本地 fd 回 standby，绝不能退出隧道（否则隧道重连导致网关 4002 tunnel closed）
                close(_localFd);
                _localFd = -1;
                TRTunnelLog("local RFB closed (EOF), stay standby");
                continue;
            }
            TRTunnelLog("local readable, read %zd bytes, sending FT_DATA", n);
            if (![self _writeFrame:tunnelFd type:kFrameTypeData data:readBuf length:(size_t)n]) {
                TRTunnelLog("FT_DATA write to tunnel failed");
                free(readBuf);
                return NO;
            }
        }
    }
    free(readBuf);
    return YES;  // stop
}

#pragma mark - 帧封装/解析

/**
 * 向帧缓冲追加原始字节（隧道读到的数据，可能含多个/部分帧）
 * @param data 数据指针
 * @param len  数据长度
 */
- (void)_appendFrameData:(const uint8_t *)data length:(size_t)len {
    if (len == 0) return;
    size_t need = _frameBufLen + len;
    if (need > _frameBufCap) {
        size_t newCap = _frameBufCap ? _frameBufCap : 8192;
        while (newCap < need) newCap *= 2;
        uint8_t *p = (uint8_t *)realloc(_frameBuf, newCap);
        if (!p) {
            // 内存分配失败：丢弃缓冲防止状态混乱
            TVLog(@"[tunnel] frame buf alloc failed, resetting");
            [self _resetFrameBuf];
            return;
        }
        _frameBuf = p;
        _frameBufCap = newCap;
    }
    memcpy(_frameBuf + _frameBufLen, data, len);
    _frameBufLen += len;
}

/**
 * 重置帧解析缓冲（释放内存并清零计数）
 */
- (void)_resetFrameBuf {
    if (_frameBuf) {
        free(_frameBuf);
        _frameBuf = nil;
    }
    _frameBufLen = 0;
    _frameBufCap = 0;
}

/**
 * 处理帧缓冲中所有完整帧：
 *   DATA   → 写本地 RFB 5901
 *   PONG   → 心跳响应（链路存活即可）
 *   PING   → 回 PONG（双向保活）
 *   CMD    → 调 commandHandler 处理，回 CMDACK
 *   其它   → 忽略并告警
 * @param tunnelFd 隧道 fd（用于回 CMDACK/PONG）
 * @param localFd  本地 RFB fd（DATA 帧 payload 写入此处）
 * @return YES 表示处理正常（可继续）；NO 表示本地 RFB 写失败（需断开重连）
 */
- (BOOL)_processFramesTunnel:(int)tunnelFd {
    while (_frameBufLen >= kFrameHeaderSize) {
        uint8_t type = _frameBuf[0];
        uint32_t payloadLen = ((uint32_t)_frameBuf[1] << 24) | ((uint32_t)_frameBuf[2] << 16)
                            | ((uint32_t)_frameBuf[3] << 8) | (uint32_t)_frameBuf[4];
        if (payloadLen > kMaxFramePayload) {
            TVLog(@"[tunnel] frame too large (%u), resetting", payloadLen);
            [self _resetFrameBuf];
            return YES;
        }
        size_t total = kFrameHeaderSize + payloadLen;
        if (_frameBufLen < total) break;  // 不完整，等更多数据

        const uint8_t *payload = _frameBuf + kFrameHeaderSize;
        switch (type) {
            case kFrameTypeData:
                if (payloadLen > 0) {
                    // 写入本地 RFB（处理部分写）
                    size_t off = 0;
                    while (off < payloadLen) {
                        ssize_t w = write(_localFd, payload + off, payloadLen - off);
                        TRTunnelLog("DATA payloadLen=%u write local fd=%d -> %zd (off=%zu)", payloadLen, _localFd, w, off);
                        if (w <= 0) {
                            TVLog(@"[tunnel] write local RFB failed");
                            TRTunnelLog("write local RFB failed w=%zd errno=%d", w, errno);
                            return NO;
                        }
                        off += (size_t)w;
                    }
                }
                break;
            case kFrameTypePong:
                // 心跳响应：收到即表示链路存活
                break;
            case kFrameTypePing:
                // 网关主动 ping 时回 pong（双向保活）
                [self _writeFrame:tunnelFd type:kFrameTypePong data:NULL length:0];
                break;
            case kFrameTypeCmd: {
                // 命令帧：解析 JSON，调 commandHandler 处理，回 CMDACK
                NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:
                    [NSData dataWithBytes:payload length:payloadLen] options:0 error:NULL];
                if (![cmd isKindOfClass:[NSDictionary class]]) break;
                if ([[cmd objectForKey:@"cmd"] isEqualToString:@"rfb.start"]) {
                    // 全新 RFB 会话：同步重建本地 5901 连接（先关旧 fd 再 connect），
                    // ack 携带 connect 结果——网关据此精确放行缓冲的握手字节（替代固定窗口），
                    // connect 失败时网关显式报错，避免 noVNC 静默黑屏。
                    if (_localFd >= 0) { close(_localFd); _localFd = -1; }
                    _localFd = [self _connectLocalRfb];
                    BOOL ok = (_localFd >= 0);
                    TRTunnelLog("rfb.start: local connect -> fd=%d", _localFd);
                    if (!ok) { TVLog(@"[tunnel] rfb.start: local connect failed, keep standby"); }
                    NSDictionary *ack0 = @{ @"type": @"ack", @"cmd": @"rfb.start",
                                            @"id": cmd[@"id"] ?: [NSNull null], @"ok": @(ok) };
                    NSData *ackJson0 = [NSJSONSerialization dataWithJSONObject:ack0 options:0 error:NULL];
                    if (ackJson0) {
                        [self _writeFrame:tunnelFd type:kFrameTypeCmdAck data:ackJson0.bytes length:ackJson0.length];
                    }
                    break;
                }
                if ([[cmd objectForKey:@"cmd"] isEqualToString:@"rfb.stop"]) {
                    // 会话结束：同步关闭本地 5901 连接，回 standby
                    if (_localFd >= 0) {
                        TRTunnelLog("rfb.stop: closing local RFB fd=%d", _localFd);
                        close(_localFd);
                        _localFd = -1;
                    }
                    NSDictionary *ack0 = @{ @"type": @"ack", @"cmd": @"rfb.stop",
                                            @"id": cmd[@"id"] ?: [NSNull null], @"ok": @YES };
                    NSData *ackJson0 = [NSJSONSerialization dataWithJSONObject:ack0 options:0 error:NULL];
                    if (ackJson0) {
                        [self _writeFrame:tunnelFd type:kFrameTypeCmdAck data:ackJson0.bytes length:ackJson0.length];
                    }
                    break;
                }
                NSDictionary *ack = self.commandHandler ? self.commandHandler(cmd) : nil;
                if (!ack) {
                    ack = @{ @"type": @"ack",
                             @"id": cmd[@"id"] ?: [NSNull null],
                             @"ok": @NO,
                             @"error": @"no command handler" };
                }
                NSData *ackJson = [NSJSONSerialization dataWithJSONObject:ack options:0 error:NULL];
                if (ackJson) {
                    [self _writeFrame:tunnelFd type:kFrameTypeCmdAck data:ackJson.bytes length:ackJson.length];
                }
                break;
            }
            case kFrameTypeCmdAck:
                // 设备侧不主动发命令，CMDACK 帧忽略
                break;
            default:
                TVLog(@"[tunnel] unknown frame type 0x%02x, ignoring", type);
                break;
        }
        // 移除已处理帧
        size_t remain = _frameBufLen - total;
        if (remain > 0) {
            memmove(_frameBuf, _frameBuf + total, remain);
        }
        _frameBufLen = remain;
    }
    return YES;
}

/**
 * 写入一个帧到隧道 fd（type + 4字节大端 length + payload）
 * @param fd   隧道 socket fd
 * @param type 帧类型（DATA/PING/PONG/CMD/CMDACK）
 * @param data payload 指针（PING/PONG 可传 NULL）
 * @param len  payload 长度
 * @return YES 表示写入成功
 */
- (BOOL)_writeFrame:(int)fd type:(uint8_t)type data:(const void *)data length:(size_t)len {
    uint8_t header[kFrameHeaderSize];
    header[0] = type;
    header[1] = (uint8_t)((len >> 24) & 0xFF);
    header[2] = (uint8_t)((len >> 16) & 0xFF);
    header[3] = (uint8_t)((len >> 8) & 0xFF);
    header[4] = (uint8_t)(len & 0xFF);
    ssize_t n = write(fd, header, kFrameHeaderSize);
    if (n != (ssize_t)kFrameHeaderSize) return NO;
    if (len > 0 && data) {
        size_t off = 0;
        while (off < len) {
            ssize_t w = write(fd, (const uint8_t *)data + off, len - off);
            if (w <= 0) return NO;
            off += (size_t)w;
        }
    }
    return YES;
}

@end
