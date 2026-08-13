/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 网关 HTTP 客户端（服务层，Phase B）：封装全部网关 REST 调用，
/// 统一超时（6s/4s）、Token 注入、主线程回调与显式错误透传。
/// 配置从 NSUserDefaults(com.82flex.trollvnc) 实时读取——设置是唯一默认源，代码不做选择。
@interface TVNCGatewayClient : NSObject

+ (instancetype)sharedClient;

/// 当前网关地址（未配置返回 nil，设置是唯一默认源）
- (nullable NSString *)gatewayHost;

/// 当前网关 HTTP 端口（未配置回退默认 8080）
- (NSInteger)gatewayPort;

/// 当前网关 Token（可为空字符串）
- (nullable NSString *)gatewayToken;

/// GET /api/devices → 设备列表（失败返回 nil + error，显式报错不静默降级）。
/// @param completion 主线程回调
- (void)fetchDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *_Nullable devices, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
