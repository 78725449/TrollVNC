/*
  TRCapabilityRegistry - 能力即服务注册表（Phase 4.1）
  功能：统一管理所有 IPA 能力（控制型 + 配置型），提供自描述元数据与统一执行入口。
       新增能力只需在 .mm 内注册一行（metadata + executor），无需改其他文件。
  设计基线（已确认决策）：
    - 能力二分类：control（即时执行，一级菜单）/ config（状态调整，二级菜单）
    - 作用域：单台 / 批量（由调用方决定，注册表不关心）
    - 触控坐标：归一化 0-1（跨设备脚本复用），设备侧转原生像素
    - 配置生效：instant（立即）/ hot（热重载）/ gateway（网关刷新）/ restart（需重启）
*/
#ifndef TRCapabilityRegistry_h
#define TRCapabilityRegistry_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 能力分类（决定 UI 分组：一级菜单 vs 二级菜单） */
typedef NS_ENUM(NSInteger, TRCapCategory) {
    TRCapCategoryControl = 0, // 控制型：一级菜单，即时执行
    TRCapCategoryConfig   = 1, // 配置型：二级菜单，状态调整
};

/** 执行路由类型（invoke 命令据此分发到不同执行通道） */
typedef NS_ENUM(NSInteger, TRCapRouteType) {
    TRCapRouteHID      = 0, // 直接调用 STHIDEventGenerator 注入硬件事件
    TRCapRouteTouch    = 1, // 触控类，归一化坐标转原生像素后注入 HID
    TRCapRouteLocalCmd = 2, // 经 5901 RFB 扩展消息（_rfbCommand 持久连接）
    TRCapRouteNative   = 3, // 其他原生 Objective-C 调用（剪贴板/截屏等）
};

/** 配置生效策略（set 命令据此决定重载方式，前端据此分区显示） */
typedef NS_ENUM(NSInteger, TRConfigReload) {
    TRConfigReloadInstant = 0, // 立即生效：无副作用，下次读取自动用新值
    TRConfigReloadHot     = 1, // 热重载：trollvncserver 监听变更并重载相关模块
    TRConfigReloadGateway = 2, // 网关刷新：改变注册字段，触发重新上报
    TRConfigReloadRestart = 3, // 需重启：端口/认证/RFB 协议头变更
};

/**
 * 能力注册表（单例）
 * 启动时自动注册所有能力模块（数据驱动表），对外提供：
 *  - 本地 executor 容器（capabilities/capMetadata 不再随 register 上报；configs 上报当前值）
 *  - invoke 统一执行入口（按 route 自动路由，不写 if/else 业务分支）
 *  - setConfig 统一配置入口（写 NSUserDefaults + 返回 reload 策略）
 */
@interface TRCapabilityRegistry : NSObject

+ (instancetype)sharedRegistry;

#pragma mark - 能力查询（query 命令通道用，2026-08-13 起不再随 register 上报）

/** 所有控制型能力完整元数据（含 id/title/icon/route/params） */
- (NSArray<NSDictionary *> *)allControlMetadata;

#pragma mark - 配置查询（供上报 configs[]）

/** 所有配置项的 schema 元数据（含 key/type/min/max/enum/reload，供前端生成表单） */
- (NSArray<NSDictionary *> *)allConfigSchema;

/** 所有配置项的当前值（读 NSUserDefaults，供上报 configs[]） */
- (NSDictionary *)currentConfigs;

#pragma mark - 能力调用（invoke 统一入口）

/**
 * 调用控制型能力（按 capId 查 executor 分发）
 * @param capId  能力 ID（如 "home" / "service.restart" / "screenshot"）
 * @param params 参数字典
 * @param error  失败时设置错误
 * @return 成功返回结果字典（含 ok/result），失败返回 nil
 */
- (nullable NSDictionary *)invoke:(NSString *)capId
                           params:(NSDictionary *)params
                            error:(NSError **)error;

#pragma mark - 配置下发（set 统一入口）

/**
 * 设置配置项（写 NSUserDefaults + 返回生效策略）
 * @param key   配置键（如 "Scale" / "FrameRateSpec"）
 * @param value 新值（类型校验见 schema）
 * @param error 失败时设置错误（类型不符/超出范围）
 * @return 成功返回 reload 策略字符串（instant/hot/gateway/restart），失败返回 nil
 */
- (nullable NSString *)setConfig:(NSString *)key
                           value:(id)value
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TRCapabilityRegistry_h */
