/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TVNCGatewayClient.h"

#import <Security/Security.h>

/// 网关 HTTP 控制台端口（固定 8080 不可调，trollvnc-farm FARM_PORT）
static const NSInteger kGatewayDefaultConsolePort = 8080;
/// 配置 Suite（与全项目一致）
static NSString *const kGatewayDefaultsSuite = @"com.82flex.trollvnc";
/// 网关地址配置键
static NSString *const kGatewayHostKey = @"GatewayHost";
/// 网关 Token 配置键
static NSString *const kGatewayTokenKey = @"GatewayToken";

@interface TVNCGatewayClient () <NSURLSessionDelegate>
@end

@implementation TVNCGatewayClient

+ (instancetype)sharedClient {
    static TVNCGatewayClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - 配置（实时读取，设置是唯一默认源）

/// 读取当前网关地址（未配置返回 nil）。
- (nullable NSString *)gatewayHost {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kGatewayDefaultsSuite];
    return [d stringForKey:kGatewayHostKey];
}

/// 读取当前网关 HTTP 端口（固定 8080 不可调）。
- (NSInteger)gatewayPort {
    return kGatewayDefaultConsolePort;
}

/// 读取当前网关 Token（可为空字符串）。
- (nullable NSString *)gatewayToken {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kGatewayDefaultsSuite];
    return [d stringForKey:kGatewayTokenKey];
}

#pragma mark - 请求构造

/// 构造网关基础 URL：https://host:port/api/...（host 未配置返回 nil）。
/// 网关默认启用 https（自签证书，见 trollvnc-farm §2.3m）；证书信任由 tlsTrustingSession 的 challenge 处理。
- (nullable NSURL *)apiURLWithPath:(NSString *)path {
    NSString *host = [self gatewayHost];
    if (!host.length) return nil;
    NSInteger port = [self gatewayPort];
    NSString *urlStr = [NSString stringWithFormat:@"https://%@:%ld%@", host, (long)port, path];
    return [NSURL URLWithString:urlStr];
}

/// 懒加载 URLSession：信任网关自签证书（内网自签边界，与"无鉴权内网"设计一致）。
/// @return 带自签信任的 URLSession
- (NSURLSession *)tlsTrustingSession {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 6.0;
        session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    });
    return session;
}

/**
 * TLS 挑战处理：网关为内网自签证书，信任 serverTrust。
 * @param challenge 认证挑战
 * @param completionHandler 完成回调
 */
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
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

/// 构造通用请求：注入 Bearer Token 与 JSON 头。
/// @param url    目标 URL
/// @param method HTTP 方法（GET/POST）
/// @param body   请求体（GET 传 nil）
/// @return 配置完成的请求
- (NSMutableURLRequest *)requestWithURL:(NSURL *)url method:(NSString *)method body:(NSData *_Nullable)body {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 6.0;
    NSString *token = [self gatewayToken];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    if (body) {
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = body;
    }
    return req;
}

/// 在主线程派发回调（网络完成回调默认在后台线程）。
- (void)dispatchOnMain:(void (^)(void))block {
    if (block) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

/// 解析响应 JSON 为字典（非字典/解析失败返回 nil）。
- (NSDictionary *)parseJSONDictionary:(NSData *)data {
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

#pragma mark - Public API

- (void)fetchDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *_Nullable, NSError *_Nullable))completion {
    NSURL *url = [self apiURLWithPath:@"/api/devices"];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(nil, [NSError errorWithDomain:@"TVNCGateway" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"未配置网关地址"}]);
        }];
        return;
    }
    NSURLRequest *req = [self requestWithURL:url method:@"GET" body:nil];
    NSURLSessionDataTask *task = [[self tlsTrustingSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray<NSDictionary *> *devices = nil;
        if (!err && data) {
            NSDictionary *json = [self parseJSONDictionary:data];
            id list = json[@"devices"];
            if ([list isKindOfClass:[NSArray class]]) devices = list;
        }
        [self dispatchOnMain:^{
            if (completion) completion(devices, err);
        }];
    }];
    [task resume];
}

@end
