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

#import "TVNCControllerViewController.h"
#import "TVNCViewerViewController.h"

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static const NSInteger kConsolePort = 8080; // trollvnc-farm FARM_PORT 默认

@interface TVNCControllerViewController () <UITableViewDataSource, UITableViewDelegate>

@property(nonatomic, strong) NSMutableArray<UIButton *> *chips;
@property(nonatomic, strong) UIButton *layoutBtn;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *devices; // 全部设备
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *shown;   // 过滤后
@property(nonatomic, assign) NSInteger filterIndex; // 0 全部 / 1 直连 / 2 中继
@property(nonatomic, strong) NSUserDefaults *defaults;

@end

@implementation TVNCControllerViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _devices = [NSMutableArray array];
        _shown = [NSMutableArray array];
        _filterIndex = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"控制端";

    // 顶部过滤：全部 / 直连 / 中继
    UIStackView *filter = [[UIStackView alloc] init];
    filter.translatesAutoresizingMaskIntoConstraints = NO;
    filter.axis = UILayoutConstraintAxisHorizontal;
    filter.spacing = 8;
    filter.distribution = UIStackViewDistributionFill;
    self.chips = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"全部", @"直连", @"中继"];
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.title = titles[i];
        cfg.baseForegroundColor = [UIColor labelColor];
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 8, 16);
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
        bg.strokeColor = [UIColor separatorColor];
        bg.strokeWidth = 1;
        cfg.background = bg;
        b.configuration = cfg;
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        b.tag = i;
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chips addObject:b];
        [filter addArrangedSubview:b];
    }
    [self updateChipAppearance];

    self.layoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.layoutBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.layoutBtn setImage:[UIImage systemImageNamed:@"square.grid.2x2"] forState:UIControlStateNormal];
    self.layoutBtn.tintColor = [UIColor labelColor];
    self.layoutBtn.layer.cornerRadius = 18;
    self.layoutBtn.layer.borderWidth = 1;
    self.layoutBtn.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.layoutBtn addTarget:self action:@selector(layoutTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 8;
    [topRow addArrangedSubview:filter];
    [topRow addArrangedSubview:self.layoutBtn];
    [self.view addSubview:topRow];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"暂无设备\n点右上角刷新，从网关拉取设备目录";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [topRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [topRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.layoutBtn.widthAnchor constraintEqualToConstant:36],
        [self.layoutBtn.heightAnchor constraintEqualToConstant:36],
        [self.tableView.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(refreshDevices)];
    [self refreshDevices];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDevices];
}

#pragma mark - 设备目录（网关 /api/devices）

- (void)refreshDevices {
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length) {
        self.emptyLabel.text = @"未配置网关\n请先在 设置 → 网关 填写网关地址";
        [self applyFilter];
        return;
    }
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices", host, (long)consolePort];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *list = nil;
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) list = json[@"devices"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleDevices:list error:err];
        });
    }];
    [task resume];
}

- (void)handleDevices:(NSArray *)list error:(NSError *)err {
    if (![list isKindOfClass:[NSArray class]]) {
        self.emptyLabel.text = err ? [NSString stringWithFormat:@"拉取设备目录失败\n%@", err.localizedDescription]
                                   : @"网关返回异常\n请检查网关是否运行";
    } else {
        [self.devices removeAllObjects];
        for (NSDictionary *d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            if ([d[@"source"] isEqualToString:@"register"] || d[@"host"]) {
                [self.devices addObject:d];
            }
        }
        if (!self.devices.count) {
            self.emptyLabel.text = @"暂无设备\n（仅显示已注册到网关的设备）";
        }
    }
    [self applyFilter];
}

- (void)applyFilter {
    [self.shown removeAllObjects];
    for (NSDictionary *d in self.devices) {
        if (self.filterIndex == 1 && ![d[@"online"] boolValue]) continue; // 直连=在线
        if (self.filterIndex == 2) continue;                              // 中继=远期
        [self.shown addObject:d];
    }
    BOOL hasAny = self.devices.count > 0;
    BOOL hasShown = self.shown.count > 0;
    self.tableView.hidden = !hasShown;
    self.emptyLabel.hidden = hasShown || !hasAny;
    if (!hasShown && hasAny) {
        self.emptyLabel.text = @"当前过滤条件下无设备";
        self.emptyLabel.hidden = NO;
    }
    [self.tableView reloadData];
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dev"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dev"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *d = self.shown[ip.row];
    BOOL online = [d[@"online"] boolValue];
    cell.textLabel.text = d[@"name"] ?: d[@"id"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@:%@%@", d[@"host"] ?: @"?", d[@"port"] ?: @"5901", online ? @"" : @" · 离线"];
    cell.imageView.image = [UIImage systemImageNamed:online ? @"circle.fill" : @"circle"];
    cell.imageView.tintColor = online ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = self.shown[ip.row];
    NSString *host = d[@"host"];
    if (!host.length) return;
    int port = (int)([d[@"port"] integerValue] ?: 5901);
    TVNCViewerViewController *viewer = [[TVNCViewerViewController alloc] initWithHost:host port:port name:d[@"name"] ?: host];
    [self.navigationController pushViewController:viewer animated:YES];
}

#pragma mark - 过滤

- (void)chipTapped:(UIButton *)sender {
    self.filterIndex = sender.tag;
    for (UIButton *b in self.chips) {
        b.selected = (b == sender);
    }
    [self updateChipAppearance];
    [self applyFilter];
}

- (void)updateChipAppearance {
    for (UIButton *b in self.chips) {
        UIButtonConfiguration *cfg = [b.configuration copy];
        if (b.selected) {
            cfg.baseBackgroundColor = [UIColor systemBlueColor];
            cfg.baseForegroundColor = [UIColor whiteColor];
            cfg.background.strokeColor = [UIColor systemBlueColor];
        } else {
            cfg.baseBackgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            cfg.baseForegroundColor = [UIColor labelColor];
            cfg.background.strokeColor = [UIColor separatorColor];
        }
        b.configuration = cfg;
    }
}

#pragma mark - 布局（v1 提示）

- (void)layoutTapped:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"布局"
                                                                  message:@"布局（横屏 N / 竖屏 N）将在后续版本生效"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
