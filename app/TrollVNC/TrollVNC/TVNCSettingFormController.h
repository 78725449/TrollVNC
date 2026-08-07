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

/// 通用设置表单（U2.1）：按 spec 渲染分组行，读写 com.82flex.trollvnc
/// groups = @[ @{ @"title": @"网关", @"rows": @[ row... ] }, ... ]
/// row = @{ @"type": @"switch|text|password|slider|choice|button|info",
///          @"key": @"...", @"label": @"...", @"default": 值,
///          @"min": @(0), @"max": @(1), @"step": @(0.05), @"format": @"%.2f",
///          @"options": @[@{@"title":@"..", @"value":@".."}, ...],
///          @"action": @"searchGateway|viewLogs|resetDefaults|generateKeys",
///          @"placeholder": @"...", @"staticValue": @"..." }
@interface TVNCSettingFormController : UITableViewController

- (instancetype)initWithGroups:(NSArray<NSDictionary *> *)groups title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
