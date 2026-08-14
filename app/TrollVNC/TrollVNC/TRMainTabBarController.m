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

#import "TRMainTabBarController.h"
#import "TVNCConnectViewController.h"
#import "TVNCConsoleWebViewController.h"
#import "TVNCRootListController.h"

#import <UIKit/UIKit.h>

@implementation TRMainTabBarController

/// 视图加载完成时构建三个 Tab 子控制器。
/// 紫色 tint（RGB 107/78/255）统一应用到 TabBar 与各控制器导航栏。
- (void)viewDidLoad {
    [super viewDidLoad];

    // 紫色主题色（RGB 107/78/255）
    UIColor *tint = [UIColor colorWithRed:(107.0 / 255.0)
                                     green:(78.0 / 255.0)
                                      blue:(255.0 / 255.0)
                                     alpha:1.0];
    self.tabBar.tintColor = tint;
    self.tabBar.backgroundColor = [UIColor systemBackgroundColor];

    // Tab 1 连接：TVNCConnectViewController（首页，保持不变）
    // 2026-08-15：同步隐藏顶部导航栏（页面顶部已按 safeAreaLayoutGuide 布局，
    // 无 push 依赖，隐藏后自动顶到状态栏下方；底部 TabBar 保留用于切换）
    TVNCConnectViewController *connect = [[TVNCConnectViewController alloc] init];
    UINavigationController *connectNav = [[UINavigationController alloc] initWithRootViewController:connect];
    connectNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"连接"
                                                          image:[UIImage systemImageNamed:@"wifi"]
                                                  selectedImage:[UIImage systemImageNamed:@"wifi"]
                                                            ];
    [connectNav setNavigationBarHidden:YES animated:NO];
    [self styleNav:connectNav tint:tint];

    // Tab 2 控制：TVNCConsoleWebViewController（Web 容器化 Phase 13：WKWebView 加载网关 H5 手机控制台，
    // 设备墙/大屏/批量/能力菜单全部由 H5 渲染，原生设备墙 TVNCControllerViewController 已删除）
    // 2026-08-15：隐藏本 Tab 顶部导航栏（UINavigationBar）——H5 自带 header（群控台标题 + 批量操作 +
    // 布局切换），原生上标题会遮挡 webView 顶部画面；底部 TabBar（连接/控制/设置）保留，切换不受影响。
    TVNCConsoleWebViewController *console = [[TVNCConsoleWebViewController alloc] init];
    UINavigationController *controllerNav = [[UINavigationController alloc] initWithRootViewController:console];
    controllerNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"控制"
                                                              image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                                      selectedImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"]
                                                                ];
    [controllerNav setNavigationBarHidden:YES animated:NO];
    [self styleNav:controllerNav tint:tint];

    // Tab 3 设置：TVNCRootListController（配置，降为次要入口，PSRootController 包装）
    // 2026-08-15：根页隐藏顶部导航栏（顶部干净）；delegate = 设置页自身——
    // 子菜单 push 进入时临时显示导航栏（返回按钮），退回根页再隐藏
    TVNCRootListController *settings = [[TVNCRootListController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                           image:[UIImage systemImageNamed:@"gearshape"]
                                                   selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]
                                                             ];
    [settingsNav setNavigationBarHidden:YES animated:NO];
    settingsNav.delegate = settings;

    self.viewControllers = @[ connectNav, controllerNav, settingsNav ];
}

/// 统一设置导航控制器外观（紫色 tint + 大标题偏好）。
/// @param nav  待设置的导航控制器
/// @param tint 紫色主题色
- (void)styleNav:(UINavigationController *)nav tint:(UIColor *)tint {
    nav.navigationBar.tintColor = tint;
    UINavigationBarAppearance *appe = [[UINavigationBarAppearance alloc] init];
    [appe configureWithOpaqueBackground];
    nav.navigationBar.standardAppearance = appe;
    nav.navigationBar.scrollEdgeAppearance = appe;
}

@end
