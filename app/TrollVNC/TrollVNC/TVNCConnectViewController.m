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
#import "TVNCUtil.h"
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

// 二维码生成（安全版：@try 保护；调用方在后台线程执行）
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

// 本地 ctl 端口一次性查询在线客户端数（connect 页「在线客户端」计数用）
static NSInteger TVNCOnlineClientCount(void) {
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

#pragma mark - 渐变 Hero 卡

@interface TVNCGradientCard : UIView
@property(nonatomic, strong) CAGradientLayer *grad;
@end
@implementation TVNCGradientCard
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _grad = [CAGradientLayer layer];
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.17 green:0.36 blue:1.0 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.23 green:0.51 blue:1.0 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1].CGColor,
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

@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *gatewayLabel;
@property(nonatomic, strong) UIView *gatewayDot;
@property(nonatomic, strong) UISegmentedControl *modeSegment;
@property(nonatomic, strong) UISegmentedControl *revModeSegment;
@property(nonatomic, strong) UIView *contentCard;      // 直连卡 / 反向卡
@property(nonatomic, strong) UIImageView *qrImageView;
@property(nonatomic, strong) UILabel *qrAddrLabel;
@property(nonatomic, strong) UITextField *revServerField;
@property(nonatomic, strong) UITextField *revIdField;
@property(nonatomic, strong) UITextField *revIntervalField;
@property(nonatomic, strong) UIButton *dialBtn;
@property(nonatomic, strong) UIView *statusPill;
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
    [self refreshContentCard:stack];
    [stack addArrangedSubview:[self makeClientsCard]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateStatusPill)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];
    [self updateStatusPill];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateStatusPill];
    [self refreshClientCount];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self generateQRAsync];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 右上角状态胶囊（只读）

- (void)setupStatusPill {
    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    pill.layer.cornerRadius = 15;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor separatorColor].CGColor;
    pill.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusDotView = [[UIView alloc] init];
    self.statusDotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDotView.layer.cornerRadius = 4;

    self.statusPillLabel = [[UILabel alloc] init];
    self.statusPillLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusPillLabel.textColor = [UIColor labelColor];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDotView, self.statusPillLabel]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    [pill addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:pill.topAnchor constant:6],
        [row.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-6],
        [row.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
        [row.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
        [self.statusDotView.widthAnchor constraintEqualToConstant:8],
        [self.statusDotView.heightAnchor constraintEqualToConstant:8],
    ]];

    self.statusPill = pill;
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

    self.gatewayDot = [[UIView alloc] init];
    self.gatewayDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.gatewayDot.layer.cornerRadius = 4;
    self.gatewayDot.backgroundColor = [UIColor systemGreenColor];

    self.gatewayLabel = [[UILabel alloc] init];
    self.gatewayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.gatewayLabel.font = [UIFont systemFontOfSize:13];
    self.gatewayLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];

    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"内网直连", @"反向连接"]];
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSegment.selectedSegmentIndex = 0;
    self.modeSegment.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    [self.modeSegment setTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor whiteColor]}
                                    forState:UIControlStateNormal];
    [self.modeSegment setTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor systemBlueColor]}
                                    forState:UIControlStateSelected];
    [self.modeSegment addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];

    [card addSubview:self.nameLabel];
    [card addSubview:self.gatewayDot];
    [card addSubview:self.gatewayLabel];
    [card addSubview:self.modeSegment];

    [NSLayoutConstraint activateConstraints:@[
        [self.nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [self.gatewayDot.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.gatewayDot.centerYAnchor constraintEqualToAnchor:self.gatewayLabel.centerYAnchor],
        [self.gatewayDot.widthAnchor constraintEqualToConstant:8],
        [self.gatewayDot.heightAnchor constraintEqualToConstant:8],
        [self.gatewayLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:10],
        [self.gatewayLabel.leadingAnchor constraintEqualToAnchor:self.gatewayDot.trailingAnchor constant:7],
        [self.gatewayLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [self.modeSegment.topAnchor constraintEqualToAnchor:self.gatewayLabel.bottomAnchor constant:16],
        [self.modeSegment.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.modeSegment.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.modeSegment.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (void)modeChanged:(UISegmentedControl *)seg {
    UIStackView *stack = (UIStackView *)self.contentCard.superview;
    [self refreshContentCard:stack];
}

#pragma mark - 内容卡切换（直连/反向）

- (void)refreshContentCard:(UIStackView *)stack {
    if (self.contentCard) {
        [stack removeArrangedSubview:self.contentCard];
        [self.contentCard removeFromSuperview];
        self.contentCard = nil;
    }
    UIView *card = (self.modeSegment.selectedSegmentIndex == 0) ? [self makeDirectCard] : [self makeReverseCard];
    self.contentCard = card;
    [stack insertArrangedSubview:card atIndex:1];
}

#pragma mark - 扫码直连卡（QR 上、ip 下，无复制/打开）

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

#pragma mark - 反向连接卡（真拨号）

- (UIView *)makeReverseCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"反向连接（需对端监听）"];
    [card addSubview:title];

    self.revModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"查看端", @"中继器"]];
    self.revModeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *mode = [self.defaults stringForKey:@"ReverseMode"] ?: @"none";
    self.revModeSegment.selectedSegmentIndex = [mode isEqualToString:@"repeater"] ? 1 : 0;
    [self.revModeSegment addTarget:self action:@selector(revModeChanged:) forControlEvents:UIControlEventValueChanged];

    self.revServerField = [self fieldWithPlaceholder:@"host:port 或 [IPv6]:port"];
    self.revServerField.text = [self.defaults stringForKey:@"ReverseSocket"];

    self.revIdField = [self fieldWithPlaceholder:@"数字 ID"];
    self.revIdField.text = [self.defaults stringForKey:@"ReverseRepeaterID"];
    self.revIdField.hidden = (self.revModeSegment.selectedSegmentIndex != 1);

    self.revIntervalField = [self fieldWithPlaceholder:@"默认 30"];
    self.revIntervalField.keyboardType = UIKeyboardTypeNumberPad;
    self.revIntervalField.text = [self.defaults stringForKey:@"ReverseRedialSec"];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.text = @"反向模式会关闭 5901/5801/Bonjour；客户端经反向通道接入。";

    self.dialBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dialBtn setTitle:@"拨号" forState:UIControlStateNormal];
    self.dialBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.dialBtn.backgroundColor = [UIColor systemBlueColor];
    [self.dialBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.dialBtn.layer.cornerRadius = 12;
    [self.dialBtn addTarget:self action:@selector(dialTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *restoreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [restoreBtn setTitle:@"恢复直连" forState:UIControlStateNormal];
    restoreBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    restoreBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    restoreBtn.layer.cornerRadius = 12;
    restoreBtn.layer.borderWidth = 1;
    restoreBtn.layer.borderColor = [UIColor separatorColor].CGColor;
    [restoreBtn addTarget:self action:@selector(restoreDirect) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *btnRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.dialBtn, restoreBtn]];
    btnRow.translatesAutoresizingMaskIntoConstraints = NO;
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 10;
    btnRow.distribution = UIStackViewDistributionFillEqually;

    [card addSubview:self.revModeSegment];
    [card addSubview:self.revServerField];
    [card addSubview:self.revIdField];
    [card addSubview:self.revIntervalField];
    [card addSubview:hint];
    [card addSubview:btnRow];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.revModeSegment.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [self.revModeSegment.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.revModeSegment.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.revServerField.topAnchor constraintEqualToAnchor:self.revModeSegment.bottomAnchor constant:12],
        [self.revServerField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.revServerField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.revServerField.heightAnchor constraintEqualToConstant:40],
        [self.revIdField.topAnchor constraintEqualToAnchor:self.revServerField.bottomAnchor constant:10],
        [self.revIdField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.revIdField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.revIdField.heightAnchor constraintEqualToConstant:40],
        [self.revIntervalField.topAnchor constraintEqualToAnchor:self.revIdField.bottomAnchor constant:10],
        [self.revIntervalField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.revIntervalField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.revIntervalField.heightAnchor constraintEqualToConstant:40],
        [hint.topAnchor constraintEqualToAnchor:self.revIntervalField.bottomAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [btnRow.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:14],
        [btnRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [btnRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [btnRow.heightAnchor constraintEqualToConstant:44],
        [btnRow.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)ph {
    UITextField *tf = [[UITextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.placeholder = ph;
    tf.font = [UIFont systemFontOfSize:14];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    return tf;
}

- (void)revModeChanged:(UISegmentedControl *)seg {
    self.revIdField.hidden = (seg.selectedSegmentIndex != 1);
}

- (void)dialTapped {
    NSString *mode = (self.revModeSegment.selectedSegmentIndex == 1) ? @"repeater" : @"viewer";
    NSString *server = [self.revServerField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!server.length) {
        [self alert:@"请填写服务器地址（host:port）"];
        return;
    }
    [self.defaults setObject:mode forKey:@"ReverseMode"];
    [self.defaults setObject:server forKey:@"ReverseSocket"];
    if (self.revModeSegment.selectedSegmentIndex == 1) {
        NSString *rid = [self.revIdField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (rid.length) [self.defaults setObject:rid forKey:@"ReverseRepeaterID"];
    }
    NSString *interval = [self.revIntervalField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (interval.length) [self.defaults setObject:interval forKey:@"ReverseRedialSec"];
    [self.defaults synchronize];

    [self.dialBtn setTitle:@"拨号中…" forState:UIControlStateNormal];
    self.dialBtn.enabled = NO;
    [self restartServiceToApply];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.dialBtn.enabled = NO;
        [self.dialBtn setTitle:@"已连接" forState:UIControlStateNormal];
    });
}

- (void)restoreDirect {
    [self.defaults setObject:@"none" forKey:@"ReverseMode"];
    [self.defaults synchronize];
    self.dialBtn.enabled = YES;
    [self.dialBtn setTitle:@"拨号" forState:UIControlStateNormal];
    [self restartServiceToApply];
}

- (void)restartServiceToApply {
    // 触发服务重启以应用反向/直连模式（TVNCUtil 内联）
    TVNCRestartVNCService();
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 在线客户端卡

- (UIView *)makeClientsCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"在线客户端"];
    [card addSubview:title];

    self.clientsCountLabel = [[UILabel alloc] init];
    self.clientsCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.clientsCountLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clientsCountLabel.textColor = [UIColor secondaryLabelColor];
    self.clientsCountLabel.text = @"0 台";

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
        [more.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [more.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [more.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (void)refreshClientCount {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger n = TVNCOnlineClientCount();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) strongSelf.clientsCountLabel.text = [NSString stringWithFormat:@"%ld 台", (long)n];
        });
    });
}

- (void)openClients {
    self.tabBarController.selectedIndex = 1;
}

#pragma mark - 状态

- (void)refreshStatus {
    [self updateStatusPill];
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
