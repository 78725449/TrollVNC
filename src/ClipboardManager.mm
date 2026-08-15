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
@property(nonatomic, copy) NSString *_Nullable lastSetValue;        // 最近一次本地/远程写入的文本（文本回显兜底）
@property(nonatomic, assign) NSInteger lastObservedChangeCount;     // last seen changeCount from UIPasteboard
@property(nonatomic, assign) NSInteger lastLocalSetBaselineCount;   // changeCount observed right before a local set
@property(nonatomic, assign) NSInteger lastSetChangeCount;          // 远程写入后自身 set 造成的 changeCount 锚点（-1=无效）
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
        _lastSetChangeCount = -1;
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

    // 2026-08-15 修复"被控端复制第一次不成功"（根因）：
    // 原实现用计数型 suppressNextCallbacks=1 吞"自身写入触发的 1 次系统通知"。但 iOS 的
    // com.apple.pasteboard.notify.changed 通知可能被延迟/合并：若自身写入的通知还没到达、
    // 用户就复制了新文本，合并后的首个通知会被计数抑制误吞 → 用户第一次真实复制丢失，
    // 只能等第二次/第三次才同步。改为 changeCount 锚点判定：记录自身 set 后的 changeCount，
    // 仅当后续系统通知的 changeCount 恰好等于该锚点时判定为"自身回显"；任何越过锚点的
    // 变化（真实复制，changeCount 更大）立即放行。锚点无效（changeCount 未同步推进）时
    // 回退到文本 echo 判断（lastSetValue 文本对比）。
    self.lastSetValue = [text copy];
    self.lastSetChangeCount = -1;
    [pb setString:text];
    NSInteger after = pb.changeCount;
    if (after > self.lastObservedChangeCount) {
        self.lastSetChangeCount = after; // 锚点有效：changeCount 已同步推进
    }
    TVLog("Remote setString length=%lu, anchor=%ld", (unsigned long)text.length, (long)self.lastSetChangeCount);
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

    // 2026-08-15 changeCount 锚点回显判定（替代原计数型抑制，防误吞真实复制）：
    // - currentCount <= lastSetChangeCount：未越过锚点 = 远程写入自身的回显
    //   （含乱序的早期通知/中间计数）→ 跳过；仅在恰好等于锚点时清锚点与文本
    //   （两次远程写入紧邻时，第一条写入的乱序通知 count < 第二条锚点，锚点必须保留，
    //   否则第二条写入的回显会被误当真实复制回调）
    // - currentCount > lastSetChangeCount：真实复制发生在远程写入之后 → 放行并清锚点
    //   （通知延迟/合并时首条通知的 changeCount 可能直接越过锚点，此时用户复制绝不能被吞）
    if (self.lastSetChangeCount >= 0) {
        if (currentCount <= self.lastSetChangeCount) {
            if (currentCount == self.lastSetChangeCount) {
                self.lastSetChangeCount = -1;
                self.lastSetValue = nil;
            }
            TVLog("Ignoring self-echo of remote set (count=%ld anchor=%ld)",
                  (long)currentCount, (long)self.lastSetChangeCount);
            return;
        }
        self.lastSetChangeCount = -1;
        TVLog("Change advanced past anchor (%ld) — real copy, dispatching", (long)currentCount);
    }

    [self dispatchChangeIfNeededFromLocal:NO];
}

- (void)dispatchChangeIfNeededFromLocal:(BOOL)local {
    NSString *current = [self currentString];

    // 2026-08-15 移除计数型抑制（已由 handlePasteboardChangeFromSystem 的 changeCount 锚点替代，
    // 计数型会在通知延迟/合并时误吞用户第一次真实复制）。
    // 文本回显兜底（锚点失效场景，如 changeCount 未同步推进）：忽略与最近写入文本相同的
    // 系统通知；不同文本（真实复制）立即放行。
    if (!local && self.lastSetValue && current &&
        [self.lastSetValue isEqualToString:current]) {
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
