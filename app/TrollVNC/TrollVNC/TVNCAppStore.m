/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TVNCAppStore.h"
#import "TVNCGatewayClient.h"
#import "TVNCUtil.h"

NSNotificationName const TVNCGatewayStateDidChangeNotification = @"TVNCGatewayStateDidChangeNotification";
NSNotificationName const TVNCDeviceDirectoryDidUpdateNotification = @"TVNCDeviceDirectoryDidUpdateNotification";
/// 设备目录缓存有效期（秒）：缓存新鲜期内不重复拉取
static const NSTimeInterval kDirectoryCacheTTL = 60.0;
/// 结果驱动重试：起始间隔（秒）
static const NSTimeInterval kRetryStartInterval = 1.0;
/// 结果驱动重试：间隔封顶（秒）
static const NSTimeInterval kRetryMaxInterval = 15.0;
/// 结果驱动重试：最大次数（约 1+2+4+8+15×4 ≈ 75s 上限）
static const NSInteger kRetryMaxCount = 8;

@interface TVNCAppStore ()

@property (nonatomic, assign, readwrite) TVNCGatewayState gatewayState;
@property (nonatomic, copy, readwrite, nullable) NSArray<NSDictionary *> *deviceDirectory;
@property (nonatomic, copy, readwrite, nullable) NSDate *lastDirectoryFetchedAt;

/// 防重入：拉取进行中
@property (nonatomic, assign) BOOL fetching;
/// 重试计数
@property (nonatomic, assign) NSInteger retryCount;

@end

@implementation TVNCAppStore

+ (instancetype)sharedStore {
    static TVNCAppStore *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _gatewayState = TVNCGatewayStateIdle;
    }
    return self;
}

#pragma mark - Public

- (void)ensureDeviceDirectory {
    // 缓存新鲜：直接复用，不重复拉取（懒加载）
    if (self.deviceDirectory.count > 0 && self.lastDirectoryFetchedAt) {
        NSTimeInterval age = -[self.lastDirectoryFetchedAt timeIntervalSinceNow];
        if (age < kDirectoryCacheTTL) return;
    }
    // 网关未配置：无拉取必要，保持 Idle
    if (![[TVNCGatewayClient sharedClient] gatewayHost].length) return;
    [self fetchWithRetry];
}

- (BOOL)isRegistered {
    // 动态读取（不缓存）：设备端 trollvncmanager 以 root 生成 UUID 于 root 用户域，见 TVNCReadSelfDeviceId
    NSString *did = TVNCReadSelfDeviceId();
    if (!did.length) return NO;
    for (NSDictionary *d in self.deviceDirectory) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        if ([d[@"id"] isEqualToString:did]) return YES;
    }
    return NO;
}

#pragma mark - 结果驱动拉取

/// 拉取设备目录（结果驱动重试，替代固定延迟等待注册完成）。
/// 结果语义：
///   - 成功且列表含 selfDeviceId → Registered（注册完成，停止重试）
///   - 成功但不含自身 → 网关可达、注册进行中 → 退避重试（1→2→4→8→15s 封顶）
///   - 失败 → 网关不可达 → Disconnected + 退避重试
- (void)fetchWithRetry {
    if (self.fetching) return; // 防重入：已有拉取在途，等待其回调续排
    self.retryCount = 0;
    self.fetching = YES;
    [self setGatewayState:TVNCGatewayStateServiceUp]; // 拉取进行中（非 Registered 时进入检测态）
    [self performFetch];
}

/// 执行单次拉取并按结果判定状态/续排重试。
- (void)performFetch {
    __weak typeof(self) weakSelf = self;
    [[TVNCGatewayClient sharedClient] fetchDevicesWithCompletion:^(NSArray<NSDictionary *> *devices, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.fetching = NO;

        if (devices) {
            // 网关可达：更新目录缓存（无论是否含自身，目录对控制端始终有效）
            BOOL directoryChanged = ![strongSelf isSameDirectory:devices];
            strongSelf.deviceDirectory = devices;
            strongSelf.lastDirectoryFetchedAt = [NSDate date];
            if (directoryChanged) {
                [[NSNotificationCenter defaultCenter] postNotificationName:TVNCDeviceDirectoryDidUpdateNotification
                                                                    object:strongSelf];
            }
            if ([strongSelf isRegistered]) {
                [strongSelf setGatewayState:TVNCGatewayStateRegistered]; // 注册完成：真「已连接」
                return;
            }
            // 网关可达但本设备尚未注册（注册进行中）：退避重试
            [strongSelf retryIfNeeded];
        } else {
            [strongSelf setGatewayState:TVNCGatewayStateDisconnected];
            [strongSelf retryIfNeeded];
        }
    }];
}

/// 退避重试：间隔 1→2→4→8→15s 封顶，最多 kRetryMaxCount 次后停止（等手动刷新/下次 ensure）。
- (void)retryIfNeeded {
    if (self.retryCount >= kRetryMaxCount) return;
    NSTimeInterval delay = MIN(kRetryStartInterval * (1 << self.retryCount), kRetryMaxInterval);
    self.retryCount++;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.fetching) return; // 期间已有手动刷新在途
        strongSelf.fetching = YES;
        [strongSelf performFetch];
    });
}

#pragma mark - Helpers

/// 目录内容是否变化（按设备 id 集合比较，忽略顺序）。
/// 类型安全：逐个取 id 并过滤非字符串/NSNull 元素（valueForKey: 遇 NSNull 会抛 NSUnknownKeyException）。
- (BOOL)isSameDirectory:(NSArray<NSDictionary *> *)newList {
    NSMutableArray<NSString *> *oldIds = [NSMutableArray array];
    for (id obj in self.deviceDirectory) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        id i = obj[@"id"];
        if ([i isKindOfClass:[NSString class]] && [(NSString *)i length]) [oldIds addObject:i];
    }
    NSMutableArray<NSString *> *newIds = [NSMutableArray array];
    for (id obj in newList) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        id i = obj[@"id"];
        if ([i isKindOfClass:[NSString class]] && [(NSString *)i length]) [newIds addObject:i];
    }
    NSSet<NSString *> *oldIdSet = [NSSet setWithArray:oldIds];
    NSSet<NSString *> *newIdSet = [NSSet setWithArray:newIds];
    return [oldIdSet isEqual:newIdSet];
}

/// 设置状态并仅在变化时发通知。
- (void)setGatewayState:(TVNCGatewayState)state {
    if (_gatewayState == state) return;
    _gatewayState = state;
    [[NSNotificationCenter defaultCenter] postNotificationName:TVNCGatewayStateDidChangeNotification
                                                        object:self];
}

@end
