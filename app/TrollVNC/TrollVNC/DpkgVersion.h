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

#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C equivalent of the dpkg version helper.
/// Represents a Debian version and provides parse/compare utilities.
@interface DpkgVersion : NSObject <NSCopying>

/// The epoch. It will be zero if no epoch is present.
@property(nonatomic, assign) uint64_t epoch;

/// The upstream part of the version.
@property(nonatomic, copy) NSString *version;

/// The Debian revision part of the version (may be empty string).
@property(nonatomic, copy) NSString *revision;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithEpoch:(uint64_t)epoch
                      version:(NSString *)version
                     revision:(NSString *)revision NS_DESIGNATED_INITIALIZER;

/// Parse a version string and check for invalid syntax.
/// Returns nil if parsing fails.
+ (nullable instancetype)parseFromString:(NSString *)string;

/// Checks if a version string is valid according to Debian package version rules.
+ (BOOL)isValid:(NSString *)versionString;

/// Compares two version strings according to Debian package version comparison rules.
/// Returns 0 if equal, <0 if lhs < rhs, >0 if lhs > rhs.
+ (NSInteger)compareVersionString:(NSString *)lhs to:(NSString *)rhs;

/// Compares two parsed versions.
/// Returns 0 if equal, <0 if a < b, >0 if a > b.
+ (NSInteger)compare:(DpkgVersion *)a to:(DpkgVersion *)b;

@end

NS_ASSUME_NONNULL_END
