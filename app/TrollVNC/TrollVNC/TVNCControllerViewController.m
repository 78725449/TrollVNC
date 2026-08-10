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

#import "TVNCControllerViewController.h"
#import "TVNCViewerViewController.h"
#import "TVNCDeviceListCell.h"
#import "TRWallTileWebView.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static const NSInteger kConsolePort = 8080; // trollvnc-farm FARM_PORT 默认
/// 视图模式持久化键：0=宫格，1=列表
static NSString *const kViewModeKey = @"TVNCControllerViewMode";
/// 宫格列数持久化键：2/3/4/6
static NSString *const kGridColumnsKey = @"TVNCControllerGridColumns";

/// 紫色主题色（RGB 107/78/255）
static UIColor *TRPurpleColor(void) {
    return [UIColor colorWithRed:(107.0 / 255.0) green:(78.0 / 255.0) blue:(255.0 / 255.0) alpha:1.0];
}

#pragma mark - 卡片墙 RFB 连接最大并发数

/// 卡片墙最大同时 RFB 连接数
static const NSInteger kMaxConcurrentWallConnections = 6;

#pragma mark - 设备卡片 Cell（宫格视图，删除 tagLabel，新增多选 checkbox）

@interface TVNCDeviceCardCell : UICollectionViewCell
@property(nonatomic, strong) UIView *screenArea;
@property(nonatomic, strong) UIImageView *screenIcon;
@property(nonatomic, strong) UIImageView *thumbView;
@property(nonatomic, strong) TRWallTileWebView *wallWebView; ///< 卡片墙实时 RFB 画面（Phase 12.1 WKWebView 改造）
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *offlineLabel; ///< 离线设备"最后在线时间"提示
@property(nonatomic, strong) UIView *dotView;
/// 卡片右下角⋯按钮（弹出能力菜单），tag=9527 用于事件识别
@property(nonatomic, strong) UIButton *moreButton;
/// 多选模式 checkbox 覆盖层
@property(nonatomic, strong) UIButton *checkBox;
/// ⋯按钮点击回调（参数为 cell 自身，便于控制器定位设备数据）
@property(nonatomic, copy, nullable) void (^moreTapped)(TVNCDeviceCardCell *cell);
- (void)configureWithDevice:(NSDictionary *)d thumbnail:(UIImage *)thumb
                   multiMode:(BOOL)multiMode selected:(BOOL)selected;
/**
 * 启动卡片墙 RFB 连接（隧道优先，直连回退）。
 * @param d 设备数据字典
 * @param gatewayHost 网关地址
 * @param gatewayPort 网关 HTTP 端口
 * @param token 认证 token
 */
- (void)startWallWebViewWithDevice:(NSDictionary *)d
                       gatewayHost:(NSString *)gatewayHost
                       gatewayPort:(NSInteger)gatewayPort
                             token:(NSString *)token;
/// 断开卡片墙 RFB 连接并缓存最后帧。
- (void)stopWallWebView;
@end

@implementation TVNCDeviceCardCell

/// 初始化卡片布局：画面区 + 名称 + 在线圆点 + ⋯按钮 + 多选 checkbox。
/// @param frame cell 帧
/// @return cell 实例
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 16;
        self.contentView.layer.borderWidth = 1;
        self.contentView.layer.borderColor = [UIColor separatorColor].CGColor;
        self.contentView.clipsToBounds = YES;
        self.contentView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.08;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.layer.shadowRadius = 12;

        _screenArea = [[UIView alloc] init];
        _screenArea.translatesAutoresizingMaskIntoConstraints = NO;
        _screenArea.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
        [self.contentView addSubview:_screenArea];

        _screenIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone"]];
        _screenIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _screenIcon.contentMode = UIViewContentModeScaleAspectFit;
        _screenIcon.tintColor = [UIColor systemGrayColor];
        [_screenArea addSubview:_screenIcon];

        _thumbView = [[UIImageView alloc] init];
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbView.contentMode = UIViewContentModeScaleAspectFit;
        _thumbView.backgroundColor = [UIColor blackColor];
        _thumbView.hidden = YES;
        [_screenArea addSubview:_thumbView];

        // 卡片墙实时 RFB 画面（Phase 12.1 WKWebView 改造）：默认隐藏，start 后显示
        _wallWebView = [[TRWallTileWebView alloc] initWithFrame:CGRectZero];
        _wallWebView.translatesAutoresizingMaskIntoConstraints = NO;
        _wallWebView.hidden = YES;
        [_screenArea addSubview:_wallWebView];

        _offlineLabel = [[UILabel alloc] init];
        _offlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _offlineLabel.font = [UIFont systemFontOfSize:9];
        _offlineLabel.textColor = [UIColor whiteColor];
        _offlineLabel.textAlignment = NSTextAlignmentCenter;
        _offlineLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        _offlineLabel.hidden = YES;
        [_screenArea addSubview:_offlineLabel];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.numberOfLines = 1;
        [self.contentView addSubview:_nameLabel];

        _dotView = [[UIView alloc] init];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        _dotView.layer.cornerRadius = 5;
        [self.contentView addSubview:_dotView];

        _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _moreButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        _moreButton.tintColor = [UIColor secondaryLabelColor];
        _moreButton.tag = 9527;
        [_moreButton addTarget:self action:@selector(moreButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_moreButton];

        _checkBox = [UIButton buttonWithType:UIButtonTypeSystem];
        _checkBox.translatesAutoresizingMaskIntoConstraints = NO;
        _checkBox.tintColor = TRPurpleColor();
        _checkBox.hidden = YES;
        _checkBox.userInteractionEnabled = NO;
        [_checkBox setImage:[UIImage systemImageNamed:@"circle"] forState:UIControlStateNormal];
        [_checkBox setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateSelected];
        [self.contentView addSubview:_checkBox];

        [NSLayoutConstraint activateConstraints:@[
            [_screenArea.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_screenArea.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_screenArea.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_screenArea.bottomAnchor constraintEqualToAnchor:_nameLabel.topAnchor constant:-10],

            [_screenIcon.centerXAnchor constraintEqualToAnchor:_screenArea.centerXAnchor],
            [_screenIcon.centerYAnchor constraintEqualToAnchor:_screenArea.centerYAnchor],
            [_screenIcon.widthAnchor constraintEqualToConstant:34],
            [_screenIcon.heightAnchor constraintEqualToConstant:40],

            [_thumbView.topAnchor constraintEqualToAnchor:_screenArea.topAnchor],
            [_thumbView.leadingAnchor constraintEqualToAnchor:_screenArea.leadingAnchor],
            [_thumbView.trailingAnchor constraintEqualToAnchor:_screenArea.trailingAnchor],
            [_thumbView.bottomAnchor constraintEqualToAnchor:_screenArea.bottomAnchor],

            [_wallWebView.topAnchor constraintEqualToAnchor:_screenArea.topAnchor],
            [_wallWebView.leadingAnchor constraintEqualToAnchor:_screenArea.leadingAnchor],
            [_wallWebView.trailingAnchor constraintEqualToAnchor:_screenArea.trailingAnchor],
            [_wallWebView.bottomAnchor constraintEqualToAnchor:_screenArea.bottomAnchor],

            [_offlineLabel.leadingAnchor constraintEqualToAnchor:_screenArea.leadingAnchor],
            [_offlineLabel.trailingAnchor constraintEqualToAnchor:_screenArea.trailingAnchor],
            [_offlineLabel.bottomAnchor constraintEqualToAnchor:_screenArea.bottomAnchor],
            [_offlineLabel.heightAnchor constraintEqualToConstant:16],

            [_checkBox.topAnchor constraintEqualToAnchor:_screenArea.topAnchor constant:6],
            [_checkBox.leadingAnchor constraintEqualToAnchor:_screenArea.leadingAnchor constant:6],
            [_checkBox.widthAnchor constraintEqualToConstant:26],
            [_checkBox.heightAnchor constraintEqualToConstant:26],

            [_moreButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_moreButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [_moreButton.widthAnchor constraintEqualToConstant:24],
            [_moreButton.heightAnchor constraintEqualToConstant:24],

            [_dotView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_dotView.centerYAnchor constraintEqualToAnchor:_moreButton.centerYAnchor],
            [_dotView.widthAnchor constraintEqualToConstant:10],
            [_dotView.heightAnchor constraintEqualToConstant:10],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_dotView.trailingAnchor constant:8],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_moreButton.leadingAnchor constant:-8],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:_moreButton.centerYAnchor],
        ]];
    }
    return self;
}

/// ⋯按钮点击事件：触发 moreTapped block 回调通知控制器弹出能力菜单。
- (void)moreButtonTapped {
    if (self.moreTapped) {
        self.moreTapped(self);
    }
}

/// 配置卡片内容：设备名、在线状态、缩略图、离线时间、多选 checkbox。
/// @param d        设备数据字典
/// @param thumb    缩略图（可为 nil）
/// @param multiMode 是否处于多选模式
/// @param selected  是否处于勾选状态
- (void)configureWithDevice:(NSDictionary *)d thumbnail:(UIImage *)thumb
                   multiMode:(BOOL)multiMode selected:(BOOL)selected {
    BOOL online = [d[@"online"] boolValue];
    self.nameLabel.text = d[@"name"] ?: d[@"id"] ?: @"?";
    self.dotView.backgroundColor = online ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.screenArea.backgroundColor = [UIColor colorWithWhite:online ? 0.93 : 0.96 alpha:1];
    self.screenIcon.tintColor = online ? [UIColor systemGrayColor] : [UIColor systemGray3Color];

    // 离线设备：画面置灰 + 显示"最后在线时间"
    if (!online) {
        NSString *lastSeen = d[@"lastSeen"] ?: d[@"lastOnline"] ?: @"";
        self.offlineLabel.text = lastSeen.length ? [NSString stringWithFormat:@"最后在线 %@", lastSeen] : @"离线";
        self.offlineLabel.hidden = NO;
        self.thumbView.alpha = 0.4;
        self.screenIcon.alpha = 0.4;
        [self.wallWebView stop];
        self.wallWebView.hidden = YES;
    } else {
        self.offlineLabel.hidden = YES;
        self.thumbView.alpha = 1.0;
        self.screenIcon.alpha = 1.0;
    }

    // 实时 RFB 画面：wallWebView 已启动连接时优先显示；其后显示缓存帧 thumbView；否则占位图标
    if (online && !self.wallWebView.hidden && self.wallWebView.state != TRWallTileStateFailed) {
        self.thumbView.hidden = YES;
        self.screenIcon.hidden = YES;
    } else if (thumb) {
        self.thumbView.image = thumb;
        self.thumbView.hidden = NO;
        self.screenIcon.hidden = YES;
    } else {
        self.thumbView.hidden = YES;
        self.screenIcon.hidden = NO;
    }

    // 多选 checkbox
    self.checkBox.hidden = !multiMode;
    self.checkBox.selected = selected;
}

/// 启动卡片墙 RFB 连接（隧道优先，直连回退）。
/// @param d 设备数据字典
/// @param gatewayHost 网关地址
/// @param gatewayPort 网关 HTTP 端口
/// @param token 认证 token
- (void)startWallWebViewWithDevice:(NSDictionary *)d
                       gatewayHost:(NSString *)gatewayHost
                       gatewayPort:(NSInteger)gatewayPort
                             token:(NSString *)token {
    if (![d[@"online"] boolValue]) return; // 离线设备不建立 RFB
    if (self.wallWebView.state == TRWallTileStateConnected ||
        self.wallWebView.state == TRWallTileStateConnecting) return; // 已连接/连接中不重复
    NSString *deviceId = d[@"id"];
    NSString *host = d[@"host"];
    int port = (int)([d[@"port"] integerValue] ?: 5901);
    __weak typeof(self) weakSelf = self;
    self.wallWebView.onStateChange = ^(TRWallTileState state) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (state == TRWallTileStateConnected) {
            strongSelf.wallWebView.hidden = NO;
            strongSelf.thumbView.hidden = YES;
            strongSelf.screenIcon.hidden = YES;
        } else if (state == TRWallTileStateFailed) {
            strongSelf.wallWebView.hidden = YES;
        }
    };
    [self.wallWebView startWithDeviceId:deviceId
                            gatewayHost:gatewayHost
                            gatewayPort:gatewayPort
                                  token:token
                                   host:host
                                   port:port];
}

/// 断开卡片墙 RFB 连接并缓存最后帧。
- (void)stopWallWebView {
    [self.wallWebView stop];
    self.wallWebView.hidden = YES;
}

/// cell 复用前清理：断开可能残留的 RFB 连接，防止跨设备画面串显。
- (void)prepareForReuse {
    [super prepareForReuse];
    [self stopWallWebView];
}

@end

#pragma mark - 控制端

@interface TVNCControllerViewController () <UICollectionViewDataSource,
                                            UICollectionViewDelegate,
                                            UICollectionViewDelegateFlowLayout,
                                            UITableViewDataSource,
                                            UITableViewDelegate,
                                            UIGestureRecognizerDelegate>

// 顶部导航栏
@property(nonatomic, strong) UIButton *selectAllButton;   ///< 全选 checkbox
@property(nonatomic, strong) UILabel *titleLabel;         ///< 标题"设备墙"/"已选 N 台"
@property(nonatomic, strong) UIButton *batchButton;       ///< 批量操作/取消
@property(nonatomic, strong) UIButton *layoutButton;      ///< 布局切换器（宫格/列表）
@property(nonatomic, strong) UIView *layoutPanel;         ///< 布局下拉面板

// 双视图
@property(nonatomic, strong) UICollectionView *collectionView; ///< 宫格视图
@property(nonatomic, strong) UITableView *tableView;           ///< 详情列表视图
@property(nonatomic, strong) UILabel *emptyLabel;

// 底部批量配置按钮
@property(nonatomic, strong) UIButton *bottomBatchButton;

// 数据
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *devices; // 全部设备
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *shown;   // 展示用（已过滤自身）
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy, nullable) NSString *selfDeviceId;

// 视图模式
@property(nonatomic, assign) NSInteger viewMode;       // 0=宫格 1=列表
@property(nonatomic, assign) NSInteger gridColumns;    // 2/3/4/6

// 多选状态
@property(nonatomic, assign) BOOL multiMode;                    ///< 是否处于多选模式
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedDevices; ///< 已勾选设备 ID 集合

// 卡片墙 RFB 连接管理（Phase 12.1 WKWebView 改造）
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *snapshotCache; ///< 不可见 cell 的缓存帧（deviceId→UIImage）
@property(nonatomic, assign) NSInteger activeWallConnections;   ///< 当前活跃的卡片墙 RFB 连接数

@end

@implementation TVNCControllerViewController

/// 初始化：读取持久化配置（视图模式、列数）、自身 deviceId、默认刷新间隔。
/// @return 控制器实例
- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _selfDeviceId = [_defaults stringForKey:@"DeviceUUID"];
        _devices = [NSMutableArray array];
        _shown = [NSMutableArray array];
        _selectedDevices = [NSMutableSet set];
        _snapshotCache = [NSMutableDictionary dictionary];
        _activeWallConnections = 0;

        NSInteger vm = [_defaults integerForKey:kViewModeKey];
        _viewMode = (vm == 1) ? 1 : 0;
        NSInteger cols = [_defaults integerForKey:kGridColumnsKey];
        _gridColumns = (cols == 2 || cols == 3 || cols == 4 || cols == 6) ? cols : 2;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"设备墙";

    [self setupTopNav];
    [self setupGridView];
    [self setupListView];
    [self setupBottomBatchButton];
    [self setupLayoutPanel];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"暂无设备\n点右上角刷新，从网关拉取设备目录";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(refreshDevices)];

    // 卡片墙 RFB 连接：由 willDisplayCell/didEndDisplayingCell 按可见性管理
    // 不再使用 libvncclient 首帧抓取 + 定时轮询

    [self applyViewMode];          // 切换初始视图可见性
    [self refreshDevices];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDevices];
    // 页面重新出现时恢复可见 cell 的 RFB 连接（viewWillDisappear 时已全部停止）
    [self startVisibleWallConnections];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 停止所有可见 cell 的 RFB 连接
    [self stopAllWallConnections];
}

#pragma mark - 顶部导航栏（Phase 12.3 + 12.4）

/// 构建顶部导航栏：[全选☑] 标题 [批量操作] [宫格▾]。
/// 位置稳定原则——模式切换只变内容不移动。
- (void)setupTopNav {
    // 全选 checkbox（浏览模式隐藏，多选模式显示）
    self.selectAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.selectAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectAllButton.tintColor = TRPurpleColor();
    [self.selectAllButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateSelected];
    [self.selectAllButton setImage:[UIImage systemImageNamed:@"circle"] forState:UIControlStateNormal];
    self.selectAllButton.hidden = YES;
    [self.selectAllButton addTarget:self action:@selector(selectAllTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.selectAllButton];

    // 标题
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.text = @"设备墙";
    [self.view addSubview:self.titleLabel];

    // 批量操作按钮（浏览模式：紫底白字；多选模式：白底灰字"取消"）
    self.batchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.batchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.batchButton setTitle:@"批量操作" forState:UIControlStateNormal];
    self.batchButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.batchButton addTarget:self action:@selector(batchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self styleBatchButtonForMode];
    [self.view addSubview:self.batchButton];

    // 布局切换器：44px 窄按钮，图标+下拉箭头
    self.layoutButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.layoutButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.layoutButton.tintColor = [UIColor labelColor];
    self.layoutButton.layer.cornerRadius = 10;
    self.layoutButton.layer.borderWidth = 1;
    self.layoutButton.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutButton.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.layoutButton addTarget:self action:@selector(layoutButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self updateLayoutButtonIcon];
    [self.view addSubview:self.layoutButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.selectAllButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [self.selectAllButton.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.selectAllButton.widthAnchor constraintEqualToConstant:28],
        [self.selectAllButton.heightAnchor constraintEqualToConstant:28],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.selectAllButton.trailingAnchor constant:8],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],

        [self.layoutButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [self.layoutButton.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.layoutButton.widthAnchor constraintEqualToConstant:44],
        [self.layoutButton.heightAnchor constraintEqualToConstant:32],

        [self.batchButton.trailingAnchor constraintEqualToAnchor:self.layoutButton.leadingAnchor constant:-10],
        [self.batchButton.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.batchButton.heightAnchor constraintEqualToConstant:32],
    ]];
}

/// 根据当前模式设置批量操作按钮样式。
/// 浏览模式：紫底白字"批量操作"；多选模式：白底灰字"取消"。
- (void)styleBatchButtonForMode {
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 14, 0, 14);
    if (self.multiMode) {
        cfg.title = @"取消";
        cfg.baseForegroundColor = [UIColor secondaryLabelColor];
        cfg.background = [UIBackgroundConfiguration clearConfiguration];
        cfg.background.strokeColor = [UIColor separatorColor];
        cfg.background.strokeWidth = 1;
    } else {
        cfg.title = @"批量操作";
        cfg.baseForegroundColor = [UIColor whiteColor];
        cfg.background = [UIBackgroundConfiguration clearConfiguration];
        cfg.background.backgroundColor = TRPurpleColor();
    }
    self.batchButton.configuration = cfg;
}

/// 全选按钮点击：浏览模式无操作；多选模式全选/取消全选。
- (void)selectAllTapped {
    if (!self.multiMode) return;
    if (self.selectedDevices.count == self.shown.count) {
        [self.selectedDevices removeAllObjects];
        self.selectAllButton.selected = NO;
    } else {
        for (NSDictionary *d in self.shown) {
            NSString *did = d[@"id"];
            if (did.length) [self.selectedDevices addObject:did];
        }
        self.selectAllButton.selected = YES;
    }
    [self updateMultiSelectUI];
}

/// 批量操作按钮点击：浏览模式→进入多选；多选模式→退出多选。
- (void)batchButtonTapped {
    if (self.multiMode) {
        [self exitMultiSelect];
    } else {
        [self enterMultiSelect];
    }
}

/// 进入多选模式：显示全选 checkbox、标题变"已选 0 台"、按钮变"取消"。
- (void)enterMultiSelect {
    self.multiMode = YES;
    [self.selectedDevices removeAllObjects];
    self.selectAllButton.hidden = NO;
    self.selectAllButton.selected = NO;
    [self styleBatchButtonForMode];
    [self updateMultiSelectUI];
}

/// 退出多选模式：清空选择、隐藏全选 checkbox、标题恢复"设备墙"、按钮恢复"批量操作"。
- (void)exitMultiSelect {
    self.multiMode = NO;
    [self.selectedDevices removeAllObjects];
    self.selectAllButton.hidden = YES;
    self.titleLabel.text = @"设备墙";
    [self styleBatchButtonForMode];
    self.bottomBatchButton.hidden = YES;
    [self reloadBothViews];
}

/// 更新多选模式 UI：标题"已选 N 台"、全选状态、底部按钮、刷新列表。
- (void)updateMultiSelectUI {
    NSInteger n = self.selectedDevices.count;
    self.titleLabel.text = [NSString stringWithFormat:@"已选 %ld 台", (long)n];
    self.selectAllButton.selected = (n > 0 && n == self.shown.count);
    self.bottomBatchButton.hidden = (n == 0);
    if (n > 0) {
        NSString *prefix = [NSString stringWithFormat:@"调整配置（%ld 台）", (long)n];
        [self.bottomBatchButton setTitle:prefix forState:UIControlStateNormal];
    }
    [self reloadBothViews];
}

#pragma mark - 布局切换器（宫格/列表）

/// 更新布局切换器图标：宫格用 2×2 方块图标，列表用三横线图标。
- (void)updateLayoutButtonIcon {
    NSString *icon = (self.viewMode == 1) ? @"list.bullet" : @"square.grid.2x2";
    UIImage *img = [UIImage systemImageNamed:icon];
    UIImage *chevron = [UIImage systemImageNamed:@"chevron.down"];
    // 水平拼接图标+下拉箭头
    UIImage *combined = [self combineImage:img withChevron:chevron];
    [self.layoutButton setImage:combined forState:UIControlStateNormal];
}

/// 水平拼接主图标与下拉箭头，用于布局切换器按钮显示。
/// @param main     主图标
/// @param chevron  下拉箭头图标
/// @return 拼接后的 UIImage
- (UIImage *)combineImage:(UIImage *)main withChevron:(UIImage *)chevron {
    if (!main) return chevron;
    if (!chevron) return main;
    CGFloat gap = 4;
    CGSize s1 = main.size;
    CGSize s2 = chevron.size;
    CGSize combined = CGSizeMake(s1.width + gap + s2.width, MAX(s1.height, s2.height));
    UIGraphicsBeginImageContextWithOptions(combined, NO, 0);
    [main drawInRect:CGRectMake(0, (combined.height - s1.height) / 2, s1.width, s1.height)];
    [chevron drawInRect:CGRectMake(s1.width + gap, (combined.height - s2.height) / 2, s2.width, s2.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

/// 构建布局下拉面板（2 选项：宫格/列表）。
- (void)setupLayoutPanel {
    self.layoutPanel = [[UIView alloc] init];
    self.layoutPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.layoutPanel.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.layoutPanel.layer.cornerRadius = 12;
    self.layoutPanel.layer.borderWidth = 1;
    self.layoutPanel.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layoutPanel.layer.shadowOpacity = 0.15;
    self.layoutPanel.layer.shadowOffset = CGSizeMake(0, 6);
    self.layoutPanel.layer.shadowRadius = 12;
    self.layoutPanel.hidden = YES;
    [self.view addSubview:self.layoutPanel];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    [self.layoutPanel addSubview:stack];

    NSArray *items = @[
        @{ @"title": @"宫格", @"icon": @"square.grid.2x2", @"mode": @(0) },
        @{ @"title": @"列表", @"icon": @"list.bullet", @"mode": @(1) },
    ];
    for (NSDictionary *item in items) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b setImage:[UIImage systemImageNamed:item[@"icon"]] forState:UIControlStateNormal];
        [b setTitle:item[@"title"] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.tintColor = [UIColor labelColor];
        b.tag = [item[@"mode"] integerValue];
        [b addTarget:self action:@selector(layoutOptionTapped:) forControlEvents:UIControlEventTouchUpInside];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [b setContentEdgeInsets:UIEdgeInsetsMake(8, 10, 8, 10)];
        [b.heightAnchor constraintEqualToConstant:36].active = YES;
        [stack addArrangedSubview:b];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.layoutPanel.trailingAnchor constraintEqualToAnchor:self.layoutButton.trailingAnchor],
        [self.layoutPanel.topAnchor constraintEqualToAnchor:self.layoutButton.bottomAnchor constant:4],
        [self.layoutPanel.widthAnchor constraintEqualToConstant:120],
        [stack.topAnchor constraintEqualToAnchor:self.layoutPanel.topAnchor constant:6],
        [stack.leadingAnchor constraintEqualToAnchor:self.layoutPanel.leadingAnchor constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:self.layoutPanel.trailingAnchor constant:-6],
        [stack.bottomAnchor constraintEqualToAnchor:self.layoutPanel.bottomAnchor constant:-6],
    ]];

    // 点击面板外关闭
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissLayoutPanel)];
    dismiss.cancelsTouchesInView = NO;
    dismiss.delegate = self;
    [self.view addGestureRecognizer:dismiss];
}

/// 布局切换器点击：切换下拉面板显示/隐藏。
- (void)layoutButtonTapped {
    BOOL show = self.layoutPanel.hidden;
    if (show) {
        [self.view bringSubviewToFront:self.layoutPanel];
        [self refreshLayoutPanelChecks];
    }
    self.layoutPanel.hidden = !show;
}

/// 布局下拉选项点击：切换视图模式并持久化。
/// @param sender 触发的选项按钮（tag=视图模式）
- (void)layoutOptionTapped:(UIButton *)sender {
    NSInteger mode = sender.tag;
    if (mode == self.viewMode) {
        self.layoutPanel.hidden = YES;
        return;
    }
    self.viewMode = mode;
    [self.defaults setInteger:mode forKey:kViewModeKey];
    [self.defaults synchronize];
    [self applyViewMode];
    [self updateLayoutButtonIcon];
    self.layoutPanel.hidden = YES;
}

/// 关闭布局下拉面板。
- (void)dismissLayoutPanel {
    self.layoutPanel.hidden = YES;
}

/// 刷新布局下拉面板中当前模式的勾选高亮。
- (void)refreshLayoutPanelChecks {
    UIStackView *stack = (UIStackView *)self.layoutPanel.subviews.firstObject;
    for (UIView *v in stack.arrangedSubviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)v;
            BOOL on = (b.tag == self.viewMode);
            if (on) {
                b.backgroundColor = [TRPurpleColor() colorWithAlphaComponent:0.12];
                b.tintColor = TRPurpleColor();
                [b setTitleColor:TRPurpleColor() forState:UIControlStateNormal];
            } else {
                b.backgroundColor = [UIColor clearColor];
                b.tintColor = [UIColor labelColor];
                [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            }
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (touch.view == self.layoutPanel || [touch.view isDescendantOfView:self.layoutPanel]) return NO;
    if (touch.view == self.layoutButton || [touch.view isDescendantOfView:self.layoutButton]) return NO;
    return YES;
}

/// 应用当前视图模式：宫格显示 collectionView，列表显示 tableView。
- (void)applyViewMode {
    BOOL grid = (self.viewMode == 0);
    // 切离宫格视图时停止所有 RFB 连接；切回宫格时恢复可见连接
    if (!grid) {
        [self stopAllWallConnections];
    }
    self.collectionView.hidden = !grid;
    self.tableView.hidden = grid;
    if (grid) {
        [self.collectionView reloadData];
    } else {
        [self.tableView reloadData];
    }
    if (grid) {
        [self startVisibleWallConnections];
    }
}

#pragma mark - 宫格视图（视图 1）

/// 构建宫格 CollectionView，注册卡片 cell，添加下拉刷新、双指捏合、长按手势。
- (void)setupGridView {
    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    fl.minimumInteritemSpacing = 12;
    fl.minimumLineSpacing = 12;
    fl.sectionInset = UIEdgeInsetsMake(12, 16, 16, 16);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[TVNCDeviceCardCell class] forCellWithReuseIdentifier:@"card"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshDevices) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = rc;

    // 双指捏合调整列数（2/3/4/6）
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchHandler:)];
    pinch.delegate = self;
    [self.collectionView addGestureRecognizer:pinch];

    // 长按进入多选模式
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressHandler:)];
    longPress.delegate = self;
    longPress.minimumPressDuration = 0.6;
    [self.collectionView addGestureRecognizer:longPress];
}

/// 双指捏合手势处理：捏合放大（减少列数）或捏合缩小（增加列数），在 [2,3,4,6] 间切换。
/// @param pinch 捏合手势
- (void)pinchHandler:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    NSArray<NSNumber *> *steps = @[@2, @3, @4, @6];
    NSInteger idx = [steps indexOfObjectPassingTest:^BOOL(NSNumber *n, NSUInteger i, BOOL *stop) {
        return n.integerValue == self.gridColumns;
    }];
    if (idx == NSNotFound) idx = 0;
    if (pinch.scale > 1.1 && idx > 0) {
        // 放大 → 卡片更大 → 列数减少
        self.gridColumns = steps[idx - 1].integerValue;
    } else if (pinch.scale < 0.9 && idx < (NSInteger)steps.count - 1) {
        // 缩小 → 卡片更小 → 列数增加
        self.gridColumns = steps[idx + 1].integerValue;
    } else {
        return;
    }
    [self.defaults setInteger:self.gridColumns forKey:kGridColumnsKey];
    [self.defaults synchronize];
    @try {
        [self.collectionView.collectionViewLayout invalidateLayout];
    } @catch (NSException *e) {
        NSLog(@"[TVNC] layout invalidate failed: %@ %@", e.name, e.reason);
    }
}

/// 长按手势处理：进入多选模式并勾选当前卡片。
/// @param gr 长按手势
- (void)longPressHandler:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [gr locationInView:self.collectionView];
    NSIndexPath *ip = [self.collectionView indexPathForItemAtPoint:pt];
    if (!ip) return;
    NSDictionary *d = self.shown[ip.row];
    NSString *did = d[@"id"];
    if (!did.length) return;
    if (!self.multiMode) {
        [self enterMultiSelect];
    }
    if ([self.selectedDevices containsObject:did]) {
        [self.selectedDevices removeObject:did];
    } else {
        [self.selectedDevices addObject:did];
    }
    [self updateMultiSelectUI];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g1
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)g2 {
    return YES; // 允许长按与滚动共存
}

#pragma mark - 列表视图（视图 2）

/// 构建详情列表 TableView，注册 TVNCDeviceListCell，添加长按手势。
- (void)setupListView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
    self.tableView.hidden = YES;
    [self.tableView registerClass:[TVNCDeviceListCell class] forCellReuseIdentifier:@"listCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(listLongPressHandler:)];
    longPress.delegate = self;
    longPress.minimumPressDuration = 0.6;
    [self.tableView addGestureRecognizer:longPress];
}

/// 列表长按手势处理：进入多选模式并勾选当前行。
/// @param gr 长按手势
- (void)listLongPressHandler:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:pt];
    if (!ip) return;
    NSDictionary *d = self.shown[ip.row];
    NSString *did = d[@"id"];
    if (!did.length) return;
    if (!self.multiMode) {
        [self enterMultiSelect];
    }
    if ([self.selectedDevices containsObject:did]) {
        [self.selectedDevices removeObject:did];
    } else {
        [self.selectedDevices addObject:did];
    }
    [self updateMultiSelectUI];
}

#pragma mark - 底部批量配置按钮

/// 构建底部悬浮"调整配置（N 台）"按钮，多选模式且有勾选时显示。
- (void)setupBottomBatchButton {
    self.bottomBatchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bottomBatchButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomBatchButton.layer.cornerRadius = 22;
    self.bottomBatchButton.backgroundColor = TRPurpleColor();
    [self.bottomBatchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.bottomBatchButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.bottomBatchButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.bottomBatchButton.layer.shadowOpacity = 0.2;
    self.bottomBatchButton.layer.shadowOffset = CGSizeMake(0, 4);
    self.bottomBatchButton.layer.shadowRadius = 8;
    self.bottomBatchButton.hidden = YES;
    [self.bottomBatchButton addTarget:self action:@selector(bottomBatchTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.bottomBatchButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.bottomBatchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.bottomBatchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.bottomBatchButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.bottomBatchButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

/// 底部批量配置按钮点击：拉取配置表单并弹出。
- (void)bottomBatchTapped {
    if (self.selectedDevices.count == 0) return;
    [self presentBatchConfigForm];
}

#pragma mark - 设备目录（网关 /api/devices）

/// 从网关拉取设备目录，过滤自身设备后刷新双视图。
- (void)refreshDevices {
    [self.collectionView.refreshControl endRefreshing];
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length) {
        self.emptyLabel.text = @"未配置网关\n请先在 设置 → 网关 填写网关地址";
        [self applyFilter];
        return;
    }
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices", host, (long)consolePort];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *list = nil;
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) list = json[@"devices"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleDevices:list error:err];
        });
    }];
    [task resume];
}

/// 处理网关返回的设备列表：过滤自身 deviceId，仅保留已注册或有 host 的设备。
/// @param list 网关返回的设备数组
/// @param err  网络错误
- (void)handleDevices:(NSArray *)list error:(NSError *)err {
    [self.collectionView.refreshControl endRefreshing];
    if (![list isKindOfClass:[NSArray class]]) {
        self.emptyLabel.text = err ? [NSString stringWithFormat:@"拉取设备目录失败\n%@", err.localizedDescription]
                                   : @"网关返回异常\n请检查网关是否运行";
    } else {
        [self.devices removeAllObjects];
        for (NSDictionary *d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            if (self.selfDeviceId.length && [d[@"id"] isEqualToString:self.selfDeviceId]) continue;
            if ([d[@"source"] isEqualToString:@"register"] || d[@"host"]) {
                [self.devices addObject:d];
            }
        }
        if (!self.devices.count) {
            self.emptyLabel.text = @"暂无设备\n（仅显示已注册到网关的设备）";
        }
    }
    [self applyFilter];
}

/// 过滤生成 shown 列表并刷新双视图与空态。
- (void)applyFilter {
    [self.shown removeAllObjects];
    [self.shown addObjectsFromArray:self.devices];
    BOOL hasAny = self.devices.count > 0;
    BOOL hasShown = self.shown.count > 0;
    self.collectionView.hidden = !hasShown || (self.viewMode == 1);
    self.tableView.hidden = !hasShown || (self.viewMode == 0);
    self.emptyLabel.hidden = hasShown || !hasAny;
    if (!hasShown && hasAny) {
        self.emptyLabel.text = @"暂无设备";
        self.emptyLabel.hidden = NO;
    }
    [self reloadBothViews];
}

/// 同时刷新宫格与列表视图。
- (void)reloadBothViews {
    [self.collectionView reloadData];
    [self.tableView reloadData];
}

#pragma mark - 宫格 CollectionView 数据源

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.shown.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)ip {
    TVNCDeviceCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"card" forIndexPath:ip];
    NSDictionary *d = self.shown[ip.row];
    UIImage *thumb = self.snapshotCache[d[@"id"]]; // 使用缓存帧（不可见 cell 的最后帧）
    NSString *did = d[@"id"];
    BOOL selected = did.length && [self.selectedDevices containsObject:did];
    [cell configureWithDevice:d thumbnail:thumb multiMode:self.multiMode selected:selected];
    __weak typeof(self) weakSelf = self;
    cell.moreTapped = ^(TVNCDeviceCardCell *c) {
        [weakSelf onDeviceCardMoreTapped:c device:d];
    };
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    NSInteger cols = MAX(1, self.gridColumns);
    CGFloat total = collectionView.bounds.size.width;
    if (total <= 0) total = self.view.bounds.size.width;
    if (total <= 0) total = 320;
    CGFloat spacing = 12;
    CGFloat insets = 16 * 2 + spacing * (cols - 1);
    CGFloat w = (total - insets) / cols;
    if (w < 60) w = 60;
    // 竖屏比例（默认）：宽高比 9:16
    CGFloat ratio = 16.0 / 9.0;
    return CGSizeMake(w, floor(w * ratio));
}

#pragma mark - 卡片墙 RFB 连接生命周期（Phase 12.1 WKWebView 改造）

/// 宫格 cell 即将显示：根据可见性启动 RFB 连接（受最大并发数限制）。
- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)ip {
    if (self.viewMode != 0) return; // 仅宫格视图使用 RFB
    if (![cell isKindOfClass:[TVNCDeviceCardCell class]]) return;
    TVNCDeviceCardCell *dc = (TVNCDeviceCardCell *)cell;
    NSDictionary *d = self.shown[ip.row];
    if (![d[@"online"] boolValue]) return;
    // 受最大并发数限制：已满则不启动（显示缓存帧）
    if (self.activeWallConnections >= kMaxConcurrentWallConnections) return;
    self.activeWallConnections++;
    [dc startWallWebViewWithDevice:d
                       gatewayHost:[self.defaults stringForKey:@"GatewayHost"]
                       gatewayPort:[self gatewayPort]
                             token:[self.defaults stringForKey:@"GatewayToken"]];
}

/// 宫格 cell 移出屏幕：断开 RFB 连接，缓存最后帧供不可见占位。
- (void)collectionView:(UICollectionView *)collectionView
     didEndDisplayingCell:(UICollectionViewCell *)cell
      forItemAtIndexPath:(NSIndexPath *)ip {
    if (![cell isKindOfClass:[TVNCDeviceCardCell class]]) return;
    TVNCDeviceCardCell *dc = (TVNCDeviceCardCell *)cell;
    NSDictionary *d = (ip.row < self.shown.count) ? self.shown[ip.row] : nil;
    [self cacheSnapshotForCardCell:dc deviceId:d[@"id"]];
    [dc stopWallWebView];
    if (self.activeWallConnections > 0) self.activeWallConnections--;
}

/// 列表 cell 即将显示：宫格视图不触发（列表仅显示缓存帧，不建立 RFB）。
- (void)tableView:(UITableView *)tableView
       willDisplayCell:(UITableViewCell *)cell
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 列表视图走缓存帧，无需实时 RFB
}

/// 列表 cell 移出屏幕：缓存最后帧。
- (void)tableView:(UITableView *)tableView
     didEndDisplayingCell:(UITableViewCell *)cell
       forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:[TVNCDeviceListCell class]]) {
        TVNCDeviceListCell *lc = (TVNCDeviceListCell *)cell;
        UIImage *img = [self snapshotFromView:lc.thumbView];
        if (img && indexPath.row < self.shown.count) {
            NSDictionary *d = self.shown[indexPath.row];
            if (d[@"id"]) self.snapshotCache[d[@"id"]] = img;
        }
    }
}

/// 缓存宫格卡片 wallWebView 的最后帧到 snapshotCache。
/// @param cell     卡片 cell
/// @param deviceId 设备 ID（用于缓存 key）
- (void)cacheSnapshotForCardCell:(TVNCDeviceCardCell *)cell deviceId:(NSString *)deviceId {
    if (!deviceId.length) return;
    UIImage *img = [self snapshotFromView:cell.wallWebView];
    if (img) self.snapshotCache[deviceId] = img;
}

/// 从视图截取快照 UIImage。
/// @param view 目标视图
/// @return 快照图；失败返回 nil
- (UIImage *)snapshotFromView:(UIView *)view {
    if (!view || view.bounds.size.width <= 0 || view.bounds.size.height <= 0) return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
    }];
}

/// 停止所有可见 cell 的 RFB 连接（视图消失时调用）。
- (void)stopAllWallConnections {
    NSArray *visible = [self.collectionView indexPathsForVisibleItems];
    for (NSIndexPath *ip in visible) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:ip];
        if ([cell isKindOfClass:[TVNCDeviceCardCell class]]) {
            TVNCDeviceCardCell *dc = (TVNCDeviceCardCell *)cell;
            NSDictionary *d = (ip.row < self.shown.count) ? self.shown[ip.row] : nil;
            [self cacheSnapshotForCardCell:dc deviceId:d[@"id"]];
            [dc stopWallWebView];
        }
    }
    self.activeWallConnections = 0;
}

/// 恢复可见宫格 cell 的 RFB 连接（页面重新出现时调用，受最大并发数限制）。
- (void)startVisibleWallConnections {
    if (self.viewMode != 0) return; // 仅宫格视图使用 RFB
    NSArray *visible = [self.collectionView indexPathsForVisibleItems];
    for (NSIndexPath *ip in visible) {
        if (self.activeWallConnections >= kMaxConcurrentWallConnections) break;
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:ip];
        if (![cell isKindOfClass:[TVNCDeviceCardCell class]]) continue;
        TVNCDeviceCardCell *dc = (TVNCDeviceCardCell *)cell;
        NSDictionary *d = (ip.row < self.shown.count) ? self.shown[ip.row] : nil;
        if (!d || ![d[@"online"] boolValue]) continue;
        if (dc.wallWebView.state == TRWallTileStateConnected ||
            dc.wallWebView.state == TRWallTileStateConnecting) continue; // 已连接/连接中跳过
        self.activeWallConnections++;
        [dc startWallWebViewWithDevice:d
                           gatewayHost:[self.defaults stringForKey:@"GatewayHost"]
                           gatewayPort:[self gatewayPort]
                                 token:[self.defaults stringForKey:@"GatewayToken"]];
    }
}

/// 从网关配置读取控制台 HTTP 端口。
/// @return 网关 HTTP 端口
- (NSInteger)gatewayPort {
    NSInteger port = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (port <= 0) port = kConsolePort;
    return port;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [collectionView deselectItemAtIndexPath:ip animated:YES];
    NSDictionary *d = self.shown[ip.row];
    NSString *did = d[@"id"];
    // 多选模式：勾选/取消勾选
    if (self.multiMode) {
        if (did.length) {
            if ([self.selectedDevices containsObject:did]) {
                [self.selectedDevices removeObject:did];
            } else {
                [self.selectedDevices addObject:did];
            }
            [self updateMultiSelectUI];
        }
        return;
    }
    // 浏览模式：进入大屏操控
    [self pushViewerForDevice:d];
}

#pragma mark - 列表 TableView 数据源

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    TVNCDeviceListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"listCell" forIndexPath:indexPath];
    NSDictionary *d = self.shown[indexPath.row];
    UIImage *thumb = self.snapshotCache[d[@"id"]]; // 使用缓存帧
    NSString *did = d[@"id"];
    BOOL selected = did.length && [self.selectedDevices containsObject:did];
    [cell configureWithDevice:d thumbnail:thumb selected:(self.multiMode && selected)];
    __weak typeof(self) weakSelf = self;
    cell.moreTapped = ^(TVNCDeviceListCell *c) {
        [weakSelf onListCellMoreTapped:c device:d];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.shown[indexPath.row];
    NSString *did = d[@"id"];
    if (self.multiMode) {
        if (did.length) {
            if ([self.selectedDevices containsObject:did]) {
                [self.selectedDevices removeObject:did];
            } else {
                [self.selectedDevices addObject:did];
            }
            [self updateMultiSelectUI];
        }
        return;
    }
    [self pushViewerForDevice:d];
}

#pragma mark - 进入大屏操控

/// 推入 TVNCViewerViewController 进行大屏操控。
/// register 来源设备走网关隧道，其余走直连。
/// @param d 设备数据字典
- (void)pushViewerForDevice:(NSDictionary *)d {
    NSString *deviceId = d[@"id"];
    NSString *source = d[@"source"];
    if ([source isEqualToString:@"register"] && deviceId.length) {
        NSString *gatewayHost = [self.defaults stringForKey:@"GatewayHost"];
        NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
        if (consolePort <= 0) consolePort = kConsolePort;
        if (gatewayHost.length) {
            TVNCViewerViewController *viewer = [[TVNCViewerViewController alloc]
                initWithHost:gatewayHost port:(int)consolePort name:d[@"name"] ?: deviceId];
            viewer.useGatewayTunnel = YES;
            viewer.deviceId = deviceId;
            [self.navigationController pushViewController:viewer animated:YES];
            return;
        }
    }
    NSString *host = d[@"host"];
    if (!host.length) return;
    int port = (int)([d[@"port"] integerValue] ?: 5901);
    TVNCViewerViewController *viewer = [[TVNCViewerViewController alloc] initWithHost:host port:port name:d[@"name"] ?: host];
    [self.navigationController pushViewController:viewer animated:YES];
}

#pragma mark - 设备能力菜单（⋯按钮 → UIAlertController actionSheet）

/// 宫格卡片⋯按钮点击回调：弹出按 category 分组的能力菜单。
/// @param cell   触发事件的卡片 cell
/// @param device 对应设备数据字典
- (void)onDeviceCardMoreTapped:(TVNCDeviceCardCell *)cell device:(NSDictionary *)device {
    [self presentCapabilitiesMenuWithSourceView:cell.contentView sourceRect:cell.moreButton.frame device:device];
}

/// 列表行⋯按钮点击回调：弹出按 category 分组的能力菜单。
/// @param cell   触发事件的列表 cell
/// @param device 对应设备数据字典
- (void)onListCellMoreTapped:(TVNCDeviceListCell *)cell device:(NSDictionary *)device {
    [self presentCapabilitiesMenuWithSourceView:cell.contentView sourceRect:cell.moreButton.frame device:device];
}

/// 通用能力菜单弹窗：异步拉取 capMetadata 后按 category 分组展示。
/// @param sourceView 弹窗锚点视图
/// @param sourceRect 弹窗锚点区域
/// @param device     设备数据字典
- (void)presentCapabilitiesMenuWithSourceView:(UIView *)sourceView
                                   sourceRect:(CGRect)sourceRect
                                       device:(NSDictionary *)device {
    NSString *deviceId = device[@"id"];
    if (!deviceId.length) return;
    NSString *deviceName = device[@"name"] ?: deviceId;

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:nil
                                                                     message:@"正在拉取设备能力列表…"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    [self fetchCapMetadataForDevice:deviceId completion:^(NSArray<NSDictionary *> *caps) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [loading dismissViewControllerAnimated:NO completion:^{
            [strongSelf showCapabilitiesMenu:deviceId deviceName:deviceName caps:caps sourceView:sourceView sourceRect:sourceRect];
        }];
    }];
}

/// 通过网关 API GET /api/devices/:id/caps 获取设备能力元数据。
/// @param deviceId   目标设备 ID
/// @param completion 完成回调（main queue），caps 为 capMetadata 数组；失败为 nil
- (void)fetchCapMetadataForDevice:(NSString *)deviceId
                       completion:(void (^)(NSArray<NSDictionary *> *caps))completion {
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length || !deviceId.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices/%@/caps",
                       host, (long)consolePort, deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 6.0;
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
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

/// 展示能力菜单（actionSheet），按 category 分组，每能力一个 action。
/// @param deviceId   设备 ID
/// @param deviceName 设备显示名
/// @param caps       能力元数据数组
/// @param sourceView 锚点视图
/// @param sourceRect 锚点区域
- (void)showCapabilitiesMenu:(NSString *)deviceId
                  deviceName:(NSString *)deviceName
                         caps:(NSArray<NSDictionary *> *)caps
                  sourceView:(UIView *)sourceView
                  sourceRect:(CGRect)sourceRect {
    NSString *title = [NSString stringWithFormat:@"%@ 的能力", deviceName];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sourceView;
        sheet.popoverPresentationController.sourceRect = sourceRect;
    }

    if (!caps.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"设备未上报能力"
                                                  style:UIAlertActionStyleDefault handler:nil]];
    } else {
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
        for (NSString *cat in order) {
            for (NSDictionary *cap in groups[cat]) {
                NSString *capId = cap[@"id"] ?: @"";
                NSString *capTitle = cap[@"title"] ?: capId;
                NSString *prefix = [NSString stringWithFormat:@"[%@] ", [self categoryChineseTitle:cat]];
                NSString *actionTitle = [prefix stringByAppendingString:capTitle];
                __weak typeof(self) weakSelf = self;
                [sheet addAction:[UIAlertAction actionWithTitle:actionTitle
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
                                                            [weakSelf invokeCap:capId params:nil forDevice:deviceId];
                                                        }]];
            }
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 能力 category 标识 → 中文分组标题映射。
/// @param category 能力分类标识
/// @return 中文分组标题
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

/// 通过网关 invoke API 调用设备能力（POST /api/devices/:id/invoke）。
/// 大屏操控时的单帧截图等能力通过此方法下发。
/// @param capId    能力 ID
/// @param params   调用参数（可为 nil）
/// @param deviceId 目标设备 ID
- (void)invokeCap:(NSString *)capId params:(NSDictionary *)params forDevice:(NSString *)deviceId {
    if (!capId.length || !deviceId.length) return;
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length) return;
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices/%@/invoke",
                       host, (long)consolePort, deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSDictionary *body = @{@"cap": capId, @"params": params ?: @{}};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    req.HTTPBody = bodyData;
    req.timeoutInterval = 6.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:nil] resume];
}

#pragma mark - 批量配置流程（Phase 12.6）

/// 弹出批量配置表单：从网关 GET /api/devices/:id/caps 获取 configSchema，
/// 按 reload 字段分区显示（instant/hot/gateway/restart），用户选择后输入值并批量下发。
- (void)presentBatchConfigForm {
    if (self.selectedDevices.count == 0) return;
    NSString *firstDeviceId = [self.selectedDevices anyObject];

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:nil
                                                                     message:@"正在拉取配置项…"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    [self fetchConfigSchemaForDevice:firstDeviceId completion:^(NSArray<NSDictionary *> *schema) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [loading dismissViewControllerAnimated:NO completion:^{
            [strongSelf showBatchConfigMenu:schema];
        }];
    }];
}

/// 通过网关 API GET /api/devices/:id/caps 获取配置 schema（configSchema 字段）。
/// @param deviceId   目标设备 ID
/// @param completion 完成回调（main queue），schema 为配置项数组；失败为 nil
- (void)fetchConfigSchemaForDevice:(NSString *)deviceId
                        completion:(void (^)(NSArray<NSDictionary *> *schema))completion {
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length || !deviceId.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices/%@/caps",
                       host, (long)consolePort, deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 6.0;
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *schema = nil;
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id s = json[@"configSchema"];
                if ([s isKindOfClass:[NSArray class]]) schema = s;
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(schema); });
    }];
    [task resume];
}

/// 展示批量配置菜单：按 reload 分区列出配置项，选择后弹出输入框，确认后批量下发。
/// @param schema 配置 schema 数组（每项含 key/label/reload/default 等）
- (void)showBatchConfigMenu:(NSArray<NSDictionary *> *)schema {
    if (!schema.count) {
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:nil
                                                                     message:@"该设备未上报配置项"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:tip animated:YES completion:nil];
        return;
    }

    // 按 reload 分组并保持顺序
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *item in schema) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *reload = item[@"reload"] ?: @"instant";
        if (!groups[reload]) {
            groups[reload] = [NSMutableArray array];
            [order addObject:reload];
        }
        [groups[reload] addObject:item];
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"批量调整配置"
                                                                    message:[NSString stringWithFormat:@"将应用到 %ld 台设备", (long)self.selectedDevices.count]
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *reload in order) {
        for (NSDictionary *item in groups[reload]) {
            NSString *key = item[@"key"] ?: @"";
            NSString *label = item[@"label"] ?: key;
            NSString *prefix = [NSString stringWithFormat:@"[%@] ", [self reloadChineseTitle:reload]];
            NSString *title = [prefix stringByAppendingString:label];
            __weak typeof(self) weakSelf = self;
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                                                        [weakSelf promptConfigValueForItem:item];
                                                    }]];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

/// reload 标识 → 中文标题映射。
/// @param reload reload 标识（instant/hot/gateway/restart）
/// @return 中文标题
- (NSString *)reloadChineseTitle:(NSString *)reload {
    static NSDictionary *mapping = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mapping = @{
            @"instant": @"即时生效",
            @"hot":     @"热重载",
            @"gateway": @"网关配置",
            @"restart": @"需重启",
        };
    });
    if (!reload.length) return @"即时生效";
    NSString *t = mapping[reload];
    return t.length ? t : reload;
}

/// 弹出输入框供用户填写配置值，确认后批量下发到所有已选设备。
/// @param item 配置 schema 项（含 key/label/default）
- (void)promptConfigValueForItem:(NSDictionary *)item {
    NSString *key = item[@"key"] ?: @"";
    NSString *label = item[@"label"] ?: key;
    NSString *defVal = [item[@"default"] isKindOfClass:[NSString class]] ? item[@"default"]
                       : [item[@"default"] description];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"设置 %@", label]
                                                                   message:[NSString stringWithFormat:@"配置键：%@", key]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = defVal ?: @"";
        tf.placeholder = @"输入新值";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下发" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *val = alert.textFields.firstObject.text ?: @"";
        [weakSelf batchApplyConfig:key value:val];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 批量下发配置到所有已选设备（逐台 POST /api/devices/:id/config），完成后 toast 提示并退出多选。
/// @param key   配置键
/// @param value 配置值
- (void)batchApplyConfig:(NSString *)key value:(NSString *)value {
    if (!key.length) return;
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length) return;
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];

    NSDictionary *body = @{@"key": key, @"value": value};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return;

    __block NSInteger remaining = self.selectedDevices.count;
    __block NSInteger success = 0;
    NSArray<NSString *> *allIds = [self.selectedDevices allObjects];
    __weak typeof(self) weakSelf = self;

    for (NSString *did in allIds) {
        NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices/%@/config",
                           host, (long)consolePort, did];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) {
            @synchronized(self) { remaining--; }
            continue;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        if (token.length) {
            [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        }
        req.HTTPBody = bodyData;
        req.timeoutInterval = 6.0;
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @synchronized(weakSelf) {
                remaining--;
                if (!err) success++;
                if (remaining <= 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf showBatchResultToast:success total:allIds.count key:key];
                    });
                }
            }
        }];
        [task resume];
    }
}

/// 显示批量配置结果 toast 并退出多选模式。
/// @param success 成功数
/// @param total   总数
/// @param key     配置键
- (void)showBatchResultToast:(NSInteger)success total:(NSInteger)total key:(NSString *)key {
    UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                   message:[NSString stringWithFormat:@"已下发 %@ 到 %ld/%ld 台设备", key, (long)success, (long)total]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [toast dismissViewControllerAnimated:YES completion:^{
                [self exitMultiSelect];
            }];
        });
    }];
}

@end
