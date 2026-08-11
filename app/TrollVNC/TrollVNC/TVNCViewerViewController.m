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

#import "TVNCViewerViewController.h"
#import "TVNCSettingsViewController.h"

#import <WebKit/WebKit.h>

// JS 桥接消息名（与 ViewerWeb.html 中 webkit.messageHandlers.viewer 对应）
static NSString *const kViewerBridgeName = @"viewer";

@interface TVNCViewerViewController () <WKScriptMessageHandler, WKNavigationDelegate>

@property(nonatomic, copy) NSString *host;
@property(nonatomic, assign) int port;
@property(nonatomic, copy) NSString *deviceName;

@property(nonatomic, strong) WKWebView *screenView;          // noVNC 画面容器（替代原 UIImageView）
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *gearBtn;               // 悬浮信号按钮（WiFi 白底，可拖动）
@property(nonatomic, strong) NSTimer *sigTimer;               // 延迟轮询定时器（每 3s ping 网关）
@property(nonatomic, assign) BOOL gearPlaced;

@property(nonatomic, assign) BOOL connected;                  // RFB 是否已建立连接
@property(nonatomic, assign) BOOL stopRequested;              // 用户已请求退出
@property(nonatomic, assign) BOOL cleanedUp;                  // WebView 资源是否已释放
@property(nonatomic, assign) BOOL pageReady;                  // ViewerWeb.html 是否已就绪

/**
 * 显示设备配置面板（Phase 12.8）：push TVNCSettingsViewController 展示完整设置页。
 */
- (void)showConfigPanel;

@end

@implementation TVNCViewerViewController

#pragma mark - 生命周期

/**
 * 初始化 Viewer。
 * @param host 目标主机（设备 IP 或网关地址）
 * @param port RFB 端口（如 5901），内部按 VNC 约定换算为 WebSocket 端口（5901→5801）
 * @param name 设备显示名称
 * @return Viewer 视图控制器实例
 */
- (instancetype)initWithHost:(NSString *)host port:(int)port name:(NSString *)name {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _deviceName = [name copy] ?: [host copy];
        self.hidesBottomBarWhenPushed = YES; // 全屏：隐藏底部 Tab
        NSLog(@"[Viewer] initWithHost host=%@ port=%d name=%@", _host, _port, _deviceName);
    }
    return self;
}

/**
 * 视图加载完成：搭建 WKWebView + 状态 UI + 悬浮菜单，并加载 ViewerWeb.html。
 */
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    NSLog(@"[Viewer] viewDidLoad begin host=%@ port=%d deviceId=%@", self.host, self.port, self.deviceId);

    // 防守：大屏控制页初始化任一步抛异常都不闪退，改为提示后返回上一级
    // （覆盖未捕获 NSException：unrecognized selector / 越界等；分段日志定位到具体失败步骤）
    @try {
        [self setupWebView];
        NSLog(@"[Viewer] setupWebView ok");

        self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
        self.spinner.color = [UIColor whiteColor];
        [self.view addSubview:self.spinner];
        [self.spinner startAnimating];

        self.statusLabel = [[UILabel alloc] init];
        self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.statusLabel.textColor = [UIColor whiteColor];
        self.statusLabel.font = [UIFont systemFontOfSize:13];
        self.statusLabel.text = [NSString stringWithFormat:@"连接 %@:%d …", self.host, self.port];
        [self.view addSubview:self.statusLabel];

        [self setupGearButton];
        NSLog(@"[Viewer] setupGearButton ok");
        [self startSignalPoll];
        NSLog(@"[Viewer] startSignalPoll ok");

        [NSLayoutConstraint activateConstraints:@[
            // screenView 全屏铺满
            [self.screenView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.screenView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.screenView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.screenView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            // spinner/spinner 与状态标签居中
            [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:12],
        ]];
        NSLog(@"[Viewer] constraints ok");

        [self loadViewerPage];
        NSLog(@"[Viewer] loadViewerPage called");
    } @catch (NSException *e) {
        NSLog(@"[Viewer] viewDidLoad exception: %@ %@", e.name, e.reason);
        NSLog(@"[Viewer] %@", e.callStackSymbols);
        [self failWithMessage:[NSString stringWithFormat:@"大屏控制初始化失败：%@", e.reason]];
    }
}

/**
 * 视图即将出现：隐藏导航栏以全屏显示画面。
 * @param animated 是否带动画
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSLog(@"[Viewer] viewWillAppear");
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

/**
 * 视图布局完成：首次放置悬浮信号按钮到右上（靠右边，垂直 1/4 高度）。
 */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.gearPlaced) {
        self.gearPlaced = YES;
        CGFloat s = self.gearBtn.bounds.size.width;
        CGRect f = self.gearBtn.frame;
        f.origin.x = self.view.bounds.size.width - s - 16;
        f.origin.y = MAX(self.view.safeAreaInsets.top + 8, self.view.bounds.size.height * 0.25);
        self.gearBtn.frame = f;
    }
}

/**
 * 视图即将消失：恢复导航栏显示并停止延迟轮询。
 * @param animated 是否带动画
 */
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self stopSignalPoll];
}

/**
 * 当本控制器被从父控制器移除（pop 返回）时触发：停止连接并释放 WebView 资源。
 * @param parent 新的父控制器，为 nil 表示正在被 pop
 */
- (void)willMoveToParentViewController:(UIViewController *)parent {
    [super willMoveToParentViewController:parent];
    if (parent == nil) {
        self.stopRequested = YES;
        [self disconnectJS];
        [self cleanup];
    }
}

/**
 * 析构：确保 WebView 资源已释放（打破 userContentController 对 self 的强引用环）。
 */
- (void)dealloc {
    [self cleanup];
}

#pragma mark - WKWebView 配置

/**
 * 创建并配置 WKWebView：允许 file URL 加载 noVNC 资源、禁用滚动/缩放、注册 viewer 消息通道。
 */
- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];

    // 允许从 file:// 加载本地 ES Module 子资源（noVNC 核心模块及其依赖）
    WKPreferences *prefs = [[WKPreferences alloc] init];
    [prefs setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    [prefs setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"];
    config.preferences = prefs;

    // 注册 JS → OC 消息通道（ViewerWeb.html 通过 webkit.messageHandlers.viewer 上报状态）
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:kViewerBridgeName];
    config.userContentController = ucc;

    self.screenView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.navigationDelegate = self;
    self.screenView.backgroundColor = [UIColor blackColor];
    self.screenView.opaque = NO;
    // 禁用 WebView 自身滚动/回弹，交由 noVNC 内部手势接管
    self.screenView.scrollView.scrollEnabled = NO;
    self.screenView.scrollView.bounces = NO;
    // 允许 noVNC 评估手势所需的 AirPlay 画中画等能力，关闭内联视频回放
    self.screenView.allowsBackForwardNavigationGestures = NO;
    [self.view addSubview:self.screenView];
}

/**
 * 加载 bundle 内的 ViewerWeb.html，授予其对整个 bundle 目录的读取权限（含 novnc/ 子目录）。
 */
- (void)loadViewerPage {
    NSURL *htmlURL = [[NSBundle mainBundle] URLForResource:@"ViewerWeb" withExtension:@"html"];
    if (!htmlURL) {
        [self failWithMessage:@"ViewerWeb.html 未找到，请检查打包资源"];
        return;
    }
    NSURL *baseURL = [[NSBundle mainBundle] bundleURL];
    [self.screenView loadFileURL:htmlURL allowingReadAccessToURL:baseURL];
}

/**
 * 构造 WebSocket URL（纯隧道，直连模式已废弃）。
 * 经网关 /ws/vnc/:deviceId 桥接隧道（跨网络）；host=网关地址、port=网关 HTTP 端口。
 * @return WebSocket URL 字符串
 */
- (NSString *)buildWebSocketURL {
    // 纯隧道：经网关 8080 /ws/vnc/:deviceId 桥接（直连 host 模式已废弃）
    NSAssert(self.useGatewayTunnel && self.deviceId.length, @"Viewer 仅支持隧道模式（直连已废弃）");
    NSString *url = [NSString stringWithFormat:@"ws://%@:%d/ws/vnc/%@",
                     self.host, self.port, self.deviceId];
    // 附加 token（如有配置，网关 wss 层校验）
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    NSString *token = [defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        url = [url stringByAppendingFormat:@"?token=%@", encoded];
    }
    return url;
}

/**
 * 在页面就绪后向 JS 注入连接参数，启动 noVNC 连接。
 */
- (void)startConnection {
    if (self.cleanedUp || self.stopRequested) return;
    NSLog(@"[Viewer] startConnection building ws url");
    NSString *wsURL = [self buildWebSocketURL];
    NSString *arg = [self jsStringLiteral:wsURL];
    NSString *js = [NSString stringWithFormat:@"connect(%@)", arg];
    NSString *shortUrl = wsURL.length > 80 ? [wsURL substringToIndex:80] : wsURL;
    NSLog(@"[Viewer] startConnection injecting connect(%@)", shortUrl);
    [self evalJS:js];
}

#pragma mark - JS 桥接（OC → JS）

/**
 * 执行一段 JavaScript，自动跳过已释放状态。
 * @param script 待执行的 JS 代码
 */
- (void)evalJS:(NSString *)script {
    if (self.cleanedUp || !script.length) return;
    [self.screenView evaluateJavaScript:script completionHandler:nil];
}

/**
 * 调用 JS 端 disconnect() 断开当前 RFB 连接。
 */
- (void)disconnectJS {
    [self evalJS:@"disconnect()"];
}

/**
 * 将任意字符串转换为合法的 JS 字符串字面量（含双引号与转义）。
 * 使用 NSJSONSerialization 序列化保证特殊字符安全转义。
 * @param s 原始字符串
 * @return 形如 "ws://host:5801/websockify" 的 JS 字面量
 */
- (NSString *)jsStringLiteral:(NSString *)s {
    if (!s) return @"\"\"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
    if (!d) return @"\"\"";
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (arr.length < 2) return @"\"\"";
    // arr 形如 ["..."]，去掉首尾方括号得到带引号的字符串字面量
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

#pragma mark - JS 桥接（JS → OC）

/**
 * 接收 ViewerWeb.html 通过 webkit.messageHandlers.viewer 上报的状态消息，更新 UI。
 * @param userContentController 注册的消息控制器
 * @param message JS 发送的消息，body 为 {type, detail} 字典
 */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kViewerBridgeName]) return;
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    if (!body) return;
    NSString *type = body[@"type"];
    NSLog(@"[Viewer] JS message type=%@", type);
    NSDictionary *detail = [body[@"detail"] isKindOfClass:[NSDictionary class]] ? body[@"detail"] : @{};

    if ([type isEqualToString:@"ready"]) {
        // 页面就绪：下发连接参数
        self.pageReady = YES;
        [self startConnection];
    } else if ([type isEqualToString:@"connected"]) {
        [self onConnected];
    } else if ([type isEqualToString:@"disconnected"]) {
        BOOL clean = [detail[@"clean"] boolValue];
        [self onDisconnected:clean];
    } else if ([type isEqualToString:@"failed"]) {
        NSString *reason = detail[@"reason"] ?: @"未知错误";
        [self onFailed:reason];
    }
}

/**
 * RFB 连接成功回调：更新状态栏、停止加载指示器。
 */
- (void)onConnected {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connected = YES;
        self.statusLabel.text = [NSString stringWithFormat:@"已连接 %@", self.deviceName];
        [self.spinner stopAnimating];
    });
}

/**
 * RFB 连接断开回调。
 * @param clean 是否为干净断开
 */
- (void)onDisconnected:(BOOL)clean {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connected = NO;
        [self.spinner stopAnimating];
        if (self.stopRequested) return; // 用户主动退出，不弹提示
        self.statusLabel.text = clean ? @"已断开" : @"连接已中断";
        [self toastAndPop:clean ? @"连接已断开" : @"连接已中断"];
    });
}

/**
 * RFB 连接失败回调。
 * @param reason 失败原因
 */
- (void)onFailed:(NSString *)reason {
    NSLog(@"[Viewer] onFailed reason=%@", reason);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connected = NO;
        [self.spinner stopAnimating];
        self.statusLabel.text = @"连接失败";
        [self toastAndPop:[NSString stringWithFormat:@"连接失败：%@", reason]];
    });
}

#pragma mark - WKNavigationDelegate

/**
 * 页面加载失败回调：提示用户并返回。
 * @param webView 发生失败的 WebView
 * @param navigation 触发加载的导航对象
 * @param error 加载错误
 */
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error {
    [self failWithMessage:[NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription]];
}

/**
 * WebContent 进程被系统终止（内存压力/Jetsam）时回调：
 * 重新加载页面，避免 App 直接闪退。
 * @param webView 发生进程终止的 WebView
 */
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    NSLog(@"[Viewer] WebContent process terminated, reloading viewer page");
    [self.screenView reload];
}

#pragma mark - 悬浮 ⚙（可拖动 + 竖排菜单）

/**
 * 创建悬浮信号按钮（WiFi 白底样式）及其拖动手势、能力菜单。
 * 与网页端 FAB（网关 8080 / 设备 5801）视觉一致：白色圆底 + 三段 WiFi 弧，
 * 信号颜色随网关 ping 延迟动态更新；点击（primaryAction）弹出能力菜单。
 * Phase 4.7 数据驱动改造：移除硬编码 ops 数组，改为通过网关 /api/devices/:id/caps
 * 拉取 capMetadata 后异步重建按 category 分组的 UIMenu；首次展示占位菜单（仅"结束控制"）。
 */
- (void)setupGearButton {
    CGFloat s = 56;
    self.gearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    // 默认信号：全灰（尚未 ping）
    [self.gearBtn setImage:[self wifiIconWithOuter:[self tvncColorWithHex:0xcbd5e1]
                                            middle:[self tvncColorWithHex:0xcbd5e1]
                                             inner:[self tvncColorWithHex:0xcbd5e1]]
                  forState:UIControlStateNormal];
    self.gearBtn.backgroundColor = [UIColor whiteColor];
    self.gearBtn.layer.cornerRadius = s / 2;
    self.gearBtn.layer.borderWidth = 1;
    self.gearBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.12].CGColor;
    self.gearBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    self.gearBtn.layer.shadowOpacity = 0.45;
    self.gearBtn.layer.shadowRadius = 12;
    self.gearBtn.layer.shadowOffset = CGSizeMake(0, 6);
    self.gearBtn.clipsToBounds = NO;
    // 默认位置：靠右边缘，垂直 1/4 高度（viewDidLayoutSubviews 再按安全区修正）
    self.gearBtn.frame = CGRectMake(self.view.bounds.size.width - s - 16, self.view.bounds.size.height * 0.25, s, s);
    [self.view addSubview:self.gearBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragGear:)];
    [self.gearBtn addGestureRecognizer:pan];

    // 占位菜单（仅"结束控制"），等待 capMetadata 异步加载后重建为数据驱动菜单
    [self rebuildGearMenuWithCaps:nil];
    self.gearBtn.showsMenuAsPrimaryAction = YES;

    // 异步拉取设备能力元数据，按 category 分组重建 ⚙ 菜单
    __weak typeof(self) weakSelf = self;
    [self fetchCapMetadata:^(NSArray<NSDictionary *> *caps) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rebuildGearMenuWithCaps:caps];
    }];
}

/**
 * 处理 ⚙ 按钮拖动，限制在安全区域内移动。
 * @param g 平移手势
 */
- (void)dragGear:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:self.view];
        CGPoint c = self.gearBtn.center;
        c.x += t.x;
        c.y += t.y;
        CGFloat s = self.gearBtn.bounds.size.width;
        CGFloat top = s / 2 + self.view.safeAreaInsets.top;
        CGFloat bottom = self.view.bounds.size.height - s / 2 - self.view.safeAreaInsets.bottom;
        c.x = MAX(s / 2, MIN(self.view.bounds.size.width - s / 2, c.x));
        c.y = MAX(top, MIN(bottom, c.y));
        self.gearBtn.center = c;
        [g setTranslation:CGPointZero inView:self.view];
    }
}

#pragma mark - 悬浮信号（WiFi 图标 + 网关延迟轮询）

/**
 * 将 0xRRGGBB 格式的十六进制颜色值转换为 UIColor。
 * @param hex 十六进制颜色值，如 0x22c55e
 * @return 对应 UIColor（不透明）
 */
- (UIColor *)tvncColorWithHex:(uint32_t)hex {
    CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
    CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
    CGFloat b = (hex & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

/**
 * 生成 WiFi 信号图标（三段顶部弧 + 底部小点），各段颜色独立指定。
 * 与网页端 FAB（网关 8080 / 设备 5801）的 SVG 三段弧视觉一致：
 *   外弧 a1（大圆环扇区）、中弧 a2（中圆环扇区）、内点 a3（底部三角）。
 * 按 24×24 逻辑坐标绘制后缩放到 30×30pt。
 * @param outer  外弧（a1）颜色
 * @param middle 中弧（a2）颜色
 * @param inner  内点（a3）颜色
 * @return 30×30pt 的 WiFi 图标 UIImage（颜色已烘焙，非 template 模式）
 */
- (UIImage *)wifiIconWithOuter:(UIColor *)outer middle:(UIColor *)middle inner:(UIColor *)inner {
    CGFloat scale = 30.0 / 24.0; // SVG viewBox 24 → 30pt
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(30, 30)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSaveGState(ctx.CGContext);
        CGContextScaleCTM(ctx.CGContext, scale, scale);
        CGPoint c = CGPointMake(12, 12);

        // 绘制一段顶部环形扇区（外弧 135°→45° 顺时针过 90° 顶点，内弧反向闭合）
        void (^annularSector)(CGFloat, CGFloat, UIColor *) = ^(CGFloat outerR, CGFloat innerR, UIColor *color) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            CGFloat start = M_PI * 3 / 4;   // 135°
            CGFloat end = M_PI / 4;         // 45°
            [p addArcWithCenter:c radius:outerR startAngle:start endAngle:end clockwise:YES];
            [p addArcWithCenter:c radius:innerR startAngle:end endAngle:start clockwise:NO];
            [p closePath];
            [color setFill];
            [p fill];
        };
        annularSector(11.0, 8.2, outer);   // a1 外弧
        annularSector(7.8, 5.2, middle);   // a2 中弧
        // a3 内点：底部小三角，与 SVG "M9 17l3 3 3-3" 一致
        UIBezierPath *dot = [UIBezierPath bezierPath];
        [dot moveToPoint:CGPointMake(9, 17)];
        [dot addLineToPoint:CGPointMake(15, 17)];
        [dot addLineToPoint:CGPointMake(12, 20)];
        [dot closePath];
        [inner setFill];
        [dot fill];
        CGContextRestoreGState(ctx.CGContext);
    }];
}

/**
 * 按延迟毫秒更新悬浮按钮信号颜色（与网页端阈值一致）：
 *   <150ms 全绿（sig-high）；<400ms 中弧+点 黄（sig-mid）；否则/失败 仅点 红（sig-low）。
 * @param ms 延迟毫秒；<0 表示请求失败/无响应
 */
- (void)applySignalWithLatency:(NSTimeInterval)ms {
    UIColor *grey  = [self tvncColorWithHex:0xcbd5e1];
    UIColor *green = [self tvncColorWithHex:0x22c55e];
    UIColor *yellow= [self tvncColorWithHex:0xeab308];
    UIColor *red   = [self tvncColorWithHex:0xef4444];
    UIColor *outer = grey, *middle = grey, *inner = grey;
    if (ms >= 0 && ms < 150) {
        outer = middle = inner = green;      // 满格：全绿
    } else if (ms >= 0 && ms < 400) {
        middle = inner = yellow;             // 中格：中弧+点 黄，外弧灰
    } else {
        inner = red;                         // 低格：仅点 红
    }
    [self.gearBtn setImage:[self wifiIconWithOuter:outer middle:middle inner:inner]
                  forState:UIControlStateNormal];
}

/**
 * 通过网关 POST /api/devices/:id/ping 测往返耗时，并刷新信号图标。
 * 失败或超时按 -1 处理（仅红点）。
 */
- (void)pingAndUpdateSignal {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    NSString *token = [defaults stringForKey:@"GatewayToken"];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/api/devices/%@/ping",
                       self.host, self.port, self.deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 4.0;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    NSDate *t0 = [NSDate date];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSTimeInterval ms = -1;
            if (!err) {
                NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
                if (hr.statusCode == 200) ms = [[NSDate date] timeIntervalSinceDate:t0] * 1000;
            }
            [strongSelf applySignalWithLatency:ms];
        });
    }];
    [task resume];
}

/**
 * 启动延迟轮询（每 3s 一次，立即先测一次），驱动悬浮按钮信号颜色。
 * 幂等：已启动时先停止再重启。
 */
- (void)startSignalPoll {
    [self stopSignalPoll];
    __weak typeof(self) weakSelf = self;
    self.sigTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        [strongSelf pingAndUpdateSignal];
    }];
    [self pingAndUpdateSignal];
}

/**
 * 停止延迟轮询（退出查看器/析构时调用，释放定时器）。
 */
- (void)stopSignalPoll {
    [self.sigTimer invalidate];
    self.sigTimer = nil;
}

#pragma mark - 能力元数据（数据驱动菜单）

/**
 * 通过网关 API GET /api/devices/:id/caps 拉取设备能力元数据（capMetadata）。
 * 纯隧道：使用 self.host/self.port/deviceId 调用网关（直连模式已废弃）。
 * @param completion 完成回调（main queue），caps 为 capMetadata 数组；失败时为 nil
 */
- (void)fetchCapMetadata:(void (^)(NSArray<NSDictionary *> *caps))completion {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    NSString *token = [defaults stringForKey:@"GatewayToken"];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/api/devices/%@/caps",
                       self.host, self.port, self.deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 6.0;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *caps = nil;
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id m = json[@"capMetadata"];
                if ([m isKindOfClass:[NSArray class]]) caps = m;
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(caps); });
    }];
    [task resume];
}

/**
 * 根据能力元数据重建 ⚙ 菜单：按 category 分组，每个分组对应一个内联子 UIMenu。
 * 末尾固定追加"结束控制"项；caps 为 nil 或空时仅显示"结束控制"。
 * @param caps 能力元数据数组（来自 capMetadata）；可为 nil
 */
- (void)rebuildGearMenuWithCaps:(NSArray<NSDictionary *> *)caps {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

    if (caps.count) {
        // 按 category 分组，保留首次出现顺序
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
        for (NSDictionary *cap in caps) {
            if (![cap isKindOfClass:[NSDictionary class]]) continue;
            NSString *cat = cap[@"category"] ?: @"other";
            if (!groups[cat]) {
                groups[cat] = [NSMutableArray array];
                [order addObject:cat];
            }
            [groups[cat] addObject:cap];
        }
        // 每个 category 一个内联子 UIMenu（title 为中文分组名）
        for (NSString *cat in order) {
            NSMutableArray<UIAction *> *acts = [NSMutableArray array];
            for (NSDictionary *cap in groups[cat]) {
                NSString *capId = cap[@"id"] ?: @"";
                // 类型安全：网关 capMetadata 字段可能为 NSNull（JSON null），直接传给 UIAction/systemImageNamed 会 unrecognized selector 崩溃
                id rawTitle = cap[@"title"];
                NSString *title = [rawTitle isKindOfClass:[NSString class]] && [(NSString *)rawTitle length]
                                  ? (NSString *)rawTitle : capId;
                id rawIcon = cap[@"icon"];
                NSString *iconName = [rawIcon isKindOfClass:[NSString class]] ? (NSString *)rawIcon : @"";
                // capMetadata 的 icon 字段可能为 emoji 或 SF Symbol 名；
                // 优先按 SF Symbol 解析，失败则回退到 "circle" 占位图
                UIImage *img = [UIImage systemImageNamed:iconName];
                if (!img) img = [UIImage systemImageNamed:@"circle"];
                UIAction *a = [UIAction actionWithTitle:title
                                                   image:img
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
                                                     [weakSelf invokeCap:capId params:nil];
                                                 }];
                [acts addObject:a];
            }
            if (!acts.count) continue;
            UIMenu *sub = [UIMenu menuWithTitle:[self categoryChineseTitle:cat]
                                           image:nil
                                      identifier:nil
                                         options:UIMenuOptionsDisplayInline
                                        children:acts];
            [children addObject:sub];
        }
    }

    // "设备配置"（Phase 12.8）：push 设置页，让用户查看/调整配置
    UIAction *configAction = [UIAction actionWithTitle:@"设备配置"
                                                  image:[UIImage systemImageNamed:@"gearshape"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
                                                    [weakSelf showConfigPanel];
                                                }];
    [children addObject:configAction];

    // "结束控制"始终在末尾（destructive 样式）
    UIAction *end = [UIAction actionWithTitle:@"结束控制"
                                        image:[UIImage systemImageNamed:@"xmark.circle.fill"]
                                   identifier:nil
                                      handler:^(__kindof UIAction *action) {
                                          [weakSelf stopAndExit];
                                      }];
    end.attributes = UIMenuElementAttributesDestructive;
    [children addObject:end];

    self.gearBtn.menu = [UIMenu menuWithTitle:@"控制" children:children];
}

/**
 * 调用设备能力（纯隧道，直连模式已废弃）。
 * 一律走网关 invoke API（POST /api/devices/:id/invoke）。
 * @param capId  能力 ID（如 home/power/volup/type.text/clipboard.set 等）
 * @param params 调用参数字典（可为 nil）
 */
- (void)invokeCap:(NSString *)capId params:(NSDictionary *)params {
    if (!capId.length) return;
    // 纯隧道：走网关 invoke API
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    NSString *token = [defaults stringForKey:@"GatewayToken"];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/api/devices/%@/invoke",
                       self.host, self.port, self.deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSDictionary *body = @{@"cap": capId, @"params": params ?: @{}};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    req.HTTPBody = bodyData;
    req.timeoutInterval = 6.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:nil] resume];
}

/**
 * 能力 category 标识 → 中文分组标题映射。
 * @param category 能力分类标识（hid/touch/stylus/system/native/service/gateway）
 * @return 中文分组标题；未知 category 原样返回（兜底为"其他"）
 */
- (NSString *)categoryChineseTitle:(NSString *)category {
    static NSDictionary *mapping = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mapping = @{
            @"hid":     @"硬件按键",
            @"touch":   @"触控操作",
            @"stylus":  @"触控笔",
            @"system":  @"系统管理",
            @"native":  @"原生功能",
            @"service": @"服务管理",
            @"gateway": @"网关信息",
        };
    });
    if (!category.length) return @"其他";
    NSString *t = mapping[category];
    return t.length ? t : category;
}

#pragma mark - 资源清理

/**
 * 释放 WebView 资源：移除消息处理器（打破强引用环）、停止加载、清空页面。
 * 幂等，可安全多次调用。
 */
- (void)cleanup {
    if (self.cleanedUp) return;
    self.cleanedUp = YES;
    WKWebView *wv = self.screenView;
    if (!wv) return;
    [wv.configuration.userContentController removeScriptMessageHandlerForName:kViewerBridgeName];
    [wv stopLoading];
    [wv loadHTMLString:@"" baseURL:nil];
}

#pragma mark - 失败/退出

/**
 * 连接失败统一处理：停止加载指示器并提示后返回。
 * @param msg 失败提示信息
 */
- (void)failWithMessage:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        self.statusLabel.text = msg;
        [self toastAndPop:msg];
    });
}

/**
 * 弹出提示框并返回上一级。
 * @param msg 提示信息
 */
- (void)toastAndPop:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/**
 * 用户点击"结束控制"：断开连接并返回上一级。
 */
- (void)stopAndExit {
    self.stopRequested = YES;
    [self disconnectJS];
    [self.navigationController popViewControllerAnimated:YES];
}

/**
 * 显示设备配置面板（Phase 12.8）。
 * 功能：push TVNCSettingsViewController 展示完整设置页（8 个分组入口）。
 * 实现：TVNCSettingsViewController 读取/写入 NSUserDefaults（com.82flex.trollvnc suite），
 *      覆盖网关/直连/安全/性能等配置；用户调整后通过热重载机制生效。
 * 参数：无
 * 返回值：void
 */
- (void)showConfigPanel {
    TVNCSettingsViewController *settings = [[TVNCSettingsViewController alloc] init];
    [self.navigationController pushViewController:settings animated:YES];
}

@end
