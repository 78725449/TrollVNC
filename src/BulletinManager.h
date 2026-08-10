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

#ifndef BulletinManager_h
#define BulletinManager_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BulletinManager : NSObject

+ (instancetype)sharedManager;
- (instancetype)init NS_UNAVAILABLE;

- (void)popBannerWithContent:(NSString *)messageContent userInfo:(NSDictionary *_Nullable)userInfo;
- (void)updateSingleBannerWithContent:(NSString *)messageContent
                           badgeCount:(NSInteger)badgeCount
                             userInfo:(NSDictionary *_Nullable)userInfo;

- (void)revokeSingleNotification;
- (void)revokeAllNotifications;

@end

NS_ASSUME_NONNULL_END

#endif /* BulletinManager_h */