/*
  TRGatewayClient - 内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）
  功能：读取预置网关配置(GatewayHost / GatewayToken)，生成并持久化设备 UUID，
       连接网关注册端口(固定 18081)，register 仅上报连接信息 + configs（2026-08-13，
       宪法 7.3），定时 hello，断线退避重连；设置变更时重发 register 保持 configs 新鲜。
       端口固定不可调：18081 注册 / 5901 VNC / 5801 HTTP 硬编码，不读 GatewayPort/Port/HttpPort。
*/
#ifndef TRGatewayClient_h
#define TRGatewayClient_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TRWatchDog;

@interface TRGatewayClient : NSObject

+ (instancetype)sharedClient;

/// 读取 com.82flex.trollvnc 配置并开始连接（幂等）
- (void)start;

/// 停止连接与重连
- (void)stop;

/// 设置服务重启处理器（由 trollvncmanager 注入，restart 命令触发）
/// @param handler 返回 YES 表示重启已发起
@property(nonatomic, copy, nullable) BOOL (^restartHandler)(void);

/// 服务进程守护实例（由 trollvncmanager 注入，供 service.* 能力访问属性与方法）
@property(nonatomic, strong, nullable) TRWatchDog *watchdog;

/// 网关连接状态（供 gateway.isConnected 能力查询）
@property(nonatomic, readonly) BOOL isConnected;

/// 当前重连退避延迟（秒，供 gateway.isConnected 能力查询）
@property(nonatomic, readonly) NSTimeInterval retryDelay;

/// 设备元数据快照（供 gateway.deviceInfo 能力查询）
@property(nonatomic, readonly) NSDictionary *deviceInfo;

@end

NS_ASSUME_NONNULL_END

#endif /* TRGatewayClient_h */
