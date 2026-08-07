/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 ... license ...
*/

#import "TVNCConnectViewController.h"
#import "TVNCServiceCoordinator.h"
#import "Control.h"
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

@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *gatewayLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UISegmentedControl *modeSegment;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIImageView *qrImageView;
@property(nonatomic, strong) UILabel *qrAddrLabel;
@property(nonatomic, strong) UIStackView *statusPill;
@property(nonatomic, strong) UIView *statusDotView;
@property(nonatomic, strong) UILabel *statusPillLabel;
@property(nonatomic, strong) UILabel *clientsCountLabel;
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
    [self setupStatusPill];

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
    [stack addArrangedSubview:[self makeModeCard]];
    [stack addArrangedSubview:[self makeDirectCard]];
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
    [self generateQRAsync];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateStatusPill];
    [self refreshClientCount];
}

#pragma mark - 右上角状态胶囊

- (void)setupStatusPill {
    self.statusDotView = [[UIView alloc] init];
    self.statusDotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDotView.layer.cornerRadius = 4;

    self.statusPillLabel = [[UILabel alloc] init];
    self.statusPillLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusPillLabel.textColor = [UIColor labelColor];

    UIStackView *pill = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDotView, self.statusPillLabel]];
    pill.axis = UILayoutConstraintAxisHorizontal;
    pill.spacing = 6;
    pill.alignment = UIStackViewAlignmentCenter;
    pill.layoutMarginsRelativeArrangement = YES;
    pill.layoutMargins = UIEdgeInsetsMake(6, 12, 6, 12);
    pill.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    pill.layer.cornerRadius = 15;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor separatorColor].CGColor;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPill = pill;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusDotView.widthAnchor constraintEqualToConstant:8],
        [self.statusDotView.heightAnchor constraintEqualToConstant:8],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:pill];
}

- (void)updateStatusPill {
    BOOL running = [[TVNCServiceCoordinator sharedCoordinator] isServiceRunning];
    self.statusDotView.backgroundColor = running ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.statusPillLabel.text = running ? @"已连接" : @"未连接";
}

#pragma mark - Hero

- (UIView *)makeHeroCard {
    TVNCGradientCard *card = [[TVNCGradientCard alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;

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
    self.gatewayLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 7;

    [card addSubview:self.nameLabel];
    [card addSubview:statusRow];
    [card addSubview:self.gatewayLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [self.nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [statusRow.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:14],
        [statusRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.statusDot.widthAnchor constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],
        [self.gatewayLabel.topAnchor constraintEqualToAnchor:statusRow.bottomAnchor constant:8],
        [self.gatewayLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.gatewayLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [self.gatewayLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];
    return card;
}

#pragma mark - 模式分段

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

- (void)modeChanged:(UISegmentedControl *)seg {
    // 反向连接参数摘要暂以弹窗提示（配置在设置页后续补齐）
    if (seg.selectedSegmentIndex == 1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"反向连接"
                                                                  message:@"反向连接参数将在「设置」中提供配置"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        seg.selectedSegmentIndex = 0;
    }
}

#pragma mark - 扫码直连卡

- (UIView *)makeDirectCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"扫码直连"];
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
        [self.qrImageView.widthAnchor constraintEqualToConstant:170],
        [self.qrImageView.heightAnchor constraintEqualToConstant:170],
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
    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    if (httpPort <= 0 || !ip.length) {
        self.qrAddrLabel.text = httpPort <= 0 ? @"HTTP 网页未开启（设置 → 直连参数 → HTTP 端口）" : @"未获取到 IP";
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
    UILabel *title = [self cardTitle:@"在线客户端"];
    [card addSubview:title];

    self.clientsCountLabel = [[UILabel alloc] init];
    self.clientsCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.clientsCountLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clientsCountLabel.textColor = [UIColor secondaryLabelColor];
    self.clientsCountLabel.text = @"0 台";
    [card addSubview:self.clientsCountLabel];

    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    [more setTitle:@"查看全部 ›" forState:UIControlStateNormal];
    more.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [more addTarget:self action:@selector(openClients) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:more];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.clientsCountLabel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.clientsCountLabel.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-8],
        [more.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [more.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [more.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (void)openClients {
    self.tabBarController.selectedIndex = 1;
}

#pragma mark - U3 操作

- (NSString *)directURL {
    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    if (httpPort <= 0 || !ip.length) return nil;
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

- (void)refreshStatus {
    BOOL running = [[TVNCServiceCoordinator sharedCoordinator] isServiceRunning];
    self.statusDot.backgroundColor = running ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.statusLabel.text = running ? @"已连接" : @"未连接";

    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (host.length) {
        self.gatewayLabel.text = [NSString stringWithFormat:@"网关 %@:8080", host];
    } else {
        self.gatewayLabel.text = @"网关未配置（设置 → 网关）";
    }
}

#pragma mark - 在线客户端计数

- (void)refreshClientCount {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger n = [self onlineClientCount];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) strongSelf.clientsCountLabel.text = [NSString stringWithFormat:@"%ld 台", (long)n];
        });
    });
}

- (NSInteger)onlineClientCount {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvDefaultCtlPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return 0; }
    const char *cmd = "list\n";
    if (send(fd, cmd, strlen(cmd), 0) < 0) { close(fd); return 0; }
    NSMutableData *md = [NSMutableData data];
    char buf[2048];
    fd_set rfds;
    for (;;) {
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval timeout = {0, 300000};
        int sel = select(fd + 1, &rfds, NULL, NULL, &timeout);
        if (sel <= 0) break;
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [md appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    NSString *tsv = [[NSString alloc] initWithData:md encoding:NSUTF8StringEncoding] ?: @"";
    NSInteger count = 0;
    for (NSString *ln in [tsv componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([ln componentsSeparatedByString:@"\t"].count >= 5) count++;
    }
    return count;
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
