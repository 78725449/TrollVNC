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

/// 控制端页（Phase 12：Tab 2 卡片墙/详情列表双视图 + 多选批量配置）
/// 顶部导航：[全选☑] 设备墙 [批量操作] [宫格▾]
/// 帧获取：RFB 完整连接首帧（替代网关 invoke screenshot 缩略图方案）
@interface TVNCControllerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
