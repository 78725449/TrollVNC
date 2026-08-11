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

#import "AppDelegate.h"
#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"

/// 崩溃现场捕获：未捕获 NSException 时写入日志文件（Documents/crash.log + /tmp/trollvnc-crash.log）。
/// 用于无法连接 Console 的真机场景（TrollStore），下次崩溃后可从 App 数据容器或系统 /tmp 读取定位。
static void TVNCUncaughtExceptionHandler(NSException *exception) {
    NSArray *stack = exception.callStackSymbols;
    NSString *body = [NSString stringWithFormat:
        @"=== SuperPhone crash @ %@ ===\nName: %@\nReason: %@\nStack:\n%@\n",
        [NSDate date], exception.name, exception.reason,
        stack ? [stack componentsJoinedByString:@"\n"] : @"(no stack)"];
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count) {
        [data writeToFile:[dirs[0] stringByAppendingPathComponent:@"crash.log"]
                  options:NSDataWritingAtomic error:nil];
    }
    [data writeToFile:@"/tmp/trollvnc-crash.log" options:NSDataWritingAtomic error:nil];
}

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 崩溃现场捕获：任何未捕获异常先落盘再闪退，便于真机无法接 Console 时定位
    NSSetUncaughtExceptionHandler(&TVNCUncaughtExceptionHandler);
    // Override point for customization after application launch.
    [[TVNCServiceCoordinator sharedCoordinator] registerServiceMonitor];
    [[TVNCHotspotManager sharedManager] registerWithName:@"SuperPhone"];


    return YES;
}

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after
    // application:didFinishLaunchingWithOptions. Use this method to release any resources that were specific to the
    // discarded scenes, as they will not return.
}

@end
