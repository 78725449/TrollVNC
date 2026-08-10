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

/// 控制端 Viewer（Phase 5.1）：基于 WKWebView + noVNC（WebSocket）渲染远端画面并注入操作，
/// 替代原 libvncclient C 库直连方案，与网关/Web 端统一技术栈。
@interface TVNCViewerViewController : UIViewController

/// 初始化 Viewer。
/// @param host 目标主机（设备 IP 或网关地址）
/// @param port RFB 端口（如 5901），内部按 VNC 约定换算为 WebSocket 端口（5901→5801）
/// @param name 设备显示名称（用于状态栏标题）
/// @return Viewer 视图控制器实例
- (instancetype)initWithHost:(NSString *)host port:(int)port name:(NSString *)name;

/// Phase 7：是否走网关隧道模式（YES=通过网关 8080 /ws/vnc/:deviceId 桥接隧道，跨网络）
/// 隧道模式下 host=网关地址、port=网关 HTTP 端口（8080），需同时设置 deviceId。
@property (nonatomic, assign) BOOL useGatewayTunnel;

/// Phase 7：隧道模式下的目标设备 ID（构造 /ws/vnc/:deviceId URL 使用）
@property (nonatomic, copy, nullable) NSString *deviceId;

@end

NS_ASSUME_NONNULL_END
