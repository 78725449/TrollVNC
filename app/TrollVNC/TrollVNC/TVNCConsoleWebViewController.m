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

#import <WebKit/WebKit.h>

/// 未配置网关时，轮询检测网关配置出现的间隔（秒）
static const NSTimeInterval kConsoleConfigPollInterval = 3.0;

@interface TVNCConsoleWebViewController () <WKNavigationDelegate>

@property(nonatomic, strong) WKWebView *webView;                 // H5 手机控制台容器
@property(nonatomic, strong) UIActivityIndicatorView *spinner;   // 加载中指示器
@property(nonatomic, strong) UIView *statusOverlay;              // 未配置/加载失败引导层（居中提示 + 按钮）
@property(nonatomic, strong) UILabel *statusLabel;               // 引导文案
@property(nonatomic, strong) UIButton *actionButton;             // 引导按钮（重试/去设置）
@property(nonatomic, strong) NSTimer *configPollTimer;           // 网关配置检测定时器（未配置时轮询）
@property(nonatomic, copy, nullable) NSString *loadedURL;        // 当前已加载的 URL（网关变更时重载）
@property(nonatomic, assign) BOOL cleanedUp;                     // 资源是否已释放

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
    if (![self loadConsoleIfNeeded]) {
        [self showConfigPrompt];
    }
}

/**
 * 视图即将出现：网关配置变化（如设置页修改后切回本 Tab）时自动重载 H5。
 * @param animated 是否带动画
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConsoleIfNeeded];
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
 * 容器加载远程 http 页面，无需 file 访问权限；若加载被 ATS 拦截需在 Info.plist 配置
 * NSAllowsLocalNetworking（见 NSAppTransportSecurity）。
 */
- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = [UIColor systemBackgroundColor];
    self.webView.allowsBackForwardNavigationGestures = NO;
    [self.view addSubview:self.webView];
}

/**
 * 构造 H5 控制台 URL。
 * 配置键与原生网关客户端一致（com.82flex.trollvnc suite：GatewayHost/GatewayToken/TVNCConsolePort）。
 * @return URL 字符串；网关未配置返回 nil
 */
- (nullable NSString *)buildConsoleURL {
    TVNCGatewayClient *client = [TVNCGatewayClient sharedClient];
    NSString *host = [client gatewayHost];
    if (!host.length) return nil;
    NSInteger port = [client gatewayPort];
    NSMutableString *url = [NSMutableString stringWithFormat:@"http://%@:%ld/?container=ipa", host, (long)port];

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

#pragma mark - WKNavigationDelegate

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
    WKWebView *wv = self.webView;
    if (!wv) return;
    [wv stopLoading];
    [wv loadHTMLString:@"" baseURL:nil];
}

@end
