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
#import <sys/sysctl.h>

#define TVNC_NOTIFY_PREFS_CHANGED "com.82flex.trollvnc.prefs-changed"

/// 格式化设备"最后在线时间"字段（网关可能返回字符串或毫秒时间戳 NSNumber）。
/// 类型安全：NSString 原样返回；NSNumber 按毫秒时间戳格式化为 "MM-dd HH:mm"；其它/空返回 @""。
/// @param raw 原始字段值（d[@"lastSeen"] 或 d[@"lastOnline"]，可为 nil/NSNull/NSNumber/NSString）
/// @return 可展示文本；无有效值返回空串
NS_INLINE NSString *TVNCFormatLastSeen(id raw) {
    if ([raw isKindOfClass:[NSString class]]) {
        return [(NSString *)raw length] ? (NSString *)raw : @"";
    }
    if ([raw isKindOfClass:[NSNumber class]]) {
        double ms = [(NSNumber *)raw doubleValue];
        if (ms <= 0) return @"";
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"MM-dd HH:mm";
        });
        return [fmt stringFromDate:date];
    }
    return @"";
}

/// 读取设备端 DeviceUUID（用于卡片墙过滤自身 / 注册状态判定）。
/// 设备端 trollvncmanager 以 root 运行（TVNCServiceCoordinator spawnService setUserIdentifier:0），
/// UUID 生成并写入 root 用户 preferences（/var/root/Library/Preferences/com.82flex.trollvnc.plist），
/// 本 App（mobile uid 501）经 NSUserDefaults suite 只能读到当前用户域，故优先直接读 root 用户
/// preferences 文件；回退当前用户域（兼容旧版本/模拟器）。动态读取（不缓存）以兼容服务未启动时序。
/// @return 设备 UUID；未生成返回 nil
NS_INLINE NSString *TVNCReadSelfDeviceId(void) {
    NSDictionary *rootPrefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/root/Library/Preferences/com.82flex.trollvnc.plist"];
    NSString *did = [rootPrefs[@"DeviceUUID"] isKindOfClass:[NSString class]] ? rootPrefs[@"DeviceUUID"] : nil;
    if (did.length) return did;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    return [d stringForKey:@"DeviceUUID"];
}

// Minimal process enumeration to restart VNC service
NS_INLINE void TVNCEnumerateProcesses(void (^enumerator)(pid_t pid, NSString *executablePath, BOOL *stop)) {
    static int kMaximumArgumentSize = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        size_t valSize = sizeof(kMaximumArgumentSize);
        if (sysctl((int[]){CTL_KERN, KERN_ARGMAX}, 2, &kMaximumArgumentSize, &valSize, NULL, 0) < 0) {
            kMaximumArgumentSize = 4096;
        }
    });

    size_t procInfoLength = 0;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, NULL, &procInfoLength, NULL, 0) < 0) {
        return;
    }

    struct kinfo_proc *procInfo = (struct kinfo_proc *)calloc(1, procInfoLength + 1);
    if (!procInfo)
        return;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, procInfo, &procInfoLength, NULL, 0) < 0) {
        free(procInfo);
        return;
    }

    char *argBuffer = (char *)calloc(1, (size_t)kMaximumArgumentSize + 1);
    if (!argBuffer) {
        free(procInfo);
        return;
    }

    int procInfoCnt = (int)(procInfoLength / sizeof(struct kinfo_proc));
    for (int i = 0; i < procInfoCnt; i++) {
        pid_t pid = procInfo[i].kp_proc.p_pid;
        if (pid <= 1)
            continue;

        size_t argSize = (size_t)kMaximumArgumentSize;
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, NULL, &argSize, NULL, 0) < 0)
            continue;
        memset(argBuffer, 0, argSize + 1);
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, argBuffer, &argSize, NULL, 0) < 0)
            continue;

        BOOL stop = NO;
        @autoreleasepool {
            NSString *exePath = [NSString stringWithUTF8String:(argBuffer + sizeof(int))] ?: @"";
            enumerator(pid, exePath, &stop);
        }
        if (stop)
            break;
    }

    free(argBuffer);
    free(procInfo);
}

NS_INLINE void TVNCRestartVNCService(void) {
    // Try to terminate trollvncserver; launchd should respawn it if configured.
    TVNCEnumerateProcesses(^(pid_t pid, NSString *executablePath, BOOL *stop) {
        if ([executablePath.lastPathComponent isEqualToString:@"trollvncserver"]) {
            int rc = kill(pid, SIGTERM);
            if (rc == 0) {
#ifdef THEBOOTSTRAP
                [UIApplication.sharedApplication setApplicationIconBadgeNumber:0];
#endif
            }
        }
    });
}
