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

#import "TVNCSettingsViewController.h"
#import "TVNCSettingFormController.h"

@interface TVNCSettingsViewController ()

@property(nonatomic, strong) NSArray<NSDictionary *> *pages;

@end

@implementation TVNCSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.pages = [TVNCSettingsViewController settingsPages];
}

#pragma mark - 数据

// 8 个分组；row spec 见 TVNCSettingFormController.h
+ (NSArray<NSDictionary *> *)settingsPages {
    NSDictionary *gateway = @{
        @"title" : @"网关",
        @"subtitle" : @"自动发现 / 手动配置 · 令牌",
        @"sections" : @[
            @{
                @"title" : @"网关",
                @"rows" : @[
                    @{@"type" : @"text", @"key" : @"GatewayHost", @"label" : @"网关地址", @"placeholder" : @"如 192.168.1.1"},
                    @{@"type" : @"text", @"key" : @"GatewayPort", @"label" : @"网关注册端口", @"default" : @"18081", @"placeholder" : @"18081"},
                    @{@"type" : @"password", @"key" : @"GatewayToken", @"label" : @"网关令牌（可选）", @"placeholder" : @"FARM_TOKEN"},
                    @{@"type" : @"text", @"key" : @"TVNCConsolePort", @"label" : @"控制台端口", @"default" : @"8080", @"placeholder" : @"8080"},
                    @{@"type" : @"button", @"label" : @"搜索网关", @"action" : @"searchGateway"},
                ],
            },
        ],
    };
    NSDictionary *direct = @{
        @"title" : @"直连参数",
        @"subtitle" : @"端口 · 绑定地址 · Bonjour · HTTP",
        @"sections" : @[
            @{
                @"title" : @"直连参数",
                @"rows" : @[
                    @{@"type" : @"switch", @"key" : @"Enabled", @"label" : @"服务开关", @"default" : @YES},
                    @{@"type" : @"text", @"key" : @"DesktopName", @"label" : @"设备名称", @"default" : @"TrollVNC"},
                    @{@"type" : @"text", @"key" : @"Port", @"label" : @"TCP 端口", @"default" : @"5901"},
                    @{@"type" : @"text", @"key" : @"BindHost", @"label" : @"绑定地址", @"placeholder" : @"留空 = 所有接口"},
                    @{@"type" : @"switch", @"key" : @"BonjourEnabled", @"label" : @"Bonjour 自动发现", @"default" : @YES},
                    @{@"type" : @"text", @"key" : @"HttpPort", @"label" : @"HTTP 端口", @"default" : @"0"},
                    @{@"type" : @"text", @"key" : @"HttpDir", @"label" : @"HTTP 文档根目录", @"placeholder" : @"留空 = 内置"},
                ],
            },
        ],
    };
    NSDictionary *security = @{
        @"title" : @"安全",
        @"subtitle" : @"密码 · 只读 · 剪贴板",
        @"sections" : @[
            @{
                @"title" : @"安全",
                @"rows" : @[
                    @{@"type" : @"password", @"key" : @"FullPassword", @"label" : @"完整访问密码", @"placeholder" : @"最多 8 位"},
                    @{@"type" : @"password", @"key" : @"ViewOnlyPassword", @"label" : @"只读密码", @"placeholder" : @"可选"},
                    @{@"type" : @"switch", @"key" : @"ViewOnly", @"label" : @"全局只读", @"default" : @NO},
                    @{@"type" : @"switch", @"key" : @"ClipboardEnabled", @"label" : @"剪贴板同步", @"default" : @YES},
                ],
            },
        ],
    };
    NSDictionary *display = @{
        @"title" : @"画面与性能",
        @"subtitle" : @"缩放 · 帧率 · 方向 · 脏区",
        @"sections" : @[
            @{
                @"title" : @"画面与性能",
                @"rows" : @[
                    @{@"type" : @"slider", @"key" : @"Scale", @"label" : @"输出缩放", @"min" : @0.1, @"max" : @1.0, @"step" : @0.05, @"format" : @"%.2f", @"default" : @1.0},
                    @{@"type" : @"text", @"key" : @"FrameRateSpec", @"label" : @"帧率", @"placeholder" : @"60 或 30-60 或 30:60:120"},
                    @{@"type" : @"switch", @"key" : @"OrientationSync", @"label" : @"方向同步", @"default" : @YES},
                    @{@"type" : @"choice", @"key" : @"OrientationPadFix", @"label" : @"方向偏移", @"default" : @"0", @"options" : @[ @{@"title" : @"0°", @"value" : @"0"}, @{@"title" : @"90°", @"value" : @"1"}, @{@"title" : @"180°", @"value" : @"2"}, @{@"title" : @"270°", @"value" : @"3"} ]},
                    @{@"type" : @"switch", @"key" : @"ServerCursor", @"label" : @"服务端光标", @"default" : @NO},
                ],
            },
            @{
                @"title" : @"进阶（画面）",
                @"rows" : @[
                    @{@"type" : @"slider", @"key" : @"DeferWindowSec", @"label" : @"合并窗口（秒）", @"min" : @0.0, @"max" : @0.5, @"step" : @0.005, @"format" : @"%.3f", @"default" : @0.015},
                    @{@"type" : @"slider", @"key" : @"MaxInflight", @"label" : @"最大在途帧", @"min" : @0, @"max" : @8, @"step" : @1, @"format" : @"%.0f", @"default" : @2},
                    @{@"type" : @"slider", @"key" : @"TileSize", @"label" : @"脏区块大小", @"min" : @8, @"max" : @128, @"step" : @8, @"format" : @"%.0f", @"default" : @32},
                    @{@"type" : @"slider", @"key" : @"FullscreenThresholdPercent", @"label" : @"全屏阈值（%）", @"min" : @0, @"max" : @100, @"step" : @5, @"format" : @"%.0f", @"default" : @0},
                    @{@"type" : @"slider", @"key" : @"MaxRects", @"label" : @"最大矩形数", @"min" : @0, @"max" : @512, @"step" : @16, @"format" : @"%.0f", @"default" : @256},
                    @{@"type" : @"switch", @"key" : @"AsyncSwap", @"label" : @"非阻塞交换", @"default" : @NO},
                ],
            },
        ],
    };
    NSDictionary *input = @{
        @"title" : @"输入",
        @"subtitle" : @"滚轮 · 修饰键 · 辅助触控",
        @"sections" : @[
            @{
                @"title" : @"输入",
                @"rows" : @[
                    @{@"type" : @"switch", @"key" : @"NaturalScroll", @"label" : @"自然滚动方向", @"default" : @YES},
                    @{@"type" : @"choice", @"key" : @"ModifierMap", @"label" : @"修饰键映射", @"default" : @"std", @"options" : @[ @{@"title" : @"标准（Alt=Option）", @"value" : @"std"}, @{@"title" : @"macOS（Alt=Command）", @"value" : @"altcmd"} ]},
                    @{@"type" : @"switch", @"key" : @"AutoAssistEnabled", @"label" : @"辅助触控自动开启", @"default" : @NO},
                    @{@"type" : @"slider", @"key" : @"WheelStepPx", @"label" : @"滚轮步长（px）", @"min" : @0, @"max" : @1000, @"step" : @8, @"format" : @"%.0f", @"default" : @48},
                    @{@"type" : @"text", @"key" : @"WheelTuning", @"label" : @"滚轮微调", @"placeholder" : @"step=48,coalesce=0.03,…"},
                ],
            },
        ],
    };
    NSDictionary *notify = @{
        @"title" : @"通知与保活",
        @"subtitle" : @"连接通知 · 防休眠",
        @"sections" : @[
            @{
                @"title" : @"通知与保活",
                @"rows" : @[
                    @{@"type" : @"slider", @"key" : @"KeepAliveSec", @"label" : @"防休眠（秒）", @"min" : @0, @"max" : @300, @"step" : @15, @"format" : @"%.0f", @"default" : @0},
                    @{@"type" : @"switch", @"key" : @"SingleNotifEnabled", @"label" : @"首连单条通知", @"default" : @YES},
                    @{@"type" : @"switch", @"key" : @"ClientNotifsEnabled", @"label" : @"连接/断开通知", @"default" : @YES},
                ],
            },
        ],
    };
    NSDictionary *advanced = @{
        @"title" : @"高级",
        @"subtitle" : @"SSL 证书 · 键盘日志",
        @"sections" : @[
            @{
                @"title" : @"高级",
                @"rows" : @[
                    @{@"type" : @"text", @"key" : @"SslCertFile", @"label" : @"SSL 证书文件", @"placeholder" : @"/path/to/cert.pem"},
                    @{@"type" : @"text", @"key" : @"SslKeyFile", @"label" : @"SSL 私钥文件", @"placeholder" : @"/path/to/key.pem"},
                    @{@"type" : @"button", @"label" : @"生成 CA 证书…", @"action" : @"generateKeys"},
                    @{@"type" : @"switch", @"key" : @"KeyLogging", @"label" : @"键盘事件日志", @"default" : @NO},
                ],
            },
        ],
    };
    NSDictionary *about = @{
        @"title" : @"关于与诊断",
        @"subtitle" : @"版本 · 日志 · 重置",
        @"sections" : @[
            @{
                @"title" : @"关于与诊断",
                @"rows" : @[
                    @{@"type" : @"info", @"label" : @"版本", @"staticValue" : [TVNCSettingsViewController appVersion]},
                    @{@"type" : @"info", @"label" : @"设备标识", @"staticValue" : [TVNCSettingsViewController deviceIdShort]},
                    @{@"type" : @"button", @"label" : @"查看日志", @"action" : @"viewLogs"},
                    @{@"type" : @"button", @"label" : @"重置默认设置", @"action" : @"resetDefaults"},
                ],
            },
        ],
    };
    return @[ gateway, direct, security, display, input, notify, advanced, about ];
}

+ (NSString *)appVersion {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *v = info[@"CFBundleShortVersionString"];
    NSString *b = info[@"CFBundleVersion"];
    if (v.length && b.length) return [NSString stringWithFormat:@"%@ (%@)", v, b];
    return v.length ? v : (b.length ? b : @"—");
}

+ (NSString *)deviceIdShort {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    NSString *uuid = [d stringForKey:@"DeviceUUID"];
    if (uuid.length >= 8) return [NSString stringWithFormat:@"%@…", [uuid substringToIndex:8]];
    return uuid.length ? uuid : @"未生成";
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.pages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pg"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pg"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *page = self.pages[ip.row];
    cell.textLabel.text = page[@"title"];
    cell.detailTextLabel.text = page[@"subtitle"];
    NSArray<NSString *> *icons = @[ @"network", @"wifi", @"lock.shield", @"display", @"keyboard", @"bell.badge", @"wrench.and.screwdriver", @"info.circle" ];
    if (ip.row < icons.count) {
        cell.imageView.image = [UIImage systemImageNamed:icons[ip.row]];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *page = self.pages[ip.row];
    TVNCSettingFormController *form = [[TVNCSettingFormController alloc] initWithGroups:page[@"sections"]
                                                                                  title:page[@"title"]];
    [self.navigationController pushViewController:form animated:YES];
}

@end
