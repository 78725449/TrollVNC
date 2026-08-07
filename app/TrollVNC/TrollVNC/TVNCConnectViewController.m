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

#import "TVNCConnectViewController.h"
#import "TVNCServiceCoordinator.h"

#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <string.h>
#import <UIKit/UIKit.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";

#pragma mark - 工具

// en0 的 IPv4（与 VNC 服务同接口），用于扫码直连地址
static NSString *TVNCEn0IPv4(void) {
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList) return nil;
    NSString *ip = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name) continue;
        if (strcmp(ifa->ifa_name, "en0") != 0) continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        if (ifa->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        char buf[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            ip = [NSString stringWithUTF8String:buf];
            break;
        }
    }
    freeifaddrs(ifaList);
    return ip;
}

// 生成二维码（内容为 http://IP:httpPort）
static UIImage *TVNCQRCodeImage(NSString *content) {
    if (!content.length) return nil;
    NSData *data = [content dataUsingEncoding:NSISOLatin1StringEncoding];
    if (!data) return nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *out = filter.outputImage;
    if (!out) return nil;
    CIImage *scaled = [out imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    return img;
}

@interface TVNCConnectViewController ()

@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *gatewayLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UISegmentedControl *modeSegment;
@property(nonatomic, strong) UIView *contentCard;   // 随分段切换（直连=扫码卡 / 反向=参数卡）
@property(nonatomic, strong) NSUserDefaults *defaults;

@end

@implementation TVNCConnectViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"连接";

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    [stack addArrangedSubview:[self makeHeroCard]];
    [stack addArrangedSubview:[self makeModeCard]];
    [self refreshContentCard:stack];
    [stack addArrangedSubview:[self makeClientsCard]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Hero

- (UIView *)makeHeroCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[(id)[UIColor systemBlueColor].CGColor,
                    (id)[UIColor systemIndigoColor].CGColor,
                    (id)[UIColor systemTealColor].CGColor];
    grad.startPoint = CGPointMake(0, 0);
    grad.endPoint = CGPointMake(1, 1);
    [card.layer insertSublayer:grad atIndex:0];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont boldSystemFontOfSize:20];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.text = [[UIDevice currentDevice] name];

    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 4;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor whiteColor];

    self.gatewayLabel = [[UILabel alloc] init];
    self.gatewayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.gatewayLabel.font = [UIFont systemFontOfSize:13];
    self.gatewayLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 7;

    [card addSubview:self.nameLabel];
    [card addSubview:statusRow];
    [card addSubview:self.gatewayLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:110],
        [self.nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [statusRow.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:12],
        [statusRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.statusDot.widthAnchor constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],
        [self.gatewayLabel.topAnchor constraintEqualToAnchor:statusRow.bottomAnchor constant:8],
        [self.gatewayLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.gatewayLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.gatewayLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

#pragma mark - 模式分段 + 内容卡

- (UIView *)makeModeCard {
    UIView *card = [self newCard];
    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"内网直连", @"反向连接"]];
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSegment.selectedSegmentIndex = 0;
    [self.modeSegment addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:self.modeSegment];
    [NSLayoutConstraint activateConstraints:@[
        [self.modeSegment.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [self.modeSegment.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [self.modeSegment.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [self.modeSegment.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
    return card;
}

// 内容卡随分段切换：直连=扫码卡；反向=参数摘要卡
- (void)refreshContentCard:(UIStackView *)stack {
    if (self.contentCard) {
        [stack removeArrangedSubview:self.contentCard];
        [self.contentCard removeFromSuperview];
        self.contentCard = nil;
    }
    UIView *card = (self.modeSegment.selectedSegmentIndex == 0) ? [self makeDirectCard] : [self makeReverseCard];
    self.contentCard = card;
    [stack insertArrangedSubview:card atIndex:2];
}

- (void)modeChanged:(UISegmentedControl *)seg {
    UIStackView *stack = (UIStackView *)self.contentCard.superview;
    [self refreshContentCard:stack];
}

#pragma mark - 内网直连：扫码卡

- (UIView *)makeDirectCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"扫码直连"];
    [card addSubview:title];

    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    UILabel *addr = [[UILabel alloc] init];
    addr.translatesAutoresizingMaskIntoConstraints = NO;
    addr.font = [UIFont boldSystemFontOfSize:16];
    addr.textAlignment = NSTextAlignmentCenter;

    if (httpPort > 0 && ip.length) {
        NSString *url = [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
        addr.text = url;
        UIImage *qr = TVNCQRCodeImage(url);
        UIImageView *iv = [[UIImageView alloc] initWithImage:qr];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [card addSubview:iv];
        [NSLayoutConstraint activateConstraints:@[
            [iv.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
            [iv.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [iv.widthAnchor constraintEqualToConstant:160],
            [iv.heightAnchor constraintEqualToConstant:160],
            [addr.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:12],
        ]];
    } else {
        addr.text = httpPort <= 0 ? @"HTTP 网页未开启（设置 → 直连参数 → HTTP 端口）" : @"未获取到 IP";
        addr.font = [UIFont systemFontOfSize:14];
        addr.textColor = [UIColor secondaryLabelColor];
        [NSLayoutConstraint activateConstraints:@[
            [addr.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:20],
        ]];
    }

    UIStackView *actions = [[UIStackView alloc] init];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 12;
    actions.distribution = UIStackViewDistributionFillEqually;
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"复制地址" forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 12;
    copyBtn.layer.borderWidth = 1;
    copyBtn.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [copyBtn addTarget:self action:@selector(copyDirectURL) forControlEvents:UIControlEventTouchUpInside];
    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [openBtn setTitle:@"打开网页" forState:UIControlStateNormal];
    openBtn.layer.cornerRadius = 12;
    openBtn.layer.borderWidth = 1;
    openBtn.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [openBtn addTarget:self action:@selector(openDirectURL) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:copyBtn];
    [actions addArrangedSubview:openBtn];
    if (httpPort <= 0 || !ip.length) actions.hidden = YES;

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = @"内网设备扫码即可连接";

    [card addSubview:addr];
    [card addSubview:actions];
    [card addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [addr.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [addr.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [actions.topAnchor constraintEqualToAnchor:addr.bottomAnchor constant:12],
        [actions.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:40],
        [actions.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-40],
        [actions.heightAnchor constraintEqualToConstant:36],
        [hint.topAnchor constraintEqualToAnchor:actions.bottomAnchor constant:10],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

#pragma mark - 反向连接：参数摘要卡

- (UIView *)makeReverseCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"反向连接（需对端监听）"];
    [card addSubview:title];

    NSString *mode = [self.defaults stringForKey:@"ReverseMode"] ?: @"none";
    NSString *sock = [self.defaults stringForKey:@"ReverseSocket"] ?: @"";
    NSString *rid = [self.defaults stringForKey:@"ReverseRepeaterID"] ?: @"";

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"模式", mode],
        @[@"服务器", sock.length ? sock : @"（未设置）"],
        @[@"中继 ID", rid.length ? rid : @"（未设置）"],
    ];
    UIStackView *rowStack = [[UIStackView alloc] init];
    rowStack.translatesAutoresizingMaskIntoConstraints = NO;
    rowStack.axis = UILayoutConstraintAxisVertical;
    rowStack.spacing = 8;
    for (NSArray<NSString *> *row in rows) {
        UILabel *k = [[UILabel alloc] init];
        k.font = [UIFont systemFontOfSize:13];
        k.textColor = [UIColor secondaryLabelColor];
        k.text = row[0];
        UILabel *v = [[UILabel alloc] init];
        v.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        v.text = row[1];
        v.textAlignment = NSTextAlignmentRight;
        UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[k, v]];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 12;
        [rowStack addArrangedSubview:line];
    }
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.text = @"反向参数在「设置」中配置；反向开启会关闭本地直连/HTTP/Bonjour。";

    [card addSubview:rowStack];
    [card addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [rowStack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [rowStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [rowStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [hint.topAnchor constraintEqualToAnchor:rowStack.bottomAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

#pragma mark - 在线客户端卡

- (UIView *)makeClientsCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"在线客户端"];
    [card addSubview:title];

    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    [more setTitle:@"查看全部 ›" forState:UIControlStateNormal];
    more.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [more addTarget:self action:@selector(openClients) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:more];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-8],
        [more.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [more.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [more.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

- (void)openClients {
    self.tabBarController.selectedIndex = 1;
}

#pragma mark - U3 扫码直连操作

- (NSString *)directURL {
    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    if (httpPort <= 0 || !ip.length) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
}

- (void)copyDirectURL {
    NSString *url = [self directURL];
    if (!url) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = url;
    [self toast:[NSString stringWithFormat:@"已复制 %@", url]];
}

- (void)openDirectURL {
    NSString *url = [self directURL];
    if (!url) return;
    NSURL *u = [NSURL URLWithString:url];
    if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
}

- (void)toast:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [a dismissViewControllerAnimated:YES completion:nil];
    });
}

#pragma mark - 状态

- (void)refreshStatus {
    BOOL running = [[TVNCServiceCoordinator sharedCoordinator] isServiceRunning];
    self.statusDot.backgroundColor = running ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.statusLabel.text = running ? @"已连接" : @"未连接";

    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (host.length) {
        // 控制台端口（trollvnc-farm FARM_PORT 默认 8080；便于浏览器直接登录控制台）
        self.gatewayLabel.text = [NSString stringWithFormat:@"网关 %@:8080", host];
    } else {
        self.gatewayLabel.text = @"网关未配置（设置 → 网关）";
    }
}

#pragma mark - 卡片工厂

- (UIView *)newCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 18;
    return card;
}

- (UILabel *)cardTitle:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont boldSystemFontOfSize:15];
    l.text = t;
    return l;
}

@end
