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

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <atomic>
#import <climits>
#import <cstdio>
#import <cstdlib>
#import <cstring>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <rfb/keysym.h>
// libvncserver 预编译库启用 LIBZ（rfbconfig.h 声明），rfb.h 不引入 rfbconfig.h，
// enableExtendedClipboard/setXCutTextUTF8 位于 #ifdef LIBVNCSERVER_HAVE_LIBZ 内。
// 此处源码级兜底定义（Makefile -D 对 .mm 的传递在不同 theos 版本/方案下不稳定），
// 确保各构建方案（default/rootless/roothide/bootstrap）都能访问 ExtendedClipboard 字段。
#ifndef LIBVNCSERVER_HAVE_LIBZ
#define LIBVNCSERVER_HAVE_LIBZ 1
#endif
#import <rfb/rfb.h>
#import <string>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <vector>

#import "BulletinManager.h"
#import "ClipboardManager.h"
#import "Control.h"
#import "FBSOrientationObserver.h"
#import "IOKitSPI.h"
#import "Logging.h"
#import "PSAssistiveTouchSettingsDetail.h"
#import "STHIDEventGenerator.h"
#import "ScreenCapturer.h"
#import "TRScreenHasher.h"

#define LocalizedString(key, comment, bundle, table)                                                                   \
    (NSLocalizedStringFromTableInBundle((key), (table), (bundle), (comment)) ?: (key))

#define TVPrintError(fmt, ...)                                                                                         \
    do {                                                                                                               \
        fprintf(stderr, fmt "\r\n", ##__VA_ARGS__);                                                                    \
    } while (0)

#pragma mark - Options

int gOrientationFixQuad = 0; // 0=0°, 1=90°CW, 2=180°, 3=270°CW

static BOOL gEnabled = YES;
static int gPort = 5901;      // 端口固定不可调（5901 = VNC 后端入口）
static NSString *gBindHost = nil; // optional bind address from CLI/config
static NSString *gDesktopName = @"SuperPhone";
static BOOL gViewOnly = NO;
static double gKeepAliveSec = 0.0; // 15..86400
static BOOL gClipboardEnabled = YES;

static double gScale = 1.0; // 0 < scale <= 1.0, 1.0 = no scaling
// Preferred frame rate range (0 = unspecified)
static int gFpsMin = 0;
static int gFpsPref = 0;
static int gFpsMax = 0;
static double gDeferWindowSec = 0.015;      // Coalescing window; 0 disables deferral
static int gMaxInflightUpdates = 2;         // Max concurrent client encodes; drop frames if >= this
static int gTileSize = 32;                  // Tile size for dirty detection (pixels)
static int gFullscreenThresholdPercent = 0; // If changed tiles exceed this %, update full screen
static int gMaxRectsLimit = 256;            // Max rects before falling back to bbox/fullscreen
static BOOL gAsyncSwapEnabled = NO;         // Enable non-blocking swap (may cause tearing)

// Wheel scroll coalescing state (async, non-blocking)
static double gWheelStepPx = 48.0;        // base pixels per wheel tick (lower = slower)
static double gWheelMaxStepPx = 192.0;    // base max distance per flush (pre-clamp)
static double gWheelCoalesceSec = 0.03;   // coalescing window
static double gWheelAbsClampFactor = 2.5; // absolute clamp = factor * gWheelMaxStepPx
static double gWheelAmpCoeff = 0.18;      // velocity amplification coefficient
static double gWheelAmpCap = 0.75;        // max extra amplification (0..1)
static double gWheelMinTakeRatio = 0.35;  // minimum take distance vs step size
static double gWheelDurBase = 0.05;       // duration base seconds
static double gWheelDurK = 0.00016;       // duration factor applied to sqrt(distance)
static double gWheelDurMin = 0.05;        // duration clamp min
static double gWheelDurMax = 0.14;        // duration clamp max
static BOOL gWheelNaturalDir = NO;        // natural scroll direction (invert delta)

// Modifier mapping scheme: 0 = standard (Alt->Option, Meta/Super->Command), 1 = Alt-as-Command
static int gModMapScheme = 0;
static BOOL gAutoAssistEnabled = NO;
static BOOL gCursorEnabled = NO;
// 前置声明：ServerCursor 配置 set 时（L3154）需即时重建/清除服务端光标（定义在 L4512）
static void setupRfbServerSideCursor(void);
static BOOL gKeyEventLogging = NO;
static BOOL gOrientationSyncEnabled = YES;

// Classic VNC authentication
static char **gAuthPasswdVec = NULL;        // owns the vector
static char *gAuthPasswdStr = NULL;         // owns the duplicated password string
static char *gAuthViewOnlyPasswdStr = NULL; // optional view-only password string

// HTTP server (LibVNCServer built-in web client)
static int gHttpPort = 5801; // 端口固定不可调（5801 = 前端入口）
static char *gHttpDirOverride = NULL;
static char *gSslCertPath = NULL;
static char *gSslKeyPath = NULL;

// Bonjour / mDNS Auto-Discovery
static BOOL gBonjourEnabled = YES; // publish _rfb._tcp (and optional _http._tcp)

// TightVNC 1.x file transfer extension (deprecated)
static BOOL gFileTransferEnabled = NO;

// User notifications
static BOOL gUserClientNotifsEnabled = YES;
static BOOL gUserSingleNotifsEnabled = YES;

// Blocked hosts (temporary blacklist)
static NSMutableSet<NSString *> *gBlockedHosts = nil;

typedef NS_ENUM(uint8_t, TVBindHostKind) {
    kTVBindHostKindNone = 0,
    kTVBindHostKindIPv4,
    kTVBindHostKindIPv6,
    kTVBindHostKindInvalid,
};

static TVBindHostKind tvClassifyBindHost(NSString *host, in_addr_t *outIPv4, struct in6_addr *outIPv6) {
    if (outIPv4)
        *outIPv4 = 0;
    if (outIPv6)
        memset(outIPv6, 0, sizeof(*outIPv6));

    if (!host || host.length == 0)
        return kTVBindHostKindNone;

    const char *cstr = [host UTF8String];
    if (!cstr || *cstr == '\0')
        return kTVBindHostKindNone;

    struct in_addr v4;
    if (inet_pton(AF_INET, cstr, &v4) == 1) {
        if (outIPv4)
            *outIPv4 = v4.s_addr;
        return kTVBindHostKindIPv4;
    }

    char addrBuf[INET6_ADDRSTRLEN + 1];
    const char *pct = strchr(cstr, '%');
    size_t copyLen = pct ? (size_t)(pct - cstr) : strlen(cstr);
    if (copyLen >= sizeof(addrBuf))
        copyLen = sizeof(addrBuf) - 1;
    memcpy(addrBuf, cstr, copyLen);
    addrBuf[copyLen] = '\0';

    struct in6_addr v6;
    if (inet_pton(AF_INET6, addrBuf, &v6) == 1) {
        if (outIPv6)
            *outIPv6 = v6;
        return kTVBindHostKindIPv6;
    }

    return kTVBindHostKindInvalid;
}

#pragma mark - Bundle

static NSString *tvExecutablePath(void) {
    static NSString *sPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Resolve executable path
        uint32_t sz = 0;
        _NSGetExecutablePath(NULL, &sz); // query size
        char *exeBuf = (char *)malloc(sz > 0 ? sz : PATH_MAX);
        if (!exeBuf)
            return;
        if (_NSGetExecutablePath(exeBuf, &sz) != 0) {
            // Fallback: leave exeBuf as-is
        }

        // Canonicalize
        char realBuf[PATH_MAX];
        const char *exePath = realpath(exeBuf, realBuf) ? realBuf : exeBuf;
        NSString *exe = [NSString stringWithUTF8String:exePath ? exePath : ""];
        free(exeBuf);

        sPath = exe ?: [[NSProcessInfo processInfo] arguments][0];
    });
    return sPath;
}

static NSBundle *tvResourceBundle(void) {
    static NSBundle *sBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#ifdef THEBOOTSTRAP
        NSString *exe = tvExecutablePath();
        NSString *dir = [exe stringByDeletingLastPathComponent];
        NSBundle *mainBundle = [NSBundle bundleWithPath:dir];
        if (!mainBundle)
            return;

        NSString *resPath = [mainBundle pathForResource:@"TrollVNCPrefs" ofType:@"bundle"];
        NSBundle *resBundle = resPath ? [NSBundle bundleWithPath:resPath] : nil;
        if (!resBundle)
            return;

        sBundle = resBundle;
#else
        NSString *exe = tvExecutablePath();
        NSString *exeDir = [exe stringByDeletingLastPathComponent];
        NSString *resRel = @"../../Library/PreferenceBundles/TrollVNCPrefs.bundle";
        NSString *resPath = [[exeDir stringByAppendingPathComponent:resRel] stringByStandardizingPath];
        NSBundle *resBundle = resPath ? [NSBundle bundleWithPath:resPath] : nil;
        if (!resBundle)
            return;

        sBundle = resBundle;
#endif
    });
    return sBundle;
}

static NSBundle *tvLocalizationBundle(void) {
    static NSBundle *sBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *resBundle = tvResourceBundle();

        NSArray<NSString *> *languages =
            [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"] ?: @"en";

        NSString *localizablePath = nil;
        for (NSString *localization in [NSBundle preferredLocalizationsFromArray:[resBundle localizations]
                                                                  forPreferences:languages]) {
            localizablePath = [resBundle pathForResource:@"Localizable"
                                                  ofType:@"strings"
                                             inDirectory:nil
                                         forLocalization:localization];
            if (localizablePath && localizablePath.length > 0)
                break;
        }

        NSString *lprojPath = [localizablePath stringByDeletingLastPathComponent];
        if (lprojPath && lprojPath.length > 0) {
            resBundle = [NSBundle bundleWithPath:lprojPath];
        }

        sBundle = resBundle;
    });
    return sBundle;
}

#pragma mark - Command-Line Parsing

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYSTRINGIFY(x)                                                                                                 \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return strdup([str UTF8String]);                                                                               \
    }()

static void printUsageAndExit(const char *prog) {
    // Compact, grouped usage for quick reference. See README for detailed explanations.
    static const char *sPackageScheme = MYSTRINGIFY(THEOS_PACKAGE_SCHEME);
    static const char *sPackageVersion = MYSTRINGIFY(PACKAGE_VERSION);

    fprintf(stderr, "SuperPhone (%s) v%s\n", sPackageScheme, sPackageVersion);
    fprintf(stderr, "Usage: %s [-p port] [-n name] [options]\n\n", prog);

    fprintf(stderr, "Basic:\n");
    fprintf(stderr, "  -b host    Bind host address (IPv4/IPv6 literal, default to all)\n");
    fprintf(stderr, "  -p port    VNC TCP port (default: %d)\n", gPort);
    fprintf(stderr, "  -n name    Desktop name (default: %s)\n", [gDesktopName UTF8String]);
    fprintf(stderr, "  -v         View-only (ignore input)\n");
    fprintf(stderr, "  -A sec     Keep-alive interval to prevent sleep; only when clients > 0 (15..86400, 0=off)\n\n");

    fprintf(stderr, "Display/Perf:\n");
    fprintf(stderr, "  -s scale   Output scale 0<s<=1 (default: %.2f)\n", gScale);
    fprintf(stderr, "  -F spec    Frame rate: fps | min-max | min:pref:max\n");
    fprintf(stderr, "  -d sec     Defer window (0..0.5, default: %.3f)\n", gDeferWindowSec);
    fprintf(stderr, "  -Q n       Max in-flight encodes (0=never drop, default: %d)\n\n", gMaxInflightUpdates);

    fprintf(stderr, "Dirty detection:\n");
    fprintf(stderr, "  -t size    Tile size (8..128, default: %d)\n", gTileSize);
    fprintf(stderr, "  -P pct     Fullscreen fallback threshold (0..100; 0=disable dirty detection, default: %d)\n",
            gFullscreenThresholdPercent);
    fprintf(stderr, "  -R max     Max dirty rects before bbox (default: %d)\n", gMaxRectsLimit);
    fprintf(stderr, "  -a         Non-blocking swap (may cause tearing)\n\n");

    fprintf(stderr, "Scroll/Input:\n");
    fprintf(stderr, "  -W px      Wheel step in pixels (0=disable, default: %.0f)\n", gWheelStepPx);
    fprintf(stderr,
            "  -w k=v,.. Wheel tuning keys: step,coalesce,max,clamp,amp,cap,minratio,durbase,durk,durmin,durmax\n");
    fprintf(stderr, "  -N         Natural scroll direction (invert wheel)\n");
    fprintf(stderr, "  -M scheme  Modifier mapping: std|altcmd (default: std)\n");
    fprintf(stderr, "  -K         Log keyboard events to stderr\n\n");

    fprintf(stderr, "HTTP/WebSockets:\n");
    fprintf(stderr, "  -H port    Enable built-in HTTP server on port (0=off, default: 0)\n");
    fprintf(stderr, "  -D path    Absolute path for HTTP document root\n");
    fprintf(stderr, "  -e file    Path to SSL certificate file\n");
    fprintf(stderr, "  -k file    Path to SSL private key file\n\n");

    fprintf(stderr, "Bonjour/mDNS:\n");
    fprintf(stderr, "  -B on|off  Advertise on local network via Bonjour (_rfb._tcp, _http._tcp) (default: on)\n\n");

    fprintf(stderr, "Accessibility:\n");
    fprintf(stderr, "  -O on|off  Observe iOS interface orientation and sync (default: on)\n");
    fprintf(stderr, "  -E on|off  Enable AssistiveTouch auto-activation (default: off)\n");
    fprintf(stderr, "  -U on|off  Enable server-side cursor X (default: off)\n\n");

    fprintf(stderr, "Notifications:\n");
    fprintf(stderr, "  -i on|off  Single notification when first client connects (default: on)\n");
    fprintf(stderr, "  -I on|off  User notifications for client connect/disconnect (default: on)\n\n");

    fprintf(stderr, "Extensions:\n");
    fprintf(stderr, "  -C on|off  Clipboard sync (default: on)\n");
    fprintf(stderr, "  -T on|off  File transfer (default: off)\n\n");

#if DEBUG
    fprintf(stderr, "Logging:\n");
    fprintf(stderr, "  -V         Enable verbose logging\n\n");
#endif

    fprintf(stderr, "Help:\n");
    fprintf(stderr, "  -h         Show this help message\n\n");

    fprintf(stderr, "Environment:\n");
    fprintf(
        stderr,
        "  TROLLVNC_PASSWORD                 Classic VNC password (enables VNC auth when set; first 8 chars used)\n");
    fprintf(stderr,
            "  TROLLVNC_VIEWONLY_PASSWORD        View-only password; passwords stored as [full..., view-only...]\n");

    exit(EXIT_SUCCESS);
}

static void parseWheelOptions(const char *spec) {
    if (!spec)
        return;
    char *dup = strdup(spec);
    if (!dup)
        return;
    char *saveptr = NULL;
    for (char *tok = strtok_r(dup, ",", &saveptr); tok; tok = strtok_r(NULL, ",", &saveptr)) {
        char *eq = strchr(tok, '=');
        if (!eq)
            continue;
        *eq = '\0';
        const char *key = tok;
        const char *val = eq + 1;
        double d = strtod(val, NULL);
        if (strcmp(key, "step") == 0) {
            if (d > 0)
                gWheelStepPx = d;
            TVLog(@"Wheel tuning: step=%g", gWheelStepPx);
        } else if (strcmp(key, "coalesce") == 0) {
            if (d >= 0 && d <= 0.5)
                gWheelCoalesceSec = d;
            TVLog(@"Wheel tuning: coalesce=%g", gWheelCoalesceSec);
        } else if (strcmp(key, "max") == 0) {
            if (d > 0)
                gWheelMaxStepPx = d;
            TVLog(@"Wheel tuning: max=%g", gWheelMaxStepPx);
        } else if (strcmp(key, "clamp") == 0) {
            if (d >= 1.0 && d <= 10.0)
                gWheelAbsClampFactor = d;
            TVLog(@"Wheel tuning: clamp=%g", gWheelAbsClampFactor);
        } else if (strcmp(key, "amp") == 0) {
            if (d >= 0.0 && d <= 5.0)
                gWheelAmpCoeff = d;
            TVLog(@"Wheel tuning: amp=%g", gWheelAmpCoeff);
        } else if (strcmp(key, "cap") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelAmpCap = d;
            TVLog(@"Wheel tuning: cap=%g", gWheelAmpCap);
        } else if (strcmp(key, "minratio") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelMinTakeRatio = d;
            TVLog(@"Wheel tuning: minratio=%g", gWheelMinTakeRatio);
        } else if (strcmp(key, "durbase") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurBase = d;
            TVLog(@"Wheel tuning: durbase=%g", gWheelDurBase);
        } else if (strcmp(key, "durk") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurK = d;
            TVLog(@"Wheel tuning: durk=%g", gWheelDurK);
        } else if (strcmp(key, "durmin") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurMin = d;
            TVLog(@"Wheel tuning: durmin=%g", gWheelDurMin);
        } else if (strcmp(key, "durmax") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelDurMax = d;
            TVLog(@"Wheel tuning: durmax=%g", gWheelDurMax);
        } else if (strcmp(key, "natural") == 0) {
            gWheelNaturalDir = (d != 0.0);
            TVLog(@"Wheel tuning: natural=%@", gWheelNaturalDir ? @"YES" : @"NO");
        }
    }
    free(dup);
}

/**
 * 解析 FrameRateSpec 字符串并更新 gFpsMin/gFpsPref/gFpsMax
 * 支持三种格式：单值"30"、范围"15-30"、完整"min:pref:max"
 * @param spec FrameRateSpec 字符串（C 字符串，UTF-8）
 * 注：复用此函数避免初始化与热重载逻辑重复（Phase 4.4）
 */
static void parseFrameRateSpec(const char *spec) {
    if (!spec) return;
    int minV = 0, prefV = 0, maxV = 0;
    const char *colon1 = strchr(spec, ':');
    const char *dash = strchr(spec, '-');
    if (colon1) {
        long a = strtol(spec, NULL, 10);
        const char *p2 = colon1 + 1;
        const char *colon2 = strchr(p2, ':');
        if (colon2) {
            long b = strtol(p2, NULL, 10);
            long c = strtol(colon2 + 1, NULL, 10);
            minV = (int)a; prefV = (int)b; maxV = (int)c;
        }
    } else if (dash) {
        long a = strtol(spec, NULL, 10);
        long b = strtol(dash + 1, NULL, 10);
        minV = (int)a; prefV = (int)b; maxV = (int)b;
    } else {
        long v = strtol(spec, NULL, 10);
        minV = (int)v; prefV = (int)v; maxV = (int)v;
    }
    // 校验与规范化：允许 0..240（0 = 未指定）
    if (minV < 0) minV = 0;  if (minV > 240) minV = 240;
    if (prefV < 0) prefV = 0;  if (prefV > 240) prefV = 240;
    if (maxV < 0) maxV = 0;  if (maxV > 240) maxV = 240;
    if (minV > 0 && maxV > 0 && minV > maxV) { int tmp = minV; minV = maxV; maxV = tmp; }
    if (prefV > 0) {
        if (minV > 0 && prefV < minV) prefV = minV;
        if (maxV > 0 && prefV > maxV) prefV = maxV;
    }
    gFpsMin = minV; gFpsPref = prefV; gFpsMax = maxV;
}

static void parseDaemonOptions(void) {
    NSDictionary *prefs = nil;

    if (!prefs) {
        NSBundle *resBundle = tvResourceBundle();
        NSString *presetPath = [resBundle pathForResource:@"Managed" ofType:@"plist"];
        if (presetPath) {
            prefs = [NSDictionary dictionaryWithContentsOfFile:presetPath];
        }
    }

    if (!prefs) {
        prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.82flex.trollvnc"];
    }

#if TARGET_IPHONE_SIMULATOR
    if (!prefs) {
        const char *sandboxPath = getenv("TROLLVNC_SANDBOX_PATH");
        if (sandboxPath && sandboxPath[0] != '\0') {
            NSString *sandbox = [NSString stringWithUTF8String:sandboxPath];
            NSString *plistPath =
                [sandbox stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.plist"];
            prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (prefs) {
                TVLog(@"-daemon: loaded simulator preferences from %@", plistPath);
            }
        }
    }
#endif

    if (!prefs) {
        TVLog(@"-daemon: no preferences found for domain com.82flex.trollvnc");
        return;
    }

    // Strings
    NSString *desktopName = [prefs objectForKey:@"DesktopName"];
    if ([desktopName isKindOfClass:[NSString class]] && desktopName.length > 0) {
        gDesktopName = desktopName;
    } else if (desktopName) {
        TVLog(@"-daemon: DesktopName is empty; using default '%@'", gDesktopName);
    }

    NSString *bindHost = [prefs objectForKey:@"BindHost"];
    if ([bindHost isKindOfClass:[NSString class]]) {
        if (bindHost.length > 0) {
            gBindHost = bindHost;
            TVLog(@"-daemon: BindHost=%@", gBindHost);
        } else {
            gBindHost = nil;
            TVLog(@"-daemon: BindHost empty; cleared to default (any)");
        }
    }

    // Port / HttpPort 端口固定不可调（5901/5801），不读 NSUserDefaults，忽略历史设置

    NSNumber *keepAliveN = [prefs objectForKey:@"KeepAliveSec"];
    if ([keepAliveN isKindOfClass:[NSNumber class]]) {
        double v = keepAliveN.doubleValue;
        if (v < 0.0) {
            TVLog(@"-daemon: KeepAliveSec < 0; set to 0");
            v = 0.0;
        } else if (v > 0.0 && v < 15.0) {
            TVLog(@"-daemon: KeepAliveSec < 15; treated as 0 (off)");
            v = 0.0;
        } else if (v > 300.0) {
            TVLog(@"-daemon: KeepAliveSec > 300; clamped to 300");
            v = 300.0;
        }
        gKeepAliveSec = v;
    }

    NSNumber *scaleN = [prefs objectForKey:@"Scale"];
    if ([scaleN isKindOfClass:[NSNumber class]]) {
        double v = scaleN.doubleValue;
        if (v <= 0.0 || v > 1.0) {
            TVLog(@"-daemon: invalid Scale=%.3f; clamped to [0.1..1.0]", v);
        }
        if (v < 0.1)
            v = 0.1;
        if (v > 1.0)
            v = 1.0;
        gScale = v;
    }

    NSNumber *deferN = [prefs objectForKey:@"DeferWindowSec"];
    if ([deferN isKindOfClass:[NSNumber class]]) {
        double v = deferN.doubleValue;
        if (v < 0.0) {
            TVLog(@"-daemon: DeferWindowSec < 0; set to 0");
            v = 0.0;
        }
        if (v > 0.5) {
            TVLog(@"-daemon: DeferWindowSec > 0.5; clamped to 0.5");
            v = 0.5;
        }
        gDeferWindowSec = v;
    }

    NSNumber *maxInflightN = [prefs objectForKey:@"MaxInflight"];
    if ([maxInflightN isKindOfClass:[NSNumber class]]) {
        int v = maxInflightN.intValue;
        if (v < 0) {
            TVLog(@"-daemon: MaxInflight < 0; set to 0");
            v = 0;
        }
        if (v > 8) {
            TVLog(@"-daemon: MaxInflight > 8; clamped to 8");
            v = 8;
        }
        gMaxInflightUpdates = v;
    }

    NSNumber *tileSizeN = [prefs objectForKey:@"TileSize"];
    if ([tileSizeN isKindOfClass:[NSNumber class]]) {
        int v = tileSizeN.intValue;
        if (v < 8) {
            TVLog(@"-daemon: TileSize < 8; set to 8");
            v = 8;
        }
        if (v > 128) {
            TVLog(@"-daemon: TileSize > 128; clamped to 128");
            v = 128;
        }
        gTileSize = v;
    }

    NSNumber *fullThreshN = [prefs objectForKey:@"FullscreenThresholdPercent"];
    if ([fullThreshN isKindOfClass:[NSNumber class]]) {
        int v = fullThreshN.intValue;
        if (v < 0) {
            TVLog(@"-daemon: FullscreenThresholdPercent < 0; set to 0");
            v = 0;
        }
        if (v > 100) {
            TVLog(@"-daemon: FullscreenThresholdPercent > 100; clamped to 100");
            v = 100;
        }
        gFullscreenThresholdPercent = v;
    }

    NSNumber *maxRectsN = [prefs objectForKey:@"MaxRects"];
    if ([maxRectsN isKindOfClass:[NSNumber class]]) {
        int v = maxRectsN.intValue;
        if (v < 1) {
            TVLog(@"-daemon: MaxRects < 1; set to 1");
            v = 1;
        }
        if (v > 4096) {
            TVLog(@"-daemon: MaxRects > 4096; clamped to 4096");
            v = 4096;
        }
        gMaxRectsLimit = v;
    }

    NSNumber *wheelPxN = [prefs objectForKey:@"WheelStepPx"];
    if ([wheelPxN isKindOfClass:[NSNumber class]]) {
        double v = wheelPxN.doubleValue;
        if (v == 0.0) {
            gWheelStepPx = 0.0;
            gWheelMaxStepPx = 0.0;
            TVLog(@"-daemon: Wheel emulation disabled (step=0)");
        } else {
            if (v <= 4.0) {
                TVLog(@"-daemon: WheelStepPx <= 4; raised to 5");
                v = 5.0;
            }
            if (v > 1000.0) {
                TVLog(@"-daemon: WheelStepPx > 1000; clamped to 1000");
                v = 1000.0;
            }
            gWheelStepPx = v;
            gWheelMaxStepPx = fmax(2.0 * gWheelStepPx, 96.0) * 1.0;
        }
    }

    // HttpPort 固定 5801（前端入口），不读 NSUserDefaults，忽略历史设置
    gHttpPort = 5801;

    // Booleans
    NSNumber *enableN = [prefs objectForKey:@"Enabled"];
    if ([enableN isKindOfClass:[NSNumber class]])
        gEnabled = enableN.boolValue;
    NSNumber *clipN = [prefs objectForKey:@"ClipboardEnabled"];
    if ([clipN isKindOfClass:[NSNumber class]])
        gClipboardEnabled = clipN.boolValue;
    NSNumber *viewOnlyN = [prefs objectForKey:@"ViewOnly"];
    if ([viewOnlyN isKindOfClass:[NSNumber class]])
        gViewOnly = viewOnlyN.boolValue;
    NSNumber *orientN = [prefs objectForKey:@"OrientationSync"];
    if ([orientN isKindOfClass:[NSNumber class]])
        gOrientationSyncEnabled = orientN.boolValue;
    NSNumber *orientFixN = [prefs objectForKey:@"OrientationPadFix"];
    if ([orientFixN isKindOfClass:[NSNumber class]]) {
        int v = orientFixN.intValue;
        gOrientationFixQuad = (v >= 0 && v <= 3) ? v : 0;
    }
    NSNumber *naturalN = [prefs objectForKey:@"NaturalScroll"];
    if ([naturalN isKindOfClass:[NSNumber class]])
        gWheelNaturalDir = naturalN.boolValue;
    NSNumber *cursorN = [prefs objectForKey:@"ServerCursor"];
    if ([cursorN isKindOfClass:[NSNumber class]])
        gCursorEnabled = cursorN.boolValue;
    NSNumber *asyncSwapN = [prefs objectForKey:@"AsyncSwap"];
    if ([asyncSwapN isKindOfClass:[NSNumber class]])
        gAsyncSwapEnabled = asyncSwapN.boolValue;
    NSNumber *keyLogN = [prefs objectForKey:@"KeyLogging"];
    if ([keyLogN isKindOfClass:[NSNumber class]])
        gKeyEventLogging = keyLogN.boolValue;
    NSNumber *assistN = [prefs objectForKey:@"AutoAssistEnabled"];
    if ([assistN isKindOfClass:[NSNumber class]])
        gAutoAssistEnabled = assistN.boolValue;
    NSNumber *bonjourN = [prefs objectForKey:@"BonjourEnabled"];
    if ([bonjourN isKindOfClass:[NSNumber class]])
        gBonjourEnabled = bonjourN.boolValue;
    NSNumber *fileN = [prefs objectForKey:@"FileTransferEnabled"];
    if ([fileN isKindOfClass:[NSNumber class]])
        gFileTransferEnabled = fileN.boolValue;
    NSNumber *singleNotifN = [prefs objectForKey:@"SingleNotifEnabled"];
    if ([singleNotifN isKindOfClass:[NSNumber class]])
        gUserSingleNotifsEnabled = singleNotifN.boolValue;
    NSNumber *clientNotifsN = [prefs objectForKey:@"ClientNotifsEnabled"];
    if ([clientNotifsN isKindOfClass:[NSNumber class]])
        gUserClientNotifsEnabled = clientNotifsN.boolValue;

    // Modifier mapping
    NSString *modMap = [prefs objectForKey:@"ModifierMap"];
    if ([modMap isKindOfClass:[NSString class]]) {
        if ([modMap isEqualToString:@"altcmd"])
            gModMapScheme = 1;
        else
            gModMapScheme = 0;
    }

    // Frame rate spec (validate and normalize) — 复用 parseFrameRateSpec（Phase 4.4 统一解析）
    NSString *fpsSpec = [prefs objectForKey:@"FrameRateSpec"];
    if ([fpsSpec isKindOfClass:[NSString class]] && fpsSpec.length > 0) {
        parseFrameRateSpec(fpsSpec.UTF8String ?: "");
    }

    // Wheel tuning (advanced)
    NSString *wheelTuning = [prefs objectForKey:@"WheelTuning"];
    if ([wheelTuning isKindOfClass:[NSString class]] && wheelTuning.length > 0) {
        parseWheelOptions(wheelTuning.UTF8String);
    }

    // HTTP dir override and SSL (require absolute paths)
    NSString *httpDir = [prefs objectForKey:@"HttpDir"];
    if ([httpDir isKindOfClass:[NSString class]] && httpDir.length > 0) {
        if (![httpDir hasPrefix:@"/"]) {
            TVLog(@"-daemon: HttpDir must be absolute: %@ (ignored)", httpDir);
        } else {
            gHttpDirOverride = strdup(httpDir.fileSystemRepresentation);
        }
    }
    NSString *sslCert = [prefs objectForKey:@"SslCertFile"];
    if ([sslCert isKindOfClass:[NSString class]] && sslCert.length > 0) {
        if (![sslCert hasPrefix:@"/"]) {
            TVLog(@"-daemon: SslCertFile must be absolute: %@ (ignored)", sslCert);
        } else {
            gSslCertPath = strdup(sslCert.fileSystemRepresentation);
        }
    }
    NSString *sslKey = [prefs objectForKey:@"SslKeyFile"];
    if ([sslKey isKindOfClass:[NSString class]] && sslKey.length > 0) {
        if (![sslKey hasPrefix:@"/"]) {
            TVLog(@"-daemon: SslKeyFile must be absolute: %@ (ignored)", sslKey);
        } else {
            gSslKeyPath = strdup(sslKey.fileSystemRepresentation);
        }
    }

    // Passwords via environment (leveraging existing setupRfbClassicAuthentication).
    // Classic VNC authentication uses only first 8 chars; truncate here for clarity.
    NSString *fullPwd = [prefs objectForKey:@"FullPassword"];
    BOOL hasFullPwd = NO, hasViewPwd = NO;
    if ([fullPwd isKindOfClass:[NSString class]]) {
        NSString *trunc = (fullPwd.length > 8) ? [fullPwd substringToIndex:8] : fullPwd;
        setenv("TROLLVNC_PASSWORD", trunc.UTF8String ?: "", 1);
        hasFullPwd = (trunc.length > 0);
    }
    NSString *viewPwd = [prefs objectForKey:@"ViewOnlyPassword"];
    if ([viewPwd isKindOfClass:[NSString class]]) {
        NSString *trunc = (viewPwd.length > 8) ? [viewPwd substringToIndex:8] : viewPwd;
        setenv("TROLLVNC_VIEWONLY_PASSWORD", trunc.UTF8String ?: "", 1);
        hasViewPwd = (trunc.length > 0);
    }

    // Single-line summary using NSMutableString
    NSMutableString *cfg = [NSMutableString stringWithFormat:@"-daemon: cfg "];
    [cfg appendFormat:@"name='%@' ", gDesktopName];
    [cfg appendFormat:@"bindHost='%@' ", gBindHost];
    [cfg appendFormat:@"port=%d http=%d ", gPort, gHttpPort];

    // Core feature flags
    [cfg appendFormat:@"viewOnly=%@ clip=%@ keepAlive=%.0fs ", gViewOnly ? @"YES" : @"NO",
                      gClipboardEnabled ? @"YES" : @"NO", gKeepAliveSec];
    [cfg appendFormat:@"scale=%.2f fps=%d:%d:%d defer=%.3f ", gScale, gFpsMin, gFpsPref, gFpsMax, gDeferWindowSec];
    [cfg appendFormat:@"inflight=%d tile=%d full%%=%d rects=%d ", gMaxInflightUpdates, gTileSize,
                      gFullscreenThresholdPercent, gMaxRectsLimit];
    [cfg appendFormat:@"async=%@ cursor=%@ orient=%@ orientFix=%d keylog=%@ ", gAsyncSwapEnabled ? @"YES" : @"NO",
                      gCursorEnabled ? @"YES" : @"NO", gOrientationSyncEnabled ? @"YES" : @"NO",
                      gOrientationFixQuad, gKeyEventLogging ? @"YES" : @"NO"];

    // Wheel / input tuning
    [cfg appendFormat:@"wheel=%.1f natural=%@ mod=%s ", gWheelStepPx, gWheelNaturalDir ? @"YES" : @"NO",
                      (gModMapScheme == 1) ? "altcmd" : "std"];

    // Networking / discovery
    [cfg appendFormat:@"bonjour=%@ ", gBonjourEnabled ? @"on" : @"off"];
    [cfg appendFormat:@"fileXfer=%@ ", gFileTransferEnabled ? @"on" : @"off"];

    // Auth and paths
    [cfg appendFormat:@"auth(full=%@,view=%@,8char) ", hasFullPwd ? @"on" : @"off", hasViewPwd ? @"on" : @"off"];
    NSString *dirStr = gHttpDirOverride ? [NSString stringWithUTF8String:gHttpDirOverride] : nil;
    NSString *certStr = gSslCertPath ? [NSString stringWithUTF8String:gSslCertPath] : nil;
    NSString *keyStr = gSslKeyPath ? [NSString stringWithUTF8String:gSslKeyPath] : nil;
    [cfg appendFormat:@"dir=%@ cert=%@ key=%@", dirStr, certStr, keyStr];

    TVLog(@"%@", cfg);
    TVLog(@"-daemon: preferences applied (domain=com.82flex.trollvnc)");
}

static void parseCLI(int argc, const char *argv[]) {
    // Special mode: -daemon reads configuration from NSUserDefaults domain
    // com.82flex.trollvnc and initializes runtime options accordingly.
    BOOL isDaemon = NO;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-daemon") == 0) {
            isDaemon = YES;
            break;
        }
    }
    if (isDaemon) {
        parseDaemonOptions();
        return;
    }

    // Prepare argv for getopt
    std::vector<const char *> __filtered;
    __filtered.reserve((size_t)argc);
    for (int i = 0; i < argc; ++i)
        __filtered.push_back(argv[i]);

    // Prepare argv for getopt from filtered vector
    int __argc2 = (int)__filtered.size();
    std::vector<char *> __argv2;
    __argv2.reserve(__filtered.size());
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc++11-extensions"
    for (const char *s : __filtered)
        __argv2.push_back(const_cast<char *>(s));
#pragma clang diagnostic pop

    int opt;
    const char *optstr = "p:b:n:vA:C:s:F:d:Q:t:P:R:aW:w:NM:KU:O:o:I:i:H:D:e:k:B:T:Vh";
    optind = 1;
    while ((opt = getopt(__argc2, __argv2.data(), optstr)) != -1) {
        switch (opt) {
        case 'b': {
            if (!optarg || !*optarg) {
                TVPrintError("-b requires a non-empty host name or address");
                exit(EXIT_FAILURE);
            }
            gBindHost = [NSString stringWithUTF8String:optarg];
            TVLog(@"CLI: Bind host set to '%@'", gBindHost);
            break;
        }
        case 'p': {
            long port = strtol(optarg, NULL, 10);
            if (port <= 0 || port > 65535) {
                TVPrintError("Invalid port: %s", optarg);
                exit(EXIT_FAILURE);
            }
            gPort = (int)port;
            TVLog(@"CLI: Port set to %d", gPort);
            break;
        }
        case 'n': {
            gDesktopName = [NSString stringWithUTF8String:optarg ?: "SuperPhone"];
            TVLog(@"CLI: Desktop name set to '%@'", gDesktopName);
            break;
        }
        case 'v': {
            gViewOnly = YES;
            TVLog(@"CLI: View-only mode enabled (-v)");
            break;
        }
        case 'A': {
            double sec = strtod(optarg ? optarg : "0", NULL);
            if (sec < 15.0 || sec > 24 * 3600.0) {
                TVPrintError("Invalid keep-alive seconds: %s (expected 15..86400)", optarg);
                exit(EXIT_FAILURE);
            }
            gKeepAliveSec = sec;
            TVLog(@"CLI: KeepAlive interval set to %.3f sec (-A)", gKeepAliveSec);
            break;
        }
        case 'C': {
            const char *val = optarg ? optarg : "on";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gClipboardEnabled = YES;
                TVLog(@"CLI: Clipboard sync enabled (-C %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gClipboardEnabled = NO;
                TVLog(@"CLI: Clipboard sync disabled (-C %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -C value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 's': {
            double sc = strtod(optarg, NULL);
            if (!(sc > 0.0 && sc <= 1.0)) {
                TVPrintError("Invalid scale: %s (expected 0 < s <= 1)", optarg);
                exit(EXIT_FAILURE);
            }
            gScale = sc;
            TVLog(@"CLI: Output scale factor set to %.3f", gScale);
            break;
        }
        case 'F': {
            // Accept formats: "fps", "min-max", "min:pref:max"
            const char *spec = optarg ? optarg : "";
            int minV = 0, prefV = 0, maxV = 0;
            if (spec[0] == '\0') {
                break; // ignore empty
            }
            const char *colon1 = strchr(spec, ':');
            const char *dash = strchr(spec, '-');
            if (colon1) {
                // min:pref:max
                long a = strtol(spec, NULL, 10);
                const char *p2 = colon1 + 1;
                const char *colon2 = strchr(p2, ':');
                if (!colon2) {
                    TVPrintError("Invalid -F spec: %s (expected min:pref:max)", spec);
                    exit(EXIT_FAILURE);
                }
                long b = strtol(p2, NULL, 10);
                long c = strtol(colon2 + 1, NULL, 10);
                minV = (int)a;
                prefV = (int)b;
                maxV = (int)c;
            } else if (dash) {
                // min-max (preferred defaults to max)
                long a = strtol(spec, NULL, 10);
                long b = strtol(dash + 1, NULL, 10);
                minV = (int)a;
                prefV = (int)b;
                maxV = (int)b;
            } else {
                // single fps
                long v = strtol(spec, NULL, 10);
                minV = (int)v;
                prefV = (int)v;
                maxV = (int)v;
            }
            // Normalize & validate: allow 0..240 (0 = unspecified)
            if (minV < 0)
                minV = 0;
            if (minV > 240)
                minV = 240;
            if (prefV < 0)
                prefV = 0;
            if (prefV > 240)
                prefV = 240;
            if (maxV < 0)
                maxV = 0;
            if (maxV > 240)
                maxV = 240;
            if (minV > 0 && maxV > 0 && minV > maxV) {
                int tmp = minV;
                minV = maxV;
                maxV = tmp;
            }
            if (prefV > 0) {
                if (minV > 0 && prefV < minV)
                    prefV = minV;
                if (maxV > 0 && prefV > maxV)
                    prefV = maxV;
            }
            gFpsMin = minV;
            gFpsPref = prefV;
            gFpsMax = maxV;
            TVLog(@"CLI: FPS preference set to min=%d pref=%d max=%d", gFpsMin, gFpsPref, gFpsMax);
            break;
        }
        case 'd': {
            double s = strtod(optarg, NULL);
            if (s < 0.0 || s > 0.5) {
                TVPrintError("Invalid defer window seconds: %s (expected 0..0.5)", optarg);
                exit(EXIT_FAILURE);
            }
            gDeferWindowSec = s;
            TVLog(@"CLI: Defer window set to %.3f sec", gDeferWindowSec);
            break;
        }
        case 'Q': {
            long q = strtol(optarg, NULL, 10);
            if (q < 0 || q > 8) {
                TVPrintError("Invalid max in-flight: %s (expected 0..8)", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxInflightUpdates = (int)q;
            TVLog(@"CLI: Max in-flight updates set to %d", gMaxInflightUpdates);
            break;
        }
        case 't': {
            long ts = strtol(optarg, NULL, 10);
            if (ts < 8 || ts > 128) {
                TVPrintError("Invalid tile size: %s (expected 8..128)", optarg);
                exit(EXIT_FAILURE);
            }
            gTileSize = (int)ts;
            TVLog(@"CLI: Tile size set to %d", gTileSize);
            break;
        }
        case 'P': {
            long p = strtol(optarg, NULL, 10);
            if (p < 0 || p > 100) {
                TVPrintError("Invalid threshold percent: %s (expected 0..100; 0 disables dirty detection)", optarg);
                exit(EXIT_FAILURE);
            }
            gFullscreenThresholdPercent = (int)p;
            TVLog(@"CLI: Fullscreen threshold percent set to %d", gFullscreenThresholdPercent);
            break;
        }
        case 'R': {
            long m = strtol(optarg, NULL, 10);
            if (m < 1 || m > 4096) {
                TVPrintError("Invalid max rects: %s (expected 1..4096)", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxRectsLimit = (int)m;
            TVLog(@"CLI: Max rects limit set to %d", gMaxRectsLimit);
            break;
        }
        case 'a': {
            gAsyncSwapEnabled = YES;
            TVLog(@"CLI: Non-blocking swap enabled (-a)");
            break;
        }
        case 'W': {
            double px = strtod(optarg, NULL);
            if (px == 0.0) {
                // 0 disables wheel emulation
                gWheelStepPx = 0.0;
                gWheelMaxStepPx = 0.0;
                TVLog(@"CLI: Wheel emulation disabled (-W 0)");
                break;
            }
            if (!(px > 4.0 && px <= 1000.0)) {
                TVPrintError("Invalid wheel step px: %s (expected 0 or >4..<=1000)", optarg);
                exit(EXIT_FAILURE);
            }
            gWheelStepPx = px;
            // Scale max step roughly 4x and adjust duration slope mildly
            gWheelMaxStepPx = fmax(2.0 * gWheelStepPx, 96.0) * 1.0;
            TVLog(@"CLI: Wheel step set to %.1f px (max=%.1f)", gWheelStepPx, gWheelMaxStepPx);
            break;
        }
        case 'w': {
            parseWheelOptions(optarg);
            break;
        }
        case 'N': {
            gWheelNaturalDir = YES;
            TVLog(@"CLI: Natural scroll direction enabled (-N)");
            break;
        }
        case 'M': {
            const char *val = optarg ? optarg : "std";
            if (strcmp(val, "std") == 0)
                gModMapScheme = 0;
            else if (strcmp(val, "altcmd") == 0)
                gModMapScheme = 1;
            else {
                TVPrintError("Invalid -M scheme: %s (expected std|altcmd)", val);
                exit(EXIT_FAILURE);
            }
            TVLog(@"CLI: Modifier mapping set to %s", gModMapScheme == 0 ? "std" : "altcmd");
            break;
        }
        case 'K': {
            gKeyEventLogging = YES;
            TVLog(@"CLI: Keyboard event logging enabled (-K)");
            break;
        }
        case 'E': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gAutoAssistEnabled = YES;
                TVLog(@"CLI: AssistiveTouch auto-activation enabled (-E %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gAutoAssistEnabled = NO;
                TVLog(@"CLI: AssistiveTouch auto-activation disabled (-E %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -E value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'U': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gCursorEnabled = YES;
                TVLog(@"CLI: Cursor enabled (-U %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gCursorEnabled = NO;
                TVLog(@"CLI: Cursor disabled (-U %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -U value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'O': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gOrientationSyncEnabled = YES;
                TVLog(@"CLI: Orientation observer enabled (-O %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gOrientationSyncEnabled = NO;
                TVLog(@"CLI: Orientation observer disabled (-O %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -O value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'o': {
            const char *val = optarg ? optarg : "0";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gOrientationFixQuad = 3; // legacy: "on" means 270° (original behavior)
                TVLog(@"CLI: Orientation fix quad=3 (-o %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gOrientationFixQuad = 0;
                TVLog(@"CLI: Orientation fix quad=0 (-o %s)", [@(val) UTF8String]);
            } else {
                long v = strtol(val, NULL, 10);
                if (v >= 0 && v <= 3) {
                    gOrientationFixQuad = (int)v;
                    TVLog(@"CLI: Orientation fix quad=%d (-o %s)", gOrientationFixQuad, [@(val) UTF8String]);
                } else {
                    TVPrintError("Invalid -o value: %s (expected 0..3 or on|off)", val);
                    exit(EXIT_FAILURE);
                }
            }
            break;
        }
        case 'I': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gUserClientNotifsEnabled = YES;
                TVLog(@"CLI: Client user notifications enabled (-I %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gUserClientNotifsEnabled = NO;
                TVLog(@"CLI: Client user notifications disabled (-I %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -I value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'i': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gUserSingleNotifsEnabled = YES;
                TVLog(@"CLI: Single user notifications enabled (-i %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gUserSingleNotifsEnabled = NO;
                TVLog(@"CLI: Single user notifications disabled (-i %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -i value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'H': {
            long hp = strtol(optarg ? optarg : "0", NULL, 10);
            if (hp < 0 || hp > 65535) {
                TVPrintError("Invalid HTTP port: %s (expected 0..65535)", optarg);
                exit(EXIT_FAILURE);
            }
            gHttpPort = (int)hp;
            TVLog(@"CLI: HTTP port set to %d (-H)", gHttpPort);
            break;
        }
        case 'D': {
            const char *path = optarg ? optarg : "";
            if (!path || path[0] != '/') {
                TVPrintError("Invalid httpDir path for -D: %s (must be absolute)", path);
                exit(EXIT_FAILURE);
            }
            gHttpDirOverride = strdup(path);
            TVLog(@"CLI: HTTP dir override set to %s (-D)", path);
            break;
        }
        case 'e': {
            const char *path = optarg ? optarg : "";
            if (!path || !*path) {
                TVPrintError("Invalid value for -e (sslcertfile)");
                exit(EXIT_FAILURE);
            }
            gSslCertPath = strdup(path);
            TVLog(@"CLI: SSL cert file set (-e %s)", path);
            break;
        }
        case 'k': {
            const char *path = optarg ? optarg : "";
            if (!path || !*path) {
                TVPrintError("Invalid value for -k (sslkeyfile)");
                exit(EXIT_FAILURE);
            }
            gSslKeyPath = strdup(path);
            TVLog(@"CLI: SSL key file set (-k %s)", path);
            break;
        }
        case 'B': {
            const char *val = optarg ? optarg : "on";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gBonjourEnabled = YES;
                TVLog(@"CLI: Bonjour advertisement enabled (-B %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gBonjourEnabled = NO;
                TVLog(@"CLI: Bonjour advertisement disabled (-B %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -B value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'T': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gFileTransferEnabled = YES;
                TVLog(@"CLI: TightVNC 1.x file transfer extension enabled (-T %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gFileTransferEnabled = NO;
                TVLog(@"CLI: TightVNC 1.x file transfer extension disabled (-T %s)", [@(val) UTF8String]);
            } else {
                TVPrintError("Invalid -T value: %s (expected on|off|1|0|true|false)", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'V': {
            tvncVerboseLoggingEnabled = YES;
            TVLog(@"CLI: Verbose logging enabled (-V)");
            break;
        }
        case 'h':
        default: {
            printUsageAndExit(argv[0]);
            break;
        }
        }
    }
}

#pragma mark - Display

static rfbScreenInfoPtr gScreen = NULL;
static void (^gFrameHandler)(CMSampleBufferRef) = nil;

static int gWidth = 0;
static int gHeight = 0;
static int gSrcWidth = 0;      // capture source width
static int gSrcHeight = 0;     // capture source height
static size_t gFBSize = 0;     // in bytes
static int gBytesPerPixel = 4; // ARGB/BGRA 32-bit

static void *gFrontBuffer = NULL; // Exposed to VNC clients via gScreen->frameBuffer
static void *gBackBuffer = NULL;  // We render into this and then swap

// Hash algorithm selection (auto: prefer CRC32 on ARM with hardware support)
#if DEBUG
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
static const BOOL cUseCRC32Hash = YES;
#else
static const BOOL cUseCRC32Hash = NO;
#endif
#endif

typedef struct {
    int x, y, w, h;
} DirtyRect;

#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
NS_INLINE uint64_t crc32_update(uint64_t h, const uint8_t *data, size_t len) {
    uint32_t c = (uint32_t)h;
    const uint8_t *p = data;
    size_t n = len;
    // Process 8-byte chunks
    while (n >= 8) {
        uint64_t v;
        // Unaligned load is acceptable on ARM64; use memcpy to be safe for strict aliasing.
        memcpy(&v, p, sizeof(v));
        c = __builtin_arm_crc32d(c, v);
        p += 8;
        n -= 8;
    }
    if (n >= 4) {
        uint32_t v32;
        memcpy(&v32, p, sizeof(v32));
        c = __builtin_arm_crc32w(c, v32);
        p += 4;
        n -= 4;
    }
    if (n >= 2) {
        uint16_t v16;
        memcpy(&v16, p, sizeof(v16));
        c = __builtin_arm_crc32h(c, v16);
        p += 2;
        n -= 2;
    }
    if (n) {
        c = __builtin_arm_crc32b(c, *p);
    }
    return (uint64_t)c;
}
#else
NS_INLINE uint64_t fnv1a_basis(void) { return 1469598103934665603ULL; }
NS_INLINE uint64_t fnv1a_update(uint64_t h, const uint8_t *data, size_t len) {
    const uint64_t FNV_PRIME = 1099511628211ULL;
    for (size_t i = 0; i < len; ++i) {
        h ^= (uint64_t)data[i];
        h *= FNV_PRIME;
    }
    return h;
}
#endif

// Generic hash wrappers: prefer hardware CRC32 when enabled and available, else fallback to FNV-1a.
NS_INLINE uint64_t hash_basis(void) {
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
    return 0u; // CRC32 initial accumulator
#else
    return fnv1a_basis();
#endif
}

NS_INLINE uint64_t hash_update(uint64_t h, const uint8_t *data, size_t len) {
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
    return crc32_update(h, data, len);
#else
    // If CRC32 not supported at compile time, fallback to FNV-1a
    return fnv1a_update(h, data, len);
#endif
}

#pragma mark - Display Tiling

static int gTilesX = 0;
static int gTilesY = 0;
static size_t gTileCount = 0;
static uint64_t *gPrevHash = NULL;
static uint64_t *gCurrHash = NULL;
static uint8_t *gPendingDirty = NULL; // per-tile pending dirty mask
static BOOL gHasPending = NO;

static void initializeTilingOrReset(void) {
    int tilesX = (gWidth + gTileSize - 1) / gTileSize;
    int tilesY = (gHeight + gTileSize - 1) / gTileSize;
    size_t tileCount = (size_t)tilesX * (size_t)tilesY;

    if (tilesX != gTilesX || tilesY != gTilesY || tileCount != gTileCount || !gPrevHash || !gCurrHash) {
        free(gPrevHash);
        free(gCurrHash);

        if (gPendingDirty) {
            free(gPendingDirty);
            gPendingDirty = NULL;
        }

        gPrevHash = (uint64_t *)malloc(tileCount * sizeof(uint64_t));
        gCurrHash = (uint64_t *)malloc(tileCount * sizeof(uint64_t));
        gPendingDirty = (uint8_t *)malloc(tileCount);

        if (!gPrevHash || !gCurrHash) {
            TVPrintError("Out of memory for tile hashes");
            exit(EXIT_FAILURE);
        }

        for (size_t i = 0; i < tileCount; ++i) {
            gPrevHash[i] = 0; // force full update first frame
            gCurrHash[i] = hash_basis();
        }

        gTilesX = tilesX;
        gTilesY = tilesY;
        gTileCount = tileCount;

        if (gPendingDirty)
            memset(gPendingDirty, 0, gTileCount);
    } else {
        for (size_t i = 0; i < gTileCount; ++i) {
            gCurrHash[i] = hash_basis();
        }
    }
}

NS_INLINE void swapTileHashes(void) {
    uint64_t *tmp = gPrevHash;
    gPrevHash = gCurrHash;
    gCurrHash = tmp;
}

NS_INLINE void resetCurrTileHashes(void) {
    if (!gCurrHash || gTileCount == 0)
        return;
    uint64_t basis = hash_basis();
    for (size_t i = 0; i < gTileCount; ++i) {
        gCurrHash[i] = basis;
    }
}

// Accumulate pending dirty tiles for time-based coalescing
NS_INLINE void accumulatePendingDirty(void) {
    if (!gPendingDirty)
        return;

    for (size_t i = 0; i < gTileCount; ++i) {
        if (gCurrHash[i] != gPrevHash[i])
            gPendingDirty[i] = 1;
    }
}

NS_INLINE void hashTiledFromBuffer(const uint8_t *buf, int width, int height, size_t bpr) {
    resetCurrTileHashes();
    for (int y = 0; y < height; ++y) {
        int ty = y / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t offset = (size_t)startX * (size_t)gBytesPerPixel;
            size_t length = (size_t)(endX - startX) * (size_t)gBytesPerPixel;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], buf + (size_t)y * bpr + offset, length);
        }
    }
}

// Sparse sampling hash: sample a subset of pixels per tile to reduce bandwidth.
NS_INLINE void hashTiledFromBufferSparse(const uint8_t *buf, int width, int height, size_t bpr, int sx, int sy) {
    if (sx < 1)
        sx = 1;
    if (sy < 1)
        sy = 1;
    resetCurrTileHashes();
    for (int y = 0; y < height; y += sy) {
        int ty = y / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            for (int x = startX; x < endX; x += sx) {
                const uint8_t *p = buf + (size_t)y * bpr + (size_t)x * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
            // Ensure last column contributes even if not aligned to stride
            int lastX = endX - 1;
            if (lastX >= startX && ((endX - startX - 1) % sx) != 0) {
                const uint8_t *p = buf + (size_t)y * bpr + (size_t)lastX * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
        }
    }
    // Also sample the last row if height-1 isn't covered by the stride
    int lastY = height - 1;
    if (lastY >= 0 && ((height - 1) % sy) != 0) {
        int ty = lastY / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            for (int x = startX; x < endX; x += sx) {
                const uint8_t *p = buf + (size_t)lastY * bpr + (size_t)x * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
            int lastX = endX - 1;
            if (lastX >= startX && ((endX - startX - 1) % sx) != 0) {
                const uint8_t *p = buf + (size_t)lastY * bpr + (size_t)lastX * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
        }
    }
}

// Parallel full hash over tiles: split by tile rows to reduce wall clock at flush.
NS_INLINE void hashTiledFromBufferParallel(const uint8_t *buf, int width, int height, size_t bpr, int threads) {
    if (threads <= 1) {
        hashTiledFromBuffer(buf, width, height, bpr);
        return;
    }
    resetCurrTileHashes();
    // Split by tile row bands
    int tilesY = gTilesY;
    if (tilesY <= 0)
        return;
    int bands = threads;
    if (bands > tilesY)
        bands = tilesY;
    dispatch_group_t grp = dispatch_group_create();
    for (int band = 0; band < bands; ++band) {
        dispatch_group_async(grp, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            for (int ty = band; ty < tilesY; ty += bands) {
                int startY = ty * gTileSize;
                int endY = startY + gTileSize;
                if (startY >= height)
                    break;
                if (endY > height)
                    endY = height;
                for (int y = startY; y < endY; ++y) {
                    for (int tx = 0; tx < gTilesX; ++tx) {
                        int startX = tx * gTileSize;
                        if (startX >= width)
                            break;
                        int endX = startX + gTileSize;
                        if (endX > width)
                            endX = width;
                        size_t offset = (size_t)startX * (size_t)gBytesPerPixel;
                        size_t length = (size_t)(endX - startX) * (size_t)gBytesPerPixel;
                        size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
                        // Each tileIndex is updated by a single band (fixed ty), no race across bands.
                        gCurrHash[tileIndex] =
                            hash_update(gCurrHash[tileIndex], buf + (size_t)y * bpr + offset, length);
                    }
                }
            }
        });
    }
    dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
}

// Build dirty rectangles from tile hash diffs. Returns number of rects written, up to maxRects.
static int buildDirtyRects(DirtyRect *rects, int maxRects, int *outChangedTiles) {
    int rectCount = 0;
    int changedTiles = 0;

    // First pass: horizontal merge per tile row
    for (int ty = 0; ty < gTilesY; ++ty) {
        int tx = 0;
        while (tx < gTilesX) {
            size_t idx = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            int changed = (gCurrHash[idx] != gPrevHash[idx]);
            if (!changed) {
                tx++;
                continue;
            }

            // Start of a run
            int runStart = tx;
            changedTiles++;
            tx++;
            while (tx < gTilesX) {
                size_t idx2 = (size_t)ty * (size_t)gTilesX + (size_t)tx;
                if (gCurrHash[idx2] != gPrevHash[idx2]) {
                    changedTiles++;
                    tx++;
                } else
                    break;
            }

            // Emit rect for this horizontal run
            if (rectCount < maxRects) {
                int x = runStart * gTileSize;
                int w = (tx - runStart) * gTileSize;
                int y = ty * gTileSize;
                int h = gTileSize;
                // Clip to screen bounds
                if (x + w > gWidth)
                    w = gWidth - x;
                if (y + h > gHeight)
                    h = gHeight - y;
                rects[rectCount++] = (DirtyRect){x, y, w, h};
            } else {
                // Too many rects; caller may fallback to fullscreen
                if (outChangedTiles)
                    *outChangedTiles = changedTiles;
                return rectCount;
            }
        }
    }

    // Optional vertical merge: merge rects with same x,w and contiguous vertically
    // Simple O(n^2) merge for small rect counts
    for (int i = 0; i < rectCount; ++i) {
        for (int j = i + 1; j < rectCount; ++j) {
            if (rects[j].w == 0 || rects[j].h == 0)
                continue;
            if (rects[i].x == rects[j].x && rects[i].w == rects[j].w) {
                if (rects[i].y + rects[i].h == rects[j].y) {
                    rects[i].h += rects[j].h;
                    rects[j].w = rects[j].h = 0; // mark removed
                } else if (rects[j].y + rects[j].h == rects[i].y) {
                    rects[j].h += rects[i].h;
                    rects[i].w = rects[i].h = 0;
                }
            }
        }
    }

    // Compact removed entries
    int k = 0;
    for (int i = 0; i < rectCount; ++i) {
        if (rects[i].w > 0 && rects[i].h > 0)
            rects[k++] = rects[i];
    }

    rectCount = k;
    if (outChangedTiles)
        *outChangedTiles = changedTiles;
    return rectCount;
}

// Build rects from pending mask by temporarily mapping to hashes
static int buildRectsFromPending(DirtyRect *rects, int maxRects) {
    if (!gPendingDirty)
        return 0;

    // Temporarily mark curr!=prev for pending tiles
    // Save originals
    // For efficiency, we only synthesize gCurrHash markers without touching buffers
    size_t changed = 0;
    for (size_t i = 0; i < gTileCount; ++i) {
        if (gPendingDirty[i]) {
            if (gCurrHash[i] == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL;
            changed++;
        }
    }

    int dummyTiles = 0;
    int cnt = buildDirtyRects(rects, maxRects, &dummyTiles);

    // Restore hashes for tiles we toggled
    for (size_t i = 0; i < gTileCount; ++i) {
        if (gPendingDirty[i]) {
            if (gCurrHash[i] == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL; // unlikely path
            else if ((gCurrHash[i] ^ 0x1ULL) == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL;
        }
    }

    (void)changed;
    return cnt;
}

NS_INLINE void markRectsModified(DirtyRect *rects, int rectCount) {
    for (int i = 0; i < rectCount; ++i) {
        rfbMarkRectAsModified(gScreen, rects[i].x, rects[i].y, rects[i].x + rects[i].w, rects[i].y + rects[i].h);
    }
}

NS_INLINE void copyRectsFromBackToFront(DirtyRect *rects, int rectCount) {
    size_t fbBPR = (size_t)gWidth * (size_t)gBytesPerPixel;
    for (int i = 0; i < rectCount; ++i) {
        int x = rects[i].x, y = rects[i].y, w = rects[i].w, h = rects[i].h;
        size_t rowBytes = (size_t)w * (size_t)gBytesPerPixel;
        for (int r = 0; r < h; ++r) {
            uint8_t *dst = (uint8_t *)gFrontBuffer + (size_t)(y + r) * fbBPR + (size_t)x * gBytesPerPixel;
            uint8_t *src = (uint8_t *)gBackBuffer + (size_t)(y + r) * fbBPR + (size_t)x * gBytesPerPixel;
            memcpy(dst, src, rowBytes);
        }
    }
}

#pragma mark - Display Hooks

static std::atomic<int> gInflight(0);

// Track encode life-cycle to provide backpressure via inflight counter
static void displayHook(rfbClientPtr cl) {
    (void)cl;
    gInflight.fetch_add(1, std::memory_order_relaxed);
}

static void displayFinishedHook(rfbClientPtr cl, int result) {
    (void)cl;
    (void)result;
    gInflight.fetch_sub(1, std::memory_order_relaxed);
}

static int setDesktopSizeHook(int width, int height, int numScreens, rfbExtDesktopScreen *extDesktopScreens,
                              rfbClientPtr cl) {
    (void)cl;
    (void)numScreens;
    (void)extDesktopScreens;
    [[ScreenCapturer sharedCapturer] forceNextFrameUpdate];
    // We do not support client-initiated resizing
    return rfbExtDesktopSize_ResizeProhibited;
}

#pragma mark - Display Tiling Constants

// Hashing performance controls
static const int cHashStrideX = 4;              // sparse sampling stride X (>=1; 1 = full scan)
static const int cHashStrideY = 4;              // sparse sampling stride Y (>=1; 1 = full scan)
static const BOOL cSparseHashDuringDefer = YES; // use sparse hashing while within defer window
// Skip vImage scaling when src/dst size difference is small; copy with pad/crop instead
static const int cNoScalePadThresholdPx = 8; // if both |dW| and |dH| <= this, do pad/crop copy

// Flush-time hashing optimization
static const BOOL cParallelHashOnFlush = YES; // use parallel hashing at flush to reduce wall time

#pragma mark - Frame Handlers

static std::atomic<int> gRotationQuad(0); // 0=0°, 1=90°, 2=180°, 3=270° (clockwise)
static void *gRotateScratch = NULL;       // rotation scratch (for 90°/270°)
static size_t gRotateScratchSize = 0;     // bytes
static void *gScaleTemp = NULL;           // vImage scale temp buffer
static size_t gScaleTempSize = 0;         // bytes

// Align width up to a multiple of 4 (helps encoders/clients). Preserve aspect by adjusting height.
NS_INLINE void alignDimensions(int rawW, int rawH, int *alignedW, int *alignedH) {
    if (rawW <= 0)
        rawW = 1;
    if (rawH <= 0)
        rawH = 1;
    // Round width up to next multiple of 4
    int w4 = (rawW + 3) & ~3;
    long long numer = (long long)rawH * (long long)w4;
    int hAdj = (int)((numer + rawW / 2) / rawW); // rounded to nearest
    if (hAdj <= 0)
        hAdj = 1;
    *alignedW = w4;
    *alignedH = hAdj;
}

// Resize framebuffer according to rotation (0/180 keep WxH from src, 90/270 swap), then apply scale
NS_INLINE void maybeResizeFramebufferForRotation(int rotQ) {
    // Source capture size (portrait-orientated)
    int srcW = gSrcWidth;
    int srcH = gSrcHeight;
    if (srcW <= 0 || srcH <= 0)
        return;

    // Rotate at source dimension stage
    int rotW = (rotQ % 2 == 0) ? srcW : srcH;
    int rotH = (rotQ % 2 == 0) ? srcH : srcW;

    // Apply output scaling then align width to multiple of 4 (adjust height to preserve aspect)
    int outWraw = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)rotW * gScale)) : rotW;
    int outHraw = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)rotH * gScale)) : rotH;
    int outW = 0, outH = 0;
    alignDimensions(outWraw, outHraw, &outW, &outH);

    if (outW == gWidth && outH == gHeight)
        return; // no change

    // Allocate new double buffers
    size_t newFBSize = (size_t)outW * (size_t)outH * (size_t)gBytesPerPixel;
    void *newFront = calloc(1, newFBSize);
    void *newBack = calloc(1, newFBSize);
    if (!newFront || !newBack) {
        TVPrintError("Failed to allocate required frame buffers");
        exit(EXIT_FAILURE);
    }

    // Swap buffers into screen & notify clients
    gWidth = outW;
    gHeight = outH;
    gFBSize = newFBSize;

    if (gScreen) {
        // Update server with new framebuffer
        rfbNewFramebuffer(gScreen, (char *)newFront, gWidth, gHeight, 8, 3, gBytesPerPixel);
        // Restore BGRA little-endian channel layout (R shift=16, G=8, B=0)
        int bps = 8;
        gScreen->serverFormat.redShift = bps * 2;   // 16
        gScreen->serverFormat.greenShift = bps * 1; // 8
        gScreen->serverFormat.blueShift = 0;        // 0
        gScreen->paddedWidthInBytes = gWidth * gBytesPerPixel;
    }

    // Free old buffers and store new pointers
    if (gFrontBuffer)
        free(gFrontBuffer);
    if (gBackBuffer)
        free(gBackBuffer);
    gFrontBuffer = newFront;
    gBackBuffer = newBack;

    // Keep gScreen->frameBuffer in sync (rfbNewFramebuffer already did, but ensure local)
    if (gScreen)
        gScreen->frameBuffer = (char *)gFrontBuffer;

    // Re-init tiling/hash state for new geometry
    initializeTilingOrReset();
    // Clear pending dirty flags to avoid carrying over old-geometry state into the new geometry
    if (gPendingDirty)
        memset(gPendingDirty, 0, gTileCount);

    gHasPending = NO;
    TVLog(@"Resize: framebuffer changed to %dx%d (rotQ=%d, scale=%.3f)", gWidth, gHeight, rotQ, gScale);
}

// Ensure scratch buffer for rotation is available and large enough
NS_INLINE int ensureRotateScratch(size_t w, size_t h) {
    size_t need = w * h * (size_t)gBytesPerPixel;
    if (need == 0)
        return -1;
    if (gRotateScratchSize >= need && gRotateScratch)
        return 0;
    void *nbuf = realloc(gRotateScratch, need);
    memset(nbuf, 0, need);
    if (!nbuf)
        return -1;
    gRotateScratch = nbuf;
    gRotateScratchSize = need;
    return 0;
}

NS_INLINE int ensureScaleTemp(size_t srcW, size_t srcH, size_t dstW, size_t dstH, vImage_Flags flags) {
    vImage_Buffer s = {.data = NULL,
                       .height = (vImagePixelCount)srcH,
                       .width = (vImagePixelCount)srcW,
                       .rowBytes = srcW * (size_t)gBytesPerPixel};
    vImage_Buffer d = {.data = NULL,
                       .height = (vImagePixelCount)dstH,
                       .width = (vImagePixelCount)dstW,
                       .rowBytes = dstW * (size_t)gBytesPerPixel};
    vImage_Error need = vImageScale_ARGB8888(&s, &d, NULL, flags | kvImageGetTempBufferSize);
    if (need < 0)
        return -1;
    size_t nbytes = (size_t)need;
    if (nbytes == 0)
        return 0;
    if (gScaleTempSize >= nbytes && gScaleTemp)
        return 0;
    void *nbuf = realloc(gScaleTemp, nbytes);
    memset(nbuf, 0, nbytes);
    if (!nbuf)
        return -1;
    gScaleTemp = nbuf;
    gScaleTempSize = nbytes;
    return 0;
}

// Row-by-row copy to convert a possibly-strided captured buffer into a tightly packed VNC buffer.
NS_INLINE void copyWithStrideTight(uint8_t *dstTight, const uint8_t *src, int width, int height,
                                   size_t srcBytesPerRow) {
    size_t dstBPR = (size_t)width * gBytesPerPixel;
    for (int y = 0; y < height; ++y) {
        memcpy(dstTight + (size_t)y * dstBPR, src + (size_t)y * srcBytesPerRow, dstBPR);
    }
}

// Copy with small pad/crop to avoid expensive scaling when sizes are close.
// Strategy:
// - Copy overlap region at (0,0) with width=min(srcW,dstW), height=min(srcH,dstH)
// - If dst wider, horizontally replicate the last pixel in each row to fill the right pad.
// - If dst taller, vertically replicate the last valid row to fill the bottom pad.
NS_INLINE void copyPadOrCropToTight(uint8_t *dstTight, int dstW, int dstH, const uint8_t *src, int srcW, int srcH,
                                    size_t srcBytesPerRow) {
    const int bpp = gBytesPerPixel;
    const size_t dstBPR = (size_t)dstW * (size_t)bpp;
    const int overlapW = srcW < dstW ? srcW : dstW;
    const int overlapH = srcH < dstH ? srcH : dstH;

    // 1) Copy overlap region row-by-row
    if (overlapW > 0 && overlapH > 0) {
        const size_t copyBytes = (size_t)overlapW * (size_t)bpp;
        for (int y = 0; y < overlapH; ++y) {
            uint8_t *drow = dstTight + (size_t)y * dstBPR;
            const uint8_t *srow = src + (size_t)y * srcBytesPerRow;
            memcpy(drow, srow, copyBytes);
            // 2) Right pad by replicating last pixel if needed
            if (dstW > overlapW) {
                const uint8_t *lastPx = (overlapW > 0) ? (drow + ((size_t)overlapW - 1) * (size_t)bpp) : drow;
                for (int x = overlapW; x < dstW; ++x) {
                    memcpy(drow + (size_t)x * (size_t)bpp, lastPx, (size_t)bpp);
                }
            }
        }
    }

    // 3) Bottom pad by replicating last valid row if needed
    if (dstH > overlapH) {
        uint8_t *lastRow = (overlapH > 0) ? (dstTight + (size_t)(overlapH - 1) * dstBPR) : dstTight;
        for (int y = overlapH; y < dstH; ++y) {
            uint8_t *drow = dstTight + (size_t)y * dstBPR;
            memcpy(drow, lastRow, dstBPR);
        }
    }
}

NS_INLINE void swapBuffers(void) {
    void *tmp = gFrontBuffer;
    gFrontBuffer = gBackBuffer;
    gBackBuffer = tmp;
    gScreen->frameBuffer = (char *)gFrontBuffer;
}

// Try to acquire all clients' sendMutex without blocking.
// Returns 1 on success and fills locked[] with acquired mutexes (count in *lockedCount),
// otherwise returns 0 and releases any partial locks.
static int tryLockAllClients(pthread_mutex_t **locked, size_t *lockedCount, size_t capacity) {
    *lockedCount = 0;
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;

    int ok = 1;
    while ((cl = rfbClientIteratorNext(it))) {
        if (*lockedCount >= capacity) {
            ok = 0;
            break;
        }
        pthread_mutex_t *m = &cl->sendMutex;
        if (pthread_mutex_trylock(m) == 0) {
            locked[(*lockedCount)++] = m;
        } else {
            ok = 0;
            break;
        }
    }

    rfbReleaseClientIterator(it);

    if (!ok) {
        // release any that were acquired
        for (size_t i = 0; i < *lockedCount; ++i) {
            pthread_mutex_unlock(locked[i]);
        }
        *lockedCount = 0;
        return 0;
    }

    return 1;
}

// Blocking lock helpers (original behavior): lock all clients, then unlock all.
NS_INLINE void lockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_lock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

NS_INLINE void unlockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_unlock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

static void handleFramebuffer(CMSampleBufferRef sampleBuffer) {

#if DEBUG
    // Perf: overall start timestamp
    CFAbsoluteTime __tv_tStart = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) {
        TVLogVerbose(@"sampleBuffer has no image buffer (skip)");
        return;
    }

    // Busy-drop: if encoders are busy and limit reached, skip this frame (disabled when -Q 0)
    if (gMaxInflightUpdates > 0 && gInflight.load(std::memory_order_relaxed) >= gMaxInflightUpdates) {
        // When busy dropping, skip all hashing/dirty work.
        TVLogVerbose(@"drop frame due to inflight=%d >= limit=%d", gInflight.load(std::memory_order_relaxed),
                     gMaxInflightUpdates);
        return;
    }

#if DEBUG
    CFAbsoluteTime __tv_tLock0 = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

#if DEBUG
    CFAbsoluteTime __tv_tLock1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msLock = (__tv_tLock1 - __tv_tLock0) * 1000.0;
    TVLogVerbose(@"lock pixel buffer took %.3f ms", __tv_msLock);
#endif

    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    const size_t srcBPR = (size_t)CVPixelBufferGetBytesPerRow(pb);
    const size_t width = (size_t)CVPixelBufferGetWidth(pb);
    const size_t height = (size_t)CVPixelBufferGetHeight(pb);

    // Determine rotation and resize framebuffer if orientation implies new dimensions.
    int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;

#if DEBUG
    CFAbsoluteTime __tv_tResize0 = CFAbsoluteTimeGetCurrent();
#endif

    maybeResizeFramebufferForRotation(rotQ);

#if DEBUG
    CFAbsoluteTime __tv_tResize1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msResize = (__tv_tResize1 - __tv_tResize0) * 1000.0;
    TVLogVerbose(@"maybeResize(rotQ=%d) took %.3f ms (server=%dx%d, src=%zux%zu)", rotQ, __tv_msResize, gWidth, gHeight,
                 width, height);
#endif

    if ((int)width != gWidth || (int)height != gHeight) {
        // With scaling enabled, this is expected; log once for info. Without scaling, warn once.
        static BOOL sLoggedSizeInfoOnce = NO;
        if (!sLoggedSizeInfoOnce) {
            sLoggedSizeInfoOnce = YES;
            if (gScale != 1.0) {
                TVLogVerbose(@"Scaling source %zux%zu -> output %dx%d (scale=%.3f)", width, height, gWidth, gHeight,
                             gScale);
            } else {
                TVLogVerbose(@"Captured frame size %zux%zu differs from server %dx%d; cropping/copying minimum region.",
                             width, height, gWidth, gHeight);
            }
        }
    }

    // Copy/Rotate/Scale into back buffer. ScreenCapturer is always portrait-oriented.
    // We rotate by UI orientation then scale to server size.
    BOOL dirtyDisabled = (gFullscreenThresholdPercent == 0);

    static int sLastRotQ = -1;
    bool rotationChanged = (sLastRotQ == -1) ? false : ((rotQ & 3) != (sLastRotQ & 3));
    bool needsRotate = (rotQ != 0);

    vImage_Buffer srcBuf = {
        .data = base, .height = (vImagePixelCount)height, .width = (vImagePixelCount)width, .rowBytes = srcBPR};

    vImage_Buffer stage = srcBuf; // after rotation
    vImage_Buffer rotBuf = {0};

#if DEBUG
    CFTimeInterval __tv_msRotate = 0.0;
    CFTimeInterval __tv_msScaleOrCopy = 0.0;
#endif

    if (needsRotate) {

#if DEBUG
        CFAbsoluteTime __tv_tRot0 = CFAbsoluteTimeGetCurrent();
#endif

        size_t rotW = (rotQ % 2 == 0) ? (size_t)width : (size_t)height;
        size_t rotH = (rotQ % 2 == 0) ? (size_t)height : (size_t)width;
        if (ensureRotateScratch(rotW, rotH) != 0) {
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return;
        }

        rotBuf.data = gRotateScratch;
        rotBuf.width = (vImagePixelCount)rotW;
        rotBuf.height = (vImagePixelCount)rotH;
        rotBuf.rowBytes = rotW * (size_t)gBytesPerPixel;

        uint8_t rotConst = kRotate0DegreesClockwise;
        switch (rotQ) {
        case 1:
            rotConst = kRotate90DegreesClockwise;
            break;
        case 2:
            rotConst = kRotate180DegreesClockwise;
            break;
        case 3:
            rotConst = kRotate270DegreesClockwise;
            break;
        default:
            rotConst = kRotate0DegreesClockwise;
            break;
        }

        uint8_t bg[4] = {0, 0, 0, 0};
        vImage_Error rerr = vImageRotate90_ARGB8888(&srcBuf, &rotBuf, rotConst, bg, kvImageNoFlags);
        if (rerr != kvImageNoError) {
            static BOOL sLoggedRotErrOnce = NO;
            if (!sLoggedRotErrOnce) {
                sLoggedRotErrOnce = YES;
                TVLog(@"vImageRotate90_ARGB8888 failed: %ld", (long)rerr);
            }

            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return;
        }

        stage = rotBuf;

#if DEBUG
        CFAbsoluteTime __tv_tRot1 = CFAbsoluteTimeGetCurrent();
        __tv_msRotate = (__tv_tRot1 - __tv_tRot0) * 1000.0;
        TVLogVerbose(@"rotate %d*90 took %.3f ms (rotW=%zu, rotH=%zu)", rotQ, __tv_msRotate, (size_t)rotBuf.width,
                     (size_t)rotBuf.height);
#endif
    }

    // Scale stage to back buffer (tightly packed)
    vImage_Buffer dstBuf = {.data = gBackBuffer,
                            .height = (vImagePixelCount)gHeight,
                            .width = (vImagePixelCount)gWidth,
                            .rowBytes = (size_t)gWidth * (size_t)gBytesPerPixel};
    if (stage.width == dstBuf.width && stage.height == dstBuf.height && gScale == 1.0) {

#if DEBUG
        CFAbsoluteTime __tv_tCopy0 = CFAbsoluteTimeGetCurrent();
#endif

        copyWithStrideTight((uint8_t *)dstBuf.data, (const uint8_t *)stage.data, gWidth, gHeight, stage.rowBytes);

#if DEBUG
        CFAbsoluteTime __tv_tCopy1 = CFAbsoluteTimeGetCurrent();
        __tv_msScaleOrCopy = (__tv_tCopy1 - __tv_tCopy0) * 1000.0;
        TVLogVerbose(@"copy stage->back (tight) took %.3f ms", __tv_msScaleOrCopy);
#endif

    } else {

        // Small-diff pad/crop fast path to avoid vImageScale when sizes are close
        int dW = (int)dstBuf.width - (int)stage.width;
        int dH = (int)dstBuf.height - (int)stage.height;
        if (cNoScalePadThresholdPx > 0 && dW <= cNoScalePadThresholdPx && dW >= -cNoScalePadThresholdPx &&
            dH <= cNoScalePadThresholdPx && dH >= -cNoScalePadThresholdPx) {

#if DEBUG
            CFAbsoluteTime __tv_tPad0 = CFAbsoluteTimeGetCurrent();
#endif

            copyPadOrCropToTight((uint8_t *)dstBuf.data, (int)dstBuf.width, (int)dstBuf.height,
                                 (const uint8_t *)stage.data, (int)stage.width, (int)stage.height, stage.rowBytes);

#if DEBUG
            CFAbsoluteTime __tv_tPad1 = CFAbsoluteTimeGetCurrent();
            __tv_msScaleOrCopy = (__tv_tPad1 - __tv_tPad0) * 1000.0;
            TVLogVerbose(@"pad/crop copy stage->back took %.3f ms (stage=%zux%zu -> dst=%dx%d, thr=%d)",
                         __tv_msScaleOrCopy, (size_t)stage.width, (size_t)stage.height, gWidth, gHeight,
                         cNoScalePadThresholdPx);
#endif

        } else {

#if DEBUG
            CFAbsoluteTime __tv_tScale0 = CFAbsoluteTimeGetCurrent();
#endif

            if (ensureScaleTemp(stage.width, stage.height, dstBuf.width, dstBuf.height, kvImageHighQualityResampling) !=
                0) {
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                return;
            }

            vImage_Error err = vImageScale_ARGB8888(&stage, &dstBuf, gScaleTemp, kvImageHighQualityResampling);
            if (err != kvImageNoError) {
                static BOOL sLoggedVImageErrOnce = NO;
                if (!sLoggedVImageErrOnce) {
                    sLoggedVImageErrOnce = YES;
                    TVLog(@"vImageScale_ARGB8888 failed: %ld", (long)err);
                }
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                return;
            }

#if DEBUG
            CFAbsoluteTime __tv_tScale1 = CFAbsoluteTimeGetCurrent();
            __tv_msScaleOrCopy = (__tv_tScale1 - __tv_tScale0) * 1000.0;
            TVLogVerbose(@"scale stage->back took %.3f ms (stage=%zux%zu -> dst=%dx%d)", __tv_msScaleOrCopy,
                         (size_t)stage.width, (size_t)stage.height, gWidth, gHeight);
#endif
        }
    }

#if DEBUG
    CFAbsoluteTime __tv_tUnlock0 = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

#if DEBUG
    CFAbsoluteTime __tv_tUnlock1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msUnlock = (__tv_tUnlock1 - __tv_tUnlock0) * 1000.0;
    TVLogVerbose(@"unlock pixel buffer took %.3f ms", __tv_msUnlock);
#endif

    // If rotation just changed, force a full-screen update and reset dirty state
    // to avoid mixing hashes/pending dirties from the previous orientation.
    if (rotationChanged) {
        // Clear pending mask/state
        if (gPendingDirty)
            memset(gPendingDirty, 0, gTileCount);
        gHasPending = NO;

#if DEBUG
        CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

        if (gAsyncSwapEnabled) {
            pthread_mutex_t *locked[64];
            size_t lockedCount = 0;
            if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
                swapBuffers();
                for (size_t i = 0; i < lockedCount; ++i)
                    pthread_mutex_unlock(locked[i]);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"rotationChanged async-swap+mark fullscreen took %.3f ms",
                             (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"rotationChanged copy(fullscreen)+mark took %.3f ms",
                             (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
            }
        } else {
            lockAllClientsBlocking();
            swapBuffers();
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            unlockAllClientsBlocking();

#if DEBUG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            TVLogVerbose(@"rotationChanged blocking-swap+mark fullscreen took %.3f ms",
                         (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
        }

        // Skip dirty detection for this frame after rotation; return early
        sLastRotQ = rotQ;

        // Rotation may not change geometry (0<->180). Maintain hashes here so
        // the next frame recomputes curr and swaps to form a clean baseline.
        resetCurrTileHashes();
        swapTileHashes();

#if DEBUG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        TVLogVerbose(@"rotationChanged summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms "
                     @"total=%.3fms",
                     rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy,
                     (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // If dirty detection is disabled, perform a full-screen update
    if (dirtyDisabled) {

#if DEBUG
        CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

        if (gAsyncSwapEnabled) {
            pthread_mutex_t *locked[64];
            size_t lockedCount = 0;
            if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
                swapBuffers();
                for (size_t i = 0; i < lockedCount; ++i)
                    pthread_mutex_unlock(locked[i]);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"dirtyDisabled async-swap+mark fullscreen took %.3f ms",
                             (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                // Whole screen copy fallback (tight -> tight)
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"dirtyDisabled copy(fullscreen)+mark took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
            }
        } else {
            // Blocking swap to avoid tearing
            lockAllClientsBlocking();
            swapBuffers();
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            unlockAllClientsBlocking();

#if DEBUG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            TVLogVerbose(@"dirtyDisabled blocking-swap+mark fullscreen took %.3f ms",
                         (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
        }

#if DEBUG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        TVLogVerbose(
            @"dirtyDisabled summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms total=%.3fms",
            rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // Build dirty rectangles with deferred coalescing window (enabled)
    // Lightweight hashing to update pending and decide whether to flush.

#if DEBUG
    CFAbsoluteTime __tv_tHash0 = CFAbsoluteTimeGetCurrent();
#endif

    if (cSparseHashDuringDefer && gDeferWindowSec > 0) {
        hashTiledFromBufferSparse((const uint8_t *)gBackBuffer, gWidth, gHeight,
                                  (size_t)gWidth * (size_t)gBytesPerPixel, cHashStrideX, cHashStrideY);
    } else {
        resetCurrTileHashes();
        hashTiledFromBuffer((const uint8_t *)gBackBuffer, gWidth, gHeight, (size_t)gWidth * (size_t)gBytesPerPixel);
    }

#if DEBUG
    CFAbsoluteTime __tv_tHash1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msHash = (__tv_tHash1 - __tv_tHash0) * 1000.0;
    TVLogVerbose(@"tile hashing took %.3f ms (tiles=%zu, tileSize=%d)%@%@", __tv_msHash, gTileCount, gTileSize,
                 (cSparseHashDuringDefer && gDeferWindowSec > 0) ? @" [sparse]" : @"",
                 cUseCRC32Hash ? @" [crc32]" : @" [fnv]");
#endif

    enum { kRectBuf = 1024 };
    DirtyRect rects[kRectBuf];
    int changedTiles = 0;

    // Accumulate pending dirty tiles

#if DEBUG
    CFAbsoluteTime __tv_tPend0 = CFAbsoluteTimeGetCurrent();
#endif

    accumulatePendingDirty();

#if DEBUG
    CFAbsoluteTime __tv_tPend1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msPend = (__tv_tPend1 - __tv_tPend0) * 1000.0;
    TVLogVerbose(@"accumulate pending took %.3f ms (hasPending=%@)", __tv_msPend, gHasPending ? @"YES" : @"NO");
#endif

    // Decide whether to flush now
    BOOL shouldFlush = YES;
    static CFAbsoluteTime sDeferStartTime = 0;
    if (gDeferWindowSec > 0) {
        if (!gHasPending) {
            gHasPending = YES;
            sDeferStartTime = CFAbsoluteTimeGetCurrent();
            shouldFlush = NO; // start window, wait for more
        } else {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            shouldFlush = ((now - sDeferStartTime) >= gDeferWindowSec);
            TVLogVerbose(@"defer window elapsed=%.3f ms (threshold=%.3f ms) -> %@", (now - sDeferStartTime) * 1000.0,
                         gDeferWindowSec * 1000.0, shouldFlush ? @"FLUSH" : @"WAIT");
        }
    }

    int rectCount = 0;
    int changedPct = 0;
    BOOL fullScreen = NO;

    if (!shouldFlush) {
        // Still deferring: do not notify clients yet; keep previous full-hash baseline.

#if DEBUG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        TVLogVerbose(@"deferred (no flush) summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms "
                     @"hash=%.3fms total=%.3fms",
                     rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, __tv_msHash,
                     (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // At flush: recompute full hashes for precise rects
    {

#if DEBUG
        CFAbsoluteTime __tv_tHashFull0 = CFAbsoluteTimeGetCurrent();
#endif

        if (cParallelHashOnFlush) {
            // Use number of logical CPUs as thread hint (capped)
            int threads = (int)[[NSProcessInfo processInfo] processorCount];
            if (threads < 2)
                threads = 2;
            if (threads > 8)
                threads = 8;
            hashTiledFromBufferParallel((const uint8_t *)gBackBuffer, gWidth, gHeight,
                                        (size_t)gWidth * (size_t)gBytesPerPixel, threads);
        } else {
            resetCurrTileHashes();
            hashTiledFromBuffer((const uint8_t *)gBackBuffer, gWidth, gHeight, (size_t)gWidth * (size_t)gBytesPerPixel);
        }

#if DEBUG
        CFAbsoluteTime __tv_tHashFull1 = CFAbsoluteTimeGetCurrent();
        __tv_msHash = (__tv_tHashFull1 - __tv_tHashFull0) * 1000.0;
        TVLogVerbose(@"tile hashing (flush full)%@ took %.3f ms (tiles=%zu, tileSize=%d)%@",
                     cParallelHashOnFlush ? @" [parallel]" : @"", __tv_msHash, gTileCount, gTileSize,
                     cUseCRC32Hash ? @" [crc32]" : @" [fnv]");
#endif
    }

// Promote pending tiles into rects
#if DEBUG
    CFAbsoluteTime __tv_tRects0 = CFAbsoluteTimeGetCurrent();
#endif

    rectCount = buildRectsFromPending(rects, MIN(gMaxRectsLimit, kRectBuf));

    // If anything from this frame is also new dirty not in pending, ensure included
    int extraTiles = 0;
    if (rectCount == 0) {
        rectCount = buildDirtyRects(rects, MIN(gMaxRectsLimit, kRectBuf), &changedTiles);
    } else {
        // Merge current frame dirties by re-running with hashes, bounded
        DirtyRect rectsNow[kRectBuf];
        int nowCount = buildDirtyRects(rectsNow, MIN(gMaxRectsLimit, kRectBuf), &extraTiles);

        // Simple append then vertical merge will compact later in pipeline
        int space = kRectBuf - rectCount;
        int take = nowCount < space ? nowCount : space;
        if (take > 0)
            memcpy(&rects[rectCount], rectsNow, (size_t)take * sizeof(DirtyRect));
        rectCount += take;
    }

    int totalTiles = (int)gTileCount;
    int totalChanged = changedTiles + extraTiles;
    changedPct = (totalTiles > 0) ? (totalChanged * 100 / totalTiles) : 100;

    if (rectCount >= gMaxRectsLimit) {
        // Collapse to bounding box
        int minX = gWidth, minY = gHeight, maxX = 0, maxY = 0;
        for (int i = 0; i < rectCount; ++i) {
            if (rects[i].w <= 0 || rects[i].h <= 0)
                continue;
            if (rects[i].x < minX)
                minX = rects[i].x;
            if (rects[i].y < minY)
                minY = rects[i].y;
            if (rects[i].x + rects[i].w > maxX)
                maxX = rects[i].x + rects[i].w;
            if (rects[i].y + rects[i].h > maxY)
                maxY = rects[i].y + rects[i].h;
        }

        rects[0] = (DirtyRect){minX, minY, maxX - minX, maxY - minY};
        rectCount = 1;

        TVLogVerbose(@"rects exceeded limit -> collapse to bbox");
    }

    fullScreen = (changedPct >= gFullscreenThresholdPercent) || rectCount == 0;

#if DEBUG
    CFAbsoluteTime __tv_tRects1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msRects = (__tv_tRects1 - __tv_tRects0) * 1000.0;
    TVLogVerbose(@"build rects took %.3f ms (rects=%d, changedTiles=%d, extraTiles=%d, changedPct=%d%%, fsThresh=%d%%, "
                 @"fullscreen=%@)",
                 __tv_msRects, rectCount, changedTiles, extraTiles, changedPct, gFullscreenThresholdPercent,
                 fullScreen ? @"YES" : @"NO");
#endif

    // Clear pending
    if (gPendingDirty)
        memset(gPendingDirty, 0, gTileCount);

    gHasPending = NO;

#if DEBUG
    CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

    if (gAsyncSwapEnabled) {
        // Try non-blocking swap with fallback to single-buffer copy.
        pthread_mutex_t *locked[64];
        size_t lockedCount = 0;

        if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
            swapBuffers();
            for (size_t i = 0; i < lockedCount; ++i)
                pthread_mutex_unlock(locked[i]);
            if (fullScreen) {
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            } else {
                markRectsModified(rects, rectCount);
            }

#if DEBUG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            TVLogVerbose(@"async-swap+mark took %.3f ms (%@)", (__tv_tSwap1 - __tv_tSwap0) * 1000.0,
                         fullScreen ? @"fullscreen" : @"partial");
#endif

        } else {
            if (fullScreen) {
                // Whole screen copy fallback (tight -> tight)
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"async path copy(fullscreen)+mark took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                // Only copy dirty regions from back to front to reduce tearing and bandwidth
                copyRectsFromBackToFront(rects, rectCount);
                markRectsModified(rects, rectCount);

#if DEBUG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                TVLogVerbose(@"async path copy(dirty %d rects)+mark took %.3f ms", rectCount,
                             (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
            }
        }
    } else {
        // Original blocking behavior to avoid tearing.
        lockAllClientsBlocking();
        swapBuffers();
        if (fullScreen) {
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
        } else {
            markRectsModified(rects, rectCount);
        }
        unlockAllClientsBlocking();

#if DEBUG
        CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
        TVLogVerbose(@"blocking-swap+mark took %.3f ms (%@)", (__tv_tSwap1 - __tv_tSwap0) * 1000.0,
                     fullScreen ? @"fullscreen" : @"partial");
#endif
    }

    // Prepare for next frame: current hashes become previous
    swapTileHashes();
    sLastRotQ = rotQ;

#if DEBUG
    CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
    TVLogVerbose(@"frame summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms hash=%.3fms "
                 @"rects=%.3fms total=%.3fms (rectCount=%d, changedPct=%d%%, fullscreen=%@, inflight=%d/%d)",
                 rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, __tv_msHash, __tv_msRects,
                 (__tv_tEnd - __tv_tStart) * 1000.0, rectCount, changedPct, fullScreen ? @"YES" : @"NO",
                 gInflight.load(std::memory_order_relaxed), gMaxInflightUpdates);
#endif
}

#pragma mark - Event Handlers

NS_INLINE NSString *keysymToString(rfbKeySym ks) {
    // Alphanumeric and basic ASCII
    if ((ks >= 0x20 && ks <= 0x7E) || ks == ' ') {
        unichar ch = (unichar)ks;
        return [NSString stringWithCharacters:&ch length:1];
    }
    switch (ks) {
    case XK_Return:
    case XK_KP_Enter:
        return @"RETURN";
    case XK_Tab:
        return @"TAB";
    case XK_Escape:
        return @"ESCAPE";
    case XK_BackSpace:
        return @"BACKSPACE";
    case XK_Delete:
        return @"FORWARDDELETE";
    case XK_Insert:
        return @"INSERT";
    case XK_Home:
        return @"HOME";
    case XK_End:
        return @"END";
    case XK_Page_Up:
        return @"PAGEUP";
    case XK_Page_Down:
        return @"PAGEDOWN";
    case XK_Left:
        return @"LEFTARROW";
    case XK_Right:
        return @"RIGHTARROW";
    case XK_Up:
        return @"UPARROW";
    case XK_Down:
        return @"DOWNARROW";
    case XK_space:
        return @" ";
    case XK_Shift_L:
        return @"LEFTSHIFT";
    case XK_Shift_R:
        return @"RIGHTSHIFT";
    case XK_Control_L:
        return @"LEFTCONTROL";
    case XK_Control_R:
        return @"RIGHTCONTROL";
    // Modifier mapping depending on scheme
    case XK_Alt_L:
        return (gModMapScheme == 1) ? @"LEFTCOMMAND" : @"LEFTALT"; // Option or Command
    case XK_Alt_R:
        return (gModMapScheme == 1) ? @"RIGHTCOMMAND" : @"RIGHTALT"; // Option or Command
    case XK_ISO_Level3_Shift:
        return @"LEFTALT"; // macOS left Option often sent as ISO_Level3_Shift
    case XK_Mode_switch:
        return @"RIGHTALT"; // Mode switch often behaves like AltGr
    case XK_Meta_L:
        return (gModMapScheme == 1) ? @"LEFTALT" : @"LEFTCOMMAND"; // Option or Command
    case XK_Meta_R:
        return (gModMapScheme == 1) ? @"RIGHTALT" : @"RIGHTCOMMAND"; // Option or Command
    case XK_Super_L:
        return @"LEFTCOMMAND"; // Treat Super as Command in both schemes
    case XK_Super_R:
        return @"RIGHTCOMMAND";
    default:
        break;
    }
    // Function keys XK_F1..XK_F24
    if (ks >= XK_F1 && ks <= XK_F24) {
        int idx = (int)(ks - XK_F1) + 1;
        return [NSString stringWithFormat:@"F%d", idx];
    }
    return nil;
}

static void kbdAddEvent(rfbBool down, rfbKeySym keySym, rfbClientPtr cl) {
    (void)cl;
    if (gViewOnly)
        return;

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];

    // Map common XF86 multimedia/brightness keysyms to iOS HID events
    switch ((unsigned long)keySym) {
    // XK_Home（0xff50）：iOS 无"桌面 Home"的 Keyboard Page 语义（KeyboardHome 0x4A 无效），
    // 必须用 Consumer Page 的 Menu（与 invoke 链路 menuPress 一致）才能回桌面。
    // 修复 5801 直连页 / 任意 RFB 键盘点击 Home 无反应的问题。
    case XK_Home:
        if (down)
            [gen menuDown];
        else
            [gen menuUp];
        return;
    // Brightness Up/Down
    case 0x1008ff02UL: // XF86MonBrightnessDown（0x1008ff02 = 标准 Down）
        if (down)
            [gen displayBrightnessDecrementDown];
        else
            [gen displayBrightnessDecrementUp];
        return;
    case 0x1008ff03UL: // XF86MonBrightnessUp（0x1008ff03 = 标准 Up）
        if (down)
            [gen displayBrightnessIncrementDown];
        else
            [gen displayBrightnessIncrementUp];
        return;
    // Volume/Mute
    case 0x1008ff13UL: // XF86AudioRaiseVolume
        if (down)
            [gen volumeIncrementDown];
        else
            [gen volumeIncrementUp];
        return;
    case 0x1008ff11UL: // XF86AudioLowerVolume
        if (down)
            [gen volumeDecrementDown];
        else
            [gen volumeDecrementUp];
        return;
    case 0x1008ff12UL: // XF86AudioMute
        if (down)
            [gen muteDown];
        else
            [gen muteUp];
        return;
    // Media keys: Previous / Play-Pause / Next (use Consumer usages)
    case 0x1008ff3eUL: // Map as Previous Track (per user observation)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_ScanPreviousTrack];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_ScanPreviousTrack];
        return;
    case 0x1008ff14UL: // XF86AudioPlay (toggle Play/Pause)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_PlayOrPause];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_PlayOrPause];
        return;
    case 0x1008ff97UL: // Map as Next Track (per user observation)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_ScanNextTrack];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_ScanNextTrack];
        return;
    // 系统动作键（H5 控制台按键直发映射）：点击即触发，仅 down 时执行（up 忽略，防 toggle 双触发）
    case 0x1008ff2eUL: // XF86Keyboard → 唤起/收起系统键盘
        if (down) [gen toggleOnScreenKeyboard];
        return;
    case 0x1008ff1dUL: // XF86Search → 搜索（Spotlight 下拉）
        if (down) [gen toggleSpotlight];
        return;
    case 0x1008ff80UL: // 自定义 keysym：Home+Power 截屏
        if (down) [gen snapshotPress];
        return;
    case 0x1008ff81UL: // 自定义 keysym：硬件键盘锁
        if (down) [gen hardwareLock];
        return;
    case 0x1008ff82UL: // 自定义 keysym：释放所有按键
        if (down) [gen releaseEveryKeys];
        return;
    default:
        break;
    }

    NSString *keyStr = keysymToString(keySym);
    if (gKeyEventLogging && tvncLoggingEnabled) {
        const char *mapped = keyStr ? [keyStr UTF8String] : "(nil)";
        rfbLog("[key] %s keysym=0x%lx (%lu) mapped=%s\n", down ? "down" : " up ", (unsigned long)keySym,
               (unsigned long)keySym, mapped);
    }

    if (!keyStr)
        return;

    if (down)
        [gen keyDown:keyStr];
    else
        [gen keyUp:keyStr];
}

static void kbdReleaseAllKeys(rfbClientPtr cl) {
    (void)cl;
    if (gViewOnly)
        return;

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    [gen releaseEveryKeys];
}

NS_INLINE CGPoint vncPointToDevicePoint(int vx, int vy) {
    // Map from VNC framebuffer space (gWidth x gHeight, post-rotation & scaling)
    // back to device capture space (portrait, gSrcWidth x gSrcHeight), inverting rotation.
    int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;

#if !TARGET_IPHONE_SIMULATOR
    // Apply user-configured rotation offset (0..3 quadrants CW)
    int effRotQ = (rotQ + gOrientationFixQuad) & 3;
#else
    int effRotQ = rotQ;
#endif

    // Dimensions of the rotated (pre-scale) stage
    int rotW = (effRotQ % 2 == 0) ? gSrcWidth : gSrcHeight;
    int rotH = (effRotQ % 2 == 0) ? gSrcHeight : gSrcWidth;

    // Undo scaling from stage(rotW x rotH) -> VNC(gWidth x gHeight)
    double sx = (gWidth > 0) ? ((double)rotW / (double)gWidth) : 1.0;
    double sy = (gHeight > 0) ? ((double)rotH / (double)gHeight) : 1.0;
    double stX = sx * (double)vx;
    double stY = sy * (double)vy;

    // Clamp to stage bounds
    if (stX < 0)
        stX = 0;
    if (stY < 0)
        stY = 0;
    if (stX > (double)(rotW - 1))
        stX = (double)(rotW - 1);
    if (stY > (double)(rotH - 1))
        stY = (double)(rotH - 1);

    // Invert rotation: stage -> source portrait space
    double dx = 0.0, dy = 0.0;
    switch (effRotQ) {
    case 0: // identity
        dx = stX;
        dy = stY;
        break;
    case 1: // 90 CW: inverse of stageX=srcH-1-srcY, stageY=srcX -> srcX=stageY; srcY=srcH-1-stageX
        dx = stY;
        dy = (double)(gSrcHeight - 1) - stX;
        break;
    case 2: // 180: srcX = srcW-1 - stageX; srcY = srcH-1 - stageY
        dx = (double)(gSrcWidth - 1) - stX;
        dy = (double)(gSrcHeight - 1) - stY;
        break;
    case 3: // 270 CW (90 CCW): inverse of stageX=srcY, stageY=srcW-1-srcX -> srcX=srcW-1-stageY; srcY=stageX
        dx = (double)(gSrcWidth - 1) - stY;
        dy = stX;
        break;
    }

    // Final clamp to device bounds
    if (dx < 0)
        dx = 0;
    if (dy < 0)
        dy = 0;
    if (dx > (double)(gSrcWidth - 1))
        dx = (double)(gSrcWidth - 1);
    if (dy > (double)(gSrcHeight - 1))
        dy = (double)(gSrcHeight - 1);

    return CGPointMake((CGFloat)dx, (CGFloat)dy);
}

@interface STHIDEventGenerator (Private)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
@end

#define CLIENT_ID_LEN 8

// Per-client state stored in cl->clientData to avoid cross-client conflicts.
typedef struct {
    int lastButtonMask;                // last received pointer button mask from this client
    double wheelAccumPx;               // accumulated scroll in pixels (+down, -up) for this client
    BOOL wheelFlushScheduled;          // whether a flush is pending for this client
    char clientId8[CLIENT_ID_LEN + 1]; // cached 8-char client id (NUL-terminated)
    BOOL isMgmtClient;                // 管理客户端标记（不计入 count/list，不推帧）
} TVClientState;

NS_INLINE TVClientState *tvGetClientState(rfbClientPtr cl) { return cl ? (TVClientState *)cl->clientData : NULL; }

static dispatch_queue_t gWheelQueue = nil; // serial queue for wheel gestures

static void wheelScheduleFlush(rfbClientPtr cl, CGPoint anchorPoint, double delaySec, int rotQ) {
    TVClientState *st = tvGetClientState(cl);
    if (!st)
        return;

    if (gWheelStepPx <= 0) { // disabled
        st->wheelAccumPx = 0.0;
        st->wheelFlushScheduled = NO;
        return;
    }

    // Ensure client remains valid during delayed execution
    rfbIncrClientRef(cl);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), gWheelQueue, ^{
        TVClientState *st2 = tvGetClientState(cl);
        if (!st2) {
            rfbDecrClientRef(cl);
            return;
        }

        // Consume the entire accumulation in one gesture to avoid many small drags.
        double takeRaw = st2->wheelAccumPx;
        st2->wheelAccumPx = 0.0; // zero out
        st2->wheelFlushScheduled = NO;
        double mag = fabs(takeRaw);
        if (mag < 1.0) {
            rfbDecrClientRef(cl);
            return;
        }

        // Velocity-like amplification: for larger accumulations (faster wheel),
        // slightly increase distance instead of emitting many short drags.
        double amp = 1.0 + fmin(gWheelAmpCap, gWheelAmpCoeff * log1p(mag / fmax(gWheelStepPx, 1.0)));
        double take = copysign(mag * amp, takeRaw);

        // Guarantee a small-but-meaningful movement for tiny scrolls
        if (fabs(take) < (gWheelMinTakeRatio * gWheelStepPx)) {
            take = copysign(gWheelMinTakeRatio * gWheelStepPx, take);
        }

        // Absolute clamp for safety
        double absClamp = gWheelMaxStepPx * gWheelAbsClampFactor;
        if (take > absClamp)
            take = absClamp;
        if (take < -absClamp)
            take = -absClamp;

        // Map VNC-vertical delta into device axis based on rotation
        CGFloat dx = 0, dy = 0;
        switch (rotQ & 3) {
        case 0: // portrait
            dx = 0;
            dy = (CGFloat)take;
            break;
        case 2: // upside-down
            dx = 0;
            dy = (CGFloat)(-take);
            break;
        case 1: // landscape left (90 CW)
            dx = (CGFloat)(+take);
            dy = 0;
            break;
        case 3: // landscape right (270 CW)
            dx = (CGFloat)(-take);
            dy = 0;
            break;
        }

        CGFloat endX = anchorPoint.x + dx;
        CGFloat endY = anchorPoint.y + dy;
        if (endX < 0)
            endX = 0;
        CGFloat maxX = (CGFloat)gSrcWidth - 1;
        if (endX > maxX)
            endX = maxX;
        if (endY < 0)
            endY = 0;
        CGFloat maxY = (CGFloat)gSrcHeight - 1;
        if (endY > maxY)
            endY = maxY;
        CGPoint endPt = CGPointMake(endX, endY);

        // Duration scales sub-linearly with distance; parameters configurable
        double dur = gWheelDurBase + gWheelDurK * sqrt(fabs(take));
        if (dur > gWheelDurMax)
            dur = gWheelDurMax;
        if (dur < gWheelDurMin)
            dur = gWheelDurMin;

        [[STHIDEventGenerator sharedGenerator] dragLinearWithStartPoint:anchorPoint endPoint:endPt duration:dur];

        rfbDecrClientRef(cl);
    });
}

static void ptrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl) {
    if (gViewOnly)
        return;

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    CGPoint pt = vncPointToDevicePoint(x, y);

    TVClientState *st = tvGetClientState(cl);
    int lastMask = st ? st->lastButtonMask : 0;

    // Left button (bit 0)
    bool leftNow = (buttonMask & 1) != 0;
    bool leftPrev = (lastMask & 1) != 0;
    if (leftNow && !leftPrev) {
        [gen touchDownAtPoints:&pt touchCount:1];
    } else if (!leftNow && leftPrev) {
        [gen liftUpAtPoints:&pt touchCount:1];
    } else if (leftNow) {
        CGPoint p = pt;
        [gen _updateTouchPoints:&p count:1];
    }

    // Middle button (bit 1 -> mask 2): map to Power key
    bool midNow = (buttonMask & 2) != 0;
    bool midPrev = (lastMask & 2) != 0;
    if (midNow && !midPrev) {
        [gen powerDown];
    } else if (!midNow && midPrev) {
        [gen powerUp];
    }

    // Right button (bit 2 -> mask 4): map to Home/Menu key
    bool rightNow = (buttonMask & 4) != 0;
    bool rightPrev = (lastMask & 4) != 0;
    if (rightNow && !rightPrev) {
        [gen menuDown];
    } else if (!rightNow && rightPrev) {
        [gen menuUp];
    }

    // Wheel emulation: coalesce ticks and perform async flicks off the VNC thread.
    bool wheelUpNow = (buttonMask & 8) != 0;  // button 4
    bool wheelDnNow = (buttonMask & 16) != 0; // button 5
    bool wheelUpPrev = (lastMask & 8) != 0;
    bool wheelDnPrev = (lastMask & 16) != 0;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gWheelQueue = dispatch_queue_create("com.82flex.trollvnc.wheel", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    });

    if (gWheelStepPx > 0 && ((wheelUpNow && !wheelUpPrev) || (wheelDnNow && !wheelDnPrev))) {
        double delta = (wheelDnNow && !wheelDnPrev) ? +gWheelStepPx : -gWheelStepPx;
        if (gWheelNaturalDir)
            delta = -delta;
        int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;
        // Ensure client remains valid while we touch its state asynchronously
        rfbIncrClientRef(cl);
        dispatch_async(gWheelQueue, ^{
            TVClientState *st2 = tvGetClientState(cl);
            if (st2) {
                st2->wheelAccumPx += delta;
                if (!st2->wheelFlushScheduled) {
                    st2->wheelFlushScheduled = YES;
                    wheelScheduleFlush(cl, pt, gWheelCoalesceSec, rotQ);
                }
            }
            rfbDecrClientRef(cl);
        });
    }

    if (st)
        st->lastButtonMask = buttonMask;
}

#pragma mark - Bonjour (mDNS) Advertisement

static NSNetService *gBonjourService = nil;     // VNC service (_rfb._tcp.)
static NSNetService *gBonjourHttpService = nil; // Optional HTTP service (_http._tcp.)

// Compute a short, per-boot stable hash suffix (8 hex chars) from boot time
static NSString *tvBootHash8(void) {
    static NSString *suf = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Read boot time from the kernel (stable across process restarts in the same boot)
        struct timeval boottv = {0};
        size_t len = sizeof(boottv);
        int mib[2] = {CTL_KERN, KERN_BOOTTIME};
        int rc = sysctl(mib, 2, &boottv, &len, NULL, 0);

        uint64_t h = 1469598103934665603ULL; // FNV-1a 64-bit offset basis
        const uint64_t p = 1099511628211ULL; // prime
        if (rc == 0 && len == sizeof(boottv)) {
            uint64_t sec = (uint64_t)boottv.tv_sec;
            uint64_t usec = (uint64_t)boottv.tv_usec;
            for (int i = 0; i < 8; i++) {
                h ^= (uint8_t)((sec >> (i * 8)) & 0xFF);
                h *= p;
            }
            for (int i = 0; i < 8; i++) {
                h ^= (uint8_t)((usec >> (i * 8)) & 0xFF);
                h *= p;
            }
        } else {
            // Fallback: hash the monotonic uptime seconds (may vary between app restarts in same boot)
            uint64_t up_ms = (uint64_t)([NSProcessInfo processInfo].systemUptime * 1000.0);
            for (int i = 0; i < 8; i++) {
                h ^= (uint8_t)((up_ms >> (i * 8)) & 0xFF);
                h *= p;
            }
        }
        unsigned int shortHash = (unsigned int)(h & 0xFFFFFFFFu); // 32-bit
        suf = [NSString stringWithFormat:@"%08x", shortHash];
    });
    return suf;
}

// Compose Bonjour service name as gDesktopName + 8-char boot hash, clamped to 63 bytes
static NSString *tvBonjourServiceName(NSString *baseName) {
    NSString *name = baseName ?: @"SuperPhone";
    NSString *suffix = tvBootHash8();
    // mDNS single-label length limit is 63 bytes (UTF-8). We reserve suffix bytes.
    const NSUInteger maxBytes = 63;
    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    // Reserve bytes for "-" + 8-char suffix (ASCII)
    NSUInteger reserve = suffix.length + 1; // hyphen + suffix
    if (reserve >= maxBytes) {
        // Pathological, but keep at least the suffix
        return suffix;
    }
    while (data.length + reserve > maxBytes && name.length > 0) {
        name = [name substringToIndex:name.length - 1];
        data = [name dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (name.length == 0) {
        return suffix; // no space left for hyphen
    }
    return [NSString stringWithFormat:@"%@-%@", name, suffix];
}

@interface TVBonjourDelegate : NSObject <NSNetServiceDelegate>
@end

@implementation TVBonjourDelegate
- (void)netServiceDidPublish:(NSNetService *)sender {
    TVLog(@"Bonjour: published %@.%@:%ld", sender.name, sender.type, (long)sender.port);
}
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    TVLog(@"Bonjour: failed to publish %@.%@ (err=%@)", sender.name, sender.type, errorDict);
}
- (void)netServiceDidStop:(NSNetService *)sender {
    TVLog(@"Bonjour: stopped %@.%@", sender.name, sender.type);
}
@end

static TVBonjourDelegate *gBonjourDelegate = nil;

static NSData *bonjourTXTRecord(void) {
    // Minimal helpful metadata for clients
    // Keys kept short; values ASCII per convention
    NSMutableDictionary<NSString *, NSData *> *txt = [NSMutableDictionary dictionary];
    // Name
    if (gDesktopName.length > 0) {
        txt[@"vn"] = [gDesktopName dataUsingEncoding:NSUTF8StringEncoding];
    }
    // View-only flag
    txt[@"vo"] = [[NSString stringWithFormat:@"%d", gViewOnly ? 1 : 0] dataUsingEncoding:NSASCIIStringEncoding];
    // HTTP availability
    txt[@"hp"] = [[NSString stringWithFormat:@"%d", gHttpPort] dataUsingEncoding:NSASCIIStringEncoding];
    // FPS pref (if provided)
    if (gFpsMin || gFpsPref || gFpsMax) {
        NSString *fps = [NSString stringWithFormat:@"%d:%d:%d", gFpsMin, gFpsPref, gFpsMax];
        txt[@"fps"] = [fps dataUsingEncoding:NSASCIIStringEncoding];
    }
    return [NSNetService dataFromTXTRecordDictionary:txt];
}

static void refreshBonjourTXTRecord(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            refreshBonjourTXTRecord();
        });
        return;
    }
    if (!gBonjourService)
        return;
    [gBonjourService setTXTRecordData:bonjourTXTRecord()];
}

// 公开访问函数：获取 inflight 编码帧统计（供 sys.stats.inflight 能力调用）
NSDictionary *tvGetInflightStats(void) {
    return @{@"current":@(gInflight.load()), @"max":@(gMaxInflightUpdates)};
}

// 公开访问函数：获取 Bonjour TXT 字典（供 sys.bonjour.txt 能力调用，返回可读字典非 NSData）
NSDictionary *tvGetBonjourTXT(void) {
    NSDictionary *raw = [NSNetService dictionaryFromTXTRecordData:bonjourTXTRecord()];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in raw) {
        NSString *val = [[NSString alloc] initWithData:raw[key] encoding:NSUTF8StringEncoding];
        if (val) result[key] = val;
    }
    return result;
}

/**
 * 配置热重载：重新从 NSUserDefaults 读取指定 key 并更新对应 C 全局变量 + 触发副作用
 * @param key 配置键名（C 字符串，对应 NSUserDefaults key）
 * @return 0=成功，-1=未知 key，-2=值无效
 * 注：仅处理 reload=hot 且属于 trollvncserver 管理的 key；Watchdog/HID 属性由调用方直接设置
 */
int tvReloadConfigForKey(const char *key) {
    if (!key) return -1;
    NSString *k = [NSString stringWithUTF8String:key];
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    int rotQ = gRotationQuad.load();

    if ([k isEqualToString:@"Scale"]) {
        double v = [p doubleForKey:@"Scale"];
        if (v < 0.1) v = 0.1; if (v > 1.0) v = 1.0;
        gScale = v;
        maybeResizeFramebufferForRotation(rotQ); // 重建 framebuffer（gWidth/gHeight 变化）
        rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
    } else if ([k isEqualToString:@"FrameRateSpec"]) {
        // 复用 parseFrameRateSpec（支持 min:pref:max / min-max / 单值三种格式 + 校验）
        NSString *spec = [p stringForKey:@"FrameRateSpec"];
        if (spec.length) parseFrameRateSpec(spec.UTF8String ?: "");
    } else if ([k isEqualToString:@"OrientationSync"]) {
        gOrientationSyncEnabled = [p boolForKey:@"OrientationSync"];
    } else if ([k isEqualToString:@"ServerCursor"]) {
        // 2026-08-14：改配置后即时重建/清除服务端光标（原实现只改全局变量，运行中开关不生效）
        gCursorEnabled = [p boolForKey:@"ServerCursor"];
        setupRfbServerSideCursor();
    } else if ([k isEqualToString:@"DeferWindowSec"]) {
        double v = [p doubleForKey:@"DeferWindowSec"];
        if (v < 0.0) v = 0.0;
        gDeferWindowSec = v;
    } else if ([k isEqualToString:@"MaxInflight"]) {
        int v = (int)[p integerForKey:@"MaxInflight"];
        if (v < 1) v = 1;
        gMaxInflightUpdates = v;
    } else if ([k isEqualToString:@"KeepAliveSec"]) {
        double v = [p doubleForKey:@"KeepAliveSec"];
        if (v > 0.0 && v < 15.0) v = 0.0;
        if (v > 300.0) v = 300.0;
        gKeepAliveSec = v;
        // 重启保活定时器逻辑由 watchdog 管辖，此处仅更新全局值
    } else if ([k isEqualToString:@"WheelStepPx"]) {
        double v = [p doubleForKey:@"WheelStepPx"];
        if (v < 0.0) v = 0.0;
        gWheelStepPx = v;
        // 同步更新 max step（与初始化逻辑一致，避免热重载后 max 仍为旧值）
        gWheelMaxStepPx = fmax(2.0 * gWheelStepPx, 96.0) * 1.0;
    } else if ([k isEqualToString:@"WheelTuning"]) {
        // 高级滚轮调优串（如 "step=48,natural=1,coalesce=0.03"），复用 parseWheelOptions
        NSString *tuning = [p stringForKey:@"WheelTuning"];
        if (tuning.length) parseWheelOptions(tuning.UTF8String);
    } else if ([k isEqualToString:@"ModifierMap"]) {
        // 修饰键映射方案：std(0) / altcmd(1)
        NSString *m = [p stringForKey:@"ModifierMap"];
        if ([m isKindOfClass:[NSString class]])
            gModMapScheme = [m isEqualToString:@"altcmd"] ? 1 : 0;
    } else if ([k isEqualToString:@"FullscreenThresholdPercent"]) {
        // 脏区阈值（0=关闭脏区检测，全屏刷新）
        int v = (int)[p integerForKey:@"FullscreenThresholdPercent"];
        if (v < 0) v = 0; if (v > 100) v = 100;
        gFullscreenThresholdPercent = v;
    } else {
        return -1; // 未知 key 或非 trollvncserver 管理的 key
    }
    return 0;
}

static void stopBonjour(void) {
    // NSNetService expects interactions on a runloop thread (prefer main).
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            stopBonjour();
        });
        return;
    }
    if (gBonjourService) {
        [gBonjourService stop];
        gBonjourService = nil;
    }
    if (gBonjourHttpService) {
        [gBonjourHttpService stop];
        gBonjourHttpService = nil;
    }
}

static void startBonjour(void) {
    // NSNetService expects interactions on a runloop thread (prefer main).
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            startBonjour();
        });
        return;
    }
    if (!gBonjourEnabled) {
        TVLog(@"Bonjour: disabled");
        return;
    }

    if (!gBonjourDelegate)
        gBonjourDelegate = [TVBonjourDelegate new];

    // Publish VNC service: _rfb._tcp. on gPort
    if (!gBonjourService) {
        NSString *svcName = tvBonjourServiceName(gDesktopName);
        gBonjourService = [[NSNetService alloc] initWithDomain:@"local." type:@"_rfb._tcp." name:svcName port:gPort];
        gBonjourService.delegate = gBonjourDelegate;
        [gBonjourService setTXTRecordData:bonjourTXTRecord()];
        [gBonjourService publish];
    } else {
        [gBonjourService stop];
        gBonjourService = nil;
        startBonjour();
        return;
    }

    // Optionally publish HTTP service when enabled
    if (gHttpPort > 0) {
        if (gBonjourHttpService) {
            [gBonjourHttpService stop];
            gBonjourHttpService = nil;
        }
        NSString *svcName = tvBonjourServiceName(gDesktopName);
        gBonjourHttpService = [[NSNetService alloc] initWithDomain:@"local."
                                                              type:@"_http._tcp."
                                                              name:svcName
                                                              port:gHttpPort];
        gBonjourHttpService.delegate = gBonjourDelegate;
        [gBonjourHttpService publish];
    }
}

// Number of connected clients
static int gClientCount = 0;

// Global client states, populated via newClientHook/clientGoneHook.
// Key: 8-char client id; Value: immutable snapshot dictionary.
static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *gClientStates = nil;

// 前向声明（RFB 扩展 handler 使用，定义在其后）
static void tvPublishUserSingleNotifs(void);

#pragma mark - RFB Extension (5901, type 0x50)

// 消息类型
#define TV_EXT_MSG_TYPE  0x50      // client→server
#define TV_EXT_RESP_TYPE 0x80      // server→client

// 帧头：1B type + 3B reserved + 4B payloadLen = 8 字节
typedef struct {
    uint8_t  type;
    uint8_t  reserved[3];
    uint32_t payloadLen;  // big-endian（网络字节序）
} TVExtHeader;

// --- 前向声明：具体 handler 在任务 2/3 实现 ---
static NSDictionary *tvExtHandleCapHello(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleCapList(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleScreenHash(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleScreenDiff(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleScreenWaitStable(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsCount(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsList(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsDisconnect(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsBlock(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsUnblock(rfbClientPtr cl, NSDictionary *params);
static NSDictionary *tvExtHandleClientsBlockedList(rfbClientPtr cl, NSDictionary *params);

/** 从 rfbClientPtr 读取一条扩展消息的 JSON payload
 *  注意：libvncserver 在 rfbProcessClientMessage 中已消费消息首字节（type，存入
 *        message->type），本函数只读帧头剩余部分：3 字节 reserved + 4 字节 payloadLen。
 *  @param cl  客户端连接指针
 *  @return    解析后的 NSDictionary；解析失败返回 nil
 */
static NSDictionary *tvExtReadMessage(rfbClientPtr cl) {
    // 帧头剩余 7 字节：reserved[3] + payloadLen[4]（网络序）
    uint8_t frame[7];
    if (rfbReadExact(cl, (char *)frame, sizeof(frame)) <= 0) return nil;
    uint32_t payloadLen = 0;
    memcpy(&payloadLen, frame + 3, 4);
    payloadLen = ntohl(payloadLen);
    if (payloadLen == 0 || payloadLen > 1024 * 1024) return nil;
    // 读取 JSON payload
    NSMutableData *payload = [NSMutableData dataWithLength:payloadLen];
    if (rfbReadExact(cl, (char *)payload.mutableBytes, payloadLen) <= 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
}

/** 向 rfbClientPtr 写回一条扩展响应
 *  @param cl   客户端连接指针
 *  @param resp 待序列化为 JSON 的 NSDictionary
 */
static void tvExtWriteResponse(rfbClientPtr cl, NSDictionary *resp) {
    if (!cl || !resp) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
    if (!json) return;
    TVExtHeader hdr;
    hdr.type = TV_EXT_RESP_TYPE;
    memset(hdr.reserved, 0, 3);
    hdr.payloadLen = htonl((uint32_t)json.length);
    rfbWriteExact(cl, (const char *)&hdr, sizeof(hdr));
    rfbWriteExact(cl, (const char *)json.bytes, json.length);
}

/** 构造成功响应
 *  @param data 数据载荷（可为 nil）
 *  @return     @{@"ok":@YES, ...data}
 */
static NSDictionary *tvExtOk(NSDictionary *data) {
    NSMutableDictionary *r = [@{@"ok": @YES} mutableCopy];
    if (data) [r addEntriesFromDictionary:data];
    return r;
}

/** 构造错误响应
 *  @param msg 错误描述（可为 nil，默认 "unknown"）
 *  @return    @{@"ok":@NO, @"error":msg}
 */
static NSDictionary *tvExtErr(NSString *msg) {
    return @{@"ok": @NO, @"error": msg ?: @"unknown"};
}

/** rfbProtocolExtension 消息分发入口
 *  @param cl      客户端连接指针
 *  @param data    扩展私有数据（本扩展未使用）
 *  @param message LibVNCServer 透传的客户端消息
 *  @return        TRUE 表示已处理；FALSE 表示不属于本扩展
 */
static rfbBool tvExtHandleMessage(rfbClientPtr cl, void *data,
                                  const rfbClientToServerMsg *message) {
    if (!cl || !message) return FALSE;
    if (message->type != TV_EXT_MSG_TYPE) return FALSE;  // 不属于本扩展

    NSDictionary *req = tvExtReadMessage(cl);
    if (!req) {
        tvExtWriteResponse(cl, tvExtErr(@"消息解析失败"));
        return TRUE;
    }

    NSString *op = req[@"op"];
    NSDictionary *params = req[@"params"] ?: @{};
    NSDictionary *resp = nil;

    // NSNull 防御：JSON 中 "op":null 时 req[@"op"] 为 NSNull 而非 nil
    if (!op || ![op isKindOfClass:[NSString class]]) {
        tvExtWriteResponse(cl, tvExtErr(@"op 字段缺失或非字符串"));
        return TRUE;
    }

    // 分发（具体 handler 在任务 2/3 填充实现）
    if ([op isEqualToString:@"cap.hello"]) {
        resp = tvExtHandleCapHello(cl, params);
    } else if ([op isEqualToString:@"cap.list"]) {
        resp = tvExtHandleCapList(cl, params);
    } else if ([op isEqualToString:@"screen.hash"]) {
        resp = tvExtHandleScreenHash(cl, params);
    } else if ([op isEqualToString:@"screen.diff"]) {
        resp = tvExtHandleScreenDiff(cl, params);
    } else if ([op isEqualToString:@"screen.waitStable"]) {
        resp = tvExtHandleScreenWaitStable(cl, params);
    } else if ([op isEqualToString:@"clients.count"]) {
        resp = tvExtHandleClientsCount(cl, params);
    } else if ([op isEqualToString:@"clients.list"]) {
        resp = tvExtHandleClientsList(cl, params);
    } else if ([op isEqualToString:@"clients.disconnect"]) {
        resp = tvExtHandleClientsDisconnect(cl, params);
    } else if ([op isEqualToString:@"clients.block"]) {
        resp = tvExtHandleClientsBlock(cl, params);
    } else if ([op isEqualToString:@"clients.unblock"]) {
        resp = tvExtHandleClientsUnblock(cl, params);
    } else if ([op isEqualToString:@"clients.blocked.list"]) {
        resp = tvExtHandleClientsBlockedList(cl, params);
    } else {
        resp = tvExtErr([NSString stringWithFormat:@"未知操作: %@", op ?: @""]);
    }

    tvExtWriteResponse(cl, resp);
    return TRUE;
}

/** 扩展 newClient：LibVNCServer 要求非 NULL 才激活扩展（rfb.h "if newClient == NULL, it is always deactivated"）
 *  @param cl   客户端连接指针（未使用）
 *  @param data 扩展私有数据指针（未使用，数据走 TVClientState）
 *  @return     TRUE 激活扩展；FALSE 拒绝客户端
 */
static rfbBool tvExtNewClient(rfbClientPtr cl, void **data) {
    (void)cl; (void)data;
    return TRUE;  // 激活扩展（不挂载扩展私有数据，数据走 TVClientState）
}

static rfbProtocolExtension gTvExtExtension = {
    .newClient            = tvExtNewClient,
    .init                 = NULL,
    .pseudoEncodings      = NULL,
    .enablePseudoEncoding = NULL,
    .handleMessage        = tvExtHandleMessage,
    .close                = NULL,
    .usage                = NULL,
    .processArgument      = NULL,
    .next                 = NULL
};

/** 注册 RFB 协议扩展（在 rfbInitServer 之前调用） */
static void setupRfbExtension(void) {
    rfbRegisterProtocolExtension(&gTvExtExtension);
    TVLog(@"RFB extension registered (type 0x50)");
}

/** 处理 cap.hello：标记管理客户端并撤销 newClientHook 的计数/状态注册
 *  - params[@"mgmt"] 为真时：st->isMgmtClient=YES、gClientCount--、
 *    从 gClientStates 移除条目、cl->viewOnly=TRUE（不推帧）、刷新通知/Bonjour
 *  - params[@"mgmt"] 为假时：no-op，仅回传 exempted:NO
 *  @param cl     客户端连接指针
 *  @param params 请求参数 NSDictionary
 *  @return        NSDictionary 响应（含 exempted 标记），永不为 nil
 */
static NSDictionary *tvExtHandleCapHello(rfbClientPtr cl, NSDictionary *params) {
    TVClientState *st = tvGetClientState(cl);
    if (!st) return tvExtErr(@"客户端状态不可用");

    BOOL isMgmt = [params[@"mgmt"] boolValue];
    if (isMgmt) {
        if (st->isMgmtClient) return tvExtOk(@{@"exempted": @YES});  // 幂等：已豁免则不再减计数
        st->isMgmtClient = YES;
        // 撤销 newClientHook 的计数与状态注册
        gClientCount--;
        if (st->clientId8[0] != '\0') {
            NSString *cid = [NSString stringWithUTF8String:st->clientId8];
            @synchronized(gClientStates) {
                [gClientStates removeObjectForKey:cid];
            }
        }
        // 不推画面帧
        cl->viewOnly = TRUE;
        // 更新通知（计数已变）
        refreshBonjourTXTRecord();
        tvPublishUserSingleNotifs();
        TVLog(@"Management client exempted (clients=%d)", gClientCount);
    }
    return tvExtOk(@{@"exempted": @(isMgmt)});
}

/** 处理 cap.list：返回扩展消息组目录供 AI 发现可用操作
 *  - 返回 extensions 数组，每组含 group 名与 ops 列表
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数（未使用）
 *  @return        NSDictionary 响应，data[@"extensions"] 为 group 目录数组
 */
static NSDictionary *tvExtHandleCapList(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    (void)params;
    NSArray *groups = @[
        @{@"group": @"cap",     @"ops": @[@"cap.hello", @"cap.list"]},
        @{@"group": @"screen",  @"ops": @[@"screen.hash", @"screen.diff", @"screen.waitStable"]},
        @{@"group": @"clients", @"ops": @[@"clients.count", @"clients.list",
                                         @"clients.disconnect", @"clients.block",
                                         @"clients.unblock", @"clients.blocked.list"]},
    ];
    return tvExtOk(@{@"extensions": groups});
}

#pragma mark - Client Helpers

// Generate a stable-length 8-char id for a given socket fd (deterministic per fd).
static NSString *tvGenerateClientId8(int fd) {
    static uint64_t sSeed = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Mix boot hash and time for seed
        NSString *boot = tvBonjourServiceName(@""); // 8-char suffix only when baseName is empty
        uint64_t h = 1469598103934665603ULL;
        for (NSUInteger i = 0; i < boot.length; i++) {
            unichar c = [boot characterAtIndex:i];
            h ^= (uint8_t)(c & 0xFF);
            h *= 1099511628211ULL;
        }
        struct timeval tv;
        gettimeofday(&tv, NULL);
        h ^= (uint64_t)tv.tv_sec;
        h *= 1099511628211ULL;
        h ^= (uint64_t)tv.tv_usec;
        h *= 1099511628211ULL;
        sSeed = h;
    });
    uint64_t x = sSeed ^ (uint64_t)(uint32_t)fd;
    // xorshift mix to spread bits
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    uint32_t v = (uint32_t)(x & 0xFFFFFFFFu);
    return [NSString stringWithFormat:@"%08x", v];
}

static NSArray *tvSnapshotClients(void) {
    // Build JSON-safe snapshot
    NSMutableArray *arr = [NSMutableArray array];
    if (!gClientStates)
        return arr;

    NSDate *now = [NSDate date];
    // No dedicated lock object earlier; guard with @synchronized on dictionary itself.
    @synchronized(gClientStates) {
        [gClientStates enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *info, BOOL *stop) {
            (void)stop;
            NSString *cid = info[@"id"] ?: key;
            NSString *host = info[@"host"] ?: @"";
            NSNumber *viewOnly = info[@"viewOnly"] ?: @(NO);
            NSDate *connectAt = info[@"connectAt"];

            double t0 = connectAt ? [connectAt timeIntervalSince1970] : [now timeIntervalSince1970];
            double dur = [[NSNumber numberWithDouble:([now timeIntervalSince1970] - t0)] doubleValue];
            [arr addObject:@{
                @"id" : cid,
                @"host" : host,
                @"viewOnly" : viewOnly,
                @"connectedAt" : @(t0),
                @"durationSec" : @(dur)
            }];
        }];
    }

    return arr;
}

static BOOL tvDisconnectClientById(NSString *cid, BOOL addToBlocklist) {
    if (!cid || cid.length == 0 || !gScreen)
        return NO;

    BOOL found = NO;
    rfbClientPtr cl = NULL;
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    while ((cl = rfbClientIteratorNext(it))) {
        NSString *kid = tvGenerateClientId8(cl->sock);
        if (![kid isEqualToString:cid]) {
            continue;
        }

        found = YES;

        // Add to blocked hosts list if requested
        if (addToBlocklist) {
            do {
                NSString *host = (cl && cl->host) ? [NSString stringWithUTF8String:cl->host] : @"";
                if (!host.length) {
                    break;
                }

                if (!gBlockedHosts) {
                    gBlockedHosts = [[NSMutableSet alloc] init];
                }

                @synchronized(gBlockedHosts) {
                    [gBlockedHosts addObject:host];
                }

                TVLog(@"Blocked host: %@", host);
            } while (NO);
        }

        rfbCloseClient(cl);
        break;
    }

    rfbReleaseClientIterator(it);
    return found;
}

static BOOL tvDisconnectAllClients(void) {
    if (!gScreen)
        return NO;

    rfbClientPtr cl = NULL;
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    while ((cl = rfbClientIteratorNext(it))) {
        rfbCloseClient(cl);
    }

    rfbReleaseClientIterator(it);
    return YES;
}

// --- RFB 扩展 handler 实现（screen.* / clients.*，复用上方辅助函数，前向声明见任务 1）---

/** 处理 screen.hash：返回当前屏幕 pHash（16 字符 hex）
 *  - 复用 TRScreenHasher.computeHashHexForCurrentFrame
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数（未使用）
 *  @return       NSDictionary 响应，data[@"hash"] 为 16 字符 hex 字符串；取帧失败为 @""
 */
static NSDictionary *tvExtHandleScreenHash(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    (void)params;
    NSString *hex = [[TRScreenHasher sharedHasher] computeHashHexForCurrentFrame];
    return tvExtOk(@{@"hash": hex ?: @""});
}

/** 处理 screen.diff：与基线哈希比较汉明距离，判定画面是否变化
 *  - params[@"baseline"]  基线哈希（16 字符 hex 字符串）
 *  - params[@"threshold"] 汉明距离阈值，缺省/传 0 时 TRScreenHasher 使用默认值 5
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数 NSDictionary
 *  @return       NSDictionary 响应，data 含 distance/threshold/changed/hash；
 *                基线非法（取帧失败）时返回 ok:NO + error:InvalidBaseline
 */
static NSDictionary *tvExtHandleScreenDiff(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    NSString *baseline = params[@"baseline"] ?: @"";
    NSInteger threshold = [params[@"threshold"] integerValue];
    NSString *currentHex = nil;
    NSDictionary *result = [[TRScreenHasher sharedHasher] diffWithBaselineHash:baseline
                                                                      threshold:threshold
                                                                    currentHash:&currentHex];
    if (!result) return tvExtErr(@"InvalidBaseline");
    return tvExtOk(@{
        @"distance": result[@"distance"],
        @"threshold": result[@"threshold"],
        @"changed": result[@"changed"],
        @"hash": currentHex ?: @""
    });
}

/** 处理 screen.waitStable：轮询等待画面稳定
 *  - params[@"maxMs"]/stableMs/intervalMs 为 NSTimeInterval（毫秒），缺省/传 0 用 TRScreenHasher 默认值
 *  - params[@"threshold"] 汉明距离阈值，缺省/传 0 用默认值 3
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数 NSDictionary
 *  @return       NSDictionary 响应，data 含 stable/frames/durationMs/hash
 */
static NSDictionary *tvExtHandleScreenWaitStable(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    NSTimeInterval maxMs = [params[@"maxMs"] doubleValue];
    NSTimeInterval stableMs = [params[@"stableMs"] doubleValue];
    NSTimeInterval intervalMs = [params[@"intervalMs"] doubleValue];
    NSInteger threshold = [params[@"threshold"] integerValue];
    NSInteger frameCount = 0;
    NSTimeInterval durationMs = 0;
    NSString *lastHash = nil;
    BOOL stable = [[TRScreenHasher sharedHasher] waitStableWithMaxMs:maxMs
                                                            stableMs:stableMs
                                                          intervalMs:intervalMs
                                                           threshold:threshold
                                                          frameCount:&frameCount
                                                          durationMs:&durationMs
                                                            lastHash:&lastHash];
    return tvExtOk(@{
        @"stable": @(stable),
        @"frames": @(frameCount),
        @"durationMs": @(durationMs),
        @"hash": lastHash ?: @""
    });
}

/** 处理 clients.count：返回当前活跃客户端数（不含管理客户端）
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数（未使用）
 *  @return       NSDictionary 响应，data[@"count"] 为整数
 */
static NSDictionary *tvExtHandleClientsCount(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    (void)params;
    return tvExtOk(@{@"count": @(gClientCount)});
}

/** 处理 clients.list：返回客户端快照列表
 *  - 复用 tvSnapshotClients()，字段 id/host/viewOnly/connectedAt/durationSec 与快照一致
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数（未使用）
 *  @return       NSDictionary 响应，data[@"clients"] 为快照数组
 */
static NSDictionary *tvExtHandleClientsList(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    (void)params;
    NSArray *clients = tvSnapshotClients();
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *c in clients) {
        [arr addObject:@{
            @"id": c[@"id"] ?: @"",
            @"host": c[@"host"] ?: @"",
            @"viewOnly": c[@"viewOnly"] ?: @NO,
            @"connectedAt": c[@"connectedAt"] ?: @"",
            @"durationSec": c[@"durationSec"] ?: @(0)
        }];
    }
    return tvExtOk(@{@"clients": arr});
}

/** 处理 clients.disconnect：踢出指定客户端（可选加入黑名单）或全部
 *  - params[@"id"]    8 字符客户端 ID；传 "ALL" 时断开全部
 *  - params[@"block"] 为真时同时将客户端 host 加入黑名单
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数 NSDictionary
 *  @return       NSDictionary 响应；ID 非法返回 ok:NO + error:InvalidID，
 *                未找到返回 ok:NO + error:NOT_FOUND
 */
static NSDictionary *tvExtHandleClientsDisconnect(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    NSString *cid = params[@"id"] ?: @"";
    BOOL shouldBlock = [params[@"block"] boolValue];
    if ([cid isEqualToString:@"ALL"]) {
        tvDisconnectAllClients();
        return tvExtOk(nil);
    }
    if (cid.length != 8) return tvExtErr(@"InvalidID");
    BOOL ok = tvDisconnectClientById(cid, shouldBlock);
    return ok ? tvExtOk(nil) : tvExtErr(@"NOT_FOUND");
}

/** 处理 clients.block：踢出指定客户端并加入黑名单
 *  - params[@"id"] 8 字符客户端 ID
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数 NSDictionary
 *  @return       NSDictionary 响应；ID 非法返回 ok:NO + error:InvalidID，
 *                未找到返回 ok:NO + error:NOT_FOUND
 */
static NSDictionary *tvExtHandleClientsBlock(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    NSString *cid = params[@"id"] ?: @"";
    if (cid.length != 8) return tvExtErr(@"InvalidID");
    BOOL ok = tvDisconnectClientById(cid, YES);
    return ok ? tvExtOk(nil) : tvExtErr(@"NOT_FOUND");
}

/** 处理 clients.unblock：从黑名单移除指定 host
 *  - params[@"host"] 待解封的主机地址
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数 NSDictionary
 *  @return       NSDictionary 响应；host 不在黑名单返回 ok:NO + error:NOT_FOUND
 */
static NSDictionary *tvExtHandleClientsUnblock(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    NSString *host = params[@"host"] ?: @"";
    if (!host.length || !gBlockedHosts) return tvExtErr(@"NOT_FOUND");
    @synchronized(gBlockedHosts) {
        if ([gBlockedHosts containsObject:host]) {
            [gBlockedHosts removeObject:host];
            return tvExtOk(nil);
        }
    }
    return tvExtErr(@"NOT_FOUND");
}

/** 处理 clients.blocked.list：返回当前黑名单主机列表
 *  @param cl     客户端连接指针（未使用，保留以统一 handler 签名）
 *  @param params 请求参数（未使用）
 *  @return       NSDictionary 响应，data[@"hosts"] 为主机地址数组
 */
static NSDictionary *tvExtHandleClientsBlockedList(rfbClientPtr cl, NSDictionary *params) {
    (void)cl;
    (void)params;
    NSMutableArray *hosts = [NSMutableArray array];
    if (gBlockedHosts) {
        @synchronized(gBlockedHosts) {
            [hosts addObjectsFromArray:[gBlockedHosts allObjects]];
        }
    }
    return tvExtOk(@{@"hosts": hosts});
}

#pragma mark - User Notifications

static void tvPublishUserSingleNotifs(void) {
    if (!gUserSingleNotifsEnabled)
        return;

    BulletinManager *mgr = [BulletinManager sharedManager];

    if (gClientCount == 0) {
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [mgr revokeSingleNotification];
        });
        return;
    }

    NSDictionary *userInfo = @{
        @"clientCount" : @(gClientCount),
    };

    NSString *localizedContentTmpl;
    localizedContentTmpl = (gClientCount == 1) ? LocalizedString(@"There is %d active VNC client.", @"Localizable",
                                                                 tvLocalizationBundle(), @"trollvncserver")
                                               : LocalizedString(@"There are %d active VNC clients.", @"Localizable",
                                                                 tvLocalizationBundle(), @"trollvncserver");

    NSString *localizedContent = [NSString stringWithFormat:localizedContentTmpl, gClientCount];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [mgr updateSingleBannerWithContent:localizedContent badgeCount:gClientCount userInfo:userInfo];
    });
}

static void tvPublishClientConnectedNotif(NSString *host) {
    if (!gUserClientNotifsEnabled || !host || host.length == 0)
        return;

    // Check if host is a loopback address
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"::1"] || [host isEqualToString:@"localhost"] ||
        [host hasPrefix:@"127."] || [host hasPrefix:@"::ffff:127."]) {
        TVLog(@"Skipping notification for loopback connection from %@", host);
        return;
    }

    BulletinManager *mgr = [BulletinManager sharedManager];

    NSDictionary *userInfo = @{
        @"clientHost" : host,
    };

    NSString *localizedContentTmpl;
    localizedContentTmpl =
        LocalizedString(@"A VNC client connected from %@.", @"Localizable", tvLocalizationBundle(), @"trollvncserver");

    NSString *localizedContent = [NSString stringWithFormat:localizedContentTmpl, host];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [mgr popBannerWithContent:localizedContent userInfo:userInfo];
    });
}

static void tvPublishClientDisconnectedNotif(NSString *host) {
    if (!gUserClientNotifsEnabled || !host || host.length == 0)
        return;

    BulletinManager *mgr = [BulletinManager sharedManager];

    NSDictionary *userInfo = @{
        @"clientHost" : host,
    };

    NSString *localizedContentTmpl;
    localizedContentTmpl = LocalizedString(@"A VNC client disconnected from %@.", @"Localizable",
                                           tvLocalizationBundle(), @"trollvncserver");

    NSString *localizedContent = [NSString stringWithFormat:localizedContentTmpl, host];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [mgr popBannerWithContent:localizedContent userInfo:userInfo];
    });
}

#pragma mark - Client Handlers

static BOOL gIsCaptureStarted = NO;
static BOOL gIsClipboardStarted = NO;

#if !TARGET_OS_SIMULATOR
static BOOL gRestoreAssist = NO;
#endif

static void clientGoneHook(rfbClientPtr cl) {
    // Free per-client state
    TVClientState *st = tvGetClientState(cl);
    BOOL wasMgmt = st && st->isMgmtClient;  // 在 free(st) 前捕获，避免悬垂访问
    NSString *removeKey = nil;
    if (st) {
        if (st->clientId8[0] != '\0') {
            removeKey = [NSString stringWithUTF8String:st->clientId8];
        }
        free(st);
        cl->clientData = NULL;
    }

    // 管理客户端：计数与状态注册已在 cap.hello 时撤销，跳过所有后续清理
    if (wasMgmt) {
        TVLog(@"Management client gone");
        return;
    }

    // Remove by cached id (fallback to fd-derived if unavailable)
    if (!removeKey)
        removeKey = tvGenerateClientId8(cl->sock);
    if (removeKey && gClientStates) {
        @synchronized(gClientStates) {
            [gClientStates removeObjectForKey:removeKey];
        }
    }

    // Decrement client count and stop capture if this was the last client.
    if (gClientCount > 0)
        gClientCount--;

    NSString *host = (cl && cl->host) ? [NSString stringWithUTF8String:cl->host] : @"";
    TVLog(@"Client %@ disconnected, active clients=%d", host, gClientCount);

    if (gIsCaptureStarted && gClientCount == 0) {
        [[ScreenCapturer sharedCapturer] endCapture];
        gIsCaptureStarted = NO;
        TVLog(@"No clients remaining; screen capture stopped.");
    }

    if (gIsClipboardStarted && gClientCount == 0) {
        [[ClipboardManager sharedManager] stop];
        gIsClipboardStarted = NO;
        TVLog(@"No clients remaining; clipboard listening stopped.");
    }

#if !TARGET_OS_SIMULATOR
    // AutoAssist: disable AssistiveTouch if we enabled it and no clients remain
    if (gClientCount == 0 && gRestoreAssist) {
        gRestoreAssist = NO;
        [PSAssistiveTouchSettingsDetail setEnabled:NO];
    }
#endif

    // KeepAlive: disable when no clients remain
    if (gClientCount == 0) {
        [[STHIDEventGenerator sharedGenerator] setKeepAliveInterval:0];
        TVLog(@"No clients remaining; KeepAlive stopped.");
    }

    // Update TXT with possibly changed state (e.g., viewOnly unaffected, but keep consistent)
    refreshBonjourTXTRecord();

    // Update user notification
    tvPublishUserSingleNotifs();

    // Notify client disconnected
    tvPublishClientDisconnectedNotif(host);
}

static enum rfbNewClientAction newClientHook(rfbClientPtr cl) {
    cl->clientGoneHook = clientGoneHook;
    if (!cl->viewOnly && gViewOnly)
        cl->viewOnly = TRUE;

    // 2026-08-14 统一协议通道：enableExtendedClipboard 为 per-client 字段（_rfbClientRec），
    // 需对每个新客户端显式置位才协商 extended caps 伪编码（0xC0A1E5CE），
    // noVNC 检测到后走 ExtendedClipboard Notify/Request/Provide（UTF-8 + deflate）→ 中文双向无损。
    if (gClipboardEnabled) {
        cl->enableExtendedClipboard = TRUE;
    }

    // Allocate per-client state bag
    TVClientState *st = (TVClientState *)calloc(1, sizeof(TVClientState));
    if (st) {
        st->lastButtonMask = 0;
        st->wheelAccumPx = 0;
        st->wheelFlushScheduled = NO;
        st->clientId8[0] = '\0';
        st->isMgmtClient = NO;  // 默认非管理客户端；cap.hello 到达后置 YES
        cl->clientData = st;
    }

    gClientCount++;
    TVLog(@"Client connected, active clients=%d", gClientCount);

    // Add to global client states
    NSString *clientId = tvGenerateClientId8(cl->sock);
    if (st && clientId.length) {
        // Cache into fixed buffer
        const char *u8 = [clientId UTF8String];
        if (u8) {
            size_t n = strnlen(u8, 8);
            memcpy(st->clientId8, u8, n);
            st->clientId8[n] = '\0';
        }
    }
    NSString *host = (cl && cl->host) ? [NSString stringWithUTF8String:cl->host] : @"";
    NSDate *now = [NSDate date];
    NSDictionary *entry = @{
        @"id" : clientId,
        @"host" : host,
        @"viewOnly" : @(cl->viewOnly ? YES : NO),
        @"connectAt" : now,
    };

    if (!gClientStates)
        gClientStates = [[NSMutableDictionary alloc] init];
    gClientStates[clientId] = entry;

    // Update TXT (e.g., potential dynamic flags in future)
    refreshBonjourTXTRecord();

    // Update user notification
    tvPublishUserSingleNotifs();

    // Notify client connected
    tvPublishClientConnectedNotif(host);

    if (!gIsCaptureStarted && gClientCount > 0 && gFrameHandler) {
        // Start capture when entering non-zero client population.
        gIsCaptureStarted = YES;
        [[ScreenCapturer sharedCapturer] startCaptureWithFrameHandler:gFrameHandler];
        TVLog(@"Screen capture started (clients=%d).", gClientCount);
    }

    if (gClipboardEnabled && !gIsClipboardStarted && gClientCount > 0) {
        gIsClipboardStarted = YES;
        [[ClipboardManager sharedManager] start];
        TVLog(@"Clipboard listening started (clients=%d).", gClientCount);
    }

#if !TARGET_OS_SIMULATOR
    // AutoAssist: enable AssistiveTouch if not already enabled
    if (gClientCount > 0 && gAutoAssistEnabled && ![PSAssistiveTouchSettingsDetail isEnabled]) {
        gRestoreAssist = YES;
        [PSAssistiveTouchSettingsDetail setEnabled:YES];
    }
#endif

    // KeepAlive: enable when at least one client is connected and interval > 0
    if (gClientCount > 0 && gKeepAliveSec > 0.0) {
        [[STHIDEventGenerator sharedGenerator] setKeepAliveInterval:gKeepAliveSec];
        TVLog(@"KeepAlive started with interval (%.3f sec)", gKeepAliveSec);
    }

    return RFB_CLIENT_ACCEPT;
}

#pragma mark - Clipboard Extension

static std::atomic<int> gClipboardSuppressSend(0); // >0 means suppress sending clipboard to clients

static void setXCutTextLatin1(char *str, int len, rfbClientPtr cl) {
    (void)cl;
    if (!str || len < 0)
        len = 0;

    TVLog(@"Clipboard: received client cut text (Latin-1) len=%d", len);
    NSData *data = [NSData dataWithBytes:str length:(NSUInteger)len];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!s)
        s = @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        gClipboardSuppressSend.fetch_add(1, std::memory_order_relaxed);

        TVLog(@"Clipboard: applying client text to UIPasteboard (Latin-1), suppression now=%d",
              gClipboardSuppressSend.load(std::memory_order_relaxed));
        [[ClipboardManager sharedManager] setStringFromRemote:s];

        gClipboardSuppressSend.fetch_sub(1, std::memory_order_relaxed);
    });
}

static void setXCutTextUTF8(char *str, int len, rfbClientPtr cl) {
    (void)cl;
    if (!str || len < 0)
        len = 0;

    TVLog(@"Clipboard: received client cut text (UTF-8) len=%d", len);

    // 2026-08-15：noVNC 的 extendedClipboardProvide 载荷为 [sizeBE(4)] + utf8 + "\0"，
    // size 包含尾部 NUL；libvncserver 按 size 原样回调 setXCutTextUTF8。剔除尾部 \0，
    // 避免设备剪贴板残留空字节（与设备→控制端 sendExtendedClipboardProvideToClients 的
    // 无 \0 载荷保持对称）。
    if (len > 0 && str[len - 1] == '\0') {
        len--;
    }

    NSData *data = [NSData dataWithBytes:str length:(NSUInteger)len];
    // 2026-08-14 移除 Latin-1 降级：Extended Clipboard 的 Provide 数据保证 UTF-8，
    // 解码失败直接丢弃并记录（不做静默降级为 Latin-1）
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) {
        TVLog(@"Clipboard: extended clipboard UTF-8 decode failed (len=%d)", len);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        gClipboardSuppressSend.fetch_add(1, std::memory_order_relaxed);

        TVLog(@"Clipboard: applying client text to UIPasteboard (UTF-8), suppression now=%d",
              gClipboardSuppressSend.load(std::memory_order_relaxed));
        [[ClipboardManager sharedManager] setStringFromRemote:s];

        gClipboardSuppressSend.fetch_sub(1, std::memory_order_relaxed);
    });
}

// 2026-08-14 设备→控制剪贴板发送（协议修复）：
// 旧版 libvncserver 的 rfbSendServerCutTextUTF8 以 framebufferUpdate rect（encoding=0x10000001）发送
// Extended Clipboard，noVNC 不识该编码 → _handleDataRect 直接 _fail 断连
// （"Failed while connected: Unsupported encoding (encoding: 268435457)"）。
// 改为按 TigerVNC / libvncserver master 同款协议发送「负长度 ServerCutText Provide」：
//   [type=3][pad×3][-(4+zlibLen) BE][flags=0x10000001 BE][zlib( [utf8Len BE] + utf8 )]
// noVNC _handleServerCutText 原生解析（Provide → inflate → decodeUTF8 → 'clipboard' 事件），无需改动前端。
//
// @param utf8     UTF-8 编码的剪贴板文本（无 \0 结尾，按 utf8Len 精确读取）
// @param utf8Len  UTF-8 文本字节数
static void sendExtendedClipboardProvideToClients(const char *utf8, int utf8Len) {
    if (!utf8 || utf8Len <= 0) {
        return;
    }

    // 1) 组装压缩前载荷：[utf8Len(4BE)] + utf8 原文（与 libvncserver rfbSendExtendedServerCutTextData 同构）
    uLongf rawLen = (uLongf)utf8Len + 4;
    std::vector<uint8_t> raw(rawLen);
    uint32_t sizeBE = htonl((uint32_t)utf8Len);
    memcpy(raw.data(), &sizeBE, 4);
    memcpy(raw.data() + 4, utf8, (size_t)utf8Len);

    // 2) zlib 压缩（compress + Z_DEFAULT_COMPRESSION，与 libvncserver 一致）
    uLongf zlibLen = compressBound(rawLen);
    std::vector<uint8_t> zlibData(zlibLen);
    if (compress(zlibData.data(), &zlibLen, raw.data(), rawLen) != Z_OK) {
        TVLog(@"Clipboard: zlib compress failed (utf8Len=%d)", utf8Len);
        return;
    }

    // 3) 组装负长度 ServerCutText 消息
    const int total = 12 + (int)zlibLen;
    std::vector<uint8_t> msg((size_t)total);
    msg[0] = 3;                        // rfbServerCutText (0x03)
    msg[1] = msg[2] = msg[3] = 0;      // padding
    uint32_t negLen = htonl((uint32_t)(-(4 + (int)zlibLen)));   // 负长度 = -(4 字节 flags + zlib 流)
    uint32_t flags = htonl((uint32_t)(rfbExtendedClipboard_Provide | rfbExtendedClipboard_Text)); // 0x10000001
    memcpy(msg.data() + 4, &negLen, 4);
    memcpy(msg.data() + 8, &flags, 4);
    memcpy(msg.data() + 12, zlibData.data(), zlibLen);

    // 4) 逐客户端发送（仅 enableExtendedClipboard 客户端；写互斥由 sendMutex 保护，
    //    与 libvncserver rfbSendServerCutTextUTF8 的 LOCK(sendMutex) 模式一致；失败显式关闭连接）
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    int sent = 0;
    while ((cl = rfbClientIteratorNext(it)) != NULL) {
        if (!cl->enableExtendedClipboard) {
            continue;
        }
        pthread_mutex_lock(&cl->sendMutex);
        if (rfbWriteExact(cl, (const char *)msg.data(), total) < 0) {
            TVLog(@"Clipboard: write to client failed, closing");
            rfbCloseClient(cl);
        } else {
            sent++;
        }
        pthread_mutex_unlock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);

    TVLog(@"Clipboard: extended provide sent (utf8Len=%d zlib=%d clients=%d)", utf8Len, (int)zlibLen, sent);
}

static void sendClipboardToClients(NSString *_Nullable text) {
    if (!gScreen) {
        TVLog(@"Clipboard: screen not initialized; skipping send");
        return;
    }

    if (!gClipboardEnabled) {
        TVLog(@"Clipboard: sync disabled; skipping send");
        return;
    }

    if (gClientCount <= 0) {
        TVLog(@"Clipboard: no connected clients; skipping send");
        return;
    }

    if (gClipboardSuppressSend.load(std::memory_order_relaxed) > 0) {
        TVLog(@"Clipboard: send suppressed (local set echo avoidance)");
        return; // suppressed (likely local set)
    }

    // 2026-08-14 移除 Latin-1 降级：统一走 Extended Clipboard UTF-8（设备端 enableExtendedClipboard 已启用），
    // 不做 Latin-1 双轨兜底——中文/emoji 必须 UTF-8 无损传输
    char *utf8 = NULL;
    int utf8Len = 0;

    do {
        if (!text) {
            break;
        }

        NSData *utf8Data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        utf8Len = (int)utf8Data.length;
        if (!utf8Len)
            break;

        utf8 = (char *)malloc((size_t)utf8Len);
        if (!utf8) {
            utf8Len = 0;
            break;
        }

        memcpy(utf8, [utf8Data bytes], (size_t)utf8Len);

    } while (0);

    if (utf8) {
        TVLog(@"Clipboard: sending to clients (utf8Len=%d, clients=%d)", utf8Len, gClientCount);
        // 2026-08-14 不再调用旧版 libvncserver 的 rfbSendServerCutTextUTF8：
        // 其 rect 编码 0x10000001 会导致 noVNC "Unsupported encoding" 断连；改走标准负长度 ServerCutText。
        sendExtendedClipboardProvideToClients(utf8, utf8Len);
    } else {
        TVLog(@"Clipboard: no valid clipboard data to send");
    }

    if (utf8)
        free(utf8);
}

#pragma mark - Server-Side Cursor

NS_INLINE void setupXCursor(rfbScreenInfoPtr screen) {
    // 2026-08-14：苹果风格圆点光标（白色填充 + 黑色描边，透明外圈）。
    // 与前端 noVNC dot 光标（server/index.js 7×7 白点黑边）视觉一致，
    // 深色/浅色画面下均清晰可见；13×13 较 7×7 在真机触控场景更易辨识。
    int width = 13, height = 13;

    // mask：半径 6.5 的圆（不透明区域）
    const char mask[] = "    xxxxx    "
                        "  xxxxxxxxx  "
                        " xxxxxxxxxxx "
                        " xxxxxxxxxxx "
                        "xxxxxxxxxxxxx"
                        "xxxxxxxxxxxxx"
                        "xxxxxxxxxxxxx"
                        "xxxxxxxxxxxxx"
                        "xxxxxxxxxxxxx"
                        " xxxxxxxxxxx "
                        " xxxxxxxxxxx "
                        "  xxxxxxxxx  "
                        "    xxxxx    ";
    // cursor：'x'=黑色像素（描边环），' '=白色像素（填充），mask 之外透明
    const char cursor[] = "    xxxxx    "
                          "  xxxxxxxxx  "
                          " xxx     xxx "
                          " xx       xx "
                          "xx         xx"
                          "xx         xx"
                          "xx         xx"
                          "xx         xx"
                          "xx         xx"
                          " xx       xx "
                          " xxx     xxx "
                          "  xxxxxxxxx  "
                          "    xxxxx    ";

    rfbCursorPtr c = rfbMakeXCursor(width, height, (char *)cursor, (char *)mask);
    if (!c)
        return;

    c->xhot = width / 2;
    c->yhot = height / 2;
    rfbSetCursor(screen, c);
}

NS_INLINE void setupAlphaCursor(rfbScreenInfoPtr screen, int mode) {
    int i, j;
    rfbCursorPtr c = screen ? screen->cursor : NULL;
    if (!c)
        return;

    int maskStride = (c->width + 7) / 8;

    if (c->alphaSource) {
        free(c->alphaSource);
        c->alphaSource = NULL;
    }
    if (mode == 0)
        return;

    c->alphaSource = (unsigned char *)malloc((size_t)c->width * (size_t)c->height);
    if (!c->alphaSource)
        return;

    for (j = 0; j < c->height; j++) {
        for (i = 0; i < c->width; i++) {
            unsigned char value = (unsigned char)(0x100 * i / c->width);
            rfbBool masked = (c->mask[(i / 8) + maskStride * j] << (i & 7)) & 0x80;
            c->alphaSource[i + c->width * j] = (unsigned char)(masked ? (mode == 1 ? value : 0xff - value) : 0);
        }
    }

    if (c->cleanupMask)
        free(c->mask);

    c->mask = (unsigned char *)rfbMakeMaskFromAlphaSource(c->width, c->height, c->alphaSource);
    c->cleanupMask = TRUE;
}

#pragma mark - Setups (Native)

static void prepareClipboardManager(void) {
    // server->client sync; start/stop tied to client presence
    if (gClipboardEnabled) {
        [[ClipboardManager sharedManager] setOnChange:^(NSString *_Nullable text) {
            // If we’re in suppression (coming from client->server), do nothing
            if (gClipboardSuppressSend.load(std::memory_order_relaxed) > 0)
                return;
            sendClipboardToClients(text);
        }];
    } else {
        [[ClipboardManager sharedManager] setOnChange:nil];
    }
}

static void prepareScreenCapturer(void) {
    // Apply preferred frame rate (if provided)
    if (gFpsMin > 0 || gFpsPref > 0 || gFpsMax > 0) {
        TVLog(@"Applying preferred FPS to ScreenCapturer: min=%d pref=%d max=%d", gFpsMin, gFpsPref, gFpsMax);
        [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:gFpsMin preferred:gFpsPref max:gFpsMax];
    }

    gFrameHandler = ^(CMSampleBufferRef _Nonnull sampleBuffer) {
        handleFramebuffer(sampleBuffer);
    };
}

static void prepareBulletinManager(void) {
    BulletinManager *mgr = [BulletinManager sharedManager];
    [mgr revokeSingleNotification];
}

static void setupGeometry(void) {
    NSDictionary *props = [[ScreenCapturer sharedCapturer] renderProperties];
    gSrcWidth = [props[(__bridge NSString *)kIOSurfaceWidth] intValue];
    gSrcHeight = [props[(__bridge NSString *)kIOSurfaceHeight] intValue];
    if (gSrcWidth <= 0 || gSrcHeight <= 0) {
        TVPrintError("Failed to get screen dimensions");
        exit(EXIT_FAILURE);
    }

    // Apply output scaling if requested, then align (width multiple of 4)
    int tmpW = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)gSrcWidth * gScale)) : gSrcWidth;
    int tmpH = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)gSrcHeight * gScale)) : gSrcHeight;
    alignDimensions(tmpW, tmpH, &gWidth, &gHeight);
    gFBSize = (size_t)gWidth * (size_t)gHeight * (size_t)gBytesPerPixel;

    // Allocate double buffers (tightly packed BGRA/ARGB32)
    gFrontBuffer = calloc(1, gFBSize);
    gBackBuffer = calloc(1, gFBSize);
    if (!gFrontBuffer || !gBackBuffer) {
        TVPrintError("Failed to allocate required frame buffers");
        exit(EXIT_FAILURE);
    }
}

#if !TARGET_IPHONE_SIMULATOR
// Rotate an orientation by N quadrants (each quadrant = 90° CW)
NS_INLINE UIInterfaceOrientation rotateOrientation(UIInterfaceOrientation o, int quads) {
    // Map orientation to quadrant index: Portrait=0, LandLeft=1, UpsideDown=2, LandRight=3
    int q;
    switch (o) {
    case UIInterfaceOrientationPortrait:
    default:
        q = 0;
        break;
    case UIInterfaceOrientationLandscapeLeft:
        q = 1;
        break;
    case UIInterfaceOrientationPortraitUpsideDown:
        q = 2;
        break;
    case UIInterfaceOrientationLandscapeRight:
        q = 3;
        break;
    }
    q = (q + quads) & 3;
    static const UIInterfaceOrientation map[] = {
        UIInterfaceOrientationPortrait,
        UIInterfaceOrientationLandscapeLeft,
        UIInterfaceOrientationPortraitUpsideDown,
        UIInterfaceOrientationLandscapeRight,
    };
    return map[q];
}
#endif

// Map UIInterfaceOrientation to rotation quadrant (clockwise degrees/90)
NS_INLINE int rotationForOrientation(UIInterfaceOrientation o) {
#if !TARGET_IPHONE_SIMULATOR
    if (gOrientationFixQuad != 0) {
        o = rotateOrientation(o, gOrientationFixQuad);
    }
#endif
    switch (o) {
    case UIInterfaceOrientationPortrait:
    default:
        return 0; // 0°
    case UIInterfaceOrientationPortraitUpsideDown:
        return 2; // 180°
    case UIInterfaceOrientationLandscapeLeft:
        return 1; // 90° CW
    case UIInterfaceOrientationLandscapeRight:
        return 3; // 270° CW
    }
}

static void setupOrientationObserver(void) {
    if (!gOrientationSyncEnabled)
        return;

    static FBSOrientationObserver *sObserver;
    sObserver = [[FBSOrientationObserver alloc] init];
    if (!sObserver) {
        TVPrintError("Failed to create orientation observer instance");
        exit(EXIT_FAILURE);
    }

    // Set update handler
    void (^handler)(FBSOrientationUpdate *) = ^(FBSOrientationUpdate *update) {
        if (!update)
            return;

        UIInterfaceOrientation activeOrientation = [update orientation];

        // Note: Actual framebuffer rotation will be handled in the next step.
        gRotationQuad.store(rotationForOrientation(activeOrientation), std::memory_order_relaxed);

#if DEBUG
        NSUInteger seq = [update sequenceNumber];
        NSInteger direction = [update rotationDirection];
        NSTimeInterval dur = [update duration];
        TVLog(@"Orientation update: seq=%lu dir=%ld ori=%ld dur=%.3f", seq, direction, (long)activeOrientation, dur);
#endif
    };

    [sObserver setHandler:handler];

    // Prime current orientation if available
    UIInterfaceOrientation activeOrientation = [sObserver activeInterfaceOrientation];
    gRotationQuad.store(rotationForOrientation(activeOrientation), std::memory_order_relaxed);

    TVLog(@"Orientation observer registered (initial=%ld -> rotQ=%d)", (long)activeOrientation,
          gRotationQuad.load(std::memory_order_relaxed));
}

#pragma mark - Setups (RFB)

static void setupRfbScreen(int argc, const char *argv[]) {
    int argcCopy = argc; // rfbGetScreen may modify argc/argv
    char **argvCopy = (char **)argv;
    int bitsPerSample = 8;
    gScreen = rfbGetScreen(&argcCopy, argvCopy, gWidth, gHeight, bitsPerSample, 3, gBytesPerPixel);
    if (!gScreen) {
        TVPrintError("Failed to create rfbScreenInfo with rfbGetScreen");
        exit(EXIT_FAILURE);
    }

    // BGRA (little-endian) layout
    gScreen->paddedWidthInBytes = gWidth * gBytesPerPixel;
    gScreen->serverFormat.redShift = bitsPerSample * 2;   // 16
    gScreen->serverFormat.greenShift = bitsPerSample * 1; // 8
    gScreen->serverFormat.blueShift = 0;
    gScreen->frameBuffer = (char *)gFrontBuffer;

    // Desktop name
    gScreen->desktopName = strdup([gDesktopName UTF8String]);

    // Server ports
    gScreen->port = gPort;
    gScreen->ipv6port = gPort;

    // Server bind addresses
    in_addr_t v4Addr = INADDR_ANY;
    struct in6_addr v6Addr;
    memset(&v6Addr, 0, sizeof(v6Addr));

    TVBindHostKind hostKind = tvClassifyBindHost(gBindHost, &v4Addr, &v6Addr);
    if (hostKind == kTVBindHostKindIPv4) {
        gScreen->listenInterface = v4Addr;
    } else if (hostKind == kTVBindHostKindIPv6) {
        char ifaceBuf[INET6_ADDRSTRLEN];
        const char *iface = inet_ntop(AF_INET6, &v6Addr, ifaceBuf, sizeof(ifaceBuf));
        if (!iface) {
            TVPrintError("Failed to normalize IPv6 bind host");
            exit(EXIT_FAILURE);
        }
        gScreen->listen6Interface = strdup(iface);
    } else if (hostKind == kTVBindHostKindInvalid && gBindHost) {
        TVPrintError("Invalid host address: %s", [gBindHost UTF8String]);
        exit(EXIT_FAILURE);
    } else {
        // Do nothing; default ANY
    }

    // Event handlers
    gScreen->newClientHook = newClientHook;
    gScreen->displayHook = displayHook;
    gScreen->displayFinishedHook = displayFinishedHook;
    gScreen->setDesktopSizeHook = setDesktopSizeHook;
}

static void setupRfbEventHandlers(void) {
    gScreen->ptrAddEvent = ptrAddEvent;
    gScreen->kbdAddEvent = kbdAddEvent;
    gScreen->kbdReleaseAllKeys = kbdReleaseAllKeys;
}

static rfbBool tvCheckPasswordByList(rfbClientPtr cl, const char *passwd, int len) {
    // Check if client host is blocked
    if (gBlockedHosts && cl && cl->host) {
        NSString *host = [NSString stringWithUTF8String:cl->host];
        BOOL isBlocked = NO;
        @synchronized(gBlockedHosts) {
            isBlocked = [gBlockedHosts containsObject:host];
        }
        if (isBlocked) {
            TVLog(@"Rejected connection from blocked host: %@", host);
            return FALSE; // Reject authentication
        }
    }

    rfbBool rc = rfbCheckPasswordByList(cl, passwd, len);

    TVClientState *st = tvGetClientState(cl);
    NSString *updateKey = nil;
    if (st && st->clientId8[0] != '\0') {
        updateKey = [NSString stringWithUTF8String:st->clientId8];
    }

    if (!updateKey)
        updateKey = tvGenerateClientId8(cl->sock);
    if (updateKey && gClientStates) {
        @synchronized(gClientStates) {
            NSMutableDictionary *entry = [gClientStates[updateKey] mutableCopy];
            if (entry) {
                entry[@"viewOnly"] = @(cl->viewOnly ? YES : NO);
                gClientStates[updateKey] = [entry copy];
            }
        }
    }

    return rc;
}

static void setupRfbClassicAuthentication(void) {
    // Enable classic VNC authentication if environment variables are provided
    const char *envPwd = getenv("TROLLVNC_PASSWORD");
    const char *envViewPwd = getenv("TROLLVNC_VIEWONLY_PASSWORD");

    int fullCount = (envPwd && *envPwd) ? 1 : 0;
    int viewCount = (envViewPwd && *envViewPwd) ? 1 : 0;
    if (fullCount + viewCount > 0) {
        // Vector size = number of passwords + 1 for NULL terminator
        int vecCount = fullCount + viewCount + 1;
        gAuthPasswdVec = (char **)calloc((size_t)vecCount, sizeof(char *));

        int idx = 0;
        if (fullCount) {
            gAuthPasswdStr = strdup(envPwd);
            gAuthPasswdVec[idx++] = gAuthPasswdStr;
        }

        if (viewCount) {
            gAuthViewOnlyPasswdStr = strdup(envViewPwd);
            gAuthPasswdVec[idx++] = gAuthViewOnlyPasswdStr;
        }

        gAuthPasswdVec[idx] = NULL; // NULL-terminated array
        gScreen->authPasswdData = (void *)gAuthPasswdVec;

        // Index of first view-only password = number of full-access passwords
        // From that index onward (1-based in description, 0-based in array) are view-only.
        gScreen->authPasswdFirstViewOnly = fullCount;
        gScreen->passwordCheck = tvCheckPasswordByList;

        TVLog(@"Classic VNC authentication enabled via env: full=%d, view-only=%d", fullCount, viewCount);
    }
}

static void setupRfbCutTextHandlers(void) {
    // client->server sync
    if (gClipboardEnabled) {
        gScreen->setXCutText = setXCutTextLatin1;
        gScreen->setXCutTextUTF8 = setXCutTextUTF8;
        // 2026-08-14 统一协议通道：启用 TightVNC Extended Clipboard（UTF-8 双向无损）。
        // setXCutTextUTF8 回调已注册（承接客户端 Provide 解压后的 UTF-8 文本）；
        // enableExtendedClipboard 为 per-client 字段（_rfbClientRec），需在 newClientHook
        // 对每个新客户端置 TRUE 才协商 extended caps 伪编码（0xC0A1E5CE），
        // noVNC 检测到后走 ExtendedClipboard Notify/Request/Provide（UTF-8 + deflate）→ 中文无损。
        TVLog(@"Clipboard: client->server handlers registered (enabled, extended clipboard)");
    } else {
        TVLog(@"Clipboard: client->server handlers not registered (disabled)");
    }
}

static void setupRfbServerSideCursor(void) {
    if (gCursorEnabled) {
        setupXCursor(gScreen);
        setupAlphaCursor(gScreen, 0);
        TVLog(@"Cursor: XCursor + alpha mode=2 enabled");
    } else {
        // 2026-08-14：关闭必须清除已注册的服务端光标（原实现只打日志，残留 X 持续发送）。
        // rfbSetCursor(NULL) 置 screen->cursor=NULL + cursorWasChanged，新连接不再发服务端光标
        // （noVNC 回落显示 dot 圆点）；已建立连接保留旧光标，重连后生效。
        rfbSetCursor(gScreen, NULL);
        TVLog(@"Cursor: disabled (default; enable with -U on)");
    }
}

static void setupRfbHttpServer(void) {
    // Built-in HTTP server settings (see rfb.h http* fields)
    gScreen->httpEnableProxyConnect = TRUE; // always allow CONNECT if HTTP is enabled
    if (gHttpPort > 0) {
        gScreen->httpPort = gHttpPort; // enable HTTP on specified port
        gScreen->http6Port = gHttpPort;
        if (gHttpDirOverride) {
            // Use override absolute path
            gScreen->httpDir = strdup(gHttpDirOverride);
            TVLog(@"HTTP server config: port=%d, dir=%s (override), proxyConnect=YES", gHttpPort, gHttpDirOverride);
        } else {
            // Compute httpDir relative to executable: ../share/trollvnc/webclients
            do {
                NSString *exe = tvExecutablePath();
                NSString *exeDir = [exe stringByDeletingLastPathComponent];
                NSString *webRel;
#ifdef THEBOOTSTRAP
                webRel = @"./webclients";
#else
                webRel = @"../share/trollvnc/webclients";
#endif
                NSString *webPath = [[exeDir stringByAppendingPathComponent:webRel] stringByStandardizingPath];
                const char *fs = [webPath fileSystemRepresentation];
                if (fs && *fs) {
                    gScreen->httpDir = strdup(fs);
                    TVLog(@"HTTP server config: port=%d, dir=%@, proxyConnect=YES", gHttpPort, webPath);
                }
            } while (0);
        }
    } else {
        gScreen->httpPort = 0;   // disabled
        gScreen->httpDir = NULL; // do not set dir to avoid default startup
    }

    // SSL certificate and key (optional)
    if (gSslCertPath && *gSslCertPath) {
        gScreen->sslcertfile = strdup(gSslCertPath);
    }
    if (gSslKeyPath && *gSslKeyPath) {
        gScreen->sslkeyfile = strdup(gSslKeyPath);
    }
}

static BOOL gFileTransferRegistered = NO;

static void setupRfbFileTransferExtension(void) {
    if (!gFileTransferEnabled) {
        return;
    }

    TVLog(@"TightVNC 1.x file transfer extension registered");
    rfbRegisterTightVNCFileTransferExtension();

    gFileTransferRegistered = YES;
}

#pragma mark - Setups (Event Model)

static const long cSelectTimeout = 1e4; // 10 ms

static void initializeAndRunRfbServer(void) {
    setupRfbExtension();
    rfbInitServer(gScreen);
    TVLog(@"VNC server initialized on port %d, %dx%d, name '%@'", gPort, gWidth, gHeight, gDesktopName);

    // Run VNC in background thread
    rfbRunEventLoop(gScreen, cSelectTimeout, TRUE);

    // Start Bonjour advertisement after server is ready
    startBonjour();
}

static void handleSignal(int signum) {
    (void)signum;
    TVLog(@"Signal %d received", signum);

    // Best-effort: stop runloop to unwind main and allow cleanup.
    CFRunLoopStop(CFRunLoopGetMain());
}

static void installSignalHandlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handleSignal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

static void installTerminationHandlers(void) {
    atexit_b(^(void) {
#if !TARGET_OS_SIMULATOR
        if (gRestoreAssist) {
            gRestoreAssist = NO;
            [PSAssistiveTouchSettingsDetail setEnabled:NO];
        }
#endif
    });
}

#pragma mark - Logging

BOOL tvncLoggingEnabled = YES;
BOOL tvncVerboseLoggingEnabled = NO;

#define LOCK(mutex) pthread_mutex_lock(&(mutex))
#define UNLOCK(mutex) pthread_mutex_unlock(&(mutex))

static MUTEX(logMutex);
static int logMutex_initialized = 0;

static void rfbCustomLog(const char *format, ...) {
    va_list args;
    char buf[256];
    time_t log_clock;

    if (!tvncLoggingEnabled)
        return;

    if (!logMutex_initialized) {
        INIT_MUTEX(logMutex);
        logMutex_initialized = 1;
    }

    LOCK(logMutex);
    va_start(args, format);

    time(&log_clock);
    strftime(buf, 255, "%Y-%m-%d %X ", localtime(&log_clock));
    fprintf(stderr, "%s", buf);

    /* If format ends with a \n, replace with \r\n */
    const char *fmt_to_use = format;
    char *fmt_copy = NULL;
    if (format) {
        size_t flen = strlen(format);
        if (flen > 0 && format[flen - 1] == '\n') {
            fmt_copy = (char *)malloc(flen + 2);
            if (fmt_copy) {
                memcpy(fmt_copy, format, flen - 1);
                fmt_copy[flen - 1] = '\r';
                fmt_copy[flen] = '\n';
                fmt_copy[flen + 1] = '\0';
                fmt_to_use = fmt_copy;
            }
        }
    }

    vfprintf(stderr, fmt_to_use, args);
    fflush(stderr);

    if (fmt_copy)
        free(fmt_copy);

    va_end(args);
    UNLOCK(logMutex);
}

static void setupRfbLogging(void) { rfbLog = rfbErr = rfbCustomLog; }

#pragma mark - Main Procedure

#define REQUIRED_UID 501
#define REQUIRED_GID 501

static void dropPrivileges(void) {
    if (isatty(STDIN_FILENO)) {
        return;
    }

    int rc;
    if (getuid() != REQUIRED_UID) {
        rc = setuid(REQUIRED_UID);
        if (rc != 0) {
            TVPrintError("Failed to set uid to %d: %d", REQUIRED_UID, rc);
            exit(EXIT_FAILURE);
        }
    }

    if (getgid() != REQUIRED_GID) {
        rc = setgid(REQUIRED_GID);
        if (rc != 0) {
            TVPrintError("Failed to set gid to %d: %d", REQUIRED_GID, rc);
            // exit(EXIT_FAILURE);
        }
    }
}

static void cleanupAndExit(int code) {
    // Stop auto discovery
    stopBonjour();

    // Clear all user notifications
    [[BulletinManager sharedManager] revokeAllNotifications];

    if (gFileTransferRegistered) {
        rfbUnregisterTightVNCFileTransferExtension();
    }

    if (gScreen) {
        rfbShutdownServer(gScreen, YES);
        rfbScreenCleanup(gScreen);
        gScreen = NULL;
    }

    // There’s no need to free other resources because we’re going to exit the process. Yay!
    exit(code);
}

#ifdef THEBOOTSTRAP
#define SINGLETON_PARENT_NAME "trollvncmanager"
#define SINGLETON_MARKER_PATH "/var/mobile/Library/Caches/com.82flex.trollvnc.server.pid"

static void monitorParentProcess(void) {
    if (isatty(STDIN_FILENO)) {
        return;
    }

    static pid_t ppid = getppid();
    if (ppid == 1) {
        return;
    }

    static dispatch_source_t source =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, ppid, DISPATCH_PROC_EXIT | DISPATCH_PROC_SIGNAL,
                               dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));

    dispatch_source_set_event_handler(source, ^{
        if (dispatch_source_get_data(source) & DISPATCH_PROC_EXIT) {
            dispatch_source_cancel(source);
            TVPrintError("Parent process %d exited", ppid);
            exit(EXIT_SUCCESS);
        } else if (kill(ppid, 0) == -1 && errno == ESRCH) {
            dispatch_source_cancel(source);
            TVPrintError("Parent process %d is gone", ppid);
            exit(EXIT_SUCCESS);
        }
    });

    dispatch_resume(source);
}

static void monitorSelfAndRestartIfVnodeDeleted(const char *executable) {
    int myHandle = open(executable, O_EVTONLY);
    if (myHandle <= 0) {
        return;
    }

    static unsigned long monitorMask = DISPATCH_VNODE_DELETE;
    static dispatch_source_t monitorSource;
    monitorSource =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, myHandle, monitorMask, dispatch_get_main_queue());

    dispatch_source_set_event_handler(monitorSource, ^{
        unsigned long flags = dispatch_source_get_data(monitorSource);
        if (flags & DISPATCH_VNODE_DELETE) {
            dispatch_source_cancel(monitorSource);
            exit(EXIT_SUCCESS);
        }
    });

    dispatch_resume(monitorSource);
}

static void ensureSingleton(const char *argv[]) {
    if (isatty(STDIN_FILENO)) {
        return;
    }

    if (!argv || !argv[0] || argv[0][0] != '/') {
        return;
    }

    monitorSelfAndRestartIfVnodeDeleted(argv[0]);

    NSString *markerPath = @SINGLETON_MARKER_PATH;
    const char *cMarkerPath = [markerPath fileSystemRepresentation];

    // Open file for read/write, create if doesn't exist
    static int lockFD = open(cMarkerPath, O_RDWR | O_CREAT, 0644);
    if (lockFD == -1) {
        TVPrintError("Failed to open lock file: %s", strerror(errno));
        exit(EXIT_FAILURE);
    }

    // Try to acquire an exclusive lock
    struct flock fl;
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0; // Lock entire file

    if (fcntl(lockFD, F_SETLK, &fl) == -1) {
        // Lock already held by another process
        TVPrintError("Another instance is already running");
        close(lockFD);
        exit(EXIT_FAILURE);
    }

    // Truncate the file to clear any previous content
    if (ftruncate(lockFD, 0) == -1) {
        TVPrintError("Failed to truncate lock file: %s", strerror(errno));
        // Continue anyway
    }

    // Write PID to file
    pid_t pid = getpid();
    char pidStr[16];
    int len = snprintf(pidStr, sizeof(pidStr), "%d\n", pid);
    if (write(lockFD, pidStr, len) != len) {
        TVPrintError("Failed to write PID to lock file: %s", strerror(errno));
        // Continue anyway
    }

    // Keep the file descriptor open to maintain the lock
    // It will be automatically closed when the process exits
    fchown(lockFD, 501, 501);
}
#endif

int main(int argc, const char *argv[]) {

    /* Drop privileges: this program should run as mobile */
    dropPrivileges();

    @autoreleasepool {
        parseCLI(argc, argv);

#ifdef THEBOOTSTRAP
        monitorParentProcess();
        ensureSingleton(argv);
#endif
    }

    /* Do nothing but keep the runloop alive */
    if (!gEnabled) {
        CFRunLoopRun();
        return EXIT_SUCCESS;
    }

    @autoreleasepool {
        setupGeometry();
        setupOrientationObserver();

        setupRfbLogging();
        setupRfbScreen(argc, argv);
        setupRfbEventHandlers();
        setupRfbClassicAuthentication();
        setupRfbCutTextHandlers();
        setupRfbServerSideCursor();
        setupRfbHttpServer();
        setupRfbFileTransferExtension();

        prepareBulletinManager();
        prepareClipboardManager();
        prepareScreenCapturer();

        initializeTilingOrReset();
        initializeAndRunRfbServer();

        installSignalHandlers();
        installTerminationHandlers();
    }

    CFRunLoopRun();
    cleanupAndExit(EXIT_SUCCESS);

    return EXIT_SUCCESS;
}