/*
 This file is part of TrollVNC
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

#import "TVNCSettingFormController.h"
#import "StripedTextTableViewController.h"
#import "TVNCUtil.h"
#import "ZTSelfSignedCertificate.h"

#import <Network/Network.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <notify.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static NSString *const kDeviceUUIDKey = @"DeviceUUID";

#pragma mark - 预置读取（未设置时回退 spec 默认）

static BOOL TVNCFormBoolPref(NSUserDefaults *d, NSString *key, BOOL def) {
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
static NSInteger TVNCFormIntPref(NSUserDefaults *d, NSString *key, NSInteger def) {
    id v = [d objectForKey:key];
    return v ? [v integerValue] : def;
}
static double TVNCFormDoublePref(NSUserDefaults *d, NSString *key, double def) {
    id v = [d objectForKey:key];
    return v ? [v doubleValue] : def;
}
static NSString *TVNCFormStrPref(NSUserDefaults *d, NSString *key, NSString *def) {
    id v = [d objectForKey:key];
    if (!v) return def;
    NSString *s = [v description];
    return s.length ? s : def;
}

#pragma mark - jailbreak root（与设置页一致，用于日志/证书路径）

static NSString *TVNCFormJbrootPath(void) {
    NSString *rootPath = [[NSBundle mainBundle] bundlePath];
    do {
        if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
            [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
            break;
        }
        if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
            break;
        }
        if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
            break;
        }
        rootPath = [rootPath stringByDeletingLastPathComponent];
    } while (YES);
    return rootPath;
}

@interface TVNCSettingFormController () <UITextFieldDelegate, NSNetServiceBrowserDelegate>

@property(nonatomic, strong) NSArray<NSDictionary *> *groups;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) NSBundle *bundle;

// 网关搜索
@property(nonatomic, strong) NSNetServiceBrowser *gatewayBrowser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *gatewayServices;
@property(nonatomic, assign) BOOL gatewaySearchShown;

@end

@implementation TVNCSettingFormController

- (instancetype)initWithGroups:(NSArray<NSDictionary *> *)groups title:(NSString *)title {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _groups = groups;
        self.title = title;
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
        if (!_bundle) _bundle = [NSBundle mainBundle];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)dealloc {
    [self.gatewayBrowser stop];
    self.gatewayBrowser = nil;
}

#pragma mark - 保存并通知

- (void)saveValue:(id)value forKey:(NSString *)key {
    if (!key.length) return;
    if (value) {
        [self.defaults setObject:value forKey:key];
    } else {
        [self.defaults removeObjectForKey:key];
    }
    [self.defaults synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.groups.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.groups[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.groups[section][@"title"];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)ip {
    return self.groups[ip.section][@"rows"][ip.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = [self rowAtIndexPath:ip];
    NSString *type = row[@"type"] ?: @"info";
    NSString *label = row[@"label"] ?: @"";
    NSString *cellId = [NSString stringWithFormat:@"cell-%@", type ?: @"info"];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    }
    cell.textLabel.text = label;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = TVNCFormBoolPref(self.defaults, row[@"key"], [row[@"default"] boolValue]);
        sw.tag = ip.section * 10000 + ip.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"password"]) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 34)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.font = [UIFont systemFontOfSize:15];
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.secureTextEntry = [type isEqualToString:@"password"];
        tf.placeholder = row[@"placeholder"];
        tf.text = TVNCFormStrPref(self.defaults, row[@"key"], [row[@"default"] description]);
        tf.delegate = self;
        tf.tag = ip.section * 10000 + ip.row;
        cell.accessoryView = tf;
    } else if ([type isEqualToString:@"slider"]) {
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 34)];
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 132, 34)];
        sl.minimumValue = [row[@"min"] doubleValue];
        sl.maximumValue = [row[@"max"] doubleValue];
        double cur = TVNCFormDoublePref(self.defaults, row[@"key"], [row[@"default"] doubleValue]);
        sl.value = cur;
        [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(138, 0, 42, 34)];
        val.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        val.textAlignment = NSTextAlignmentRight;
        val.textColor = [UIColor secondaryLabelColor];
        val.text = [NSString stringWithFormat:(row[@"format"] ?: @"%.2f"), cur];
        val.tag = 99;
        [holder addSubview:sl];
        [holder addSubview:val];
        sl.tag = ip.section * 10000 + ip.row;
        cell.accessoryView = holder;
    } else if ([type isEqualToString:@"choice"]) {
        NSArray *opts = row[@"options"];
        NSString *cur = TVNCFormStrPref(self.defaults, row[@"key"], row[@"default"]);
        NSString *curTitle = cur;
        for (NSDictionary *o in opts) {
            if ([[o[@"value"] description] isEqualToString:cur]) curTitle = o[@"title"];
        }
        cell.detailTextLabel.text = curTitle;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if ([type isEqualToString:@"button"]) {
        cell.textLabel.text = label;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else { // info
        cell.detailTextLabel.text = row[@"staticValue"];
    }
    return cell;
}

#pragma mark - 值变更

- (void)switchChanged:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:sw.tag inSection:0];
    // 找到所属 section：tag 只存 row，跨 section 会错位；改为用 tag 编码 section*1000+row
    ip = [self indexPathForTag:sw.tag];
    NSDictionary *row = [self rowAtIndexPath:ip];
    [self saveValue:@(sw.on) forKey:row[@"key"]];
}

- (void)sliderChanged:(UISlider *)sl {
    NSIndexPath *ip = [self indexPathForTag:sl.tag];
    NSDictionary *row = [self rowAtIndexPath:ip];
    [self saveValue:@(sl.value) forKey:row[@"key"]];
    UIView *holder = sl.superview;
    UILabel *val = (UILabel *)[holder viewWithTag:99];
    val.text = [NSString stringWithFormat:(row[@"format"] ?: @"%.2f"), sl.value];
}

// tag 编码：section * 10000 + row
- (NSIndexPath *)indexPathForTag:(NSInteger)tag {
    NSInteger section = tag / 10000;
    NSInteger row = tag % 10000;
    return [NSIndexPath indexPathForRow:row inSection:section];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSIndexPath *ip = [self indexPathForTag:tf.tag];
    NSDictionary *row = [self rowAtIndexPath:ip];
    [self saveValue:tf.text forKey:row[@"key"]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

#pragma mark - 行点击（choice / button）

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row = [self rowAtIndexPath:ip];
    NSString *type = row[@"type"];
    if ([type isEqualToString:@"choice"]) {
        [self showChoice:row];
    } else if ([type isEqualToString:@"button"]) {
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"searchGateway"]) {
            [self searchGateway];
        } else if ([action isEqualToString:@"viewLogs"]) {
            [self viewLogs];
        } else if ([action isEqualToString:@"resetDefaults"]) {
            [self resetDefaults];
        } else if ([action isEqualToString:@"generateKeys"]) {
            [self generateKeys];
        }
    }
}

- (void)showChoice:(NSDictionary *)row {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row[@"label"]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *opts = row[@"options"];
    NSString *cur = TVNCFormStrPref(self.defaults, row[@"key"], row[@"default"]);
    for (NSDictionary *o in opts) {
        NSString *value = [o[@"value"] description];
        NSString *title = o[@"title"];
        if ([value isEqualToString:cur]) {
            title = [title stringByAppendingString:@" ✓"];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self saveValue:value forKey:row[@"key"]];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 搜索网关（_trollvnc-farm._tcp）

- (void)searchGateway {
    [self.gatewayBrowser stop];
    self.gatewayBrowser = nil;
    self.gatewayServices = [NSMutableArray array];
    self.gatewaySearchShown = NO;
    self.gatewayBrowser = [[NSNetServiceBrowser alloc] init];
    self.gatewayBrowser.delegate = self;
    [self.gatewayBrowser searchForServicesOfType:@"_trollvnc-farm._tcp" inDomain:@"local."];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索网关"
                                                                  message:@"正在局域网内查找 TrollVNC 网关…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf.gatewayBrowser stop];
        weakSelf.gatewayBrowser = nil;
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf presentFoundGateways];
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

    NSMutableArray<NSString *> *ready = [NSMutableArray array];
    for (NSNetService *svc in self.gatewayServices) {
        NSString *host = [self ipAddressOfService:svc];
        if (host) [ready addObject:host];
    }
    if (!ready.count) {
        [self showMessage:@"未找到网关，请检查软路由是否运行 trollvnc-farm"];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择网关"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNetService *svc in self.gatewayServices) {
        NSString *host = [self ipAddressOfService:svc];
        if (!host) continue;
        NSString *title = [NSString stringWithFormat:@"%@ (%@:%ld)", svc.name, host, (long)svc.port];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf saveGateway:host port:svc.port];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
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

- (void)saveGateway:(NSString *)host port:(NSInteger)port {
    [self saveValue:host forKey:@"GatewayHost"];
    [self saveValue:@(port) forKey:@"GatewayPort"];
    [self showMessage:[NSString stringWithFormat:@"已设置网关 %@:%ld", host, (long)port]];
    [self.tableView reloadData];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"网关"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 查看日志

- (void)viewLogs {
    NSString *logsPath;
#if TARGET_IPHONE_SIMULATOR
    logsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#else
    logsPath = [[TVNCFormJbrootPath() stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"trollvnc-stderr.log"];
#endif
    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = [UIColor systemBlueColor];
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
    [logsVC setTitle:@"查看日志"];
    [logsVC setLocalizationBundle:self.bundle];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 重置默认设置

- (void)resetDefaults {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置默认设置"
                                                                  message:@"确定要恢复所有设置为默认值吗？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
                                                [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kDefaultsSuite];
                                                [[NSUserDefaults standardUserDefaults] synchronize];
                                                [weakSelf.tableView reloadData];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 生成 CA 证书

- (void)generateKeys {
    NSString *cakeyPath = [self cakeyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cakeyPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"覆盖已有密钥"
                                                                      message:@"已存在 CA 私钥，生成新密钥将覆盖旧密钥，是否继续？"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self reallyGenerateKeys];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self reallyGenerateKeys];
}

- (void)reallyGenerateKeys {
    NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
    NSString *commonName = [NSString stringWithFormat:@"TrollVNC %@", randomUUID];
    ZTSelfSignedCertificate *ca = [ZTSelfSignedCertificate generateWithCommonName:commonName];
    if (!ca) {
        [self showMessage:@"生成自签名 CA 证书失败"];
        return;
    }
    NSError *error = nil;
    BOOL ok = [ca.certificatePEM writeToFile:[self cacertPath] atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (ok) {
        ok = [ca.privateKeyPEM writeToFile:[self cakeyPath] atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }
    if (!ok) {
        [self showMessage:[NSString stringWithFormat:@"写入证书失败：%@", error.localizedDescription]];
        return;
    }
    [self showMessage:@"已生成 CA 证书与私钥（可在「高级 → SSL」中使用）"];
}

- (NSString *)cacertPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#else
    return [[TVNCFormJbrootPath() stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]
        stringByAppendingPathComponent:@"com.82flex.trollvnc.ca-cert.pem"];
#endif
}

- (NSString *)cakeyPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#else
    return [[TVNCFormJbrootPath() stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]
        stringByAppendingPathComponent:@"com.82flex.trollvnc.ca-key.pem"];
#endif
}

@end
