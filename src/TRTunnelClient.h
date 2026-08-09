#import <Foundation/Foundation.h>

/**
 * TRTunnelClient - 设备侧隧道客户端
 * 功能：设备注册到网关成功后，自动建立到网关 18181 端口的隧道连接，
 *       用于跨网络访问时的 RFB/控制流量透传。
 * 单例模式，仿 TRGatewayClient 连接管理风格。
 */
@interface TRTunnelClient : NSObject

/** 获取共享单例 */
+ (instancetype)sharedClient;

/** 隧道是否已连接 */
@property (nonatomic, readonly) BOOL isConnected;

/**
 * 启动隧道客户端，建立到网关 18181 的连接
 * @param gatewayHost 网关主机地址
 * @param gatewayPort 网关隧道端口（默认 18181）
 * @param deviceId 设备 ID（用于鉴权握手）
 * @param token 网关鉴权 token（可为 nil）
 * @return YES 表示启动成功（异步连接），NO 表示参数无效
 */
- (BOOL)startWithHost:(NSString *)gatewayHost
                 port:(NSInteger)gatewayPort
             deviceId:(NSString *)deviceId
                token:(NSString *)token;

/** 停止隧道客户端，断开连接 */
- (void)stop;

/**
 * 命令处理器（隧道 CMD 帧到达时调用，返回 ack 字典）
 * 由 TRGatewayClient 注入，复用现有命令处理逻辑（query/set/invoke/restart/ping）。
 * @param cmd 网关通过隧道下发的命令字典（{type:"cmd", cmd, id, ...}）
 * @return ack 字典（{type:"ack", cmd, id, ok, ...}），将通过 CMDACK 帧回传网关
 */
@property (nonatomic, copy, nullable) NSDictionary *(^commandHandler)(NSDictionary *cmd);

@end
