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

#import "TVNCConsoleWebViewController.h"
#import "TVNCGatewayClient.h"
#import "TVNCUtil.h"

#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import <notify.h>

/// 未配置网关时，轮询检测网关配置出现的间隔（秒）
static const NSTimeInterval kConsoleConfigPollInterval = 3.0;

/// 系统剪贴板变化 Darwin 通知（与设备端 ClipboardManager 同源）
static NSString *const kConsolePasteboardDarwinNotification = @"com.apple.pasteboard.notify.changed";

@interface TVNCConsoleWebViewController () <WKNavigationDelegate, WKScriptMessageHandler>

@property(nonatomic, strong) WKWebView *webView;                 // H5 手机控制台容器
@property(nonatomic, strong) UIActivityIndicatorView *spinner;   // 加载中指示器
@property(nonatomic, strong) UIView *statusOverlay;              // 未配置/加载失败引导层（居中提示 + 按钮）
@property(nonatomic, strong) UILabel *statusLabel;               // 引导文案
@property(nonatomic, strong) UIButton *actionButton;             // 引导按钮（重试/去设置）
@property(nonatomic, strong) NSTimer *configPollTimer;           // 网关配置检测定时器（未配置时轮询）
@property(nonatomic, copy, nullable) NSString *loadedURL;        // 当前已加载的 URL（网关变更时重载）
@property(nonatomic, assign) BOOL cleanedUp;                     // 资源是否已释放
@property(nonatomic, assign) BOOL consoleNeedsInitialLoad;              // 首屏待加载标记（viewDidLayoutSubviews 后触发）
// 剪贴板监听（控制端 → 被控端自动同步，2026-08-14）
@property(nonatomic, assign) int clipboardNotifyToken;           // Darwin 剪贴板通知 token（0=未注册）
@property(nonatomic, assign) NSInteger clipboardLastCount;       // 上次观察到的 UIPasteboard changeCount
@property(nonatomic, assign) NSInteger clipboardEchoCount;       // 预期回显的 changeCount（被控端同步写入触发的一次，命中即吞；-1=无待吞）

/**
 * 构造 H5 控制台 URL（读 NSUserDefaults 网关配置 + 本机 DeviceUUID）。
 * @return URL 字符串；网关未配置返回 nil
 */
- (nullable NSString *)buildConsoleURL;

/**
 * 加载 H5 控制台（幂等：URL 未变化不重复加载）。
 * @return 是否发起加载
 */
- (BOOL)loadConsoleIfNeeded;

/**
 * 未配置网关引导层（提示去设置页配置网关，自动轮询检测配置出现）。
 */
- (void)showConfigPrompt;

/**
 * 加载失败引导层（提示重试）。
 * @param reason 失败原因
 */
- (void)showLoadFailure:(NSString *)reason;

/**
 * 隐藏引导层，恢复 WebView。
 */
- (void)hideStatusOverlay;

/**
 * 释放 WebView 资源（幂等）。
 */
- (void)cleanup;

@end

@implementation TVNCConsoleWebViewController

#pragma mark - 生命周期

/**
 * 视图加载完成：搭建 WKWebView + 加载指示 + 引导层，分步 @try 降级（关键步骤失败仅引导，不崩溃）。
 */
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 步骤 1：WebView 容器（关键）
    @try {
        [self setupWebView];
    } @catch (NSException *e) {
        NSLog(@"[Console] setupWebView exception: %@ %@", e.name, e.reason);
        [self showLoadFailure:[NSString stringWithFormat:@"网页容器初始化失败：%@", e.reason]];
        return;
    }

    // 步骤 2：spinner（关键 UI，加载中转圈）
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [UIColor secondaryLabelColor];
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    // 步骤 3：引导层（未配置/加载失败时显示，覆盖 WebView 之上）
    @try {
        [self setupStatusOverlay];
    } @catch (NSException *e) {
        NSLog(@"[Console] setupStatusOverlay exception: %@ %@ (degraded)", e.name, e.reason);
    }

    // 步骤 4：约束（关键）
    // 2026-08-15 容器保持全屏（webView 顶到状态栏，与 5801 直连页一致的触屏网页全屏适配，
    // 本意：不使用 IPA 原生顶栏，整个控制页由 H5 网页接管）。
    // 顶部安全区由 H5 内 env(safe-area-inset-top) 自行避让（viewport-fit=cover 下有效）；
    // WKWebView 首帧 safe-area inset 未就绪（=0）随后注入真实值会造成 header 高度跳变，
    // 该"尺寸信号"由前端聚焦画布绝对居中（.focus-stage canvas translate(-50%,-50%)）
    // 免疫——画布位置与容器测量时序解耦，尺寸信号不再影响画面位置（见 web/style.css）。
    @try {
        [NSLayoutConstraint activateConstraints:@[
            [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [self.statusOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.statusOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.statusOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.statusOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    } @catch (NSException *e) {
        NSLog(@"[Console] constraints exception: %@ %@", e.name, e.reason);
        [self showLoadFailure:[NSString stringWithFormat:@"网页容器初始化失败：%@", e.reason]];
        return;
    }

    // 步骤 5：首屏加载（未配置网关时引导，配置后自动加载）
    // 2026-08-15 根因修复：不再在 viewDidLoad 立即加载——此时 AutoLayout 约束虽已激活，
    // 但 webView frame 需到首次布局（viewDidLayoutSubviews）才被约束更新为最终尺寸。
    // viewDidLoad 中加载会让 WKWebView 以初始 frame（主屏 bounds）建立布局视口，若后续
    // 约束将 frame 更新为实际尺寸（含 TabBar 扣除），H5 视口与 webView 尺寸不一致 →
    // 点击卡片时画布贴顶、系统重排后跳底。改由 viewDidLayoutSubviews 布局完成后加载。
    self.consoleNeedsInitialLoad = YES;

    // 步骤 6：本机剪贴板监听（控制端 → 被控端自动同步，2026-08-14）。
    // 常开：控制端复制即自动桥出给 Web 层经 RFB 协议通道同步到受控设备；
    // 页面未加载/无受控会话时 Web 层静默丢弃；回前台补一次（覆盖「其他 App 复制→切回」）。
    [self startClipboardMonitoring];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

/**
 * 视图即将出现：网关配置变化（如设置页修改后切回本 Tab）时自动重载 H5。
 * @param animated 是否带动画
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 2026-08-15：首次进入时首屏加载由 viewDidLayoutSubviews 负责（此时 webView frame 才
    // 被约束更新为最终尺寸，确保 H5 布局视口正确）；首次布局完成后此处才参与重载。
    if (!self.consoleNeedsInitialLoad) {
        [self loadConsoleIfNeeded];
    }
    // 2026-08-15：状态栏样式沿 VC 链转发，此处显式刷新确保浅色文字生效
    [self setNeedsStatusBarAppearanceUpdate];
}

/**
 * 首次布局完成（2026-08-15 根因修复）：AutoLayout 约束在此刻将 webView frame 更新为
 * 最终尺寸（含 TabBar 扣除）。此时才加载 H5——确保 WKWebView 以正确布局视口建立页面，
 * 否则首帧视口尺寸错误导致点击卡片时画布贴顶、系统重排后跳底。
 */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.consoleNeedsInitialLoad) {
        self.consoleNeedsInitialLoad = NO;
        if (![self loadConsoleIfNeeded]) {
            [self showConfigPrompt];
        }
    }
}

/**
 * 析构：确保 WebView 资源释放。
 */
- (void)dealloc {
    [self cleanup];
}

#pragma mark - WKWebView 配置与加载

/**
 * 创建并配置 WKWebView：禁用返回手势，允许页面滚动（设备墙滚动由 H5 内部处理）。
 * 容器加载网关 https 页面（§2.3m，自签证书由 didReceiveAuthenticationChallenge 信任）；
 * ATS 已配 NSAllowsArbitraryLoads（Info.plist）兜底，兼容设备端 5801 http 直连页。
 */
- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    // 2026-08-14：Web→原生桥（farmBridge）。设备→控制端剪贴板写入在 iOS WebKit 非用户手势下
    // writeText 会被拒（NotAllowedError，手机 Safari 与 WKWebView 同受限，电脑 Chrome 无此限制），
    // 故容器模式改走原生写 UIPasteboard（无手势/安全上下文限制）。需在 dealloc/cleanup 移除 handler 防循环引用。
    [config.userContentController addScriptMessageHandler:self name:@"farmBridge"];
    // 2026-08-15 根因修复：初始 frame 用主屏 bounds（而非 self.view.bounds——纯代码 VC 在
    // viewDidLoad 时 view 尚未布局，bounds 为 CGRectZero）。WKWebView 以 0×0 frame 创建会让
    // H5 首帧视口尺寸错误（识别到"很小的一点区域"）→ 点击卡片时画布贴顶；布局完成后自动拉伸。
    self.webView = [[WKWebView alloc] initWithFrame:[UIScreen mainScreen].bounds configuration:config];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = [UIColor systemBackgroundColor];
    self.webView.allowsBackForwardNavigationGestures = NO;
    // 2026-08-15：禁用 UIScrollView 橡皮筋回弹（iOS bounce 会把页面顶部/底部拉出背景，
    // 与 H5 内部固定布局冲突；H5 内部滚动（设备墙）不受影响）
    self.webView.scrollView.bounces = NO;
    // 2026-08-15：禁用自动内容偏移调整——WKWebView 全屏顶到状态栏（覆盖安全区）时，
    // UIScrollView 默认按 safe-area 自动调 contentInset，页面可视区域被系统推挤偏移，
    // 触发画布"贴顶/贴底"类漂移；.never 保证页面以真实视口尺寸布局，锚定不受系统调整影响。
    if (@available(iOS 11.0, *)) {
        self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.webView];
}

/**
 * 状态栏文字样式（2026-08-15 规范化改造）：webView 全屏顶到状态栏（无原生顶栏），
 * 状态栏区域由 H5 背景色接管（--bg 跟随系统主题：深色模式深底/浅色模式浅底），
 * 文字颜色须与 H5 背景同主题匹配——深色模式浅色文字，浅色模式深色文字。
 * 通过 traitCollection.userInterfaceStyle 动态返回，系统主题切换自动生效。
 * @return 状态栏文字样式（深色模式浅色 / 浅色模式深色）
 */
- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIStatusBarStyleLightContent
            : UIStatusBarStyleDarkContent;
    }
    return UIStatusBarStyleLightContent;
}

#pragma mark - WKScriptMessageHandler（Web → 原生桥）

/**
 * 接收 Web 层消息（2026-08-14）：
 * - {type:'writeClipboard', text} 设备→控制端剪贴板同步写入（RFB clipboard 事件 → 原生写 UIPasteboard，
 *   绕开 iOS WebKit 非手势 writeText 被拒的平台限制；写入后同步基线抑制本机监听回显推送）。
 */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"farmBridge"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSString *type = message.body[@"type"];
    if ([type isEqualToString:@"writeClipboard"]) {
        @try {
            NSString *text = message.body[@"text"];
            if (![text isKindOfClass:[NSString class]] || !text.length) return;
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            self.clipboardLastCount = pb.changeCount;     // 写入前基线：写入触发的 Darwin 通知会推进 count
            self.clipboardEchoCount = pb.changeCount + 1; // changeCount 锚点：仅吞本次写入触发的那一次通知（防回环）
            pb.string = text;
            NSLog(@"[Console] native writeClipboard (%lu chars)", (unsigned long)text.length);
        } @catch (NSException *e) {
            // 2026-08-15：UIPasteboard 写入在 iOS 16+ 粘贴权限/前台过渡期可能抛 NSException，
            // 捕获后仅记录（桥调用失败由 JS 侧降级 writeText），不让 App 闪退。
            NSLog(@"[Console] writeClipboard exception: %@ %@", e.name, e.reason);
        }
    } else if ([type isEqualToString:@"setTabBarHidden"]) {
        // 2026-08-15：控制页聚焦时隐藏/恢复底部 TabBar——点开卡片后画面占满整个屏幕
        //（与 web/app.js enterFocus/exitFocus 配对）。tabBar.hidden 在现代 iOS（11+）下
        // 会触发 tabBarController 重新布局，child view（含 webView）自动扩展到底部。
        @try {
            NSNumber *hidden = message.body[@"hidden"];
            if (hidden && self.tabBarController) {
                self.tabBarController.tabBar.hidden = hidden.boolValue;
                NSLog(@"[Console] tabBar hidden=%@", hidden.boolValue ? @"YES" : @"NO");
            }
        } @catch (NSException *e) {
            NSLog(@"[Console] setTabBarHidden exception: %@ %@", e.name, e.reason);
        }
    }
}


/**
 * 构造 H5 控制台 URL。
 * 配置键与原生网关客户端一致（com.82flex.trollvnc suite：GatewayHost/GatewayToken/TVNCConsolePort）。
 * 网关默认启用 https（自签证书，见 trollvnc-farm §2.3m）；自签信任由 didReceiveAuthenticationChallenge 处理。
 * @return URL 字符串；网关未配置返回 nil
 */
- (nullable NSString *)buildConsoleURL {
    TVNCGatewayClient *client = [TVNCGatewayClient sharedClient];
    NSString *host = [client gatewayHost];
    if (!host.length) return nil;
    NSInteger port = [client gatewayPort];
    NSMutableString *url = [NSMutableString stringWithFormat:@"https://%@:%ld/?container=ipa", host, (long)port];

    // token：网关 API 鉴权（H5 app.js 优先读 URL 参数，其次 localStorage）
    NSString *token = [client gatewayToken];
    if (token.length) {
        NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        [url appendFormat:@"&token=%@", encoded];
    }
    // selfId：本设备 DeviceUUID，H5 据此过滤自身设备（不显示自己）
    NSString *selfId = TVNCReadSelfDeviceId();
    if (selfId.length) {
        NSString *encoded = [selfId stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        [url appendFormat:@"&selfId=%@", encoded];
    }
    return url;
}

/**
 * 加载 H5 控制台（幂等：URL 未变化且已加载成功则不重复加载）。
 * 网关未配置返回 NO（由调用方显示引导）；加载失败由导航代理回调处理。
 * @return 是否发起加载
 */
- (BOOL)loadConsoleIfNeeded {
    NSString *urlStr = [self buildConsoleURL];
    if (!urlStr.length) return NO;                                   // 网关未配置
    BOOL urlChanged = ![urlStr isEqualToString:self.loadedURL];
    BOOL alreadyLoaded = (self.webView.URL != nil && !urlChanged);   // 已加载成功且 URL 未变
    if (alreadyLoaded) return YES;

    self.loadedURL = urlStr;
    [self hideStatusOverlay];
    [self.spinner startAnimating];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:15.0];
    [self.webView loadRequest:req];
    NSLog(@"[Console] loading %@", urlStr);
    return YES;
}

#pragma mark - 引导层（未配置 / 加载失败）

/**
 * 构建居中引导层：图标 + 文案 + 按钮，覆盖在 WebView 之上。
 */
- (void)setupStatusOverlay {
    self.statusOverlay = [[UIView alloc] init];
    self.statusOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusOverlay.backgroundColor = [UIColor systemBackgroundColor];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.actionButton.backgroundColor = [UIColor colorWithRed:(107.0 / 255.0)
                                                       green:(78.0 / 255.0)
                                                        blue:(255.0 / 255.0)
                                                       alpha:1.0];
    self.actionButton.layer.cornerRadius = 10;
    self.actionButton.contentEdgeInsets = UIEdgeInsetsMake(10, 22, 10, 22);
    [self.actionButton addTarget:self action:@selector(actionButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.statusOverlay addSubview:self.statusLabel];
    [self.statusOverlay addSubview:self.actionButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusOverlay.leadingAnchor constant:32],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.statusOverlay.trailingAnchor constant:-32],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.statusOverlay.centerYAnchor constant:-24],
        [self.actionButton.centerXAnchor constraintEqualToAnchor:self.statusOverlay.centerXAnchor],
        [self.actionButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:16],
    ]];
    [self.view addSubview:self.statusOverlay];
}

/**
 * 未配置网关引导：提示去设置页配置，并轮询检测配置出现后自动加载。
 */
- (void)showConfigPrompt {
    self.statusLabel.text = @"尚未配置网关\n请前往「设置」页填写网关地址与端口\n配置后本页将自动加载控制台";
    [self.actionButton setTitle:@"去设置" forState:UIControlStateNormal];
    self.statusOverlay.hidden = NO;
    [self startConfigPoll];
}

/**
 * 加载失败引导：显示原因 + 重试按钮。
 * @param reason 失败原因
 */
- (void)showLoadFailure:(NSString *)reason {
    self.statusLabel.text = reason ?: @"控制台加载失败";
    [self.actionButton setTitle:@"重试" forState:UIControlStateNormal];
    self.statusOverlay.hidden = NO;
    [self.spinner stopAnimating];
}

/**
 * 隐藏引导层（加载成功后调用）。
 */
- (void)hideStatusOverlay {
    self.statusOverlay.hidden = YES;
    [self stopConfigPoll];
}

/**
 * 引导按钮点击：重试加载；去设置模式无实际动作（切 Tab 由用户完成）。
 */
- (void)actionButtonTapped {
    if ([self.actionButton.currentTitle isEqualToString:@"重试"]) {
        [self loadConsoleIfNeeded];
    }
}

#pragma mark - 网关配置检测轮询

/**
 * 启动网关配置检测：未配置时每 3s 检测一次，配置出现后自动加载并停止。
 */
- (void)startConfigPoll {
    [self stopConfigPoll];
    self.configPollTimer = [NSTimer scheduledTimerWithTimeInterval:kConsoleConfigPollInterval
                                                            target:self
                                                          selector:@selector(configPollTick:)
                                                          userInfo:nil
                                                           repeats:YES];
}

/**
 * 停止网关配置检测（幂等）。
 */
- (void)stopConfigPoll {
    [self.configPollTimer invalidate];
    self.configPollTimer = nil;
}

/**
 * 检测回调：网关配置出现则自动加载控制台。
 * @param timer 触发定时器
 */
- (void)configPollTick:(NSTimer *)timer {
    if ([self loadConsoleIfNeeded]) {
        [self stopConfigPoll];
    }
}

#pragma mark - 剪贴板监听（控制端 → 被控端自动同步，2026-08-14）

/**
 * 启动本机剪贴板监听（常开）：注册 Darwin 通知 + 建立 changeCount 基线。
 * 控制端设备复制 → 本机 UIPasteboard 变化 → handleClipboardChanged 读文本推给 WebView，
 * Web 层经 RFB clipboardPasteFrom（Extended Clipboard 协议通道）同步到当前受控设备。
 * 与设备端（被控端）trollvncserver 的 ClipboardManager 同源同模式；App 进程内常开，
 * 页面未加载/无受控会话时 Web 层静默丢弃，无副作用。
 * 注：iOS 16+ 读 UIPasteboard 受「粘贴权限」约束（首次/按系统设置弹提示），属平台限制。
 */
- (void)startClipboardMonitoring {
    if (self.clipboardNotifyToken != 0) return;
    self.clipboardLastCount = [UIPasteboard generalPasteboard].changeCount;
    self.clipboardEchoCount = -1;   // 无待吞回显
    __weak __typeof(self) weakSelf = self;
    int token = 0;
    uint32_t status = notify_register_dispatch(kConsolePasteboardDarwinNotification.UTF8String, &token,
                                               dispatch_get_main_queue(), ^(int t) {
        __strong __typeof(weakSelf) selfRef = weakSelf;
        if (!selfRef) return;
        [selfRef handleClipboardChanged];
    });
    if (status == NOTIFY_STATUS_OK) {
        self.clipboardNotifyToken = token;
        NSLog(@"[Console] clipboard monitoring started (token=%d)", token);
    } else {
        NSLog(@"[Console] clipboard notify register failed (status=%u)", status);
    }
}

/**
 * 停止剪贴板监听（幂等）。
 */
- (void)stopClipboardMonitoring {
    if (self.clipboardNotifyToken != 0) {
        notify_cancel(self.clipboardNotifyToken);
        self.clipboardNotifyToken = 0;
        NSLog(@"[Console] clipboard monitoring stopped");
    }
}

/**
 * App 回到前台：补齐后台挂起期间可能错过的剪贴板变化
 * （覆盖「在其他 App 复制 → 切回 SuperPhone」场景，changeCount 未变则自然跳过）。
 * 2026-08-15：延迟 0.4s 再读取——iOS 16+ 的 UIPasteboard 粘贴权限弹窗在 App 前台过渡
 * 瞬间弹出可能抛 NSException（原实现直接闪退）；延后到前台动画完成后读取，避开过渡窗口。
 */
- (void)appDidBecomeActive {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) selfRef = weakSelf;
        if (selfRef) [selfRef handleClipboardChanged];
    });
}

/**
 * 剪贴板变化处理：changeCount 去重 → 一次性回显抑制 → 桥出到 Web 层。
 * 回显抑制（2026-08-15 基建）：控制端收到被控端剪贴板（RFB 'clipboard' 事件 → writeClipboard 写本机剪贴板）
 * 同样触发 Darwin 通知；若推送回 Web 会触发 clipboardPasteFrom 回发 → 死循环。
 * 用 changeCount 锚点（clipboardEchoCount）只吞"被控端同步写入"触发的那一次通知，
 * 用户后续复制（含相同文本）每次放行——不再用文本记忆（原 clipboardLastPushed 会误伤相同文本）。
 * 2026-08-15：UIPasteboard 访问整体 @try 包裹——iOS 16+ 在权限弹窗未决/前台过渡期读取
 * 会抛 NSException（原实现无保护直接闪退）；异常时重设 changeCount 基线防重复触发。
 */
- (void)handleClipboardChanged {
    @try {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSInteger count = pb.changeCount;
        if (count == self.clipboardLastCount) return; // 重复/无变化通知
        self.clipboardLastCount = count;
        // 2026-08-15 一次性回显抑制（changeCount 锚点）：仅吞"被控端同步写入"触发的那一次通知，
        // 用户后续复制（含相同文本）count 越过锚点，每次放行——替代原 clipboardLastPushed 文本记忆
        //（后者会误伤"连续复制相同文本"：第二次起被当作回显跳过）。
        if (self.clipboardEchoCount == count) {
            self.clipboardEchoCount = -1;
            return;
        }
        NSString *text = pb.string;
        if (!text.length) return;
        [self pushClipboardToWeb:text];
    } @catch (NSException *e) {
        NSLog(@"[Console] handleClipboardChanged exception: %@ %@", e.name, e.reason);
        // 重设基线，避免异常后每次都重复进入（changeCount 读取失败时强制刷新）
        @try { self.clipboardLastCount = [UIPasteboard generalPasteboard].changeCount; }
        @catch (NSException *ignored) { self.clipboardLastCount = -1; }
    }
}

/**
 * 桥出剪贴板文本到 WebView：调用 window.__farmNativeClipboard(JSON 字符串)。
 * 2026-08-15：JSON 序列化不转义 \u2028（行分隔符）/ \u2029（段分隔符）——直接嵌入 JS
 * 字符串字面量在 iOS ≤15 的 JavaScriptCore 中是语法错误（视为字符串外的行终止符），
 * evaluateJavaScript 失败 → 剪贴板同步静默失效（"复制后不同步"诱因之一）。
 * 手动替换为 \uXXXX 转义序列，保证任意文本可安全注入。
 * @param text 控制端本机剪贴板文本
 */
- (void)pushClipboardToWeb:(NSString *)text {
    WKWebView *wv = self.webView;
    if (!wv) return;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:text options:0 error:nil];
    if (!jsonData) return;
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    json = [json stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    json = [json stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    NSString *js = [NSString stringWithFormat:@"window.__farmNativeClipboard && window.__farmNativeClipboard(%@);", json];
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error) NSLog(@"[Console] clipboard push JS error: %@", error.localizedDescription);
    }];
}

#pragma mark - WKNavigationDelegate

/**
 * TLS 挑战处理：网关为内网自签证书（https 无感剪贴板依赖，见 trollvnc-farm §2.3m），
 * 无条件信任 serverTrust（内网自签边界，MITM 风险与"无鉴权内网"设计一致；挑战处理优先于 ATS）。
 * @param challenge 认证挑战
 * @param completionHandler 完成回调（disposition + credential）
 */
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        if (trust) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

/**
 * 主页面加载完成：隐藏加载指示器。
 */
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
}

/**
 * 主页面加载失败：显示失败引导（可重试）。
 */
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    // 忽略主动取消加载的导航错误（如 Tab 切换触发的 stopLoading）
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    NSLog(@"[Console] load failed: %@", error);
    [self.spinner stopAnimating];
    [self showLoadFailure:[NSString stringWithFormat:@"控制台加载失败\n%@", error.localizedDescription]];
}

/**
 * 主页面 HTTP 错误（如网关返回 500）：同样转入失败引导。
 */
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    NSLog(@"[Console] navigation failed: %@", error);
    [self.spinner stopAnimating];
    [self showLoadFailure:[NSString stringWithFormat:@"控制台加载失败\n%@", error.localizedDescription]];
}

#pragma mark - 资源清理

/**
 * 释放 WebView 资源（幂等）：停止加载并清空页面。
 */
- (void)cleanup {
    if (self.cleanedUp) return;
    self.cleanedUp = YES;
    [self stopConfigPoll];
    // 2026-08-14：停止剪贴板监听 + 移除前台观察者（防通知回调悬挂）
    [self stopClipboardMonitoring];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    WKWebView *wv = self.webView;
    if (!wv) return;
    // 2026-08-14：移除 WKScriptMessageHandler（addScriptMessageHandler:self 会强引用 self，必须显式移除防泄漏）
    @try {
        [wv.configuration.userContentController removeScriptMessageHandlerForName:@"farmBridge"];
    } @catch (NSException *e) {
        NSLog(@"[Console] removeScriptMessageHandler exception: %@", e);
    }
    [wv stopLoading];
    [wv loadHTMLString:@"" baseURL:nil];
}

@end
