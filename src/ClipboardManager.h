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

#ifndef ClipboardManager_h
#define ClipboardManager_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight clipboard manager that only supports UTF-8 text.
/// Wraps UIPasteboard and listens for the Darwin notification: com.apple.pasteboard.notify.changed.
/// Exposes an onChange callback invoked on the main thread.
@interface ClipboardManager : NSObject

/// Global singleton instance
+ (instancetype)sharedManager;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// Start listening for clipboard changes (idempotent)
- (void)start;

/// Stop listening for clipboard changes (safe to call multiple times)
- (void)stop;

/// Get current clipboard string (UTF-8). Returns nil if no plain text is available.
- (nullable NSString *)currentString;

/// Set clipboard string (UTF-8). Internally tries to avoid self-triggered callback loops.
- (void)setString:(NSString *)text;

/// Set clipboard string originating from a remote VNC client. Avoids echo by
/// changeCount-anchored + text-comparison detection of the self-induced system
/// notification (no count-based suppression, so a real user copy is never swallowed).
- (void)setStringFromRemote:(NSString *)text;

/// Clipboard change callback (executed on the main thread; text is nil when no plain text).
@property (atomic, copy, nullable) void (^onChange)(NSString *_Nullable text);

@end

NS_ASSUME_NONNULL_END

#endif /* ClipboardManager_h */
