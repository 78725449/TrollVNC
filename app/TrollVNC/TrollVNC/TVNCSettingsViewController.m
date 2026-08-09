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
@property(nonatomic, strong) TVNCSettingFormController *actionController;

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
                    @{@"type" : @"choice", @"key" : @"PerformanceMode", @"label" : @"性能模式", @"default" : @"balanced",
                      @"options" : @[ @{@"title" : @"均衡", @"value" : @"balanced"},
                                      @{@"title" : @"画质", @"value" : @"quality"},
                                      @{@"title" : @"性能", @"value" : @"performance"},
                                      @{@"title" : @"自定义", @"value" : @"custom"} ]},
                    @{@"type" : @"slider", @"key" : @"TileSize", @"label" : @"脏区块大小", @"min" : @8, @"max" : @128, @"step" : @8, @"format" : @"%.0f", @"default" : @32, @"visibleWhen" : @{@"PerformanceMode" : @"custom"}},
                    @{@"type" : @"slider", @"key" : @"FullscreenThresholdPercent", @"label" : @"全屏阈值（%）", @"min" : @0, @"max" : @100, @"step" : @5, @"format" : @"%.0f", @"default" : @0, @"visibleWhen" : @{@"PerformanceMode" : @"custom"}},
                    @{@"type" : @"slider", @"key" : @"MaxRects", @"label" : @"最大矩形数", @"min" : @0, @"max" : @512, @"step" : @16, @"format" : @"%.0f", @"default" : @256, @"visibleWhen" : @{@"PerformanceMode" : @"custom"}},
                    @{@"type" : @"switch", @"key" : @"AsyncSwap", @"label" : @"非阻塞交换", @"default" : @NO, @"visibleWhen" : @{@"PerformanceMode" : @"custom"}},
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
                    @{@"type" : @"choice", @"key" : @"Notifications", @"label" : @"通知模式", @"default" : @"all",
                      @"options" : @[ @{@"title" : @"全部通知", @"value" : @"all"},
                                      @{@"title" : @"仅连接通知", @"value" : @"connectOnly"},
                                      @{@"title" : @"静默", @"value" : @"silent"} ]},
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
    // 查看日志 / 重置默认设置 直接放在设置一级菜单（见下方 section 1 动作行）
    return @[ gateway, direct, security, display, input, notify, advanced ];
}

+ (NSString *)appVersion {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *v = info[@"CFBundleShortVersionString"];
    NSString *b = info[@"CFBundleVersion"];
    if (v.length && b.length) return [NSString stringWithFormat:@"%@ (%@)", v, b];
    return v.length ? v : (b.length ? b : @"—");
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (section == 0) ? self.pages.count : 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell;
    if (ip.section == 0) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"pg"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pg"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        NSDictionary *page = self.pages[ip.row];
        cell.textLabel.text = page[@"title"];
        cell.detailTextLabel.text = page[@"subtitle"];
        NSArray<NSString *> *icons = @[ @"network", @"wifi", @"lock.shield", @"display", @"keyboard", @"bell.badge", @"wrench.and.screwdriver" ];
        if (ip.row < icons.count) {
            cell.imageView.image = [UIImage systemImageNamed:icons[ip.row]];
            cell.imageView.tintColor = [UIColor systemBlueColor];
        }
        return cell;
    }

    // 一级菜单动作行：查看日志 / 重置默认设置
    cell = [tableView dequeueReusableCellWithIdentifier:@"act"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"act"];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    NSArray<NSString *> *actions = @[ @"查看日志", @"重置默认设置" ];
    cell.textLabel.text = actions[ip.row];
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.imageView.image = [UIImage systemImageNamed:(ip.row == 0) ? @"doc.text" : @"arrow.counterclockwise"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 1) ? @"通用" : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        // 一级动作
        if (!self.actionController) {
            self.actionController = [[TVNCSettingFormController alloc] initWithGroups:@[] title:@""];
        }
        if (ip.row == 0) {
            [self.actionController viewLogs];
        } else {
            [self.actionController resetDefaults];
        }
        return;
    }
    NSDictionary *page = self.pages[ip.row];
    TVNCSettingFormController *form = [[TVNCSettingFormController alloc] initWithGroups:page[@"sections"]
                                                                                  title:page[@"title"]];
    [self.navigationController pushViewController:form animated:YES];
}

@end
