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
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>

#define TVNC_NOTIFY_PREFS_CHANGED "com.82flex.trollvnc.prefs-changed"

/// 读取设备端 DeviceUUID（用于卡片墙过滤自身 / 注册状态判定）。
/// 设备端 trollvncmanager 以 root 运行（TVNCServiceCoordinator spawnService setUserIdentifier:0），
/// UUID 生成并写入 root 用户 preferences（/var/root/Library/Preferences/com.82flex.trollvnc.plist），
/// 并镜像写入 mobile 用户域（经 cfprefsd + 文件双通道，见 TRGatewayClient _mirrorDeviceIdToMobileDomain）。
/// 读取优先级：
///   1. CFPreferencesCopyAppValue（cfprefsd 通道：无 sandbox 文件限制、实时同步，设备端镜像主通道）
///   2. root 用户域 plist 文件（权威值，App 有 storage.preferences 时可直接读）
///   3. mobile 用户域 plist 文件（镜像写入，兼容非 cfprefsd 通道）
///   4. 当前用户域 NSUserDefaults（兼容模拟器/旧版本）
/// 动态读取（不缓存）以兼容服务未启动时序。
/// @return 设备 UUID；未生成返回 nil
NS_INLINE NSString *TVNCReadSelfDeviceId(void) {
    // 1. cfprefsd 通道（App 的配置读写走同一通道已验证可用；镜像写后实时可读）
    //    先强制同步该域缓存，避免读到进程内旧快照（设备端 trollvncmanager 写的是外部新值）
    CFStringRef appID = CFSTR("com.82flex.trollvnc");
    CFPreferencesAppSynchronize(appID);
    CFPropertyListRef plist = CFPreferencesCopyAppValue(CFSTR("DeviceUUID"), appID);
    if (plist) {
        if (CFGetTypeID(plist) == CFStringGetTypeID()) {
            NSString *s = CFBridgingRelease(plist);
            if (s.length) return s;
        } else {
            CFRelease(plist);
        }
    }
    // 2. root 用户域文件（trollvncmanager 以 root 写入的权威值）
    NSDictionary *rootPrefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/root/Library/Preferences/com.82flex.trollvnc.plist"];
    NSString *did = [rootPrefs[@"DeviceUUID"] isKindOfClass:[NSString class]] ? rootPrefs[@"DeviceUUID"] : nil;
    if (did.length) return did;
    // 3. mobile 用户域文件（设备端镜像写入，绕过 App sandbox 对 /var/root 的读取限制）
    NSDictionary *mobilePrefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist"];
    did = [mobilePrefs[@"DeviceUUID"] isKindOfClass:[NSString class]] ? mobilePrefs[@"DeviceUUID"] : nil;
    if (did.length) return did;
    // 4. 当前用户域 NSUserDefaults（兼容模拟器/旧版 mobile 运行）
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
