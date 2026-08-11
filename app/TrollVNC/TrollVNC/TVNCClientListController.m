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
#import <errno.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "Control.h"

#pragma mark - Networking

// Placeholder item id used when there are no clients
static NSString *const kTVNCEmptyItemId = @"__empty__";
static NSString *const kTVNCFrozenHostsKey = @"TVNCFrozenHosts";
static NSString *const kTVNCDefaultsSuite = @"com.82flex.trollvnc";

static inline BOOL TVNCIsEmptyItemId(NSString *_Nullable itemId) {
    return itemId != nil && [itemId isEqualToString:kTVNCEmptyItemId];
}

static NSData *TVNCReadAll(int fd, double timeoutSec) {
    NSMutableData *md = [NSMutableData data];
    struct timeval tv;
    tv.tv_sec = (int)timeoutSec;
    tv.tv_usec = (int)((timeoutSec - tv.tv_sec) * 1e6);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint8_t buf[2048];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0) {
            // EAGAIN/EWOULDBLOCK means timeout fired — no more data available
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            if (errno == EINTR)
                continue;
            break; // real error
        }
        if (n == 0)
            break; // peer closed / EOF
        [md appendBytes:buf length:(NSUInteger)n];
    }
    return md;
}

static int TVNCSendLine(int fd, NSString *line) {
    NSString *ln = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *d = [ln dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (n == 0)
            break;
        p += (size_t)n;
        left -= (size_t)n;
    }
    return 0;
}

static int TVNCConnect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvDefaultCtlPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

#pragma mark - Private Interface

@interface TVNCClientListController ()

@property(nonatomic, strong) UIBarButtonItem *dismissItem;
@property(nonatomic, strong) UIBarButtonItem *disconnectItem;

@property(nonatomic, strong) UITableViewDiffableDataSource<NSString *, NSString *> *dataSource; // section -> itemId
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *clientLookup;     // id -> dict
@property(nonatomic, strong) NSMutableSet<NSString *> *frozenHosts;                                   // 冻结 host 集合（持久化）

// Subscription (long-lived connection)
@property(nonatomic, assign) int subFd;
@property(nonatomic, strong) dispatch_source_t subReadSource;

// Reconnection state
@property(nonatomic, strong) dispatch_source_t subReconnectTimer;
@property(nonatomic, assign) NSTimeInterval subReconnectDelay;
@property(nonatomic, assign) BOOL subIntentionallyStopped;

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
    self.subIntentionallyStopped = NO;
    self.subReconnectDelay = 1.0;
    [self startSubscriptionIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopSubscription];
}

- (void)dealloc {
    [self stopSubscription];
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

#pragma mark - Subscription (Plan B)

- (void)startSubscriptionIfNeeded {
    if (self.subFd > 0 || self.subReadSource)
        return;

    int fd = TVNCConnect();
    if (fd < 0)
        return;

    if (TVNCSendLine(fd, @"subscribe on") < 0) {
        close(fd);
        return;
    }

    // Verify server acknowledged the subscription
    NSData *okData = TVNCReadAll(fd, 0.5);
    if (!okData || okData.length < 2 || memmem(okData.bytes, okData.length, "OK", 2) == NULL) {
        close(fd);
        return;
    }

    // Enable TCP keepalive to detect dead connections promptly
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
#ifdef TCP_KEEPALIVE
    int idle = 5; // Start probing after 5s idle
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
#endif
#ifdef TCP_KEEPINTVL
    int intvl = 2; // Probe every 2s
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
#endif
#ifdef TCP_KEEPCNT
    int cnt = 3; // Give up after 3 failed probes (~11s total)
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
#endif

    self.subFd = fd;

    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, q);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        [weakSelf onSubscriptionReadable];
    });

    dispatch_source_set_cancel_handler(src, ^{
        if (weakSelf.subFd > 0) {
            close(weakSelf.subFd);
            weakSelf.subFd = 0;
        }
    });

    self.subReadSource = src;
    dispatch_resume(src);
}

- (void)teardownSubscriptionConnection {
    if (self.subReadSource) {
        dispatch_source_cancel(self.subReadSource);
        self.subReadSource = nil;
    }
    if (self.subFd > 0) {
        close(self.subFd);
        self.subFd = 0;
    }
}

- (void)stopSubscription {
    [self cancelReconnect];
    self.subIntentionallyStopped = YES;
    self.subReconnectDelay = 1.0;

    [self teardownSubscriptionConnection];
}

- (void)scheduleReconnect {
    if (self.subIntentionallyStopped)
        return;
    if (self.subReconnectTimer)
        return;

    // Add ±20% jitter to avoid thundering herd
    NSTimeInterval base = self.subReconnectDelay;
    if (base < 1.0)
        base = 1.0;
    double jitter = base * 0.2 * ((double)arc4random_uniform(UINT32_MAX) / UINT32_MAX * 2.0 - 1.0);
    NSTimeInterval delay = base + jitter;

    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    uint64_t delayNs = (uint64_t)(delay * NSEC_PER_SEC);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, delayNs), DISPATCH_TIME_FOREVER, delayNs / 10);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.subReconnectTimer = nil;

        [strongSelf startSubscriptionIfNeeded];
        if (strongSelf.subFd > 0) {
            // Reconnected successfully — reset backoff and pull fresh data
            strongSelf.subReconnectDelay = 1.0;
            [strongSelf refresh];
        } else {
            // Still failing — exponential backoff, cap at 30s
            strongSelf.subReconnectDelay = MIN(strongSelf.subReconnectDelay * 2.0, 30.0);
            [strongSelf scheduleReconnect];
        }
    });

    self.subReconnectTimer = t;
    dispatch_resume(t);
}

- (void)cancelReconnect {
    if (self.subReconnectTimer) {
        dispatch_source_cancel(self.subReconnectTimer);
        self.subReconnectTimer = nil;
    }
}

#pragma mark - Actions

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh {
    [self reloadDataFromServer];
}

// Removed index-based disconnect; use -disconnectClientWithId:block: instead.

- (void)disconnectClientWithId:(NSString *)cid block:(BOOL)shouldBlock {
    if (cid.length == 0)
        return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd >= 0) {
            NSString *cmd = shouldBlock ? @"block" : @"disconnect";
            TVNCSendLine(fd, [NSString stringWithFormat:@"%@ %@", cmd, cid]);
            (void)TVNCReadAll(fd, 2.0);
            close(fd);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

- (void)disconnectAll {
    [self.disconnectItem setEnabled:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd >= 0) {
            TVNCSendLine(fd, @"disconnect ALL");
            (void)TVNCReadAll(fd, 2.0);
            close(fd);
        }

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

- (void)unfreezeHost:(NSString *)host {
    if (!host.length)
        return;
    [self.frozenHosts removeObject:host];
    [self persistFrozenHosts];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd >= 0) {
            TVNCSendLine(fd, [NSString stringWithFormat:@"unblock %@", host]);
            (void)TVNCReadAll(fd, 2.0);
            close(fd);
        }
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

- (NSArray<NSDictionary *> *)parseTSV:(NSString *)tsv {
    if (tsv.length == 0)
        return @[];
    NSArray<NSString *> *lines = [tsv componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSDictionary *> *rows =
        [NSMutableArray arrayWithCapacity:MAX((NSInteger)0, (NSInteger)lines.count - 1)];
    BOOL first = YES;
    for (NSString *ln in lines) {
        if (ln.length == 0)
            continue;
        if (first) {
            first = NO;
            continue;
        } // skip header
        NSArray *cols = [ln componentsSeparatedByString:@"\t"];
        if (cols.count < 5)
            continue;
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{
            @"id" : cols[0],
            @"host" : cols[1],
            @"viewOnly" : cols[2],
            @"connectedAt" : cols[3],
            @"durationSec" : cols[4]
        }];
        [rows addObject:row];
    }
    return rows;
}

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

- (void)reloadDataFromServer {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.refreshControl endRefreshing];
                [self applyRows:@[]];
            });
            return;
        }

        TVNCSendLine(fd, @"list");
        NSData *data = TVNCReadAll(fd, 2.0);
        close(fd);

        NSString *tsv = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSDictionary *> *rows = [self parseTSV:tsv];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            [self applyRows:rows];
        });
    });
}

- (void)onSubscriptionReadable {
    int fd = self.subFd;
    if (fd <= 0) {
        return;
    }
    uint8_t buf[256];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) {
        // Connection lost — tear down and schedule reconnect
        [self teardownSubscriptionConnection];
        [self scheduleReconnect];
        return;
    }
    buf[n] = '\0';
    // Any line containing "changed" triggers a refresh
    if (memmem(buf, (size_t)n, "changed", 7) != NULL) {
        [self refresh];
    }
}

#pragma mark - Table

// Diffable data source drives cells; no need to implement UITableViewDataSource methods here.

/**
 * 表格右滑操作配置（trailing swipe，手指从右向左滑，揭示右侧操作按钮）。
 * 功能：依据当前行的客户端状态（在线 / 冻结）返回对应右滑按钮：
 *   - 在线行：冻结🟠（橙色）+ 断开🔴（红色 destructive）
 *   - 冻结行：仅解冻🟢（绿色）
 *   - 控制端口未连接（能力不可用）：返回"能力不可用"按钮，点击弹提示，不执行动作
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
    // 均经本地命令通道（46752 端口）执行；订阅 socket（subFd）活跃即代表通道可达
    BOOL capabilityAvailable = (self.subFd > 0);

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
 * 功能：当控制端口未连接（clients.freeze/unfreeze/disconnect 能力实质不可用）时，
 *       弹出短暂提示告知用户，1.2 秒后自动消失。
 * 参数：无
 * 返回值：void
 */
- (void)showCapabilityUnavailableHint {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                    message:@"能力不可用（控制端口未连接）"
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
