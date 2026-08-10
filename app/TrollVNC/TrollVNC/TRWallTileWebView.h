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
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 卡片墙 RFB 连接状态
typedef NS_ENUM(NSInteger, TRWallTileState) {
    TRWallTileStateIdle,       ///< 空闲（未连接）
    TRWallTileStateConnecting, ///< 连接中
    TRWallTileStateConnected,  ///< 已连接（画面正常渲染）
    TRWallTileStateFailed,     ///< 连接失败
};

/**
 * 卡片墙 RFB 连接管理器（Phase 12.1 卡片墙 WKWebView 改造）。
 * 封装 WKWebView + noVNC 实现完整 RFB 连接（viewOnly 只读），用于设备卡片墙实时画面渲染。
 * 支持帧率节流控制、连接状态回调、隧道/直连 URL 构造。
 */
@interface TRWallTileWebView : UIView

/// 当前连接状态
@property (nonatomic, assign, readonly) TRWallTileState state;
/// 帧率节流间隔（毫秒），0=不限制（实时渲染），默认 0
@property (nonatomic, assign) NSInteger frameInterval;
/// 状态变化回调（main queue），首次连接成功 / 断开 / 失败时触发
@property (nonatomic, copy, nullable) void (^onStateChange)(TRWallTileState state);

/**
 * 初始化卡片墙 WebView。
 * @param frame 初始 frame
 * @return 实例
 */
- (instancetype)initWithFrame:(CGRect)frame NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/**
 * 启动 RFB 连接（隧道优先，直连回退）。
 * @param deviceId     设备 ID（用于隧道模式 /ws/vnc/:id）
 * @param gatewayHost  网关地址（隧道模式必填）
 * @param gatewayPort  网关 HTTP 端口（隧道模式必填，如 8080）
 * @param token        认证 token（可选）
 * @param host         设备直连 IP（直连回退时使用）
 * @param port         设备直连 RFB 端口（直连回退时使用，如 5901）
 */
- (void)startWithDeviceId:(NSString *)deviceId
              gatewayHost:(nullable NSString *)gatewayHost
              gatewayPort:(NSInteger)gatewayPort
                    token:(nullable NSString *)token
                     host:(nullable NSString *)host
                     port:(int)port;

/**
 * 断开 RFB 连接并清理 WebView 资源。
 */
- (void)stop;

/**
 * 设置帧率节流间隔，通过 JS 注入到 noVNC 桥接页面。
 * @param interval 间隔毫秒数，0=不限制
 */
- (void)setFrameRate:(NSInteger)interval;

@end

NS_ASSUME_NONNULL_END