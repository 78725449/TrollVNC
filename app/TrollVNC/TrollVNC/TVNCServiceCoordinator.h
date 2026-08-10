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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TVNCServiceStatusDidChangeNotification;

// 设备唯一标识（硬件 UDID；拿不到时回退注册 UUID）
FOUNDATION_EXPORT NSString *TVNCDeviceUDID(void);


@interface TVNCServiceCoordinator : NSObject

@property(nonatomic, assign, getter=isServiceRunning) BOOL serviceRunning;

+ (instancetype)sharedCoordinator;
- (void)registerServiceMonitor;
- (void)ensureServiceRunning;

@end

NS_ASSUME_NONNULL_END
