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

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVNCClientListController : UITableViewController

@property(nonatomic, strong) NSBundle *bundle;
@property(nonatomic, strong) UIColor *primaryColor;
@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
/// 嵌入 Tab 时隐藏右上角关闭按钮（默认 NO）
@property(nonatomic, assign) BOOL hideDismissButton;
/// 嵌入卡片时：隐藏导航按钮、禁用下拉刷新（默认 NO）
@property(nonatomic, assign) BOOL embedded;
/// 列表变化回调（在线数 / 冻结数）
@property(nonatomic, copy) void (^onCountChange)(NSInteger onlineCount, NSInteger frozenCount);

/// 立即重新拉取列表
- (void)refreshNow;
/// 断开全部客户端（供嵌入卡片头部按钮调用）
- (void)disconnectAllClients;
/// 冻结（断开 + 加入黑名单并本地记录）
- (void)freezeClientWithId:(NSString *)cid;
/// 解冻（移除黑名单并清除本地记录）
- (void)unfreezeHost:(NSString *)host;

@end

NS_ASSUME_NONNULL_END
