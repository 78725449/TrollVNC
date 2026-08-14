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
#import <Network/Network.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>

#import "StripedTextTableViewController.h"
#import "TVNCRootListController.h"
#import "TVNCUtil.h"
#import "ZTSelfSignedCertificate.h"

NS_INLINE BOOL TVNCIsValidBindHostLiteral(NSString *host) {
    if (!host)
        return YES;

    NSString *trimmed = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return YES; // Empty means bind any interface

    const char *cstr = trimmed.UTF8String;
    if (!cstr || cstr[0] == '\0')
        return YES;

    struct in_addr v4;
    if (inet_pton(AF_INET, cstr, &v4) == 1)
        return YES;

    // Allow optional IPv6 scope suffix (e.g. fe80::1%en0)
    char addrBuf[INET6_ADDRSTRLEN + 1] = {0};
    const char *pct = strchr(cstr, '%');
    size_t copyLen = pct ? (size_t)(pct - cstr) : strlen(cstr);
    if (copyLen >= sizeof(addrBuf))
        copyLen = sizeof(addrBuf) - 1;
    memcpy(addrBuf, cstr, copyLen);
    addrBuf[copyLen] = '\0';

    struct in6_addr v6;
    return inet_pton(AF_INET6, addrBuf, &v6) == 1;
}

@interface TVNCRootListController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
@property(nonatomic, strong) UIColor *primaryColor;
@property(nonatomic, copy) NSString *jbrootPath;

@property(nonatomic, strong) PSSpecifier *certSpecifier;
@property(nonatomic, strong) PSSpecifier *keysSpecifier;
@property(nonatomic, strong) PSSpecifier *exportCertSpecifier;
@property(nonatomic, strong) NSNetServiceBrowser *gatewayBrowser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *gatewayServices;
@property(nonatomic, assign) BOOL gatewaySearchShown;
@property(nonatomic, assign) BOOL restartConfirmVisible; // restart 级配置变更后的重启确认框是否已展示（防重复弹窗）


@end

@implementation TVNCRootListController

#ifdef THEBOOTSTRAP
@synthesize bundle = _bundle;

- (NSBundle *)bundle {
    if (!_bundle) {
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    }
    return _bundle;
}
#endif

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYNSSTRINGIFY(x)                                                                                               \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return str;                                                                                                    \
    }()

- (BOOL)hasManagedConfiguration {
    static BOOL sIsManaged = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *presetPath = [self.bundle pathForResource:@"Managed" ofType:@"plist"];
        if (presetPath) {
            NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
            if (presetDict) {
                sIsManaged = YES;
            }
        }
    });
    return sIsManaged;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray<PSSpecifier *> *specifiers = nil;

        if (!specifiers) {
            if ([self hasManagedConfiguration]) {
                specifiers = [self loadSpecifiersFromPlistName:@"ManagedRoot" target:self];
            }
        }

        if (!specifiers) {
            specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        }

        for (PSSpecifier *specifier in specifiers) {
            NSString *actionName = [specifier propertyForKey:@"action"];
            if ([actionName isEqualToString:@"exportCertificate"]) {
                _exportCertSpecifier = specifier;
                break;
            }

            NSString *keyName = [specifier propertyForKey:@"key"];
            if ([keyName isEqualToString:@"SslCertFile"]) {
                _certSpecifier = specifier;
            } else if ([keyName isEqualToString:@"SslKeyFile"]) {
                _keysSpecifier = specifier;
            }
        }

        _specifiers = specifiers;
    }

    return _specifiers;
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];

    _notificationGenerator = [[UINotificationFeedbackGenerator alloc] init];
    _primaryColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    [[UISwitch appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setOnTintColor:_primaryColor];
    [[UISlider appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setMinimumTrackTintColor:_primaryColor];
    [self.view setTintColor:_primaryColor];

    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:nil
                                                                            action:nil];
    self.navigationItem.backBarButtonItem.tintColor = _primaryColor;

    if ([self hasManagedConfiguration]) {
        return;
    }
    // 右上角 Apply 按钮已移除（2026-08-14）：
    // 配置变更按 reload 级别即时生效（网关组自动重注册 / hot 走控制端热重载），
    // restart 级配置修改后由 setPreferenceValue 拦截自动弹确认框触发重启，
    // 不再需要手动"应用"动作（对齐控制端 Web 面板 setConfig 自动重启行为）。
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

#pragma mark - UINavigationControllerDelegate（2026-08-15：根页隐藏导航栏，子页临时显示）

/**
 * 导航控制器即将显示某个 VC 时按层级切换导航栏显隐：
 * 根页（self）隐藏（顶部干净、顶到状态栏）；push 进入的子设置页显示（承载返回按钮），
 * 退回根页再次隐藏。仅影响「设置」Tab 的导航控制器。
 * @param navigationController 设置页所在导航控制器
 * @param viewController 即将显示的控制器
 * @param animated 是否动画
 */
- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    BOOL isRoot = (viewController == self);
    [navigationController setNavigationBarHidden:!isRoot animated:animated];
}

#pragma mark - Actions

// 覆写配置写入：restart 级 key 变更后防抖弹重启确认框（替代原 Apply 按钮）
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    // Managed 配置下不干预（MDM 覆盖）
    if ([self hasManagedConfiguration]) {
        return;
    }

    NSString *key = [specifier propertyForKey:@"key"];
    if (key && [[self _restartRequiredKeys] containsObject:key]) {
        [self _scheduleRestartConfirm];
    }
}

/**
 * 需要重启服务才能生效的配置键（与 CONFIG_DEFS reload=restart 对齐）
 * @return NSSet<NSString *> 键集合
 */
- (NSSet<NSString *> *)_restartRequiredKeys {
    static NSSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"BindHost", @"FullPassword", @"ViewOnlyPassword",
            @"TileSize", @"MaxRects", @"AsyncSwap",
            @"HttpDir", @"SslCertFile", @"SslKeyFile",
        ]];
    });
    return keys;
}

/// 防抖：连续修改多个 restart 配置时合并为一次确认（400ms 窗口）
- (void)_scheduleRestartConfirm {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_maybeConfirmRestart) object:nil];
    [self performSelector:@selector(_maybeConfirmRestart) withObject:nil afterDelay:0.4];
}

- (void)_maybeConfirmRestart {
    if (self.restartConfirmVisible) {
        return;
    }

    // 端口固定不可调（5901/5801），仅校验绑定地址（沿用原 Apply 逻辑）
    NSString *bindHost = @"";
    for (PSSpecifier *sp in _specifiers) {
        NSString *key = [sp propertyForKey:@"key"];
        if ([key isEqualToString:@"BindHost"]) {
            id val = [self readPreferenceValue:sp];
            if ([val isKindOfClass:[NSString class]]) {
                bindHost = (NSString *)val;
            }
            break;
        }
    }

    if (!TVNCIsValidBindHostLiteral(bindHost)) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Bind Address", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"Bind address must be a valid IPv4/IPv6 literal, or empty to listen on all interfaces.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    self.restartConfirmVisible = YES;

    NSString *title = NSLocalizedStringFromTableInBundle(@"Apply Changes", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(@"Are you sure you want to restart the VNC service?",
                                                           @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) self = weakSelf;
        self.restartConfirmVisible = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                __strong typeof(weakSelf) self = weakSelf;
                                                TVNCRestartVNCService();
                                                [self.notificationGenerator
                                                    notificationOccurred:UINotificationFeedbackTypeSuccess];
                                                [self.view endEditing:YES];
                                                self.restartConfirmVisible = NO;
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)jbrootPath {
    if (!_jbrootPath) {
        NSString *rootPath = [self.bundle bundlePath];
        do {
            if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
                [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
                // Found the jailbreak root
                break;
            }
            if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
                // Found the jailbreak root (NathanLR)
                break;
            }
            if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
                // Reached the root without finding jailbreak root
                break;
            }
            rootPath = [rootPath stringByDeletingLastPathComponent];
        } while (YES);
        _jbrootPath = rootPath;
    }
    return _jbrootPath;
}

- (void)viewLogs {
#if TARGET_IPHONE_SIMULATOR
    NSString *logsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#else
    NSString *logsPath = [self.jbrootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#endif

    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = self.primaryColor;

    [logsVC setAutoReload:YES];
    [logsVC setMaximumNumberOfRows:1000];
    [logsVC setMaximumNumberOfLines:20];
    [logsVC setReversed:YES];
    [logsVC setAllowDismissal:YES];
    [logsVC setAllowMultiline:YES];
    [logsVC setAllowTrash:NO];
    [logsVC setAllowSearch:YES];
    [logsVC setAllowShare:YES];
    [logsVC setPullToReload:YES];
    [logsVC setTapToCopy:YES];
    [logsVC setPressToCopy:YES];
    [logsVC setPreserveEmptyLines:NO];
    [logsVC setRemoveDuplicates:NO];

    NSRegularExpression *rowRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\b"
                                                  options:0
                                                    error:nil];

    [logsVC setRowPrefixRegularExpression:rowRegex];
    [logsVC setRowSeparator:@"\r\n"];
    [logsVC setTitle:NSLocalizedStringFromTableInBundle(@"View Logs", @"Localizable", self.bundle, nil)];
    [logsVC setLocalizationBundle:self.bundle];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [self presentViewController:navController animated:YES completion:nil];
}

- (NSString *)cacertPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#endif
}

- (NSString *)cakeyPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#endif
}

- (void)exportCertificate {
    NSString *cacertPath = [self cacertPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cacertPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Certificate Not Found", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(
            @"You need to generate a self-signed CA certificate first before exporting it.", @"Localizable",
            self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:cacertPath];
    if (!fileURL) {
        return;
    }

    UIActivityViewController *activityViewController =
        [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

    PSTableCell *exportCertCell = nil;
    if (_exportCertSpecifier) {
        exportCertCell = [self cachedCellForSpecifier:_exportCertSpecifier];
    }
    activityViewController.popoverPresentationController.sourceView = exportCertCell ?: self.view;

    [self presentViewController:activityViewController animated:YES completion:nil];
}

- (void)generateKeys {
    NSString *cakeyPath = [self cakeyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cakeyPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Overwrite Existing Keys", @"Localizable", self.bundle, nil);
        NSString *message =
            NSLocalizedStringFromTableInBundle(@"A CA private key already exists. Generating new keys will overwrite "
                                               @"the existing ones. Are you sure you want to continue?",
                                               @"Localizable", self.bundle, nil);
        NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
        NSString *generate = NSLocalizedStringFromTableInBundle(@"Overwrite", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:generate
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf _reallyGenerateKeys];
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(
                                                            @"Export Certificate…", @"Localizable", self.bundle, nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf exportCertificate];
                                                }]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self _reallyGenerateKeys];
}

- (void)_reallyGenerateKeys {
    NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
    NSString *commonName = [NSString stringWithFormat:@"SuperPhone %@", randomUUID];

    ZTSelfSignedCertificate *ca = [ZTSelfSignedCertificate generateWithCommonName:commonName];
    if (!ca) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(@"Failed to generate self-signed CA certificate.",
                                                               @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    BOOL succeed = YES;
    NSError *error = nil;
    do {
        NSString *cacertPath = [self cacertPath];
        succeed = [ca.certificatePEM writeToFile:cacertPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cacertPath
                                                          error:&error];
        if (!succeed) {
            break;
        }

        NSString *cakeyPath = [self cakeyPath];
        succeed = [ca.privateKeyPEM writeToFile:cakeyPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cakeyPath
                                                          error:&error];
        if (!succeed) {
            break;
        }
    } while (0);

    if (!succeed) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message =
            [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Failed to save generated keys: %@",
                                                                          @"Localizable", self.bundle, nil),
                                       error.localizedDescription];
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [super setPreferenceValue:[self cacertPath] specifier:[self certSpecifier]];
    [super setPreferenceValue:[self cakeyPath] specifier:[self keysSpecifier]];

    [self reloadSpecifiers];

    NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Succeeded", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"The self-signed CA certificate and private key have been successfully generated. You need to trust this "
        @"certificate in your client browser or operating system. Restart the service to apply the changes.",
        @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // Apply 按钮已移除：生成证书后直接提供"重启服务"入口使 SslCertFile/SslKeyFile 生效
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Export Certificate…",
                                                                                       @"Localizable", self.bundle, nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [self exportCertificate];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults {
    NSString *title = NSLocalizedStringFromTableInBundle(@"Reset to Defaults", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"Are you sure you want to reset all settings to their defaults?", @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *reset = NSLocalizedStringFromTableInBundle(@"Reset", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:reset
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [weakSelf _reallyResetDefaults];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyResetDefaults {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.82flex.trollvnc"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self reloadSpecifiers];

    // Apply 按钮已移除：重置后触发重启确认，使默认值在服务端全局变量中生效
    [self _scheduleRestartConfirm];
}

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    }

    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];
    if ([key isEqualToString:@"PSButtonCell"]) {
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

        BOOL isDestructive =
            ([specifier propertyForKey:@"isDestructive"] && [[specifier propertyForKey:@"isDestructive"] boolValue]);
        cell.textLabel.textColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        cell.textLabel.highlightedTextColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        return cell;
    }

    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];
    if ([key isEqualToString:@"PSSliderCell"]) {
        // Find any UILabel in the cell's content view recursively
        UILabel *label = [self findLabelInView:cell.contentView];
        if (label) {
            // Do something with the label
            [label sizeToFit];
        }
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [super tableView:tableView titleForFooterInSection:section];
}

#pragma mark - Helper Methods

- (UILabel *)findLabelInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            return (UILabel *)subview;
        }
        UILabel *label = [self findLabelInView:subview];
        if (label) {
            return label;
        }
    }
    return nil;
}


#pragma mark - Gateway Search (internal farm)

- (void)searchGateway {
    if (self.gatewayBrowser) {
        [self.gatewayBrowser stop];
        self.gatewayBrowser = nil;
    }
    self.gatewayServices = [NSMutableArray array];
    self.gatewaySearchShown = NO;
    self.gatewayBrowser = [[NSNetServiceBrowser alloc] init];
    self.gatewayBrowser.delegate = self;
    [self.gatewayBrowser searchForServicesOfType:@"_superphone-farm._tcp" inDomain:@"local."];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索网关"
                                                                  message:@"正在局域网内查找 SuperPhone 网关…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self.gatewayBrowser stop];
        self.gatewayBrowser = nil;
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentFoundGateways];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.gatewayServices addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:3.0];
}

- (void)presentFoundGateways {
    if (!self.gatewayBrowser || self.gatewaySearchShown) return;
    self.gatewaySearchShown = YES;
    [self.gatewayBrowser stop];
    self.gatewayBrowser = nil;

    [self dismissViewControllerAnimated:YES completion:nil];

    NSMutableArray<NSNetService *> *ready = [NSMutableArray array];
    for (NSNetService *svc in self.gatewayServices) {
        if ([self ipAddressOfService:svc]) [ready addObject:svc];
    }

    if (!ready.count) {
        [self showGatewayMessage:@"未找到网关，请检查软路由是否运行 superphone-farm"];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择网关"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNetService *svc in ready) {
        NSString *host = [self ipAddressOfService:svc];
        NSInteger port = svc.port;
        NSString *title = [NSString stringWithFormat:@"%@ (%@:%ld)", svc.name, host, (long)port];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            [self saveGateway:host port:port];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveGateway:(NSString *)host port:(NSInteger)port {
    // 端口固定不可调（18081 = 网关注册端口），忽略搜索到的 port，统一写 18081
    (void)port;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    [defaults setObject:host forKey:@"GatewayHost"];
    [defaults setInteger:18081 forKey:@"GatewayPort"];
    [defaults synchronize];
    [self showGatewayMessage:[NSString stringWithFormat:@"已设置网关 %@:%d", host, 18081]];
    [self reloadSpecifiers];
}

- (NSString *)ipAddressOfService:(NSNetService *)service {
    for (NSData *address in service.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)address.bytes;
        if (sa->sa_family != AF_INET) continue;
        char host[NI_MAXHOST];
        if (getnameinfo(sa, (socklen_t)address.length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            NSString *ip = [NSString stringWithUTF8String:host];
            if (![ip hasPrefix:@"169.254."]) return ip;
        }
    }
    return nil;
}

- (void)showGatewayMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"网关" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
