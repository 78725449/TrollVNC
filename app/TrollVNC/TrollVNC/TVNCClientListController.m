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

#import "TVNCClientListController.h"
#import "TVNCClientCell.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#pragma mark - Networking

// Placeholder item id used when there are no clients
static NSString *const kTVNCEmptyItemId = @"__empty__";
static NSString *const kTVNCFrozenHostsKey = @"TVNCFrozenHosts";
static NSString *const kTVNCDefaultsSuite = @"com.82flex.trollvnc";

static inline BOOL TVNCIsEmptyItemId(NSString *_Nullable itemId) {
    return itemId != nil && [itemId isEqualToString:kTVNCEmptyItemId];
}

// ===== 5901 RFB 扩展消息客户端（与 TRCapabilityRegistry._rfbCommand 协议对齐）=====
static const int kTVNCControlRfbPort = 5901;

/**
 * 建立 5901 连接并完成 RFB 3.8 握手 + cap.hello 管理豁免
 * 功能：连接 127.0.0.1:5901，完成 ProtocolVersion → Security → ClientInit → ServerInit 握手，
 *       随后发送 cap.hello（mgmt=YES）将本连接标记为管理客户端（豁免客户端计数/帧推送/互斥）。
 *       帧格式与 TRCapabilityRegistry tvRfbConnect 完全对齐（0x50 请求 / 8 字节大端头）。
 * 参数：无
 * 返回值：int - 成功返回已就绪的 fd；任一步失败返回 -1（内部已 close）
 */
static int TVNCControlConnect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTVNCControlRfbPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    // --- RFB 3.8 握手（与 TRCapabilityRegistry tvRfbConnect 对齐）---
    char buf[256];
    ssize_t n = recv(fd, buf, 12, MSG_WAITALL);
    if (n != 12 || strncmp(buf, "RFB", 3) != 0) { close(fd); return -1; }
    send(fd, "RFB 003.008\n", 12, 0);
    uint8_t secCount = 0;
    if (recv(fd, &secCount, 1, MSG_WAITALL) != 1) { close(fd); return -1; }
    if (secCount > 0) {
        uint8_t secTypes[32] = {0};
        if (secCount > sizeof(secTypes)) secCount = (uint8_t)sizeof(secTypes);  // clamp 防越界
        if (recv(fd, secTypes, secCount, MSG_WAITALL) != secCount) { close(fd); return -1; }
        uint8_t chosen = 1;  // None
        if (send(fd, &chosen, 1, 0) != 1) { close(fd); return -1; }
        uint32_t secResult = 0;
        if (recv(fd, &secResult, 4, MSG_WAITALL) != 4) { close(fd); return -1; }
        if (ntohl(secResult) != 0) { close(fd); return -1; }
    }
    uint8_t shared = 1;
    send(fd, &shared, 1, 0);
    uint8_t initBuf[24];
    if (recv(fd, initBuf, 24, MSG_WAITALL) != 24) { close(fd); return -1; }
    uint32_t nameLen = 0;
    memcpy(&nameLen, initBuf + 20, 4);
    nameLen = ntohl(nameLen);
    if (nameLen > 0 && nameLen < sizeof(buf)) recv(fd, buf, nameLen, MSG_WAITALL);
    // cap.hello：标记为管理客户端（豁免计数/帧推送/互斥）
    NSDictionary *hello = @{@"op": @"cap.hello", @"params": @{@"mgmt": @YES}};
    NSData *helloJson = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    if (!helloJson) { close(fd); return -1; }
    uint8_t hdr[8];
    hdr[0] = 0x50;
    memset(hdr + 1, 0, 3);
    uint32_t helloLen = htonl((uint32_t)helloJson.length);
    memcpy(hdr + 4, &helloLen, 4);
    if (send(fd, hdr, 8, 0) != 8) { close(fd); return -1; }
    if (send(fd, helloJson.bytes, helloJson.length, 0) != (ssize_t)helloJson.length) { close(fd); return -1; }
    uint8_t respHdr[8];
    if (recv(fd, respHdr, 8, MSG_WAITALL) != 8 || respHdr[0] != 0x80) { close(fd); return -1; }
    uint32_t respLen = 0;
    memcpy(&respLen, respHdr + 4, 4);
    respLen = ntohl(respLen);
    if (respLen > 0 && respLen < sizeof(buf)) recv(fd, buf, respLen, MSG_WAITALL);
    return fd;
}

/**
 * 发送扩展消息并读取 JSON 响应
 * 功能：以 {op, params} 封装为 0x50 帧发送到 5901，读取 0x80 帧解析 JSON 响应。
 *       每次调用新建连接（本地回环开销可忽略；与 TRCapabilityRegistry._rfbCommand 帧格式对齐）。
 * 参数：op     - 扩展操作名（如 "clients.list" / "clients.block"）
 *       params - 请求参数字典（可为空）
 * 返回值：NSDictionary* - 服务端 JSON 响应字典（含 ok 字段）；连接/解析失败返回 nil
 */
static NSDictionary *TVNCControlInvoke(NSString *op, NSDictionary *params) {
    int fd = TVNCControlConnect();
    if (fd < 0) return nil;
    NSDictionary *req = @{@"op": op ?: @"", @"params": params ?: @{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:req options:0 error:nil];
    if (!json) { close(fd); return nil; }
    uint8_t hdr[8];
    hdr[0] = 0x50;
    memset(hdr + 1, 0, 3);
    uint32_t len = htonl((uint32_t)json.length);
    memcpy(hdr + 4, &len, 4);
    if (send(fd, hdr, 8, 0) != 8 || send(fd, json.bytes, json.length, 0) != (ssize_t)json.length) { close(fd); return nil; }
    uint8_t respHdr[8];
    ssize_t n = recv(fd, respHdr, 8, MSG_WAITALL);
    if (n != 8 || respHdr[0] != 0x80) { close(fd); return nil; }
    uint32_t respLen = 0;
    memcpy(&respLen, respHdr + 4, 4);
    respLen = ntohl(respLen);
    if (respLen == 0 || respLen > 1024 * 1024) { close(fd); return nil; }
    NSMutableData *respData = [NSMutableData dataWithLength:respLen];
    if (recv(fd, respData.mutableBytes, respLen, MSG_WAITALL) != (ssize_t)respLen) { close(fd); return nil; }
    close(fd);
    return [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
}

#pragma mark - Private Interface

@interface TVNCClientListController ()

@property(nonatomic, strong) UIBarButtonItem *dismissItem;
@property(nonatomic, strong) UIBarButtonItem *disconnectItem;

@property(nonatomic, strong) UITableViewDiffableDataSource<NSString *, NSString *> *dataSource; // section -> itemId
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *clientLookup;     // id -> dict
@property(nonatomic, strong) NSMutableSet<NSString *> *frozenHosts;                                   // 冻结 host 集合（持久化）

// 5901 RFB 控制通道状态
@property(nonatomic, assign) BOOL controlAvailable;                 // 控制服务可达（clients.list 探测结果）
@property(nonatomic, strong) NSTimer *pollTimer;                    // 列表轮询定时器（原订阅推送的替代）

@end

#pragma mark - Implementation

@implementation TVNCClientListController

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.embedded) {
        // 嵌入卡片：隐藏导航/下拉刷新，透明背景融入卡片
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tableView.alwaysBounceVertical = NO;
        self.tableView.scrollEnabled = YES;
    } else {
        self.title = NSLocalizedStringFromTableInBundle(@"Clients", @"Localizable", self.bundle, nil);

        UIRefreshControl *refreshControl = [UIRefreshControl new];
        [refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
        self.refreshControl = refreshControl;

        // 对齐 mockup：右上角「全部断开」（嵌入 Tab，无 dismiss 语义）
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItem = self.disconnectItem;
    }

    // Diffable data source
    self.clientLookup = [NSMutableDictionary new];
    __weak typeof(self) weakSelf = self;
    self.dataSource = [[UITableViewDiffableDataSource alloc]
        initWithTableView:self.tableView
             cellProvider:^UITableViewCell *_Nullable(UITableView *tableView, NSIndexPath *indexPath,
                                                      NSString *identifier) {
                 return [weakSelf cellForTableView:tableView indexPath:indexPath itemId:identifier];
             }];

    // Initial empty snapshot with one section
    NSDiffableDataSourceSnapshot<NSString *, NSString *> *empty = [NSDiffableDataSourceSnapshot new];
    [empty appendSectionsWithIdentifiers:@[ @"main" ]];
    [self.dataSource applySnapshot:empty animatingDifferences:NO];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self startPolling];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPolling];
}

- (void)dealloc {
    [self stopPolling];
}

/**
 * 启动列表轮询定时器
 * 功能：每 5 秒调用一次 refresh 拉取 clients.list（替代原订阅长连接推送）。
 * 参数：无
 * 返回值：void
 */
- (void)startPolling {
    if (self.pollTimer)
        return;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                      target:self
                                                    selector:@selector(refresh)
                                                    userInfo:nil
                                                     repeats:YES];
    // 滚动等 UI 事件期间也保持轮询（可选，保持列表实时性）
    // UITrackingRunLoopCommonModes 为 iOS15+ 常量（iOS14.5 SDK 无声明），用字面量兼容（运行时不存在的 mode 仅不生效，无害）
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:@"UITrackingRunLoopCommonModes"];
}

/**
 * 停止列表轮询定时器
 * 功能：视图消失或控制器销毁时释放定时器，避免后台空轮询。
 * 参数：无
 * 返回值：void
 */
- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

#pragma mark - Getters

- (UIBarButtonItem *)dismissItem {
    if (!_dismissItem) {
        _dismissItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                     target:self
                                                                     action:@selector(dismiss)];
    }
    return _dismissItem;
}

- (UIBarButtonItem *)disconnectItem {
    if (!_disconnectItem) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Disconnect All", @"Localizable", self.bundle, nil);
        _disconnectItem = [[UIBarButtonItem alloc] initWithTitle:title
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(disconnectAll)];
        _disconnectItem.tintColor = self.primaryColor;
        _disconnectItem.enabled = NO;
    }
    return _disconnectItem;
}

#pragma mark - Actions

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh {
    [self reloadDataFromServer];
}

// Removed index-based disconnect; use -disconnectClientWithId:block: instead.

/**
 * 断开单个客户端（可选加黑名单）
 * 功能：经 5901 RFB 扩展消息执行 clients.block（断连+黑名单）或 clients.disconnect（仅断连）。
 * 参数：cid        - 客户端 ID（8 字符）
 *       shouldBlock - YES 走 clients.block（断开+临时黑名单）；NO 走 clients.disconnect
 * 返回值：void
 */
- (void)disconnectClientWithId:(NSString *)cid block:(BOOL)shouldBlock {
    if (cid.length == 0)
        return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = shouldBlock ? TVNCControlInvoke(@"clients.block", @{@"id": cid})
                                         : TVNCControlInvoke(@"clients.disconnect", @{@"id": cid});
        (void)resp; // 失败静默（与旧行为一致：连不上不提示）

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

/**
 * 断开全部客户端
 * 功能：经 5901 RFB 扩展消息执行 clients.disconnect（id=ALL）。
 * 参数：无
 * 返回值：void
 */
- (void)disconnectAll {
    [self.disconnectItem setEnabled:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = TVNCControlInvoke(@"clients.disconnect", @{@"id": @"ALL"});
        (void)resp; // 失败静默

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

#pragma mark - 冻结 / 解冻

- (NSUserDefaults *)frozenDefaults {
    return [[NSUserDefaults alloc] initWithSuiteName:kTVNCDefaultsSuite];
}

- (NSMutableSet<NSString *> *)frozenHosts {
    if (!_frozenHosts) {
        NSArray *arr = [[self frozenDefaults] arrayForKey:kTVNCFrozenHostsKey] ?: @[];
        _frozenHosts = [NSMutableSet setWithArray:arr];
    }
    return _frozenHosts;
}

- (void)persistFrozenHosts {
    [[self frozenDefaults] setObject:[self.frozenHosts allObjects] forKey:kTVNCFrozenHostsKey];
    [[self frozenDefaults] synchronize];
}

- (BOOL)isHostFrozen:(NSString *)host {
    if (!host.length)
        return NO;
    return [self.frozenHosts containsObject:host];
}

- (void)freezeClientWithId:(NSString *)cid {
    if (cid.length == 0)
        return;
    NSDictionary *c = self.clientLookup[cid];
    NSString *host = c[@"host"] ?: @"";
    if (host.length) {
        [self.frozenHosts addObject:host];
        [self persistFrozenHosts];
    }
    // block = 断开 + 服务器临时黑名单（本机记录保证离线仍显示灰色）
    [self disconnectClientWithId:cid block:YES];
}

/**
 * 解冻主机
 * 功能：本地 frozenHosts 记录移除 + 经 5901 RFB 扩展消息执行 clients.unblock（host）。
 * 参数：host - 待解封的主机地址
 * 返回值：void
 */
- (void)unfreezeHost:(NSString *)host {
    if (!host.length)
        return;
    [self.frozenHosts removeObject:host];
    [self persistFrozenHosts];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = TVNCControlInvoke(@"clients.unblock", @{@"host": host});
        (void)resp; // 失败静默（host 不在黑名单时服务端返回 ok:NO，属正常）

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

- (void)refreshNow {
    [self refresh];
}

- (void)disconnectAllClients {
    [self disconnectAll];
}

#pragma mark - Helpers (Cells)

- (UITableViewCell *)cellForTableView:(UITableView *)tableView
                            indexPath:(NSIndexPath *)indexPath
                               itemId:(NSString *)identifier {
    if (TVNCIsEmptyItemId(identifier)) {
        return [self dequeuePlaceholderCellForTableView:tableView];
    }
    return [self dequeueClientCellForTableView:tableView itemId:identifier];
}

- (UITableViewCell *)dequeuePlaceholderCellForTableView:(UITableView *)tableView {
    static NSString *const kEmptyReuse = @"TVNCEmptyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEmptyReuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kEmptyReuse];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.numberOfLines = 0;
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = nil;
    }
    cell.textLabel.text = @"暂无客户端连接";
    return cell;
}

- (UITableViewCell *)dequeueClientCellForTableView:(UITableView *)tableView itemId:(NSString *)identifier {
    TVNCClientCell *cell = (TVNCClientCell *)[tableView dequeueReusableCellWithIdentifier:@"TVNCClientCell"];
    if (!cell) {
        cell = [[TVNCClientCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"TVNCClientCell"];
        cell.bundle = self.bundle;
    }
    cell.backgroundColor = [UIColor clearColor];

    NSDictionary *c = self.clientLookup[identifier] ?: @{};
    NSString *cid = c[@"id"] ?: identifier ?: @"";
    NSString *host = c[@"host"] ?: @"";
    BOOL frozen = [[c objectForKey:@"frozen"] boolValue] || [self isHostFrozen:host];

    if (frozen) {
        // 冻结行：灰色，主行显示 host，副行提示解冻
        [cell configureWithId:host host:@"已冻结" viewOnly:NO subtitle:@"冻结中 · 右滑解冻" primaryColor:nil];
        cell.idLabel.textColor = [UIColor secondaryLabelColor];
        cell.hostLabel.textColor = [UIColor systemOrangeColor];
        cell.subtitleLabel.textColor = [UIColor tertiaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.alpha = 0.85;
        return cell;
    }

    BOOL vo = [[c objectForKey:@"viewOnly"] boolValue] || [[c objectForKey:@"viewOnly"] isEqual:@"1"];
    double dur = [[c objectForKey:@"durationSec"] doubleValue];

    static NSRelativeDateTimeFormatter *sFmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sFmt = [NSRelativeDateTimeFormatter new];
        sFmt.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    });

    NSString *rel = [sFmt localizedStringFromTimeInterval:-dur];
    NSString *subtitle = [NSString
        stringWithFormat:NSLocalizedStringFromTableInBundle(@"Connected %@", @"Localizable", self.bundle, nil),
                         rel ?: @"-"];

    [cell configureWithId:cid host:host viewOnly:vo subtitle:subtitle primaryColor:self.primaryColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.alpha = 1.0;
    return cell;
}

#pragma mark - Helpers (Networking)

- (void)applyRows:(NSArray<NSDictionary *> *)rows {
    [self.clientLookup removeAllObjects];

    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:rows.count];
    NSMutableSet<NSString *> *seenHosts = [NSMutableSet set];
    NSInteger onlineCount = 0;
    for (NSDictionary *item in rows) {
        NSString *cid = item[@"id"] ?: @"";
        if (!cid.length)
            continue;
        onlineCount++;
        self.clientLookup[cid] = item;
        [ids addObject:cid];
        NSString *host = item[@"host"] ?: @"";
        if (host.length)
            [seenHosts addObject:host];
    }

    // 合并冻结客户端：断开/离线后仍显示，灰色
    for (NSString *host in [[self.frozenHosts allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if ([seenHosts containsObject:host])
            continue; // 已在线（如服务重启后黑名单清空），行内按 host 判定冻结样式
        NSString *fid = [@"frozen:" stringByAppendingString:host];
        self.clientLookup[fid] = @{ @"id" : fid, @"host" : host, @"frozen" : @YES };
        [ids addObject:fid];
    }

    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snap = [NSDiffableDataSourceSnapshot new];
    [snap appendSectionsWithIdentifiers:@[ @"main" ]];
    if (ids.count == 0) {
        [snap appendItemsWithIdentifiers:@[ kTVNCEmptyItemId ] intoSectionWithIdentifier:@"main"];
    } else {
        [snap appendItemsWithIdentifiers:ids intoSectionWithIdentifier:@"main"];
        [snap reloadItemsWithIdentifiers:ids]; // force reconfigure for content changes
    }

    [self.dataSource applySnapshot:snap animatingDifferences:YES];
    [self.disconnectItem setEnabled:(ids.count > 0)];

    if (self.onCountChange) {
        self.onCountChange(onlineCount, (NSInteger)self.frozenHosts.count);
    }
}

/**
 * 从服务端拉取客户端列表
 * 功能：后台队列经 5901 RFB 扩展消息执行 clients.list，成功后取 resp[@"clients"]（JSON 数组，
 *       元素含 id/host/viewOnly/connectedAt/durationSec）回主线程 applyRows。
 *       同时刷新 controlAvailable 状态（成功 YES / 失败 NO），供右滑能力判定。
 * 参数：无
 * 返回值：void
 */
- (void)reloadDataFromServer {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = TVNCControlInvoke(@"clients.list", nil);
        NSArray<NSDictionary *> *rows = nil;
        BOOL ok = [resp isKindOfClass:[NSDictionary class]] && [resp[@"ok"] boolValue];
        if (ok) {
            id clients = resp[@"clients"];
            if ([clients isKindOfClass:[NSArray class]])
                rows = clients;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.controlAvailable = ok;
            [self.refreshControl endRefreshing];
            [self applyRows:rows ?: @[]];
        });
    });
}

#pragma mark - Table

// Diffable data source drives cells; no need to implement UITableViewDataSource methods here.

/**
 * 表格右滑操作配置（trailing swipe，手指从右向左滑，揭示右侧操作按钮）。
 * 功能：依据当前行的客户端状态（在线 / 冻结）返回对应右滑按钮：
 *   - 在线行：冻结🟠（橙色）+ 断开🔴（红色 destructive）
 *   - 冻结行：仅解冻🟢（绿色）
 *   - 控制服务未连接（能力不可用）：返回"能力不可用"按钮，点击弹提示，不执行动作
 * 参数：tableView  - 表格视图
 *       indexPath - 行索引
 * 返回值：UISwipeActionsConfiguration* - 右滑按钮配置；nil 表示无操作
 */
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {

    NSString *itemId = [self.dataSource itemIdentifierForIndexPath:indexPath];
    if ([itemId isEqualToString:kTVNCEmptyItemId])
        return nil;

    // 检查 clients.freeze/unfreeze/disconnect 能力是否可用：
    // IPA 端无法直接访问 TRCapabilityRegistry，但底层 freeze/unfreeze/disconnect
    // 均经 5901 RFB 扩展消息执行；controlAvailable 由 clients.list 探测结果驱动
    BOOL capabilityAvailable = self.controlAvailable;

    if (!capabilityAvailable) {
        // 能力不可用：仅显示一个禁用样式的提示按钮，点击弹 toast，不执行实际动作
        __weak typeof(self) weakSelf = self;
        UIContextualAction *unavail = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:@"能力不可用"
                              handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView,
                                        void (^completionHandler)(BOOL)) {
                                  [weakSelf showCapabilityUnavailableHint];
                                  if (completionHandler)
                                      completionHandler(NO);  // 不收起按钮，便于用户继续查看提示
                              }];
        unavail.backgroundColor = [UIColor systemGrayColor];
        UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[ unavail ]];
        cfg.performsFirstActionWithFullSwipe = NO;
        return cfg;
    }

    __weak typeof(self) weakSelf = self;
    NSDictionary *c = self.clientLookup[itemId] ?: @{};
    NSString *host = c[@"host"] ?: @"";
    BOOL frozen = [[c objectForKey:@"frozen"] boolValue] || [self isHostFrozen:host];

    if (frozen) {
        // 冻结行：仅「解冻」🟢（绿色），调用 clients.unfreeze 能力
        UIContextualAction *unfreeze = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:@"解冻"
                              handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView,
                                        void (^completionHandler)(BOOL)) {
                                  NSString *h = weakSelf.clientLookup[itemId][@"host"] ?: @"";
                                  [weakSelf unfreezeHost:h];
                                  if (completionHandler)
                                      completionHandler(YES);
                              }];
        unfreeze.backgroundColor = [UIColor systemGreenColor];
        UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[ unfreeze ]];
        cfg.performsFirstActionWithFullSwipe = NO;
        return cfg;
    }

    // 在线行：「冻结」🟠（橙色）+ 「断开」🔴（红色 destructive）
    // 冻结：调用 clients.freeze 能力（本地命令 block = 断开 + 临时黑名单，行变灰不清除）
    UIContextualAction *freeze = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"冻结"
                          handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                              NSString *cid = [weakSelf.dataSource itemIdentifierForIndexPath:indexPath] ?: @"";
                              [weakSelf freezeClientWithId:cid];
                              if (completionHandler)
                                  completionHandler(YES);
                          }];
    freeze.backgroundColor = [UIColor systemOrangeColor];

    // 断开：调用 clients.disconnect 能力（断开后卡片自动从列表清除）
    UIContextualAction *kick = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"断开"
                          handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                              NSString *cid = [weakSelf.dataSource itemIdentifierForIndexPath:indexPath] ?: @"";
                              [weakSelf disconnectClientWithId:cid block:NO];
                              if (completionHandler)
                                  completionHandler(YES);
                          }];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[ freeze, kick ]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

/**
 * 显示"能力不可用"提示弹窗（toast 风格）。
 * 功能：当 5901 RFB 控制服务不可达（clients.freeze/unfreeze/disconnect 能力实质不可用）时，
 *       弹出短暂提示告知用户，1.2 秒后自动消失。
 * 参数：无
 * 返回值：void
 */
- (void)showCapabilityUnavailableHint {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                    message:@"能力不可用（控制服务未连接）"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.dataSource) {
        NSString *itemId = [self.dataSource itemIdentifierForIndexPath:indexPath];
        if ([itemId isEqualToString:kTVNCEmptyItemId]) {
            return 180;
        }
    }
    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *itemId = [self.dataSource itemIdentifierForIndexPath:indexPath];
    if ([itemId isEqualToString:kTVNCEmptyItemId])
        return NO;
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// iOS 14 min: Provide long-press context menu with copy actions
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
    NSString *cid = [self.dataSource itemIdentifierForIndexPath:indexPath];
    if ([cid isEqualToString:kTVNCEmptyItemId])
        return nil;
    if (cid.length == 0)
        return nil;

    NSString *host = self.clientLookup[cid][@"host"] ?: @"";
    BOOL frozen = [cid hasPrefix:@"frozen:"] || [self isHostFrozen:host];
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu *_Nullable(NSArray<UIMenuElement *> *_Nonnull suggestedActions) {
                         UIAction *copyHost = [UIAction
                             actionWithTitle:NSLocalizedStringFromTableInBundle(@"Copy Host", @"Localizable",
                                                                                self.bundle, nil)
                                       image:[UIImage systemImageNamed:@"globe"]
                                  identifier:nil
                                     handler:^(__kindof UIAction *_Nonnull action) {
                                         [UIPasteboard generalPasteboard].string = host;
                                         UINotificationFeedbackGenerator *gen = [UINotificationFeedbackGenerator new];
                                         [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                                     }];

                         if (frozen) {
                             UIAction *unfreeze = [UIAction
                                 actionWithTitle:@"解冻"
                                           image:[UIImage systemImageNamed:@"snowflake"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *_Nonnull action) {
                                             [self unfreezeHost:host];
                                         }];
                             return [UIMenu menuWithTitle:@"" children:@[ copyHost, unfreeze ]];
                         }

                         UIAction *copyId = [UIAction
                             actionWithTitle:NSLocalizedStringFromTableInBundle(@"Copy ID", @"Localizable", self.bundle,
                                                                                nil)
                                       image:[UIImage systemImageNamed:@"doc.on.doc"]
                                  identifier:nil
                                     handler:^(__kindof UIAction *_Nonnull action) {
                                         [UIPasteboard generalPasteboard].string = cid;
                                         UINotificationFeedbackGenerator *gen = [UINotificationFeedbackGenerator new];
                                         [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                                     }];
                         UIAction *disconnect = [UIAction
                             actionWithTitle:@"断开"
                                       image:[UIImage systemImageNamed:@"xmark.circle"]
                                  identifier:nil
                                     handler:^(__kindof UIAction *_Nonnull action) {
                                         [self disconnectClientWithId:cid block:NO];
                                     }];
                         disconnect.attributes = UIMenuElementAttributesDestructive;

                         UIAction *freeze = [UIAction
                             actionWithTitle:@"冻结"
                                       image:[UIImage systemImageNamed:@"snowflake"]
                                  identifier:nil
                                     handler:^(__kindof UIAction *_Nonnull action) {
                                         [self freezeClientWithId:cid];
                                     }];
                         freeze.attributes = UIMenuElementAttributesDestructive;

                         return [UIMenu menuWithTitle:@"" children:@[ copyId, copyHost, disconnect, freeze ]];
                     }];
}

@end
