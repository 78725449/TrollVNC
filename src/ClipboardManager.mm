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

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <UIKit/UIKit.h>
#import <notify.h>

#import "ClipboardManager.h"
#import "Logging.h"

static NSString *const kPasteboardDarwinNotification = @"com.apple.pasteboard.notify.changed";

@interface ClipboardManager ()
@property(nonatomic, assign) int notifyToken;
@property(nonatomic, assign, getter=isStarted) BOOL started;
@property(nonatomic, copy) NSString *_Nullable lastSetValue;
@property(nonatomic, assign) NSInteger lastObservedChangeCount;   // last seen changeCount from UIPasteboard
@property(nonatomic, assign) NSInteger lastLocalSetBaselineCount; // changeCount observed right before a local set
@property(nonatomic, assign) NSInteger suppressNextCallbacks;     // >0: skip next onChange and one system notify once
@end

@implementation ClipboardManager

+ (instancetype)sharedManager {
    static ClipboardManager *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _notifyToken = 0;
        _started = NO;
        _lastObservedChangeCount = -1;
        _lastLocalSetBaselineCount = -1;
        _suppressNextCallbacks = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.started) {
        TVLog("start called but already started");
        return;
    }

    self.started = YES;
    TVLog("Starting clipboard monitoring");

    // Register Darwin notification for pasteboard changes
    __weak __typeof(self) weakSelf = self;
    int token = 0;
    uint32_t status =
        notify_register_dispatch(kPasteboardDarwinNotification.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            __strong __typeof(weakSelf) selfRef = weakSelf;
            if (!selfRef)
                return;
            [selfRef handlePasteboardChangeFromSystem];
        });

    if (status == NOTIFY_STATUS_OK) {
        self.notifyToken = token;
        TVLog("Registered for pasteboard notifications (token=%d)", token);
    } else {
        self.notifyToken = 0;
        TVLog("Failed to register pasteboard notifications (status=%u)", status);
    }

    // Initialize baseline change count to avoid spurious first-time callbacks
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        self.lastObservedChangeCount = pb.changeCount;
        TVLog("Initial pasteboard changeCount=%ld", (long)self.lastObservedChangeCount);
    });
}

- (void)stop {
    if (!self.started) {
        TVLog("stop called but not started");
        return;
    }

    self.started = NO;
    TVLog("Stopping clipboard monitoring");

    if (self.notifyToken != 0) {
        notify_cancel(self.notifyToken);
        TVLog("Notification token %d canceled", self.notifyToken);
        self.notifyToken = 0;
    }
}

- (nullable NSString *)currentString {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (text.length == 0)
        return nil;
    return text;
}

- (void)setString:(NSString *)text {
    if (!text)
        return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];

    // Record the baseline count before our local set; the system will bump it later in the loop.
    self.lastLocalSetBaselineCount = pb.changeCount;
    self.lastSetValue = [text copy];
    TVLog("Local setString length=%lu, baseline=%ld", (unsigned long)text.length, (long)self.lastLocalSetBaselineCount);
    pb.string = text;

    // Proactively trigger a callback so upstream can sync to remote immediately
    TVLog("Proactively dispatching local change to onChange callback");
    [self dispatchChangeIfNeededFromLocal:YES];
}

- (void)setStringFromRemote:(NSString *)text {
    if (!text)
        return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];

    // Baseline before set; and mark suppression to avoid echo
    self.lastLocalSetBaselineCount = pb.changeCount;
    self.lastSetValue = [text copy];
    // 2026-08-14 修复：仅吞写入本身触发的 1 次系统通知（本方法不主动回调）。
    // 原 2 会连用户随后第一次真实复制一起吞掉（"被控端复制好几次才同步"根因）；
    // 之后靠 lastSetValue 文本 echo 判断拦截同文本回显，不同文本（真实复制）立即发送。
    self.suppressNextCallbacks = 1;
    TVLog("Remote setString length=%lu, baseline=%ld, suppression=%ld", (unsigned long)text.length,
          (long)self.lastLocalSetBaselineCount, (long)self.suppressNextCallbacks);

    [pb setString:text];
    // Do NOT proactively callback: remote already has the content
}

#pragma mark - Internal

- (void)handlePasteboardChangeFromSystem {

    // System change notification received (triggered by external apps or by our own set)
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger currentCount = pb.changeCount;
    TVLog("System pasteboard changed: changeCount=%ld (last=%ld)", (long)currentCount,
          (long)self.lastObservedChangeCount);

    // Ignore duplicate or out-of-order notifications
    if (self.lastObservedChangeCount == currentCount) {
        TVLog("Ignoring duplicate pasteboard notification");
        return;
    }

    // Advance baseline and then process
    self.lastObservedChangeCount = currentCount;
    TVLog("Dispatching change from system notification");
    [self dispatchChangeIfNeededFromLocal:NO];
}

- (void)dispatchChangeIfNeededFromLocal:(BOOL)local {
    NSString *current = [self currentString];

    // If suppression is active, consume one token and skip
    if (self.suppressNextCallbacks > 0) {
        self.suppressNextCallbacks -= 1;
        TVLog("Suppression active (%ld left); skipping callback", (long)self.suppressNextCallbacks);
        return;
    }

    // Avoid loop: If this matches the value we just set and this call is from the system notification, ignore it.
    // If it’s a local setString call, allow the callback so the remote can be updated.
    if (!local && self.lastSetValue &&
        ((current ?: (id)NSNull.null) == (id)NSNull.null ? YES : [self.lastSetValue isEqualToString:current ?: @""])) {
        // Clear the flag once, but do not callback
        self.lastSetValue = nil;
        TVLog("Ignoring echo of locally set value from system notification");
        return;
    }

    // Optional extra guard when called from system: if we just performed a local set and
    // changeCount hasn’t advanced past the baseline, skip. This protects from edge cases
    // where multiple notifications arrive in the same loop.
    if (!local && self.lastLocalSetBaselineCount >= 0) {

        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        if (pb.changeCount <= self.lastLocalSetBaselineCount) {
            TVLog("Skipping due to unchanged changeCount <= baseline (%ld <= %ld)", (long)pb.changeCount,
                  (long)self.lastLocalSetBaselineCount);
            return;
        }

        // Once we’ve seen a changeCount advance, clear the baseline
        self.lastLocalSetBaselineCount = -1;
    }

    // Clear lastSetValue to avoid holding references
    self.lastSetValue = nil;

    void (^cb)(NSString *_Nullable) = self.onChange;
    if (cb) {
        // Ensure callback is invoked on the main thread
        TVLog("Invoking onChange with %s string (len=%lu)", local ? "local" : "system", (unsigned long)current.length);
        if ([NSThread isMainThread]) {
            cb(current);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(current);
            });
        }
    }
}

@end
