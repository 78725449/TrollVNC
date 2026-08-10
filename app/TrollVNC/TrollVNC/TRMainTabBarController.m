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

#import "TRMainTabBarController.h"
#import "TVNCConnectViewController.h"
#import "TVNCControllerViewController.h"
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
    TVNCConnectViewController *connect = [[TVNCConnectViewController alloc] init];
    UINavigationController *connectNav = [[UINavigationController alloc] initWithRootViewController:connect];
    connectNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"连接"
                                                          image:[UIImage systemImageNamed:@"wifi"]
                                                  selectedImage:[UIImage systemImageNamed:@"wifi"]
                                                            tag:0];
    [self styleNav:connectNav tint:tint];

    // Tab 2 控制：TVNCControllerViewController（卡片墙，升为主入口之一）
    TVNCControllerViewController *controller = [[TVNCControllerViewController alloc] init];
    UINavigationController *controllerNav = [[UINavigationController alloc] initWithRootViewController:controller];
    controllerNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"控制"
                                                              image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                                      selectedImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"]
                                                                tag:1];
    [self styleNav:controllerNav tint:tint];

    // Tab 3 设置：TVNCRootListController（配置，降为次要入口，PSRootController 包装）
    TVNCRootListController *settings = [[TVNCRootListController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                           image:[UIImage systemImageNamed:@"gearshape"]
                                                   selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]
                                                             tag:2];

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
