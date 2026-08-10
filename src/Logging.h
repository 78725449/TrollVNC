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
#import <Foundation/NSObjCRuntime.h>

FOUNDATION_EXPORT BOOL tvncLoggingEnabled;
FOUNDATION_EXPORT BOOL tvncVerboseLoggingEnabled;

#define TVLog(fmt, ...)                                                                                                \
    do {                                                                                                               \
        if (tvncLoggingEnabled)                                                                                        \
            NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);                                 \
    } while (0)

#define TVLogVerbose(fmt, ...)                                                                                         \
    do {                                                                                                               \
        if (tvncVerboseLoggingEnabled)                                                                                 \
            NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);                                 \
    } while (0)
