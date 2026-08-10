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

#import "TRWallTileWebView.h"

/// JS 桥接消息名（与 WallTileWeb.html 中 webkit.messageHandlers.wallTile 对应）
static NSString *const kWallTileBridgeName = @"wallTile";

/// 共享 WKProcessPool（减少 noVNC 模块加载开销）
static WKProcessPool *sharedProcessPool = nil;

@interface TRWallTileWebView () <WKScriptMessageHandler, WKNavigationDelegate>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign, readwrite) TRWallTileState state;
@property (nonatomic, copy, nullable) NSString *deviceId;        // 当前连接目标设备 ID
@property (nonatomic, copy, nullable) NSString *pendingWSURL;  // 等待页面就绪后注入的 WS URL
@property (nonatomic, assign) BOOL pageReady;                  // WallTileWeb.html 是否已就绪
@property (nonatomic, assign) BOOL stopped;                    // 是否已主动停止
@property (nonatomic, assign) BOOL handlerRegistered;          // messageHandler 是否已注册

@end

@implementation TRWallTileWebView

#pragma mark - 初始化

/**
 * 初始化卡片墙 WebView：创建共享 ProcessPool 的 WKWebView，加载 WallTileWeb.html。
 * @param frame 初始 frame
 * @return 实例
 */
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _state = TRWallTileStateIdle;
        _frameInterval = 0;
        _pageReady = NO;
        _stopped = NO;
        _handlerRegistered = NO;
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor blackColor];

        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sharedProcessPool = [[WKProcessPool alloc] init];
        });

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.processPool = sharedProcessPool;

        WKPreferences *prefs = [[WKPreferences alloc] init];
        [prefs setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
        [prefs setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"];
        config.preferences = prefs;

        WKUserContentController *ucc = [[WKUserContentController alloc] init];
        [ucc addScriptMessageHandler:self name:kWallTileBridgeName];
        config.userContentController = ucc;
        _handlerRegistered = YES;

        _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        _webView.translatesAutoresizingMaskIntoConstraints = NO;
        _webView.navigationDelegate = self;
        _webView.backgroundColor = [UIColor blackColor];
        _webView.opaque = NO;
        _webView.scrollView.scrollEnabled = NO;
        _webView.scrollView.bounces = NO;
        _webView.userInteractionEnabled = NO;
        [self addSubview:_webView];

        [NSLayoutConstraint activateConstraints:@[
            [_webView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_webView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_webView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_webView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        [self loadWallTilePage];
    }
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    return nil;
}

/**
 * 加载 bundle 内的 WallTileWeb.html。
 */
- (void)loadWallTilePage {
    NSURL *htmlURL = [[NSBundle mainBundle] URLForResource:@"WallTileWeb" withExtension:@"html"];
    if (!htmlURL) {
        NSLog(@"[TRWallTileWebView] WallTileWeb.html not found in bundle");
        self.state = TRWallTileStateFailed;
        return;
    }
    NSURL *baseURL = [[NSBundle mainBundle] bundleURL];
    [_webView loadFileURL:htmlURL allowingReadAccessToURL:baseURL];
}

#pragma mark - 连接管理

/**
 * 启动 RFB 连接：构造 WS URL（隧道优先，直连回退）并注入到 JS 桥接页面。
 * 页面未就绪时暂存 URL，等待 ready 消息后自动注入；页面已就绪则直接注入。
 */
- (void)startWithDeviceId:(NSString *)deviceId
              gatewayHost:(nullable NSString *)gatewayHost
              gatewayPort:(NSInteger)gatewayPort
                    token:(nullable NSString *)token
                     host:(nullable NSString *)host
                     port:(int)port {
    self.stopped = NO;
    self.deviceId = deviceId;

    // 构造 WS URL
    NSString *wsURL = nil;
    if (gatewayHost.length && deviceId.length) {
        NSString *url = [NSString stringWithFormat:@"ws://%@:%ld/ws/vnc/%@",
                         gatewayHost, (long)gatewayPort, deviceId];
        if (token.length) {
            NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLQueryAllowedCharacterSet]];
            url = [url stringByAppendingFormat:@"?token=%@", encoded];
        }
        wsURL = url;
    }
    if (!wsURL && host.length > 0) {
        int wsPort = port;
        if (wsPort >= 5900) wsPort = wsPort - 100;
        wsURL = [NSString stringWithFormat:@"ws://%@:%d/websockify", host, wsPort];
    }

    if (!wsURL) {
        self.state = TRWallTileStateFailed;
        if (self.onStateChange) self.onStateChange(self.state);
        return;
    }

    self.pendingWSURL = wsURL;
    self.state = TRWallTileStateConnecting;

    // 页面已就绪，直接注入连接
    if (self.pageReady) {
        [self injectConnect:wsURL];
    }
    // 否则等待 ready 消息后自动注入（pendingWSURL 已保存）
}

/**
 * 向 JS 注入 connect 调用。
 * @param wsURL WebSocket URL
 */
- (void)injectConnect:(NSString *)wsURL {
    if (self.stopped) return;
    NSString *arg = [self jsStringLiteral:wsURL];
    NSString *js = [NSString stringWithFormat:@"connect(%@)", arg];
    [self evalJS:js];
    // 连接成功后设置帧率节流
    if (self.frameInterval > 0) {
        NSString *fps = [NSString stringWithFormat:@"setFrameRate(%ld)", (long)self.frameInterval];
        [self evalJS:fps];
    }
}

/**
 * 断开 RFB 连接（保留 WebView 供复用）。
 * 调用后 state 变为 Idle；页面 JS 上下文仍存活（pageReady 保持 YES），
 * 下次 start 可直接注入 connect，无需重新等待 ready。
 */
- (void)stop {
    if (self.webView) {
        // 直接下发 disconnect（不走 evalJS，避免被 stopped 检查拦截）
        [self.webView evaluateJavaScript:@"disconnect()" completionHandler:nil];
    }
    self.stopped = YES;
    self.state = TRWallTileStateIdle;
    self.pendingWSURL = nil;
}

/**
 * 清理并卸载 WebView（dealloc 时调用，不可复用）。
 */
- (void)cleanup {
    WKWebView *wv = self.webView;
    if (wv) {
        [wv evaluateJavaScript:@"disconnect()" completionHandler:nil];
        if (self.handlerRegistered) {
            [wv.configuration.userContentController removeScriptMessageHandlerForName:kWallTileBridgeName];
            self.handlerRegistered = NO;
        }
        [wv stopLoading];
        [wv loadHTMLString:@"" baseURL:nil];
    }
    self.stopped = YES;
    self.state = TRWallTileStateIdle;
    self.pendingWSURL = nil;
    self.pageReady = NO;
}

/**
 * 设置帧率节流间隔，通过 JS 注入到 noVNC 桥接页面。
 * @param interval 间隔毫秒数，0=不限制
 */
- (void)setFrameRate:(NSInteger)interval {
    _frameInterval = interval;
    NSString *js = [NSString stringWithFormat:@"setFrameRate(%ld)", (long)interval];
    [self evalJS:js];
}

#pragma mark - JS 桥接（JS → OC）

/**
 * 接收 WallTileWeb.html 通过 webkit.messageHandlers.wallTile 上报的状态消息。
 */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kWallTileBridgeName]) return;
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    if (!body) return;
    NSString *type = body[@"type"];

    if ([type isEqualToString:@"ready"]) {
        // 页面就绪：若有待注入的 WS URL，立即发起连接
        self.pageReady = YES;
        if (self.pendingWSURL.length && !self.stopped) {
            [self injectConnect:self.pendingWSURL];
        }
    } else if ([type isEqualToString:@"connected"]) {
        self.state = TRWallTileStateConnected;
        // 连接成功后若已设帧率节流，重发一次
        if (self.frameInterval > 0) {
            [self setFrameRate:self.frameInterval];
        }
        if (self.onStateChange) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onStateChange(self.state);
            });
        }
    } else if ([type isEqualToString:@"disconnected"]) {
        if (!self.stopped) {
            self.state = TRWallTileStateIdle;
            if (self.onStateChange) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.onStateChange(self.state);
                });
            }
        }
    } else if ([type isEqualToString:@"failed"]) {
        self.state = TRWallTileStateFailed;
        if (self.onStateChange) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onStateChange(self.state);
            });
        }
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error {
    NSLog(@"[TRWallTileWebView] page load failed: %@", error.localizedDescription);
    self.state = TRWallTileStateFailed;
    if (self.onStateChange) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onStateChange(self.state);
        });
    }
}

#pragma mark - JS 桥接（OC → JS）

/**
 * 执行一段 JavaScript。
 * @param script 待执行的 JS 代码
 */
- (void)evalJS:(NSString *)script {
    if (self.stopped || !script.length) return;
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

/**
 * 将任意字符串转换为合法的 JS 字符串字面量。
 * @param s 原始字符串
 * @return 形如 "ws://host:5801/websockify" 的 JS 字面量
 */
- (NSString *)jsStringLiteral:(NSString *)s {
    if (!s) return @"\"\"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
    if (!d) return @"\"\"";
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (arr.length < 2) return @"\"\"";
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

#pragma mark - 清理

- (void)dealloc {
    [self cleanup];
}

@end