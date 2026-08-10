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

@interface TVNCClientCell : UITableViewCell

@property(nonatomic, strong) NSBundle *bundle;
@property(nonatomic, strong, readonly) UILabel *idLabel;       // 8-char ID (bold, monospaced)
@property(nonatomic, strong, readonly) UILabel *hostLabel;     // host/IP
@property(nonatomic, strong, readonly) UILabel *subtitleLabel; // relative connection time
@property(nonatomic, strong, readonly) UIImageView *badgeView; // view-only badge

- (void)configureWithId:(NSString *)cid
                   host:(NSString *)host
               viewOnly:(BOOL)viewOnly
               subtitle:(NSString *)subtitle
           primaryColor:(nullable UIColor *)primaryColor;

@end

NS_ASSUME_NONNULL_END
