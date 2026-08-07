/*
 This file is part of TrollVNC
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

@end

NS_ASSUME_NONNULL_END
