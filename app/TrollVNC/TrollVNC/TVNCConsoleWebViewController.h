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

/// 控制端 Web 容器（Phase 13）：控制 Tab 整页由 WKWebView 加载网关 H5 手机控制台。
/// 原生设备墙/大屏（TVNCControllerViewController / TVNCViewerViewController）已由 H5 完全替代并删除——
/// 所有交互组件（设备墙/聚焦大屏/批量操作/FAB 能力菜单/布局切换）统一由网页端渲染，
/// 与浏览器操作网页端完全一致；改 Web 端即生效（网关 no-cache + 版本号），App 容器自动同步。
///
/// URL 构造：https://{GatewayHost}:8080/?token={GatewayToken}&selfId={DeviceUUID}&container=ipa
///   - 8080    网关 web/API 端口（固定不可调，TVNCGatewayClient.gatewayPort）
///   - https   网关默认启用 TLS（自签证书，见 trollvnc-farm §2.3m），信任由 challenge 处理
///   - token    网关 API 鉴权（H5 的 app.js 优先读 URL 参数）
///   - selfId   本设备 DeviceUUID（H5 据此从设备墙过滤自身）
///   - container=ipa 容器模式标记（H5 据此分支容器差异行为）
@interface TVNCConsoleWebViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
