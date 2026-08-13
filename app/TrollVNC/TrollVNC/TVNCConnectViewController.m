/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 ... license ...
*/

#import "TVNCConnectViewController.h"
#import "TVNCServiceCoordinator.h"
#import "TVNCAppStore.h"
#import "Control.h"
#import "TVNCUtil.h"
#import "TVNCClientListController.h"
#import <sys/socket.h>

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

// 二维码生成（安全版：@try 保护 + 由调用方在后台线程执行）
static UIImage *TVNCQRCodeImage(NSString *content) {
    if (!content.length) return nil;
    @try {
        NSData *data = [content dataUsingEncoding:NSISOLatin1StringEncoding];
        if (!data) return nil;
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
        CIImage *out = filter.outputImage;
        if (!out) return nil;
        CIImage *scaled = [out imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
        CIContext *ctx = [CIContext contextWithOptions:@{}];
        CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
        UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
        if (cg) CGImageRelease(cg);
        return img;
    } @catch (NSException *e) {
        NSLog(@"[TVNC] QR generation failed: %@ %@", e.name, e.reason);
        return nil;
    }
}

#pragma mark - 渐变 Hero 卡（layoutSubviews 更新渐变 frame，确保可见）

@interface TVNCGradientCard : UIView
@property(nonatomic, strong) CAGradientLayer *grad;
@end

@implementation TVNCGradientCard
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _grad = [CAGradientLayer layer];
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.16 green:0.35 blue:0.98 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.24 green:0.52 blue:1.0 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.42 green:0.72 blue:1.0 alpha:1].CGColor,
        ];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_grad];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.grad.frame = self.bounds;
}
@end

#pragma mark - 连接页

@interface TVNCConnectViewController ()

// Hero 卡片（3 行直观信息）
@property(nonatomic, strong) UILabel *nameLabel;             // 第 1 行：设备名
@property(nonatomic, strong) UIView *heroStatusDot;          // 第 1 行右侧：状态点
@property(nonatomic, strong) UILabel *heroStatusLabel;        // 第 1 行右侧：状态文字（已连接/未连接）
@property(nonatomic, strong) UILabel *connectStateLabel;     // 第 2 行：连接状态文字
@property(nonatomic, strong) UILabel *serviceStateLabel;     // 第 3 行：服务状态文字

@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIImageView *qrImageView;
@property(nonatomic, strong) UILabel *qrAddrLabel;
@property(nonatomic, strong) UILabel *clientsCountLabel;     // 客户端卡：在线/冻结计数
@property(nonatomic, strong) TVNCClientListController *clientsVC;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, assign) NSInteger currentOnlineCount;   // 缓存在线客户端数（供 Hero 第 3 行使用）

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
    stack.spacing = 14;
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

    self.contentCard = [[UIView alloc] init];
    self.contentCard.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.contentCard];

    [stack addArrangedSubview:[self makeClientsCard]];
    [self refreshContentCard];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];
    // 网关状态/设备目录事件驱动刷新（真注册判定替代服务存活近似）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:TVNCGatewayStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:TVNCDeviceDirectoryDidUpdateNotification
                                               object:nil];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
    // 懒加载：确保设备目录就绪（缓存新鲜直接复用；否则结果驱动拉取并判定注册状态）
    [[TVNCAppStore sharedStore] ensureDeviceDirectory];
    [self generateQRAsync];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

#pragma mark - Hero

/**
 * 构建 Hero 卡片（3 行直观信息）。
 * 功能：创建渐变卡片，包含三行：
 *   - 第 1 行：设备名（左）+ 状态点+文字（右，🟢已连接/🔴未连接）
 *   - 第 2 行：连接状态文字（已注册到网关，隧道已建立 / 未注册到网关）
 *   - 第 3 行：服务状态文字（VNC 服务运行中·N 个客户端在线 / VNC 服务未运行·请前往设置配置网关）
 * 参数：无
 * 返回值：UIView* - Hero 卡片根视图（TVNCGradientCard 实例）
 */
- (UIView *)makeHeroCard {
    TVNCGradientCard *card = [[TVNCGradientCard alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;

    // 第 1 行：设备名（左）+ 状态点+文字（右）
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont boldSystemFontOfSize:21];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.text = [[UIDevice currentDevice] name];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.6;

    self.heroStatusDot = [[UIView alloc] init];
    self.heroStatusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroStatusDot.layer.cornerRadius = 4;
    self.heroStatusDot.backgroundColor = [UIColor systemGreenColor];

    self.heroStatusLabel = [[UILabel alloc] init];
    self.heroStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroStatusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.heroStatusLabel.textColor = [UIColor whiteColor];
    self.heroStatusLabel.text = @"已连接";

    UIStackView *statusStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.heroStatusDot, self.heroStatusLabel]];
    statusStack.translatesAutoresizingMaskIntoConstraints = NO;
    statusStack.axis = UILayoutConstraintAxisHorizontal;
    statusStack.alignment = UIStackViewAlignmentCenter;
    statusStack.spacing = 6;

    // 第 2 行：连接状态文字
    self.connectStateLabel = [[UILabel alloc] init];
    self.connectStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectStateLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.connectStateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.94];
    self.connectStateLabel.numberOfLines = 1;
    self.connectStateLabel.adjustsFontSizeToFitWidth = YES;
    self.connectStateLabel.minimumScaleFactor = 0.6;

    // 第 3 行：服务状态文字
    self.serviceStateLabel = [[UILabel alloc] init];
    self.serviceStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.serviceStateLabel.font = [UIFont systemFontOfSize:13];
    self.serviceStateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    self.serviceStateLabel.numberOfLines = 1;
    self.serviceStateLabel.adjustsFontSizeToFitWidth = YES;
    self.serviceStateLabel.minimumScaleFactor = 0.5;

    [card addSubview:self.nameLabel];
    [card addSubview:statusStack];
    [card addSubview:self.connectStateLabel];
    [card addSubview:self.serviceStateLabel];

    [NSLayoutConstraint activateConstraints:@[
        // 第 1 行：设备名顶部 + 左对齐，状态栈右对齐，居中对齐
        [self.nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:statusStack.leadingAnchor constant:-8],

        [statusStack.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],
        [statusStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],

        [self.heroStatusDot.widthAnchor constraintEqualToConstant:8],
        [self.heroStatusDot.heightAnchor constraintEqualToConstant:8],

        // 第 2 行：连接状态文字
        [self.connectStateLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:10],
        [self.connectStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [self.connectStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],

        // 第 3 行：服务状态文字
        [self.serviceStateLabel.topAnchor constraintEqualToAnchor:self.connectStateLabel.bottomAnchor constant:6],
        [self.serviceStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [self.serviceStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [self.serviceStateLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22],
    ]];
    return card;
}

#pragma mark - 内容卡切换

- (void)refreshContentCard {
    if (!self.contentCard) return;
    for (UIView *v in [self.contentCard.subviews copy]) {
        [v removeFromSuperview];
    }
    UIView *card = [self makeDirectCard];
    [self.contentCard addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor],
    ]];
}

- (UILabel *)fieldLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = t;
    return l;
}

- (UITextField *)fieldInput {
    UITextField *f = [[UITextField alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:15];
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return f;
}

#pragma mark - 扫描直连卡

- (UIView *)makeDirectCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"扫描直连"];
    [card addSubview:title];

    self.qrImageView = [[UIImageView alloc] init];
    self.qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrImageView.backgroundColor = [UIColor whiteColor];
    self.qrImageView.layer.cornerRadius = 8;
    self.qrImageView.layer.masksToBounds = YES;

    self.qrAddrLabel = [[UILabel alloc] init];
    self.qrAddrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrAddrLabel.font = [UIFont boldSystemFontOfSize:16];
    self.qrAddrLabel.textColor = [UIColor labelColor];
    self.qrAddrLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = @"内网设备扫码即可连接";

    [card addSubview:self.qrImageView];
    [card addSubview:self.qrAddrLabel];
    [card addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.qrImageView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [self.qrImageView.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [self.qrImageView.widthAnchor constraintEqualToConstant:110],
        [self.qrImageView.heightAnchor constraintEqualToConstant:110],
        [self.qrAddrLabel.topAnchor constraintEqualToAnchor:self.qrImageView.bottomAnchor constant:12],
        [self.qrAddrLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.qrAddrLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [hint.topAnchor constraintEqualToAnchor:self.qrAddrLabel.bottomAnchor constant:6],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    return card;
}

- (void)generateQRAsync {
    NSInteger httpPort = 5801; // 端口固定不可调（5801 = 前端入口）
    NSString *ip = TVNCEn0IPv4();
    if (!ip.length) {
        self.qrAddrLabel.text = @"未获取到 IP";
        self.qrImageView.hidden = YES;
        return;
    }
    NSString *url = [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
    self.qrAddrLabel.text = url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *qr = TVNCQRCodeImage(url);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (qr) {
                self.qrImageView.image = qr;
                self.qrImageView.hidden = NO;
            } else {
                self.qrImageView.hidden = YES;
            }
        });
    });
}

#pragma mark - 客户端入口卡

- (UIView *)makeClientsCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"客户端"];
    [card addSubview:title];

    self.clientsCountLabel = [[UILabel alloc] init];
    self.clientsCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.clientsCountLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clientsCountLabel.textColor = [UIColor secondaryLabelColor];
    self.clientsCountLabel.text = @"在线 0 · 冻结 0";
    [card addSubview:self.clientsCountLabel];

    UIButton *disconnectAll = [UIButton buttonWithType:UIButtonTypeSystem];
    disconnectAll.translatesAutoresizingMaskIntoConstraints = NO;
    [disconnectAll setTitle:@"全部断开" forState:UIControlStateNormal];
    disconnectAll.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [disconnectAll setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [disconnectAll addTarget:self action:@selector(disconnectAllClients) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:disconnectAll];

    // 内嵌客户端列表（子控制器，卡片内直接显示与管理）
    UIView *tableContainer = [[UIView alloc] init];
    tableContainer.translatesAutoresizingMaskIntoConstraints = NO;
    tableContainer.layer.cornerRadius = 12;
    tableContainer.clipsToBounds = YES;
    [card addSubview:tableContainer];

    TVNCClientListController *clientsVC = [[TVNCClientListController alloc] init];
    NSBundle *resBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                   ofType:@"bundle"]];
    clientsVC.bundle = resBundle ?: [NSBundle mainBundle];
    clientsVC.primaryColor = [UIColor systemBlueColor];
    clientsVC.embedded = YES;
    __weak typeof(self) weakSelf = self;
    clientsVC.onCountChange = ^(NSInteger online, NSInteger frozen) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            // 缓存在线数并刷新客户端卡计数 + Hero 第 3 行服务状态文字
            strongSelf.currentOnlineCount = online;
            strongSelf.clientsCountLabel.text =
                [NSString stringWithFormat:@"在线 %ld · 冻结 %ld", (long)online, (long)frozen];
            [strongSelf updateHeroServiceState];
        }
    };
    [self addChildViewController:clientsVC];
    clientsVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [tableContainer addSubview:clientsVC.view];
    [clientsVC didMoveToParentViewController:self];
    self.clientsVC = clientsVC;

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.clientsCountLabel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.clientsCountLabel.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:disconnectAll.leadingAnchor constant:-8],
        [disconnectAll.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [disconnectAll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [tableContainer.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [tableContainer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [tableContainer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [tableContainer.heightAnchor constraintEqualToConstant:260],
        [tableContainer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],

        [clientsVC.view.topAnchor constraintEqualToAnchor:tableContainer.topAnchor],
        [clientsVC.view.leadingAnchor constraintEqualToAnchor:tableContainer.leadingAnchor],
        [clientsVC.view.trailingAnchor constraintEqualToAnchor:tableContainer.trailingAnchor],
        [clientsVC.view.bottomAnchor constraintEqualToAnchor:tableContainer.bottomAnchor],
    ]];
    return card;
}

- (void)disconnectAllClients {
    [self.clientsVC disconnectAllClients];
}

#pragma mark - U3 操作

- (NSString *)directURL {
    NSInteger httpPort = 5801; // 端口固定不可调（5801 = 前端入口）
    NSString *ip = TVNCEn0IPv4();
    if (!ip.length) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
}

- (void)copyDirectURL {
    NSString *url = [self directURL];
    if (!url) return;
    [UIPasteboard generalPasteboard].string = url;
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

/**
 * 刷新 Hero 卡片状态显示（3 行整体刷新）。
 * 功能：依据 TVNCAppStore 网关状态机（真注册判定）更新 Hero 卡片：
 *   - 第 1 行状态点颜色 + 状态文字：Registered→绿「已连接」/ ServiceUp→黄「连接中」/
 *     Disconnected→红「未连接」/ Idle→灰「未连接」
 *   - 第 2 行连接状态文字（已注册到网关，隧道已建立 / 正在连接网关… / 网关不可达 / 未注册到网关）
 *   - 第 3 行服务状态文字（VNC 服务运行中·N 个客户端在线 / VNC 服务未运行）
 * 参数：无
 * 返回值：void
 */
- (void)refreshStatus {
    TVNCGatewayState st = [TVNCAppStore sharedStore].gatewayState;

    // 第 1 行右侧：状态点（绿=已注册 / 黄=连接中 / 红=不可达 / 灰=未连接）+ 状态文字
    switch (st) {
        case TVNCGatewayStateRegistered:
            self.heroStatusDot.backgroundColor = [UIColor systemGreenColor];
            self.heroStatusLabel.text = @"已连接";
            break;
        case TVNCGatewayStateServiceUp:
            self.heroStatusDot.backgroundColor = [UIColor systemYellowColor];
            self.heroStatusLabel.text = @"连接中";
            break;
        case TVNCGatewayStateDisconnected:
            self.heroStatusDot.backgroundColor = [UIColor systemRedColor];
            self.heroStatusLabel.text = @"未连接";
            break;
        default: // Idle
            self.heroStatusDot.backgroundColor = [UIColor systemGrayColor];
            self.heroStatusLabel.text = @"未连接";
            break;
    }

    // 第 2 行：连接状态文字（真实注册判定，替代服务存活近似）
    switch (st) {
        case TVNCGatewayStateRegistered:
            self.connectStateLabel.text = @"已注册到网关，隧道已建立";
            break;
        case TVNCGatewayStateServiceUp:
            self.connectStateLabel.text = @"正在连接网关…";
            break;
        case TVNCGatewayStateDisconnected:
            self.connectStateLabel.text = @"网关不可达，请检查网关配置";
            break;
        default:
            self.connectStateLabel.text = @"未注册到网关";
            break;
    }

    // 第 3 行：服务状态文字
    [self updateHeroServiceState];
}

/**
 * 仅刷新 Hero 第 3 行服务状态文字。
 * 功能：按 isServiceRunning + currentOnlineCount 更新 serviceStateLabel 文案。
 *       当客户端计数变化时（onCountChange 回调）调用此方法可避免完整 refreshStatus 的重复状态读取。
 * 参数：无
 * 返回值：void
 */
- (void)updateHeroServiceState {
    BOOL connected = [[TVNCServiceCoordinator sharedCoordinator] isServiceRunning];
    if (connected) {
        self.serviceStateLabel.text =
            [NSString stringWithFormat:@"VNC 服务运行中 · %ld 个客户端在线", (long)self.currentOnlineCount];
    } else {
        self.serviceStateLabel.text = @"VNC 服务未运行 · 请前往设置配置网关";
    }
}

#pragma mark - 卡片工厂

- (UIView *)newCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    return card;
}

- (UILabel *)cardTitle:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont boldSystemFontOfSize:15];
    l.text = t;
    l.textColor = [UIColor labelColor];
    return l;
}

@end
