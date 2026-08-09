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

#import "TVNCViewerViewController.h"
#import "TVNCSettingsViewController.h"

#import <WebKit/WebKit.h>

// X11 keysym 常量，供 sendKey 通过 JS 桥接下发到 noVNC
static const uint32_t kKeysymHome                = 0xff50;      // Home 键
static const uint32_t kKeysymPowerOff            = 0x1008ff2a;  // 电源键（XF86XK_PowerOff）
static const uint32_t kKeysymAudioRaiseVolume    = 0x1008ff13;  // 音量+
static const uint32_t kKeysymAudioLowerVolume    = 0x1008ff11;  // 音量−
static const uint32_t kKeysymAudioMute           = 0x1008ff12;  // 静音
static const uint32_t kKeysymMonBrightnessUp     = 0x1008ff03;  // 亮度+
static const uint32_t kKeysymMonBrightnessDown   = 0x1008ff05;  // 亮度−

// JS 桥接消息名（与 ViewerWeb.html 中 webkit.messageHandlers.viewer 对应）
static NSString *const kViewerBridgeName = @"viewer";

@interface TVNCViewerViewController () <WKScriptMessageHandler, WKNavigationDelegate>

@property(nonatomic, copy) NSString *host;
@property(nonatomic, assign) int port;
@property(nonatomic, copy) NSString *deviceName;

@property(nonatomic, strong) WKWebView *screenView;          // noVNC 画面容器（替代原 UIImageView）
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *gearBtn;               // 悬浮 ⚙（可拖动）
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
    }
    return self;
}

/**
 * 视图加载完成：搭建 WKWebView + 状态 UI + 悬浮菜单，并加载 ViewerWeb.html。
 */
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    [self setupWebView];

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

    [self loadViewerPage];
}

/**
 * 视图即将出现：隐藏导航栏以全屏显示画面。
 * @param animated 是否带动画
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

/**
 * 视图布局完成：首次放置悬浮 ⚙ 按钮到右下角。
 */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.gearPlaced) {
        self.gearPlaced = YES;
        CGFloat s = self.gearBtn.bounds.size.width;
        CGRect f = self.gearBtn.frame;
        f.origin.x = self.view.bounds.size.width - s - 16;
        f.origin.y = self.view.bounds.size.height - s - 56;
        self.gearBtn.frame = f;
    }
}

/**
 * 视图即将消失：恢复导航栏显示。
 * @param animated 是否带动画
 */
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
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
 * 构造 WebSocket URL。
 * Phase 7 隧道模式：useGatewayTunnel=YES 时返回 ws://<网关>:<8080>/ws/vnc/<deviceId>?token=<可选>，
 *   经网关桥接到设备 18181 隧道（跨网络访问）；此时 host/port 为网关地址与 HTTP 端口。
 * 直连模式：按 TrollVNC 约定 RFB 5901 → WS 5801（端口差 100），路径 /websockify（局域网）。
 * @return WebSocket URL 字符串
 */
- (NSString *)buildWebSocketURL {
    // Phase 7：隧道模式通过网关 8080 /ws/vnc/:deviceId 桥接隧道（跨网络）
    if (self.useGatewayTunnel && self.deviceId.length) {
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
    // 直连模式：RFB 端口 5901 → WebSocket 端口 5801（端口差 100），路径 /websockify
    int wsPort = self.port;
    if (wsPort >= 5900) {
        wsPort = wsPort - 100; // 5901(RFB) → 5801(WS)
    }
    return [NSString stringWithFormat:@"ws://%@:%d/websockify", self.host, wsPort];
}

/**
 * 在页面就绪后向 JS 注入连接参数，启动 noVNC 连接。
 */
- (void)startConnection {
    if (self.cleanedUp || self.stopRequested) return;
    NSString *wsURL = [self buildWebSocketURL];
    NSString *arg = [self jsStringLiteral:wsURL];
    NSString *js = [NSString stringWithFormat:@"connect(%@)", arg];
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
 * 调用 JS 端 sendKey(keysym, down) 下发一个按键事件。
 * @param keysym X11 keysym 值
 * @param down  YES=按下，NO=释放
 */
- (void)sendKey:(uint32_t)keysym down:(BOOL)down {
    NSString *js = [NSString stringWithFormat:@"sendKey(%lu, %@)",
                    (unsigned long)keysym, down ? @"true" : @"false"];
    [self evalJS:js];
}

/**
 * 调用 JS 端 pasteText(text) 向远端写入文本（剪贴板/文本输入）。
 * @param text 待发送文本
 */
- (void)pasteText:(NSString *)text {
    NSString *arg = [self jsStringLiteral:text];
    NSString *js = [NSString stringWithFormat:@"pasteText(%@)", arg];
    [self evalJS:js];
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

#pragma mark - 悬浮 ⚙（可拖动 + 竖排菜单）

/**
 * 创建悬浮 ⚙ 按钮及其拖动手势、能力菜单（FAB 风格）。
 * Phase 4.7 数据驱动改造：移除硬编码 ops 数组，改为通过网关 /api/devices/:id/caps
 * 拉取 capMetadata 后异步重建按 category 分组的 UIMenu；首次展示占位菜单（仅"结束控制"）。
 */
- (void)setupGearButton {
    CGFloat s = 52;
    self.gearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.gearBtn setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    self.gearBtn.tintColor = [UIColor whiteColor];
    self.gearBtn.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
    self.gearBtn.layer.cornerRadius = s / 2;
    self.gearBtn.layer.borderWidth = 1;
    self.gearBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.gearBtn.frame = CGRectMake(self.view.bounds.size.width - s - 16, self.view.bounds.size.height - s - 56, s, s);
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

#pragma mark - 能力元数据（数据驱动菜单）

/**
 * 通过网关 API GET /api/devices/:id/caps 拉取设备能力元数据（capMetadata）。
 * 隧道模式（useGatewayTunnel=YES）下使用 self.host/self.port/deviceId 调用网关；
 * 直连模式下无法调用网关 API，回调以 nil 返回（菜单仅显示"结束控制"）。
 * @param completion 完成回调（main queue），caps 为 capMetadata 数组；失败时为 nil
 */
- (void)fetchCapMetadata:(void (^)(NSArray<NSDictionary *> *caps))completion {
    if (!self.useGatewayTunnel || !self.deviceId.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
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
                NSString *title = cap[@"title"] ?: capId;
                NSString *iconName = cap[@"icon"] ?: @"";
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
 * 调用设备能力。隧道模式走网关 invoke API（POST /api/devices/:id/invoke）；
 * 直连模式回退到本地 keysym 映射（仅已知 hid 能力）或键盘/剪贴板专用流程。
 * @param capId  能力 ID（如 home/power/volup/keyboard/clipboard.paste 等）
 * @param params 调用参数字典（可为 nil，目前未使用）
 */
- (void)invokeCap:(NSString *)capId params:(NSDictionary *)params {
    if (!capId.length) return;
    // 直连模式回退：基于 capId 做本地分发
    if (!self.useGatewayTunnel || !self.deviceId.length) {
        NSInteger tag = [self tagForCapId:capId];
        if (tag >= 1 && tag <= 7) {
            [self performOp:tag]; // 已知 hid 能力，本地 sendKey
            return;
        }
        if (tag == 8) { [self keyboardTapped]; return; }
        if (tag == 9) { [self clipboardTapped]; return; }
        return; // 未知能力，直连模式无法处理
    }
    // 隧道模式：走网关 invoke API
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
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:nil] resume];
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

/**
 * 能力 ID → 本地整型 tag 映射（用于直连模式回退到 performOp/keyboardTapped/clipboardTapped）。
 * @param capId 能力 ID（home/power/volup/voldn/mute/briup/bridn/keyboard/clipboard）
 * @return 整型 tag（1~9）；未知返回 0
 */
- (NSInteger)tagForCapId:(NSString *)capId {
    if (!capId.length) return 0;
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"home":      @1,
            @"power":     @2,
            @"volup":     @3,
            @"voldn":     @4,
            @"mute":      @5,
            @"briup":     @6,
            @"bridn":     @7,
            @"keyboard":  @8,
            @"clipboard": @9,
            @"clipboard.paste": @9,
        };
    });
    NSNumber *n = m[capId];
    return n ? n.integerValue : 0;
}

/**
 * 能力菜单点击分发：键盘/剪贴板走专用流程，其余通过 sendKey 下发按键。
 * @param tag 操作标签（见 tagForOp:）
 */
- (void)menuOpTapped:(NSInteger)tag {
    if (tag == 8) { // 键盘
        [self keyboardTapped];
        return;
    }
    if (tag == 9) { // 剪贴板
        [self clipboardTapped];
        return;
    }
    [self performOp:tag];
}

#pragma mark - 操作映射

/**
 * 将操作标识字符串映射为整型 tag，便于菜单 handler 引用。
 * @param op 操作标识字符串
 * @return 整型 tag（1~9）
 */
- (NSInteger)tagForOp:(NSString *)op {
    if ([op isEqualToString:@"home"]) return 1;
    if ([op isEqualToString:@"power"]) return 2;
    if ([op isEqualToString:@"volup"]) return 3;
    if ([op isEqualToString:@"voldn"]) return 4;
    if ([op isEqualToString:@"mute"]) return 5;
    if ([op isEqualToString:@"briup"]) return 6;
    if ([op isEqualToString:@"bridn"]) return 7;
    if ([op isEqualToString:@"keyboard"]) return 8;
    if ([op isEqualToString:@"clipboard"]) return 9;
    return 0;
}

/**
 * 根据操作 tag 下发对应 keysym 按键（按下+释放），通过 JS 桥接注入 noVNC。
 * @param op 操作 tag（1=Home 2=电源 3=音量+ 4=音量− 5=静音 6=亮度+ 7=亮度−）
 */
- (void)performOp:(NSInteger)op {
    uint32_t keysym = 0;
    switch (op) {
        case 1: keysym = kKeysymHome; break;                // Home
        case 2: keysym = kKeysymPowerOff; break;            // 电源
        case 3: keysym = kKeysymAudioRaiseVolume; break;    // 音量+
        case 4: keysym = kKeysymAudioLowerVolume; break;    // 音量−
        case 5: keysym = kKeysymAudioMute; break;           // 静音
        case 6: keysym = kKeysymMonBrightnessUp; break;     // 亮度+
        case 7: keysym = kKeysymMonBrightnessDown; break;   // 亮度−
        default: return;
    }
    [self sendKey:keysym down:YES];
    [self sendKey:keysym down:NO];
}

/**
 * 弹出文本输入框，将用户输入作为按键序列发送到设备（v1 仅 ASCII 可见字符）。
 */
- (void)keyboardTapped {
    if (!self.connected) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"发送按键文本"
                                                               message:@"将文本作为按键发送到设备"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"输入要发送的文本";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        [weakSelf sendText:text];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/**
 * 将文本逐字符作为按键发送（ASCII 0x20~0x7E），通过 JS pasteText 下发。
 * @param text 待发送文本
 */
- (void)sendText:(NSString *)text {
    if (!text.length) return;
    NSMutableString *ascii = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch < 0x20 || ch > 0x7E) continue; // v1 仅 ASCII 可见字符
        [ascii appendFormat:@"%C", ch];
    }
    if (!ascii.length) return;
    [self pasteText:ascii];
}

/**
 * 弹出文本输入框，将内容写入设备剪贴板。
 */
- (void)clipboardTapped {
    if (!self.connected) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"写入设备剪贴板"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"粘贴要写入设备的内容";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"写入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        [weakSelf sendClipboard:text];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/**
 * 通过 JS pasteText 将文本写入远端剪贴板（noVNC clipboardPasteFrom）。
 * @param text 待写入剪贴板的文本
 */
- (void)sendClipboard:(NSString *)text {
    if (!text.length) return;
    [self pasteText:text];
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
