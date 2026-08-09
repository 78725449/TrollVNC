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

/// 详情列表行 Cell（Phase 12.5 视图 2）：每设备一行
/// 左侧 40×40 缩略图 + 右侧设备信息（名称/IP/iOS 版本/在线状态/任务状态）+ ⋯ 按钮
@interface TVNCDeviceListCell : UITableViewCell

/// 缩略图（左侧 40×40）
@property (nonatomic, strong) UIImageView *thumbView;
/// 设备名
@property (nonatomic, strong) UILabel *nameLabel;
/// 副信息（IP + iOS 版本 / 最后在线时间）
@property (nonatomic, strong) UILabel *subLabel;
/// 在线状态圆点
@property (nonatomic, strong) UIView *dotView;
/// 任务状态标签（空闲 / 任务中 / 排队 / 失败）
@property (nonatomic, strong) UILabel *taskStatusLabel;
/// ⋯ 按钮（单台设备设置），tag=9528
@property (nonatomic, strong) UIButton *moreButton;
/// 多选模式 checkbox
@property (nonatomic, strong) UIButton *checkBox;
/// ⋯按钮点击回调（参数为 cell 自身）
@property (nonatomic, copy, nullable) void (^moreTapped)(TVNCDeviceListCell *cell);

/// 配置行内容
/// @param d        设备数据字典
/// @param thumb    缩略图（可为 nil）
/// @param selected 是否处于勾选状态（多选模式）
- (void)configureWithDevice:(NSDictionary *)d thumbnail:(UIImage *)thumb selected:(BOOL)selected;

@end

NS_ASSUME_NONNULL_END
