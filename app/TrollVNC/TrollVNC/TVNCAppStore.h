/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 网关连接状态机（Phase A：控制端唯一真相，替代「服务进程存活近似」）。
typedef NS_ENUM(NSInteger, TVNCGatewayState) {
    TVNCGatewayStateIdle = 0,        // 服务未运行/网关未配置（未拉取）
    TVNCGatewayStateServiceUp,       // 服务进程在跑、拉取进行中（网关可达性未定）
    TVNCGatewayStateRegistered,      // 网关设备目录已含 selfDeviceId（真注册成功）
    TVNCGatewayStateDisconnected,    // 网关不可达/拉取失败
};

/// 网关状态变化通知（object = TVNCAppStore）
FOUNDATION_EXPORT NSNotificationName const TVNCGatewayStateDidChangeNotification;
/// 设备目录更新通知（object = TVNCAppStore，含目录变化与拉取完成）
FOUNDATION_EXPORT NSNotificationName const TVNCDeviceDirectoryDidUpdateNotification;

/// 控制端状态层（单一数据源）：网关连接状态 + 设备目录缓存 + 结果驱动注册判定。
/// 全端共享同一份数据，页面只消费状态与事件，不各自拉取/判定。
@interface TVNCAppStore : NSObject

+ (instancetype)sharedStore;

/// 当前网关连接状态（默认 Idle）
@property (nonatomic, assign, readonly) TVNCGatewayState gatewayState;

/// 确保设备目录就绪（懒加载）：缓存有效（<60s）直接复用；无效则拉取并结果驱动重试。
/// 页面（连接页）出现时调用，幂等。
- (void)ensureDeviceDirectory;

@end

NS_ASSUME_NONNULL_END
