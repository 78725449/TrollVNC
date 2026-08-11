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

/// GET /api/devices?changedSince=<ms> → 该时刻后画面变化的设备（Phase C 增量通道，失败 nil）。
/// @param sinceMs    起始时刻（毫秒时间戳），仅返回 screenChangedAt 晚于该值的设备
/// @param completion 主线程回调
- (void)fetchChangedDevicesSince:(NSTimeInterval)sinceMs
                      completion:(void (^)(NSArray<NSDictionary *> *_Nullable devices))completion;

/// POST /api/devices/:id/invoke → ack 字典（失败 nil）。
/// @param capId      能力 ID（如 screen.hash/screenshot/home）
/// @param params     调用参数（可为 nil）
/// @param deviceId   目标设备 ID
/// @param completion 主线程回调
- (void)invokeCap:(NSString *)capId
           params:(NSDictionary *_Nullable)params
        forDevice:(NSString *)deviceId
       completion:(void (^)(NSDictionary *_Nullable ack))completion;

/// POST /api/devices/:id/ping → 往返延迟毫秒（失败/超时 -1）。
/// @param deviceId   目标设备 ID
/// @param completion 主线程回调
- (void)pingDevice:(NSString *)deviceId completion:(void (^)(NSTimeInterval ms))completion;

/// GET /api/devices/:id/caps → capMetadata 数组（失败 nil）。
/// @param deviceId   目标设备 ID
/// @param completion 主线程回调
- (void)fetchCapsForDevice:(NSString *)deviceId completion:(void (^)(NSArray<NSDictionary *> *_Nullable caps))completion;

/// GET /api/devices/:id/caps → configSchema 数组（失败 nil）。
/// @param deviceId   目标设备 ID
/// @param completion 主线程回调
- (void)fetchConfigSchemaForDevice:(NSString *)deviceId completion:(void (^)(NSArray<NSDictionary *> *_Nullable schema))completion;

/// POST /api/devices/:id/config → 是否下发成功。
/// @param key        配置键
/// @param value      配置值
/// @param deviceId   目标设备 ID
/// @param completion 主线程回调
- (void)setConfig:(NSString *)key value:(NSString *)value forDevice:(NSString *)deviceId completion:(void (^)(BOOL ok))completion;

@end

NS_ASSUME_NONNULL_END
