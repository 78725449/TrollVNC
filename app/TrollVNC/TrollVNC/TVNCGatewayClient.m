/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TVNCGatewayClient.h"

/// 网关 HTTP 控制台端口默认值（trollvnc-farm FARM_PORT）
static const NSInteger kGatewayDefaultConsolePort = 8080;
/// 配置 Suite（与全项目一致）
static NSString *const kGatewayDefaultsSuite = @"com.82flex.trollvnc";
/// 网关地址配置键
static NSString *const kGatewayHostKey = @"GatewayHost";
/// 网关 HTTP 端口配置键
static NSString *const kGatewayConsolePortKey = @"TVNCConsolePort";
/// 网关 Token 配置键
static NSString *const kGatewayTokenKey = @"GatewayToken";

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

/// 读取当前网关 HTTP 端口（未配置回退默认 8080）。
- (NSInteger)gatewayPort {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kGatewayDefaultsSuite];
    NSInteger port = [d integerForKey:kGatewayConsolePortKey];
    return (port > 0) ? port : kGatewayDefaultConsolePort;
}

/// 读取当前网关 Token（可为空字符串）。
- (nullable NSString *)gatewayToken {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kGatewayDefaultsSuite];
    return [d stringForKey:kGatewayTokenKey];
}

#pragma mark - 请求构造

/// 构造网关基础 URL：http://host:port/api/...（host 未配置返回 nil）。
- (nullable NSURL *)apiURLWithPath:(NSString *)path {
    NSString *host = [self gatewayHost];
    if (!host.length) return nil;
    NSInteger port = [self gatewayPort];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld%@", host, (long)port, path];
    return [NSURL URLWithString:urlStr];
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
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
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

- (void)fetchChangedDevicesSince:(NSTimeInterval)sinceMs
                      completion:(void (^)(NSArray<NSDictionary *> *_Nullable devices))completion {
    NSString *path = [NSString stringWithFormat:@"/api/devices?changedSince=%.0f", sinceMs];
    NSURL *url = [self apiURLWithPath:path];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(nil);
        }];
        return;
    }
    NSURLRequest *req = [self requestWithURL:url method:@"GET" body:nil];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray<NSDictionary *> *devices = nil;
        if (!err && data) {
            NSDictionary *json = [self parseJSONDictionary:data];
            id list = json[@"devices"];
            if ([list isKindOfClass:[NSArray class]]) devices = list;
        }
        [self dispatchOnMain:^{
            if (completion) completion(devices);
        }];
    }];
    [task resume];
}

- (void)invokeCap:(NSString *)capId
           params:(NSDictionary *_Nullable)params
        forDevice:(NSString *)deviceId
       completion:(void (^)(NSDictionary *_Nullable ack))completion {
    if (!capId.length || !deviceId.length) {
        [self dispatchOnMain:^{
            if (completion) completion(nil);
        }];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/devices/%@/invoke", deviceId];
    NSURL *url = [self apiURLWithPath:path];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(nil);
        }];
        return;
    }
    NSDictionary *body = @{@"cap": capId, @"params": params ?: @{}};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) {
        [self dispatchOnMain:^{
            if (completion) completion(nil);
        }];
        return;
    }
    NSURLRequest *req = [self requestWithURL:url method:@"POST" body:bodyData];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *ack = nil;
        if (!err && data) {
            NSDictionary *json = [self parseJSONDictionary:data];
            id a = json[@"ack"];
            if ([a isKindOfClass:[NSDictionary class]]) ack = a;
        }
        [self dispatchOnMain:^{
            if (completion) completion(ack);
        }];
    }];
    [task resume];
}

- (void)pingDevice:(NSString *)deviceId completion:(void (^)(NSTimeInterval ms))completion {
    if (!deviceId.length) {
        [self dispatchOnMain:^{
            if (completion) completion(-1);
        }];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/devices/%@/ping", deviceId];
    NSURL *url = [self apiURLWithPath:path];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(-1);
        }];
        return;
    }
    NSMutableURLRequest *req = [self requestWithURL:url method:@"POST" body:nil];
    req.timeoutInterval = 4.0;
    NSDate *t0 = [NSDate date];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSTimeInterval ms = -1;
        if (!err) {
            NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
            if (hr.statusCode == 200) ms = [[NSDate date] timeIntervalSinceDate:t0] * 1000;
        }
        [self dispatchOnMain:^{
            if (completion) completion(ms);
        }];
    }];
    [task resume];
}

- (void)fetchCapsForDevice:(NSString *)deviceId completion:(void (^)(NSArray<NSDictionary *> *_Nullable caps))completion {
    [self fetchDeviceCapsPath:[NSString stringWithFormat:@"/api/devices/%@/caps", deviceId]
                       field:@"capMetadata"
                  completion:completion];
}

- (void)fetchConfigSchemaForDevice:(NSString *)deviceId completion:(void (^)(NSArray<NSDictionary *> *_Nullable schema))completion {
    [self fetchDeviceCapsPath:[NSString stringWithFormat:@"/api/devices/%@/caps", deviceId]
                       field:@"configSchema"
                  completion:completion];
}

/// 拉取设备 /caps 端点指定字段（capMetadata / configSchema），失败 nil。
- (void)fetchDeviceCapsPath:(NSString *)path
                      field:(NSString *)field
                 completion:(void (^)(NSArray<NSDictionary *> *_Nullable list))completion {
    NSURL *url = [self apiURLWithPath:path];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(nil);
        }];
        return;
    }
    NSURLRequest *req = [self requestWithURL:url method:@"GET" body:nil];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *list = nil;
        if (!err && data) {
            NSDictionary *json = [self parseJSONDictionary:data];
            id m = json[field];
            if ([m isKindOfClass:[NSArray class]]) list = m;
        }
        [self dispatchOnMain:^{
            if (completion) completion(list);
        }];
    }];
    [task resume];
}

- (void)setConfig:(NSString *)key value:(NSString *)value forDevice:(NSString *)deviceId completion:(void (^)(BOOL ok))completion {
    if (!key.length || !deviceId.length) {
        [self dispatchOnMain:^{
            if (completion) completion(NO);
        }];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/devices/%@/config", deviceId];
    NSURL *url = [self apiURLWithPath:path];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(NO);
        }];
        return;
    }
    NSDictionary *body = @{@"key": key, @"value": value ?: @""};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) {
        [self dispatchOnMain:^{
            if (completion) completion(NO);
        }];
        return;
    }
    NSURLRequest *req = [self requestWithURL:url method:@"POST" body:bodyData];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        BOOL ok = (!err && ((NSHTTPURLResponse *)resp).statusCode == 200);
        [self dispatchOnMain:^{
            if (completion) completion(ok);
        }];
    }];
    [task resume];
}

@end
