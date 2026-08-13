/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "TVNCServiceCoordinator.h"
#import "TRTask.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MobileCoreServices/LSApplicationProxy.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <dlfcn.h>

#import "Control.h"

NSNotificationName const TVNCServiceStatusDidChangeNotification = @"TVNCServiceStatusDidChangeNotification";

static NSString *const kTVNCBGRefreshIdentifier = @"com.82flex.trollvnc.refresh";

FOUNDATION_EXPORT NSString *const SBSApplicationLaunchOptionUnlockDeviceKey;
FOUNDATION_EXPORT
int SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(CFStringRef bundleIdentifier, CFURLRef url,
                                                             CFDictionaryRef appOptions, CFDictionaryRef launchOptions,
                                                             BOOL suspended);

@interface TVNCServiceCoordinator ()
@property(nonatomic, strong) NSTimer *checkTimer;
@property(nonatomic, strong) NSUserDefaults *userDefaults;
@end

NSString *TVNCDeviceUDID(void) {
    static NSString *sUDID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (handle) {
            CFStringRef (*mgCopyAnswer)(CFStringRef) = (CFStringRef(*)(CFStringRef))dlsym(handle, "MGCopyAnswer");
            if (mgCopyAnswer) {
                CFStringRef v = mgCopyAnswer(CFSTR("UniqueDeviceID"));
                if (v) {
                    sUDID = (__bridge_transfer NSString *)v;
                }
            }
        }
        if (!sUDID.length) {
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
            sUDID = [d stringForKey:@"DeviceUUID"] ?: @"";
        }
    });
    return sUDID;
}

@implementation TVNCServiceCoordinator

+ (instancetype)sharedCoordinator {
    static TVNCServiceCoordinator *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (NSDictionary *)sharedTaskEnvironment {
    static NSDictionary *sharedEnvironment = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *env =
            [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
        NSString *languageCode = [[NSLocale preferredLanguages] firstObject];
        if (languageCode) {
            env[@"TVNC_LANGUAGE_CODE"] = languageCode;
        }
        // ??????????? trollvncmanager?manager ? root persona ???
        // ??? App ????? defaults suite???????????TRGatewayClient ?????
        NSUserDefaults *gwDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
        NSString *gwHost = [gwDefaults stringForKey:@"GatewayHost"];
        if (gwHost.length) {
            env[@"TVNC_GATEWAY_HOST"] = gwHost;
            // GatewayPort 固定 18081（网关注册端口）不可调，不注入 env（TRGatewayClient 固定读取）
            NSString *gwToken = [gwDefaults stringForKey:@"GatewayToken"];
            if (gwToken.length) env[@"TVNC_GATEWAY_TOKEN"] = gwToken;
        }
#if TARGET_IPHONE_SIMULATOR
        [env addEntriesFromDictionary:[[NSProcessInfo processInfo] environment]];
#endif
        sharedEnvironment = [env copy];
    });
    return sharedEnvironment;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _checkTimer = nil;
    _serviceRunning = NO;
    _userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];

    NSBundle *prefsBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                     ofType:@"bundle"]];

    // 自然滚动方向默认开启（未显式设置过时写入，保证服务端真实生效）
    if ([_userDefaults objectForKey:@"NaturalScroll"] == nil) {
        [_userDefaults setBool:YES forKey:@"NaturalScroll"];
        [_userDefaults synchronize];
    }

    // 设备名称统一使用“关于本机”的真实名称（设置项已移除，注册/VNC 桌面名/mDNS 保持一致）
    NSString *realDeviceName = [[UIDevice currentDevice] name];
    if (realDeviceName.length) {
        [_userDefaults setObject:realDeviceName forKey:@"DesktopName"];
        [_userDefaults synchronize];
    }

    // 设备唯一标识：首次启动用硬件 UDID 作为设备身份（注册/去重/展示一致）
    if (![_userDefaults stringForKey:@"DeviceUUID"].length) {
        NSString *udid = TVNCDeviceUDID();
        if (udid.length) {
            [_userDefaults setObject:udid forKey:@"DeviceUUID"];
            [_userDefaults synchronize];
        }
    }

    NSString *presetPath = [prefsBundle pathForResource:@"Managed" ofType:@"plist"];
    if (presetPath) {
        NSDictionary *presetDefaults = [NSDictionary dictionaryWithContentsOfFile:presetPath];
        if (presetDefaults) {
            [_userDefaults registerDefaults:presetDefaults];
        }
    }

    // HTTP 端口固定 5801（前端入口）不可调，由 trollvncserver 硬编码，无需写 defaults
}

#pragma mark - Public Methods

- (void)registerServiceMonitor {
    [_checkTimer invalidate];
    [self checkTimerFired:nil];
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                   target:self
                                                 selector:@selector(checkTimerFired:)
                                                 userInfo:nil
                                                  repeats:YES];
    [self registerBackgroundTasks];
}

- (BOOL)isServiceRunning {
    return _serviceRunning;
}

#pragma mark - Background Refresh (BGTaskScheduler, 延长锁屏存活)

- (void)registerBackgroundTasks {
    if (@available(iOS 13.0, *)) {
        [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:kTVNCBGRefreshIdentifier
                                                             usingQueue:nil
                                                          launchHandler:^(BGTask *task) {
            [self handleBGRefreshTask:(BGAppRefreshTask *)task];
        }];
        [self scheduleBGRefresh];
    }
}

- (void)scheduleBGRefresh {
    if (@available(iOS 13.0, *)) {
        BGAppRefreshTaskRequest *request =
            [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kTVNCBGRefreshIdentifier];
        request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:15 * 60];
        NSError *error = nil;
        [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
    }
}

- (void)handleBGRefreshTask:(BGAppRefreshTask *)task {
    // iOS 唤醒本 App 的窗口内：确保 manager（含注册/心跳客户端）存活，掉线即重新拉起
    [self ensureServiceRunning];

    __weak typeof(self) weakSelf = self;
    task.expirationHandler = ^{
        [task setTaskCompletedWithSuccess:NO];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [task setTaskCompletedWithSuccess:YES];
        [weakSelf scheduleBGRefresh];
    });
}

#pragma mark - Private Methods

- (void)checkTimerFired:(NSTimer *_Nullable)timer {
    [self ensureServiceRunning];
}

- (void)ensureServiceRunning {
    BOOL running = [self _isServiceRunning];
    if (!running) {
        [self checkPrebootDependencies];
        [self spawnService];
    }
    if (_serviceRunning != running) {
        _serviceRunning = running;
        [[NSNotificationCenter defaultCenter] postNotificationName:TVNCServiceStatusDidChangeNotification object:self];
    }
}

- (BOOL)_isServiceRunning {
#if TARGET_IPHONE_SIMULATOR
    return YES;
#else
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return NO;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvAlivePort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
    close(sockfd);

    return result == 0;
#endif
}

- (void)spawnService {
    static TRTask *serviceTask = nil;
    serviceTask = [[TRTask alloc] init];

    NSString *executablePath = [[NSBundle mainBundle] pathForResource:@"trollvncmanager" ofType:@""];
    if (!executablePath) {
        return;
    }

    [serviceTask setExecutableURL:[NSURL fileURLWithPath:executablePath]];

#if !TARGET_IPHONE_SIMULATOR
    [serviceTask setUserIdentifier:0];
    [serviceTask setGroupIdentifier:0];
#endif

    [serviceTask setArguments:[NSArray array]];
    [serviceTask setEnvironment:[TVNCServiceCoordinator sharedTaskEnvironment]];

    NSError *error = nil;
    BOOL launched = [serviceTask launchAndReturnError:&error];
    if (!launched) {
#if DEBUG
        NSLog(@"[TVNC] Failed to launch service: %@", error);
#endif
        return;
    }

    int unused;
    waitpid(serviceTask.processIdentifier, &unused, WNOHANG);
}

- (void)checkPrebootDependencies {
#if !TARGET_IPHONE_SIMULATOR
    id configVal = [_userDefaults objectForKey:@"LaunchAtLogin"];

    NSString *appId = nil;
    if ([configVal isKindOfClass:[NSNumber class]]) {
        BOOL launchAtLogin = [(NSNumber *)configVal boolValue];
        if (launchAtLogin) {
            appId = [[NSBundle mainBundle] bundleIdentifier];
        }
    } else if ([configVal isKindOfClass:[NSString class]]) {
        appId = (NSString *)configVal;
    } else if ([configVal isKindOfClass:[NSArray class]]) {
        NSArray *appIds = (NSArray *)configVal;
        for (NSString *candidateAppId in appIds) {
            LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:candidateAppId];
            if (![appProxy isInstalled]) {
                continue;
            }
            appId = candidateAppId;
        }
    }

    if (!appId) {
        return;
    }

    NSDate *lastLaunch = [_userDefaults objectForKey:@"LastPrebootLaunch"];
    if (lastLaunch) {
        // Compare with device uptime
        NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
        NSDate *bootTime = [NSDate dateWithTimeIntervalSinceNow:-uptime];
        if ([lastLaunch compare:bootTime] == NSOrderedDescending) {
            // Already launched since last boot
            return;
        }
    }

    UInt32 result;
    result = SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        (__bridge CFStringRef)appId, NULL, NULL,
        (__bridge CFDictionaryRef) @{SBSApplicationLaunchOptionUnlockDeviceKey : @YES}, NO);

    if (result == 0) {
        NSDate *now = [NSDate date];
        [_userDefaults setObject:now forKey:@"LastPrebootLaunch"];
        [_userDefaults synchronize];
    }
#endif
}

@end
