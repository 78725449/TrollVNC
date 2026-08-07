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

#import "SceneDelegate.h"
#import "TVNCClientListController.h"
#import "TVNCConnectViewController.h"
#import "TVNCControllerViewController.h"
#import "TVNCSettingsViewController.h"
#import "TVNCRootListController.h"

#import <Preferences/PSRootController.h>

@interface SceneDelegate ()

@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    // 防御：新 Tab UI 启动异常时回退旧设置页
    @try {
        [self buildTabApp:scene];
    } @catch (NSException *e) {
        NSLog(@"[TVNC] Tab app launch failed: %@ %@", e.name, e.reason);
        NSLog(@"[TVNC] %@", e.callStackSymbols);
        [self buildLegacyRoot:scene];
    }
}

- (void)buildTabApp:(UIScene *)scene {
    if (!self.window) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    }

    UITabBarController *tab = [[UITabBarController alloc] init];

    // Tab 1 连接（【二分诊断】占位 VC，排除连接页 viewDidLoad）
    UIViewController *connect = [[UIViewController alloc] init];
    connect.title = @"连接";
    connect.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    UINavigationController *connectNav = [[UINavigationController alloc] initWithRootViewController:connect];
    connectNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"连接"
                                                          image:[UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"]
                                                            tag:0];

    // Tab 2 客户端（复用现有客户端列表）
    NSBundle *resBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                   ofType:@"bundle"]];
    TVNCClientListController *clients = [[TVNCClientListController alloc] init];
    clients.bundle = resBundle ?: [NSBundle mainBundle];
    clients.primaryColor = [UIColor systemBlueColor];
    UINavigationController *clientsNav = [[UINavigationController alloc] initWithRootViewController:clients];
    clientsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"客户端"
                                                          image:[UIImage systemImageNamed:@"iphone"]
                                                            tag:1];

    // Tab 3 控制端（U2 外壳；viewer 为 U4 远期）
    TVNCControllerViewController *controller = [[TVNCControllerViewController alloc] init];
    UINavigationController *controllerNav = [[UINavigationController alloc] initWithRootViewController:controller];
    controllerNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"控制端"
                                                             image:[UIImage systemImageNamed:@"rectangle.grid.2x2"]
                                                               tag:2];

    // Tab 4 设置（U2.1：8 分组 UIKit 设置）
    TVNCSettingsViewController *settings = [[TVNCSettingsViewController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                           image:[UIImage systemImageNamed:@"gearshape"]
                                                             tag:3];

    tab.viewControllers = @[ connectNav, clientsNav, controllerNav, settingsNav ];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];
}

// 回退：旧 Preferences 设置页（设备上已验证可打开）
- (void)buildLegacyRoot:(UIScene *)scene {
    if (!self.window) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    }
    TVNCRootListController *settings = [[TVNCRootListController alloc] init];
    PSRootController *nav = [[PSRootController alloc] initWithRootViewController:settings];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see
    // `application:didDiscardSceneSessions` instead).
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}

- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}

@end
