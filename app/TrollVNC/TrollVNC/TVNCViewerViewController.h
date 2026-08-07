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

/// 控制端 Viewer（U4）：经 libvncclient 直连设备 5901，显示画面并注入操作
@interface TVNCViewerViewController : UIViewController

- (instancetype)initWithHost:(NSString *)host port:(int)port name:(NSString *)name;

/// 由 libvncclient 帧回调调用（RFB 线程），标记有新帧可渲染
- (void)markFrameReady;

@end

NS_ASSUME_NONNULL_END
