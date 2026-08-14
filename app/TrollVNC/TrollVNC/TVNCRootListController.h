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

#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 设置根页（Tab 3）。
 * 2026-08-15：根页隐藏顶部导航栏（顶部干净）；作为 settingsNav 的
 * UINavigationControllerDelegate，子菜单 push 进入时临时显示导航栏（承载返回按钮），
 * 退回根页再次隐藏。底部 TabBar 保留。
 */
@interface TVNCRootListController : PSListController <UINavigationControllerDelegate>

@end

NS_ASSUME_NONNULL_END
