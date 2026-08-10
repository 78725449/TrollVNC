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

#import "SceneDelegate.h"
#import "TRMainTabBarController.h"
#import "TVNCRootListController.h"

#import <UIKit/UIKit.h>

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

    // Phase 12.2：根控制器改为 TRMainTabBarController（三 Tab 导航）
    TRMainTabBarController *tab = [[TRMainTabBarController alloc] init];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];
}

// 回退：旧 Preferences 设置页（设备上已验证可打开）
- (void)buildLegacyRoot:(UIScene *)scene {
    if (!self.window) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    }
    TVNCRootListController *settings = [[TVNCRootListController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
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
