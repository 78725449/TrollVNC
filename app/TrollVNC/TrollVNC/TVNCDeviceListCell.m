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

#import "TVNCDeviceListCell.h"
#import "TVNCUtil.h"

/// 紫色主题色（与 TRMainTabBarController 一致）
static UIColor *TRPurpleColor(void) {
    return [UIColor colorWithRed:(107.0 / 255.0) green:(78.0 / 255.0) blue:(255.0 / 255.0) alpha:1.0];
}

@implementation TVNCDeviceListCell

/// 初始化并构建行布局：缩略图(40×40) + 名称/副信息/任务状态 + ⋯按钮 + checkbox。
/// @param style    表格样式
/// @param reuseIdentifier 复用标识
/// @return cell 实例
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryNone;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _checkBox = [UIButton buttonWithType:UIButtonTypeSystem];
        _checkBox.translatesAutoresizingMaskIntoConstraints = NO;
        _checkBox.tintColor = TRPurpleColor();
        _checkBox.hidden = YES;
        [_checkBox setImage:[UIImage systemImageNamed:@"circle"] forState:UIControlStateNormal];
        [_checkBox setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateSelected];
        _checkBox.userInteractionEnabled = NO;
        [self.contentView addSubview:_checkBox];

        _thumbView = [[UIImageView alloc] init];
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.layer.cornerRadius = 8;
        _thumbView.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
        _thumbView.tintColor = [UIColor systemGrayColor];
        [self.contentView addSubview:_thumbView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];

        _subLabel = [[UILabel alloc] init];
        _subLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subLabel.font = [UIFont systemFontOfSize:12];
        _subLabel.textColor = [UIColor secondaryLabelColor];
        _subLabel.numberOfLines = 1;
        [self.contentView addSubview:_subLabel];

        _dotView = [[UIView alloc] init];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        _dotView.layer.cornerRadius = 4;
        [self.contentView addSubview:_dotView];

        _taskStatusLabel = [[UILabel alloc] init];
        _taskStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _taskStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _taskStatusLabel.textColor = [UIColor systemGrayColor];
        _taskStatusLabel.text = @"空闲";
        [self.contentView addSubview:_taskStatusLabel];

        _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _moreButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        _moreButton.tintColor = [UIColor secondaryLabelColor];
        _moreButton.tag = 9527;
        [_moreButton addTarget:self action:@selector(moreButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_moreButton];

        [NSLayoutConstraint activateConstraints:@[
            [_checkBox.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_checkBox.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkBox.widthAnchor constraintEqualToConstant:24],
            [_checkBox.heightAnchor constraintEqualToConstant:24],

            [_thumbView.leadingAnchor constraintEqualToAnchor:_checkBox.trailingAnchor constant:10],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_thumbView.widthAnchor constraintEqualToConstant:40],
            [_thumbView.heightAnchor constraintEqualToConstant:40],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:10],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_taskStatusLabel.leadingAnchor constant:-8],

            [_subLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_subLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
            [_subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_moreButton.leadingAnchor constant:-8],

            [_dotView.leadingAnchor constraintEqualToAnchor:_subLabel.trailingAnchor constant:6],
            [_dotView.centerYAnchor constraintEqualToAnchor:_subLabel.centerYAnchor],
            [_dotView.widthAnchor constraintEqualToConstant:8],
            [_dotView.heightAnchor constraintEqualToConstant:8],

            [_taskStatusLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
            [_taskStatusLabel.trailingAnchor constraintEqualToAnchor:_moreButton.leadingAnchor constant:-6],

            [_moreButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_moreButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_moreButton.widthAnchor constraintEqualToConstant:28],
            [_moreButton.heightAnchor constraintEqualToConstant:28],

            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:64],
        ]];
    }
    return self;
}

/// ⋯按钮点击事件：触发 moreTapped block 回调通知控制器弹出单台设备设置菜单。
- (void)moreButtonTapped {
    if (self.moreTapped) {
        self.moreTapped(self);
    }
}

/// 配置行内容：设备名、副信息（IP+iOS 版本 / 最后在线时间）、在线状态、缩略图、勾选态。
/// @param d        设备数据字典（含 name/id/host/online/lastSeen 等）
/// @param thumb    缩略图（可为 nil，为空时显示 iphone 占位图标）
/// @param multiMode 是否处于多选模式（仅多选时显示行首复选框）
/// @param selected 是否处于勾选状态
- (void)configureWithDevice:(NSDictionary *)d thumbnail:(UIImage *)thumb
                   multiMode:(BOOL)multiMode selected:(BOOL)selected {
    BOOL online = [d[@"online"] boolValue];
    self.nameLabel.text = d[@"name"] ?: d[@"id"] ?: @"?";

    // 副信息：在线显示 IP + iOS 版本；离线显示最后在线时间
    NSString *ip = d[@"host"] ?: @"";
    NSString *ios = d[@"iosVersion"] ?: @"";
    if (online) {
        NSMutableArray *parts = [NSMutableArray array];
        if (ip.length) [parts addObject:ip];
        if (ios.length) [parts addObject:[NSString stringWithFormat:@"iOS %@", ios]];
        self.subLabel.text = parts.count ? [parts componentsJoinedByString:@" · "] : @"已连接";
    } else {
        NSString *lastSeen = TVNCFormatLastSeen(d[@"lastSeen"] ?: d[@"lastOnline"]);
        self.subLabel.text = lastSeen.length ? [NSString stringWithFormat:@"最后在线 %@", lastSeen] : @"离线";
    }

    self.dotView.backgroundColor = online ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    // 最右侧状态文字：在线/离线（替代预留的"空闲"）
    self.taskStatusLabel.text = online ? @"在线" : @"离线";
    self.taskStatusLabel.textColor = online ? [UIColor systemGreenColor] : [UIColor systemGrayColor];

    // checkbox：仅多选模式显示（正常浏览时不出现，避免遮挡画面）
    self.checkBox.selected = selected;
    self.checkBox.hidden = !multiMode;

    // 缩略图
    if (thumb) {
        self.thumbView.image = thumb;
        self.thumbView.contentMode = UIViewContentModeScaleAspectFill;
        // 离线设备画面置灰
        self.thumbView.alpha = online ? 1.0 : 0.4;
    } else {
        self.thumbView.image = [UIImage systemImageNamed:@"iphone"];
        self.thumbView.contentMode = UIViewContentModeScaleAspectFit;
        self.thumbView.alpha = online ? 0.5 : 0.25;
    }
}

/// 复用前清理旧内容，避免图片错位。
- (void)prepareForReuse {
    [super prepareForReuse];
    self.thumbView.image = nil;
    self.nameLabel.text = nil;
    self.subLabel.text = nil;
}

@end
