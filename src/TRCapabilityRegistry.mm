/*
  TRCapabilityRegistry.mm - 能力即服务注册表实现（Phase 4.1）
  数据驱动设计：能力/配置以表项注册，新增能力只需加一行 _registerControl/_registerConfig。
  执行路由：HID 注入 / 触控（归一化坐标）/ 本地命令 / 原生调用，不写 if/else 业务分支。
*/
#import "TRCapabilityRegistry.h"
#import "STHIDEventGenerator.h"
#import "ClipboardManager.h"
#import "ScreenCapturer.h"
#import "TRGatewayClient.h"
#import "TRWatchDog.h"
#import "BulletinManager.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

// trollvncserver.mm 公开访问函数（供系统查询能力调用）
extern NSDictionary *tvGetInflightStats(void);
extern NSDictionary *tvGetBonjourTXT(void);
// Phase 4.4：trollvncserver 配置热重载入口（hot 级别 key 更新 C 全局变量 + 副作用）
extern int tvReloadConfigForKey(const char *key);

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
// 本地控制端口（来自 Control.h 的 kTvDefaultCtlPort，仅 127.0.0.1 回环）
static const int kLocalCmdPort = 46752;
// Phase 11.4：本地命令 socket 超时常量（毫秒，统一管理）
// 短命令默认超时：count/list/disconnect/block/unblock/subscribe/blocked.list/screen.hash/screen.diff 等
// 本地回环实际响应 <50ms，3 秒超时已含极端 CPU 满载余量
static const NSTimeInterval kLocalCmdDefaultTimeoutMs = 3000;

#pragma mark - 预置读取辅助（未设置时回退默认值）

/** 读取 BOOL 配置，区分"未设置"与"显式 NO" */
static BOOL TRBoolPref(NSUserDefaults *d, NSString *key, BOOL def) {
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
/** 读取整数配置，未设置回退默认 */
static NSInteger TRIntPref(NSUserDefaults *d, NSString *key, NSInteger def) {
    id v = [d objectForKey:key];
    return v ? [v integerValue] : def;
}
/** 读取浮点配置，未设置回退默认 */
static double TRDoublePref(NSUserDefaults *d, NSString *key, double def) {
    id v = [d objectForKey:key];
    return v ? [v doubleValue] : def;
}
/** 读取字符串配置，未设置回退默认 */
static NSString *TRStrPref(NSUserDefaults *d, NSString *key, NSString *def) {
    id v = [d objectForKey:key];
    if (!v) return def;
    NSString *s = [v description];
    return s.length ? s : def;
}

#pragma mark - 内部表项结构

/** 控制型能力表项（metadata + executor block） */
@interface TRControlCap : NSObject
@property(nonatomic, copy) NSString *capId;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *icon;
@property(nonatomic, copy) NSString *category;  // Phase 10.3：能力分类（hid/touch/stylus/system/native/service/gateway）
@property(nonatomic, assign) TRCapRouteType routeType;
@property(nonatomic, copy) NSArray *params;
// Phase 11.1：场景化分层字段
@property(nonatomic, copy) NSString *menuLevel;  // primary/secondary/internal（默认 primary）
@property(nonatomic, copy) NSArray *scenes;      // [single,batch,ai] 子集（默认 [single]）
@property(nonatomic, assign) BOOL batchSupport;  // scenes 含 batch 的快捷判断
@property(nonatomic, copy) NSDictionary * _Nullable (^executor)(NSDictionary *params, NSError **error);
@end
@implementation TRControlCap @end

/** 配置型能力表项（schema） */
@interface TRConfigCap : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *type;   // bool/number/string/enum
@property(nonatomic, copy) NSNumber * _Nullable min;
@property(nonatomic, copy) NSNumber * _Nullable max;
@property(nonatomic, copy) NSNumber * _Nullable step;
@property(nonatomic, copy) NSArray * _Nullable enumValues;
@property(nonatomic, copy) NSArray * _Nullable enumTitles;
@property(nonatomic, assign) TRConfigReload reload;
@end
@implementation TRConfigCap @end

#pragma mark - 注册表实现

@interface TRCapabilityRegistry () {
    NSUserDefaults *_defaults;
    NSMutableDictionary<NSString *, TRControlCap *> *_controlCaps; // capId -> 表项
    NSMutableDictionary<NSString *, TRConfigCap *> *_configCaps;    // key -> schema
}
@end

@implementation TRCapabilityRegistry

/** 单例 */
+ (instancetype)sharedRegistry {
    static TRCapabilityRegistry *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[TRCapabilityRegistry alloc] init]; });
    return inst;
}

/** 初始化：注册所有能力模块 */
- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _controlCaps = [NSMutableDictionary dictionary];
        _configCaps = [NSMutableDictionary dictionary];
        [self _registerAllCapabilities];
    }
    return self;
}

#pragma mark - 能力注册（HID 控制型）

/** 注册所有能力模块（数据驱动，新增能力在此追加一行即可） */
- (void)_registerAllCapabilities {
    [self _registerHIDCapabilities];
    [self _registerTouchCapabilities];
    [self _registerStylusCapabilities];
    [self _registerNativeCapabilities];
    [self _registerBulletinCapabilities];
    [self _registerWatchdogCapabilities];
    [self _registerLocalCmdCapabilities];
    [self _registerSystemQueryCapabilities];
    [self _registerScreenExtCapabilities];
    [self _registerGatewayCapabilities];
    [self _registerScreenHashCapabilities];
    [self _registerConfigSchemas];
}

/** 注册 HID 硬件注入能力（Home/电源/音量/亮度/键盘等） */
- (void)_registerHIDCapabilities {
    STHIDEventGenerator *hid = [STHIDEventGenerator sharedGenerator];
    [self _registerControl:@"home"      title:@"Home 键"  icon:@"🏠" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid menuPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"power"     title:@"电源"     icon:@"⏻"  route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid powerPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"volup"     title:@"音量 +"   icon:@"🔊" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid volumeIncrementPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"voldn"      title:@"音量 −"  icon:@"🔉" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid volumeDecrementPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"mute"       title:@"静音"    icon:@"🔇" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid mutePress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"briup"      title:@"亮度 +"  icon:@"☀️" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid displayBrightnessIncrementPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"bridn"      title:@"亮度 −"  icon:@"🌙" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid displayBrightnessDecrementPress]; return @{@"ok":@YES};
    }];
    [self _registerControl:@"keyboard"   title:@"键盘"    icon:@"⌨️" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid toggleOnScreenKeyboard]; return @{@"ok":@YES};
    }];
    // Batch 1：无参数 HID 能力批量注册（24 项，数组驱动避免重复模式代码）
    NSArray<NSDictionary *> *hidNoParam = @[
        @{@"id":@"spotlight",   @"title":@"搜索",       @"icon":@"🔍",  @"sel":NSStringFromSelector(@selector(toggleSpotlight))},
        @{@"id":@"home.double", @"title":@"双击Home",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuDoublePress))},
        @{@"id":@"home.long",   @"title":@"长按Home",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuLongPress))},
        @{@"id":@"power.double",@"title":@"双击电源",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerDoublePress))},
        @{@"id":@"power.triple",@"title":@"三击电源",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerTriplePress))},
        @{@"id":@"power.long",  @"title":@"长按电源",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerLongPress))},
        @{@"id":@"snapshot",    @"title":@"Home+Power截屏", @"icon":@"📸", @"sel":NSStringFromSelector(@selector(snapshotPress))},
        @{@"id":@"home.down",   @"title":@"Home按下",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuDown))},
        @{@"id":@"home.up",     @"title":@"Home抬起",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuUp))},
        @{@"id":@"power.down",  @"title":@"电源按下",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerDown))},
        @{@"id":@"power.up",    @"title":@"电源抬起",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerUp))},
        @{@"id":@"volup.down",  @"title":@"音量+按下",  @"icon":@"🔊",  @"sel":NSStringFromSelector(@selector(volumeIncrementDown))},
        @{@"id":@"volup.up",    @"title":@"音量+抬起",  @"icon":@"🔊",  @"sel":NSStringFromSelector(@selector(volumeIncrementUp))},
        @{@"id":@"voldn.down",  @"title":@"音量−按下",  @"icon":@"🔉",  @"sel":NSStringFromSelector(@selector(volumeDecrementDown))},
        @{@"id":@"voldn.up",    @"title":@"音量−抬起",  @"icon":@"🔉",  @"sel":NSStringFromSelector(@selector(volumeDecrementUp))},
        @{@"id":@"mute.down",   @"title":@"静音按下",   @"icon":@"🔇",  @"sel":NSStringFromSelector(@selector(muteDown))},
        @{@"id":@"mute.up",     @"title":@"静音抬起",   @"icon":@"🔇",  @"sel":NSStringFromSelector(@selector(muteUp))},
        @{@"id":@"briup.down",  @"title":@"亮度+按下",  @"icon":@"☀️",  @"sel":NSStringFromSelector(@selector(displayBrightnessIncrementDown))},
        @{@"id":@"briup.up",    @"title":@"亮度+抬起",  @"icon":@"☀️",  @"sel":NSStringFromSelector(@selector(displayBrightnessIncrementUp))},
        @{@"id":@"bridn.down",  @"title":@"亮度−按下",  @"icon":@"🌙",  @"sel":NSStringFromSelector(@selector(displayBrightnessDecrementDown))},
        @{@"id":@"bridn.up",    @"title":@"亮度−抬起",  @"icon":@"🌙",  @"sel":NSStringFromSelector(@selector(displayBrightnessDecrementUp))},
        @{@"id":@"hwlock",      @"title":@"硬件键盘锁", @"icon":@"🔒",  @"sel":NSStringFromSelector(@selector(hardwareLock))},
        @{@"id":@"hwunlock",    @"title":@"硬件键盘解锁",@"icon":@"🔓", @"sel":NSStringFromSelector(@selector(hardwareUnlock))},
        @{@"id":@"releasekeys", @"title":@"释放所有按键",@"icon":@"🙊", @"sel":NSStringFromSelector(@selector(releaseEveryKeys))},
    ];
    for (NSDictionary *item in hidNoParam) {
        SEL sel = NSSelectorFromString(item[@"sel"]);
        NSString *capId = item[@"id"];
        [self _registerControl:capId title:item[@"title"] icon:item[@"icon"] route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            ((void(*)(id,SEL))[hid methodForSelector:sel])(hid, sel);
            return @{@"ok":@YES};
        }];
    }
    // screenshot.system：系统截屏（存相册，与静默 screenshot 区分）
    [self _registerControl:@"screenshot.system" title:@"系统截屏" icon:@"📸" route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        [hid snapshotPress]; return @{@"ok":@YES};
    }];
    // Consumer 用法（3 项）：params {usage:int}
    NSArray *consumerIds = @[@"consumer.press", @"consumer.down", @"consumer.up"];
    NSArray *consumerSels = @[@"otherConsumerUsagePress:", @"otherConsumerUsageDown:", @"otherConsumerUsageUp:"];
    for (NSUInteger i = 0; i < consumerIds.count; i++) {
        NSString *capId = consumerIds[i]; SEL sel = NSSelectorFromString(consumerSels[i]);
        [self _registerControl:capId title:(i==0?@"Consumer按下":(i==1?@"Consumer按下":@"Consumer抬起"))
                          icon:@"🎛" route:TRCapRouteHID
            params:@[@{@"name":@"usage",@"type":@"number",@"min":@0,@"max":@0xFFFFFFFF,@"required":@YES}]
            executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                uint32_t usage = (uint32_t)[p[@"usage"] unsignedIntValue];
                ((void(*)(id,SEL,uint32_t))[hid methodForSelector:sel])(hid, sel, usage);
                return @{@"ok":@YES, @"usage":@(usage)};
            }];
    }
    // 任意页+用法（3 项）：params {page:int, usage:int}
    NSArray *hidPageIds = @[@"hid.press", @"hid.down", @"hid.up"];
    NSArray *hidPageSels = @[@"otherPage:usagePress:", @"otherPage:usageDown:", @"otherPage:usageUp:"];
    for (NSUInteger i = 0; i < hidPageIds.count; i++) {
        NSString *capId = hidPageIds[i]; SEL sel = NSSelectorFromString(hidPageSels[i]);
        [self _registerControl:capId title:(i==0?@"HID按下":(i==1?@"HID按下":@"HID抬起"))
                          icon:@"🕹" route:TRCapRouteHID
            params:@[@{@"name":@"page",@"type":@"number",@"min":@0,@"max":@0xFFFF,@"required":@YES},
                     @{@"name":@"usage",@"type":@"number",@"min":@0,@"max":@0xFFFF,@"required":@YES}]
            executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                uint32_t page = (uint32_t)[p[@"page"] unsignedIntValue];
                uint32_t usage = (uint32_t)[p[@"usage"] unsignedIntValue];
                ((void(*)(id,SEL,uint32_t,uint32_t))[hid methodForSelector:sel])(hid, sel, page, usage);
                return @{@"ok":@YES, @"page":@(page), @"usage":@(usage)};
            }];
    }
    // 键盘按下/抬起（2 项）：params {char:string(1)}
    [self _registerControl:@"key.down" title:@"按键按下" icon:@"⬇" route:TRCapRouteHID
        params:@[@{@"name":@"char",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *c = p[@"char"];
            if (c.length != 1) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"char 需为单字符"}]; return nil; }
            [hid keyDown:c]; return @{@"ok":@YES};
        }];
    [self _registerControl:@"key.up" title:@"按键抬起" icon:@"⬆" route:TRCapRouteHID
        params:@[@{@"name":@"char",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *c = p[@"char"];
            if (c.length != 1) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"char 需为单字符"}]; return nil; }
            [hid keyUp:c]; return @{@"ok":@YES};
        }];
}

/** 注册触控类能力（归一化 0-1 坐标，设备侧转原生像素） */
- (void)_registerTouchCapabilities {
    STHIDEventGenerator *hid = [STHIDEventGenerator sharedGenerator];
    // 单点触控：params {x:0-1, y:0-1}
    [self _registerControl:@"touch.tap" title:@"点击" icon:@"👆" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid tap:pt]; return @{@"ok":@YES};
        }];
    // 滑动：params {x1,y1,x2,y2,duration}
    [self _registerControl:@"touch.swipe" title:@"滑动" icon:@"↔" route:TRCapRouteTouch
        params:@[@{@"name":@"x1",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y1",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"x2",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y2",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"duration",@"type":@"number",@"min":@0.1,@"max":@5.0,@"default":@0.5}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint s = [self _denormalizePoint:@{@"x":p[@"x1"],@"y":p[@"y1"]} error:e];
            if (s.x < 0) return nil;
            CGPoint ed = [self _denormalizePoint:@{@"x":p[@"x2"],@"y":p[@"y2"]} error:e];
            if (ed.x < 0) return nil;
            NSTimeInterval dur = [p[@"duration"] doubleValue] ?: 0.5;
            [hid dragLinearWithStartPoint:s endPoint:ed duration:dur];
            return @{@"ok":@YES};
        }];
    // 文本输入：params {text:"..."}（逐字符 keyPress，支持 ASCII）
    [self _registerControl:@"type.text" title:@"文本输入" icon:@"⌨" route:TRCapRouteTouch
        params:@[@{@"name":@"text",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *text = p[@"text"];
            if (text.length == 0) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"text 为空"}]; return nil; }
            for (NSUInteger i = 0; i < text.length; i++) {
                unichar c = [text characterAtIndex:i];
                if (c < 128) [hid keyPress:[NSString stringWithCharacters:&c length:1]];
            }
            return @{@"ok":@YES, @"count":@(text.length)};
        }];
    // Batch 3：粘贴输入（任意文本，支持中文/emoji）
    // 实现策略：先 setStringFromRemote 写入设备剪贴板，再模拟 Cmd+V 粘贴键序列
    [self _registerControl:@"type.paste" title:@"粘贴输入" icon:@"📋" route:TRCapRouteTouch
        params:@[@{@"name":@"text",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *text = p[@"text"];
            if (!text) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"text 缺失"}]; return nil; }
            // 1. 写入设备剪贴板（复用 clipboard.set 逻辑）
            [[ClipboardManager sharedManager] setStringFromRemote:text];
            // 2. 模拟 Cmd+V 粘贴键序列（COMMAND 映射 LeftGUI，v 映射 KeyboardV）
            [hid keyDown:@"COMMAND"];
            [hid keyDown:@"v"];
            [hid keyUp:@"v"];
            [hid keyUp:@"COMMAND"];
            return @{@"ok":@YES, @"length":@(text.length)};
        }];
    // Batch 1：多点触控与手势（12 项）
    // 双击/双指/三指/长按：params {x,y}
    NSArray *tapIds = @[@"touch.doubleTap", @"touch.twoFingerTap", @"touch.threeFingerTap", @"touch.longPress"];
    NSArray *tapSels = @[@"doubleTap:", @"twoFingerTap:", @"threeFingerTap:", @"longPress:"];
    NSArray *tapTitles = @[@"双击", @"双指点击", @"三指点击", @"长按"];
    NSArray *tapIcons = @[@"👆×2", @"✌️", @"🖐️", @"👆⌛"];
    for (NSUInteger i = 0; i < tapIds.count; i++) {
        SEL sel = NSSelectorFromString(tapSels[i]);
        [self _registerControl:tapIds[i] title:tapTitles[i] icon:tapIcons[i] route:TRCapRouteTouch
            params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                CGPoint pt = [self _denormalizePoint:p error:e];
                if (pt.x < 0) return nil;
                ((void(*)(id,SEL,CGPoint))[hid methodForSelector:sel])(hid, sel, pt);
                return @{@"ok":@YES};
            }];
    }
    // 曲线滑动：params {x1,y1,x2,y2,duration?}
    [self _registerControl:@"touch.curveSwipe" title:@"曲线滑动" icon:@"〰" route:TRCapRouteTouch
        params:@[@{@"name":@"x1",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y1",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"x2",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y2",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"duration",@"type":@"number",@"min":@0.1,@"max":@5.0,@"default":@0.5}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint s = [self _denormalizePoint:@{@"x":p[@"x1"],@"y":p[@"y1"]} error:e];
            if (s.x < 0) return nil;
            CGPoint ed = [self _denormalizePoint:@{@"x":p[@"x2"],@"y":p[@"y2"]} error:e];
            if (ed.x < 0) return nil;
            NSTimeInterval dur = [p[@"duration"] doubleValue] ?: 0.5;
            [hid dragCurveWithStartPoint:s endPoint:ed duration:dur];
            return @{@"ok":@YES};
        }];
    // 捏合缩放：params {bounds:{x,y,w,h}, scale, angle, duration}
    [self _registerControl:@"touch.pinch" title:@"捏合缩放" icon:@"🤏" route:TRCapRouteTouch
        params:@[@{@"name":@"bounds",@"type":@"object",@"required":@YES},
                 @{@"name":@"scale",@"type":@"number",@"min":@0.1,@"max":@10.0,@"required":@YES},
                 @{@"name":@"angle",@"type":@"number",@"min":@0,@"max":@(M_PI*2),@"default":@0},
                 @{@"name":@"duration",@"type":@"number",@"min":@0.1,@"max":@5.0,@"default":@0.5}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *b = p[@"bounds"];
            if (!b) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"bounds 缺失"}]; return nil; }
            // bounds 的 x/y/w/h 均为归一化 0-1，转原生像素（复用 _denormalizePoint 同款 UIScreen 获取方式）
            CGPoint o = [self _denormalizePoint:@{@"x":b[@"x"],@"y":b[@"y"]} error:e];
            if (o.x < 0) return nil;
            UIScreen *scr = [UIScreen mainScreen];
            CGFloat scale = [scr respondsToSelector:@selector(nativeScale)] ? [scr nativeScale] : [scr scale];
            if (scale <= 0) scale = 1.0;
            CGFloat w = [b[@"w"] doubleValue] * scr.bounds.size.width * scale;
            CGFloat h = [b[@"h"] doubleValue] * scr.bounds.size.height * scale;
            CGRect bounds = CGRectMake(o.x, o.y, w, h);
            CGFloat pinchScale = [p[@"scale"] doubleValue];
            CGFloat angle = [p[@"angle"] doubleValue] ?: 0;
            NSTimeInterval dur = [p[@"duration"] doubleValue] ?: 0.5;
            [hid pinchLinearInBounds:bounds scale:pinchScale angle:angle duration:dur];
            return @{@"ok":@YES};
        }];
    // 触摸按下/抬起：params {x,y}
    [self _registerControl:@"touch.down" title:@"触摸按下" icon:@"👇" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid touchDown:pt]; return @{@"ok":@YES};
        }];
    [self _registerControl:@"touch.up" title:@"触摸抬起" icon:@"👆" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid liftUp:pt]; return @{@"ok":@YES};
        }];
    // 多指同点按下/抬起：params {x,y,count}
    [self _registerControl:@"touch.downMulti" title:@"多指按下" icon:@"👥" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"count",@"type":@"number",@"min":@1,@"max":@30,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            NSUInteger count = [p[@"count"] unsignedIntegerValue];
            if (count < 1 || count > HIDMaxTouchCount) {
                *e = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"count 需在 1-%lu", (unsigned long)HIDMaxTouchCount]}];
                return nil;
            }
            [hid touchDown:pt touchCount:count]; return @{@"ok":@YES, @"count":@(count)};
        }];
    [self _registerControl:@"touch.upMulti" title:@"多指抬起" icon:@"👥" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"count",@"type":@"number",@"min":@1,@"max":@30,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            NSUInteger count = [p[@"count"] unsignedIntegerValue];
            if (count < 1 || count > HIDMaxTouchCount) {
                *e = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"count 需在 1-%lu", (unsigned long)HIDMaxTouchCount]}];
                return nil;
            }
            [hid liftUp:pt touchCount:count]; return @{@"ok":@YES, @"count":@(count)};
        }];
    // Batch 4：多指异点按下/抬起（每个触点独立坐标，params {points:[{x,y},...]}）
    [self _registerControl:@"touch.downMultiAt" title:@"多指异点按下" icon:@"🖐️" route:TRCapRouteTouch
        params:@[@{@"name":@"points",@"type":@"array",@"items":@{@"type":@"object",@"properties":@{@"x":@{@"type":@"number",@"min":@0,@"max":@1},@"y":@{@"type":@"number",@"min":@0,@"max":@1}},@"required":@[@"x",@"y"]},@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSArray *pts = p[@"points"];
            if (![pts isKindOfClass:[NSArray class]] || pts.count == 0) {
                *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"points 需为非空数组"}];
                return nil;
            }
            NSUInteger count = pts.count;
            if (count > HIDMaxTouchCount) {
                *e = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"触点数超过上限 %lu", (unsigned long)HIDMaxTouchCount]}];
                return nil;
            }
            CGPoint *locations = malloc(count * sizeof(CGPoint));
            if (!locations) { *e = [NSError errorWithDomain:@"TRCap" code:4 userInfo:@{NSLocalizedDescriptionKey:@"内存分配失败"}]; return nil; }
            for (NSUInteger i = 0; i < count; i++) {
                locations[i] = [self _denormalizePoint:pts[i] error:e];
                if (locations[i].x < 0) { free(locations); return nil; }
            }
            [hid touchDownAtPoints:locations touchCount:count];
            free(locations);
            return @{@"ok":@YES, @"count":@(count)};
        }];
    [self _registerControl:@"touch.upMultiAt" title:@"多指异点抬起" icon:@"🖐️" route:TRCapRouteTouch
        params:@[@{@"name":@"points",@"type":@"array",@"items":@{@"type":@"object",@"properties":@{@"x":@{@"type":@"number",@"min":@0,@"max":@1},@"y":@{@"type":@"number",@"min":@0,@"max":@1}},@"required":@[@"x",@"y"]},@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSArray *pts = p[@"points"];
            if (![pts isKindOfClass:[NSArray class]] || pts.count == 0) {
                *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"points 需为非空数组"}];
                return nil;
            }
            NSUInteger count = pts.count;
            if (count > HIDMaxTouchCount) {
                *e = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"触点数超过上限 %lu", (unsigned long)HIDMaxTouchCount]}];
                return nil;
            }
            CGPoint *locations = malloc(count * sizeof(CGPoint));
            if (!locations) { *e = [NSError errorWithDomain:@"TRCap" code:4 userInfo:@{NSLocalizedDescriptionKey:@"内存分配失败"}]; return nil; }
            for (NSUInteger i = 0; i < count; i++) {
                locations[i] = [self _denormalizePoint:pts[i] error:e];
                if (locations[i].x < 0) { free(locations); return nil; }
            }
            [hid liftUpAtPoints:locations touchCount:count];
            free(locations);
            return @{@"ok":@YES, @"count":@(count)};
        }];
    // Batch 4：重置触摸状态（清除所有触点）
    [self _registerControl:@"touch.reset" title:@"重置触摸" icon:@"🔄" route:TRCapRouteTouch params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [hid dispatchHandResetEvent]; return @{@"ok":@YES};
        }];
    // Batch 4：单事件派发（透传 eventInfo 字典）
    [self _registerControl:@"touch.event" title:@"单事件派发" icon:@"🎞️" route:TRCapRouteTouch
        params:@[@{@"name":@"eventInfo",@"type":@"object",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *eventInfo = p[@"eventInfo"];
            if (![eventInfo isKindOfClass:[NSDictionary class]]) {
                *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"eventInfo 需为对象"}];
                return nil;
            }
            [hid dispatchEventWithInfo:eventInfo];
            return @{@"ok":@YES};
        }];
    // 通用N击M指：params {x,y,tapCount,touchCount,delay}
    [self _registerControl:@"touch.taps" title:@"通用N击M指" icon:@"👆✖️N" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"tapCount",@"type":@"number",@"min":@1,@"max":@50,@"required":@YES},
                 @{@"name":@"touchCount",@"type":@"number",@"min":@1,@"max":@30,@"required":@YES},
                 @{@"name":@"delay",@"type":@"number",@"min":@0,@"max":@2.0,@"default":@0.15}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            NSUInteger tapCount = [p[@"tapCount"] unsignedIntegerValue];
            NSUInteger touchCount = [p[@"touchCount"] unsignedIntegerValue];
            NSTimeInterval delay = [p[@"delay"] doubleValue] ?: 0.15;
            [hid sendTaps:tapCount location:pt numberOfTouches:touchCount delayBetweenTaps:delay];
            return @{@"ok":@YES, @"tapCount":@(tapCount), @"touchCount":@(touchCount)};
        }];
    // 自定义事件流：params {eventInfo}（透传给 STHIDEventGenerator.sendEventStream:）
    [self _registerControl:@"touch.eventStream" title:@"自定义事件流" icon:@"🎞️" route:TRCapRouteTouch
        params:@[@{@"name":@"eventInfo",@"type":@"object",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *eventInfo = p[@"eventInfo"];
            if (![eventInfo isKindOfClass:[NSDictionary class]]) {
                *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"eventInfo 需为对象"}];
                return nil;
            }
            [hid sendEventStream:eventInfo];
            return @{@"ok":@YES};
        }];
}

/** 注册原生调用能力（剪贴板/截屏等） */
- (void)_registerNativeCapabilities {
    [self _registerControl:@"clipboard.get" title:@"获取剪贴板" icon:@"📋" route:TRCapRouteNative params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        // 读取设备当前剪贴板文本（空剪贴板返回空串，不报错；合并自原 clipboard.paste 空操作）
        NSString *text = [[ClipboardManager sharedManager] currentString] ?: @"";
        return @{@"ok":@YES, @"text":text};
    }];
    [self _registerControl:@"clipboard.set" title:@"设置剪贴板" icon:@"📋" route:TRCapRouteNative
        params:@[@{@"name":@"text",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *text = p[@"text"];
            if (!text) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"text 缺失"}]; return nil; }
            [[ClipboardManager sharedManager] setStringFromRemote:text];
            return @{@"ok":@YES};
        }];
    [self _registerControl:@"screenshot" title:@"截屏" icon:@"📷" route:TRCapRouteNative params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        // 静默截图：调用 ScreenCapturer 单帧捕获 → UIImage → JPEG base64（不触发系统动画，不存相册）
        UIImage *img = [[ScreenCapturer sharedCapturer] captureSingleFrameImage];
        if (!img) {
            *e = [NSError errorWithDomain:@"TRCap" code:99 userInfo:@{NSLocalizedDescriptionKey:@"截图失败：屏幕渲染或图像转换失败"}];
            return nil;
        }
        NSData *jpegData = UIImageJPEGRepresentation(img, 0.8);
        if (!jpegData) {
            *e = [NSError errorWithDomain:@"TRCap" code:98 userInfo:@{NSLocalizedDescriptionKey:@"截图失败：JPEG 编码失败"}];
            return nil;
        }
        NSString *base64 = [jpegData base64EncodedStringWithOptions:0];
        // 返回 base64 图像 + 实际像素尺寸（调用方据此做坐标归一化转换，勿用 fbw/fbh）
        return @{@"ok":@YES, @"image":base64, @"format":@"jpeg",
                 @"width":@(img.size.width), @"height":@(img.size.height)};
    }];
    [self _registerControl:@"service.restart" title:@"重启服务" icon:@"🔄" route:TRCapRouteNative params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        // 复用 TRGatewayClient 注入的 restartHandler（trollvncmanager 启动时设置为 [gWatchDog restart]）
        // 使 invoke 与网关 cmd 双入口均可触发重启，无需跨模块引用 gWatchDog
        BOOL (^handler)(void) = [TRGatewayClient sharedClient].restartHandler;
        if (!handler) {
            *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"重启处理器未注入"}];
            return nil;
        }
        if (!handler()) {
            *e = [NSError errorWithDomain:@"TRCap" code:6 userInfo:@{NSLocalizedDescriptionKey:@"重启服务失败"}];
            return nil;
        }
        return @{@"ok":@YES};
    }];
}

/** 注册触控笔能力（Batch 1：4 项，归一化 0-1 坐标 + 方位/压力参数） */
- (void)_registerStylusCapabilities {
    STHIDEventGenerator *hid = [STHIDEventGenerator sharedGenerator];
    NSArray *stylusParams = @[
        @{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
        @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
        @{@"name":@"azimuth",@"type":@"number",@"min":@0,@"max":@(M_PI*2),@"default":@0},
        @{@"name":@"altitude",@"type":@"number",@"min":@0,@"max":@(M_PI_2),@"default":@(M_PI_2)},
        @{@"name":@"pressure",@"type":@"number",@"min":@0,@"max":@1.0,@"default":@1.0},
    ];
    // tap/down/move 共享参数签名
    NSArray *stylusIds = @[@"stylus.tap", @"stylus.down", @"stylus.move"];
    NSArray *stylusSels = @[@"stylusTapAtPoint:azimuthAngle:altitudeAngle:pressure:",
                            @"stylusDownAtPoint:azimuthAngle:altitudeAngle:pressure:",
                            @"stylusMoveToPoint:azimuthAngle:altitudeAngle:pressure:"];
    NSArray *stylusTitles = @[@"触控笔点击", @"触控笔按下", @"触控笔移动"];
    for (NSUInteger i = 0; i < stylusIds.count; i++) {
        SEL sel = NSSelectorFromString(stylusSels[i]);
        [self _registerControl:stylusIds[i] title:stylusTitles[i] icon:@"✏️" route:TRCapRouteTouch
            params:stylusParams executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                CGPoint pt = [self _denormalizePoint:p error:e];
                if (pt.x < 0) return nil;
                CGFloat az = [p[@"azimuth"] doubleValue] ?: 0;
                CGFloat alt = [p[@"altitude"] doubleValue] ?: M_PI_2;
                CGFloat pressure = [p[@"pressure"] doubleValue] ?: 1.0;
                ((void(*)(id,SEL,CGPoint,CGFloat,CGFloat,CGFloat))[hid methodForSelector:sel])(hid, sel, pt, az, alt, pressure);
                return @{@"ok":@YES};
            }];
    }
    // stylus.up 只需坐标
    [self _registerControl:@"stylus.up" title:@"触控笔抬起" icon:@"✏️" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid stylusUpAtPoint:pt]; return @{@"ok":@YES};
        }];
}

/** 注册通知能力（Batch 1：4 项，调用 BulletinManager） */
- (void)_registerBulletinCapabilities {
    BulletinManager *bm = [BulletinManager sharedManager];
    // 推送横幅：params {content, userInfo?}
    [self _registerControl:@"notify.banner" title:@"推送横幅" icon:@"🔔" route:TRCapRouteNative
        params:@[@{@"name":@"content",@"type":@"string",@"required":@YES},
                 @{@"name":@"userInfo",@"type":@"object",@"required":@NO}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *content = p[@"content"];
            if (!content) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"content 缺失"}]; return nil; }
            [bm popBannerWithContent:content userInfo:p[@"userInfo"]];
            return @{@"ok":@YES};
        }];
    // 更新横幅：params {content, badgeCount, userInfo?}
    [self _registerControl:@"notify.banner.update" title:@"更新横幅" icon:@"🔔" route:TRCapRouteNative
        params:@[@{@"name":@"content",@"type":@"string",@"required":@YES},
                 @{@"name":@"badgeCount",@"type":@"number",@"required":@YES},
                 @{@"name":@"userInfo",@"type":@"object",@"required":@NO}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *content = p[@"content"];
            NSInteger badge = [p[@"badgeCount"] integerValue];
            if (!content) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"content 缺失"}]; return nil; }
            [bm updateSingleBannerWithContent:content badgeCount:badge userInfo:p[@"userInfo"]];
            return @{@"ok":@YES};
        }];
    // 撤销单条通知
    [self _registerControl:@"notify.revoke" title:@"撤销通知" icon:@"🔕" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [bm revokeSingleNotification]; return @{@"ok":@YES};
        }];
    // 撤销全部通知
    [self _registerControl:@"notify.revokeAll" title:@"撤销全部通知" icon:@"🔕" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [bm revokeAllNotifications]; return @{@"ok":@YES};
        }];
}

/** 注册服务控制能力（Batch 1：6 项，通过 TRGatewayClient.watchdog 访问 gWatchDog） */
- (void)_registerWatchdogCapabilities {
    // service.signal：发送信号 params {signal:int}
    [self _registerControl:@"service.signal" title:@"发送信号" icon:@"📡" route:TRCapRouteNative
        params:@[@{@"name":@"signal",@"type":@"number",@"min":@1,@"max":@31,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            int sig = (int)[p[@"signal"] intValue];
            if (![wd sendSignal:sig]) {
                *e = [NSError errorWithDomain:@"TRCap" code:6 userInfo:@{NSLocalizedDescriptionKey:@"发送信号失败（无运行进程或信号无效）"}];
                return nil;
            }
            return @{@"ok":@YES, @"signal":@(sig)};
        }];
    // service.state：服务状态（返回状态字符串）
    [self _registerControl:@"service.state" title:@"服务状态" icon:@"📊" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            return @{@"ok":@YES, @"state":[self _watchdogStateName:wd.state]};
        }];
    // service.info：服务详情（9 个 readonly 属性聚合）
    [self _registerControl:@"service.info" title:@"服务详情" icon:@"ℹ️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            return @{@"ok":@YES,
                @"pid":@(wd.processIdentifier),
                @"restartCount":@(wd.restartCount),
                @"uptime":@(wd.totalUptime),
                @"lastExitTime":wd.lastExitTime ?: [NSNull null],
                @"lastExitStatus":@(wd.lastExitStatus),
                @"lastUncaughtSignal":@(wd.lastUncaughtSignal),
                @"lastTerminationReason":@(wd.lastTerminationReason),
                @"timeUntilNextRestart":@(wd.timeUntilNextRestart),
                @"state":[self _watchdogStateName:wd.state],
            };
        }];
    // service.isActive：是否活跃
    [self _registerControl:@"service.isActive" title:@"是否活跃" icon:@"🟢" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            return @{@"ok":@YES, @"active":@(wd.isActive)};
        }];
    // service.isThrottled：是否限流
    [self _registerControl:@"service.isThrottled" title:@"是否限流" icon:@"⏳" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            return @{@"ok":@YES, @"throttled":@(wd.isThrottled)};
        }];
    // service.validate：校验配置
    [self _registerControl:@"service.validate" title:@"校验配置" icon:@"✅" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (!wd) { *e = [NSError errorWithDomain:@"TRCap" code:5 userInfo:@{NSLocalizedDescriptionKey:@"watchdog 未注入"}]; return nil; }
            NSError *verr = nil;
            BOOL ok = [wd validateConfigurationWithError:&verr];
            NSMutableDictionary *r = [@{@"ok":@YES, @"valid":@(ok)} mutableCopy];
            if (verr) r[@"error"] = verr.localizedDescription;
            return r;
        }];
}

/** TRWatchDogState 枚举转状态名称字符串 */
- (NSString *)_watchdogStateName:(TRWatchDogState)state {
    switch (state) {
        case TRWatchDogStateStopped:   return @"stopped";
        case TRWatchDogStateStarting:  return @"starting";
        case TRWatchDogStateRunning:   return @"running";
        case TRWatchDogStateStopping:  return @"stopping";
        case TRWatchDogStateCrashed:   return @"crashed";
        case TRWatchDogStateThrottled: return @"throttled";
    }
    return @"unknown";
}

/** 注册本地命令能力（Batch 2：6 项，经 46752 控制端口桥接 clients.* 命令） */
- (void)_registerLocalCmdCapabilities {
    // clients.count：客户端数量
    [self _registerControl:@"clients.count" title:@"客户端数量" icon:@"🔢" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *resp = [self _executeLocalCmd:@"count" timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            int count = [resp intValue];
            return @{@"ok":@YES, @"count":@(count)};
        }];
    // clients.list：客户端列表（TSV 解析为 JSON 数组）
    [self _registerControl:@"clients.list" title:@"客户端列表" icon:@"📋" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *resp = [self _executeLocalCmd:@"list" timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            // TSV 格式：首行表头 id\thost\tviewOnly\tconnectedAt\tdurationSec
            NSArray *lines = [resp componentsSeparatedByString:@"\n"];
            NSMutableArray *clients = [NSMutableArray array];
            for (NSUInteger i = 1; i < lines.count; i++) { // 跳过表头
                NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                NSArray *fields = [line componentsSeparatedByString:@"\t"];
                if (fields.count >= 5) {
                    [clients addObject:@{
                        @"id":fields[0], @"host":fields[1],
                        @"viewOnly":@([fields[2] boolValue]),
                        @"connectedAt":@([fields[3] longLongValue]),
                        @"durationSec":@([fields[4] doubleValue]),
                    }];
                }
            }
            return @{@"ok":@YES, @"clients":clients};
        }];
    // clients.disconnect：断开客户端 params {clientId}（支持 "ALL"）
    [self _registerControl:@"clients.disconnect" title:@"断开客户端" icon:@"🔌" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"clientId",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *cid = p[@"clientId"];
            if (!cid) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"clientId 缺失"}]; return nil; }
            NSString *resp = [self _executeLocalCmd:[NSString stringWithFormat:@"disconnect %@", cid] timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"] || [resp hasPrefix:@"NOT_FOUND"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // clients.block：阻止并加黑名单 params {clientId}
    [self _registerControl:@"clients.block" title:@"阻止客户端" icon:@"🚫" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"clientId",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *cid = p[@"clientId"];
            if (!cid) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"clientId 缺失"}]; return nil; }
            NSString *resp = [self _executeLocalCmd:[NSString stringWithFormat:@"block %@", cid] timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"] || [resp hasPrefix:@"NOT_FOUND"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // clients.unblock：解除主机黑名单 params {host}
    [self _registerControl:@"clients.unblock" title:@"解除阻止" icon:@"✅" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"host",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *host = p[@"host"];
            if (!host) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"host 缺失"}]; return nil; }
            NSString *resp = [self _executeLocalCmd:[NSString stringWithFormat:@"unblock %@", host] timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"] || [resp hasPrefix:@"NOT_FOUND"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // clients.subscribe：订阅推送 params {enable:bool}
    // 注意：subscribe on 在 invoke 同步模式下连接会关闭，持久订阅需通过 WS 接口
    [self _registerControl:@"clients.subscribe" title:@"订阅推送" icon:@"📡" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"enable",@"type":@"bool",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            BOOL enable = [p[@"enable"] boolValue];
            NSString *cmd = enable ? @"subscribe on" : @"subscribe off";
            NSString *resp = [self _executeLocalCmd:cmd timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES, @"enabled":@(enable)};
        }];
    // Batch 3：黑名单列表（需 trollvncserver 控制端口 blocked.list 命令支持）
    [self _registerControl:@"clients.blocked.list" title:@"黑名单列表" icon:@"📜" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *resp = [self _executeLocalCmd:@"blocked.list" timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            // 响应：每行一个 host（空列表为空字符串）
            NSMutableArray *hosts = [NSMutableArray array];
            if (resp.length > 0) {
                NSArray *lines = [resp componentsSeparatedByString:@"\n"];
                for (NSString *line in lines) {
                    NSString *h = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (h.length > 0) [hosts addObject:h];
                }
            }
            return @{@"ok":@YES, @"hosts":hosts};
        }];
    // clients.freeze：冻结客户端 params {clientId}
    // 语义：与本地命令 block 等价（断开 + 加入临时黑名单，客户端下次无法自动注册）
    // 与 TVNCClientListController.freezeClientWithId: 行为对齐，提供网关 invoke API 入口
    [self _registerControl:@"clients.freeze" title:@"冻结客户端" icon:@"🧊" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"clientId",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *cid = p[@"clientId"];
            if (!cid) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"clientId 缺失"}]; return nil; }
            NSString *resp = [self _executeLocalCmd:[NSString stringWithFormat:@"block %@", cid] timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"] || [resp hasPrefix:@"NOT_FOUND"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // clients.unfreeze：解冻客户端 params {host}
    // 语义：与本地命令 unblock 等价（移除黑名单，释放客户端，下次可自动注册）
    // 与 TVNCClientListController.unfreezeHost: 行为对齐，提供网关 invoke API 入口
    [self _registerControl:@"clients.unfreeze" title:@"解冻客户端" icon:@"🔥" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"host",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *host = p[@"host"];
            if (!host) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"host 缺失"}]; return nil; }
            NSString *resp = [self _executeLocalCmd:[NSString stringWithFormat:@"unblock %@", host] timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"] || [resp hasPrefix:@"NOT_FOUND"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
}

/** 注册系统查询能力（Batch 5：6 项，UIKit API + trollvncserver 公开函数） */
- (void)_registerSystemQueryCapabilities {
    // sys.version：应用版本信息
    [self _registerControl:@"sys.version" title:@"版本信息" icon:@"🏷️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
            return @{@"ok":@YES,
                @"scheme":info[@"CFBundleIdentifier"] ?: @"",
                @"version":info[@"CFBundleShortVersionString"] ?: @"",
                @"build":info[@"CFBundleVersion"] ?: @""};
        }];
    // sys.configSnapshot：配置快照（复用 currentConfigs，34+ 字段）
    [self _registerControl:@"sys.configSnapshot" title:@"配置快照" icon:@"⚙️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            return @{@"ok":@YES, @"configs":[self currentConfigs]};
        }];
    // sys.resolution：屏幕分辨率
    [self _registerControl:@"sys.resolution" title:@"屏幕分辨率" icon:@"📐" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            UIScreen *scr = [UIScreen mainScreen];
            CGFloat scale = [scr respondsToSelector:@selector(nativeScale)] ? [scr nativeScale] : [scr scale];
            return @{@"ok":@YES,
                @"width":@(scr.bounds.size.width * scale),
                @"height":@(scr.bounds.size.height * scale),
                @"nativeScale":@(scale)};
        }];
    // sys.rotation：当前旋转方向（quad: 0=0°, 1=90°, 2=180°, 3=270°）
    [self _registerControl:@"sys.rotation" title:@"当前旋转" icon:@"🔄" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            int quad = 0;
            switch ([UIDevice currentDevice].orientation) {
                case UIDeviceOrientationPortrait:          quad = 0; break;
                case UIDeviceOrientationLandscapeLeft:     quad = 1; break;
                case UIDeviceOrientationPortraitUpsideDown:quad = 2; break;
                case UIDeviceOrientationLandscapeRight:    quad = 3; break;
                default: quad = 0; break;
            }
            return @{@"ok":@YES, @"quad":@(quad)};
        }];
    // sys.stats.inflight：编码帧统计（调 trollvncserver 公开函数）
    [self _registerControl:@"sys.stats.inflight" title:@"编码帧数" icon:@"📊" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *stats = tvGetInflightStats();
            int current = [stats[@"current"] intValue];
            int max = [stats[@"max"] intValue];
            return @{@"ok":@YES, @"current":@(current), @"max":@(max), @"isThrottled":@(current >= max)};
        }];
    // sys.bonjour.txt：Bonjour TXT 记录（调 trollvncserver 公开函数）
    [self _registerControl:@"sys.bonjour.txt" title:@"Bonjour TXT" icon:@"📡" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            return @{@"ok":@YES, @"txt":tvGetBonjourTXT()};
        }];
}

/** 注册 ScreenCapturer 扩展能力（Batch 5：5 项） */
- (void)_registerScreenExtCapabilities {
    ScreenCapturer *cap = [ScreenCapturer sharedCapturer];
    // screen.capture.start：开始流式采集（传 no-op block，RFB 内核有自己的帧处理）
    [self _registerControl:@"screen.capture.start" title:@"开始采集" icon:@"▶️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [cap startCaptureWithFrameHandler:^(CMSampleBufferRef sb){}];
            return @{@"ok":@YES};
        }];
    // screen.capture.stop：停止流式采集
    [self _registerControl:@"screen.capture.stop" title:@"停止采集" icon:@"⏹️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [cap endCapture]; return @{@"ok":@YES};
        }];
    // screen.fps：设置帧率范围 params {min, preferred, max}
    [self _registerControl:@"screen.fps" title:@"设置帧率" icon:@"🎬" route:TRCapRouteNative
        params:@[@{@"name":@"min",@"type":@"number",@"min":@1,@"max":@120,@"default":@0},
                 @{@"name":@"preferred",@"type":@"number",@"min":@1,@"max":@120,@"required":@YES},
                 @{@"name":@"max",@"type":@"number",@"min":@1,@"max":@120,@"default":@0}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSInteger minFps = [p[@"min"] integerValue];
            NSInteger prefFps = [p[@"preferred"] integerValue];
            NSInteger maxFps = [p[@"max"] integerValue];
            [cap setPreferredFrameRateWithMin:minFps preferred:prefFps max:maxFps];
            return @{@"ok":@YES, @"min":@(minFps), @"preferred":@(prefFps), @"max":@(maxFps)};
        }];
    // screen.resolution：查询采集分辨率属性
    [self _registerControl:@"screen.resolution" title:@"采集分辨率" icon:@"📐" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            return @{@"ok":@YES, @"properties":cap.renderProperties ?: @{}};
        }];
    // screen.forceRefresh：强制下一帧脏
    [self _registerControl:@"screen.forceRefresh" title:@"强制刷新" icon:@"🔄" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [cap forceNextFrameUpdate]; return @{@"ok":@YES};
        }];
}

/** 注册网关客户端能力（Batch 5：3 项） */
- (void)_registerGatewayCapabilities {
    // gateway.isConnected：网关连接状态
    [self _registerControl:@"gateway.isConnected" title:@"网关状态" icon:@"🟢" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRGatewayClient *gw = [TRGatewayClient sharedClient];
            return @{@"ok":@YES, @"connected":@(gw.isConnected), @"retryDelay":@(gw.retryDelay)};
        }];
    // gateway.reconnect：手动重连
    [self _registerControl:@"gateway.reconnect" title:@"手动重连" icon:@"🔌" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            TRGatewayClient *gw = [TRGatewayClient sharedClient];
            [gw stop]; [gw start];
            return @{@"ok":@YES};
        }];
    // gateway.deviceInfo：设备元数据
    [self _registerControl:@"gateway.deviceInfo" title:@"设备元数据" icon:@"📱" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            return @{@"ok":@YES, @"info":[TRGatewayClient sharedClient].deviceInfo ?: @{}};
        }];
}

/**
 * 注册屏幕感知能力（Phase 11.4：4 项，route=LocalCmd 转发到 46752）
 * 借鉴 hermes-android screen_hash/diff_screen/wait/event_stream。
 * pHash 计算在 trollvncserver 进程内执行（TRScreenHasher），通过 46752 端口桥接。
 * 全部标记为 internal（AI 专用，不进人工菜单），scenes=[ai]。
 */
- (void)_registerScreenHashCapabilities {
    // screen.hash：当前屏幕 pHash（16 字符 hex）
    TRControlCap *hashCap = [self _registerControl:@"screen.hash" title:@"屏幕哈希" icon:@"#" route:TRCapRouteLocalCmd
        params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *resp = [self _executeLocalCmd:@"screen.hash" timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            NSString *hex = [resp stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return @{@"ok":@YES, @"hash":hex};
        }];
    hashCap.menuLevel = @"internal";
    hashCap.scenes = @[@"ai"];
    hashCap.batchSupport = NO;

    // screen.diff：与基线哈希比较
    TRControlCap *diffCap = [self _registerControl:@"screen.diff" title:@"屏幕差异" icon:@"Δ" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"baselineHash",@"type":@"string",@"required":@YES},
                 @{@"name":@"threshold",@"type":@"number",@"min":@0,@"max":@64,@"default":@5}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *baseline = p[@"baselineHash"] ?: @"";
            NSInteger threshold = [p[@"threshold"] integerValue];
            NSString *cmd = [NSString stringWithFormat:@"screen.diff %@ %ld", baseline, (long)threshold];
            NSString *resp = [self _executeLocalCmd:cmd timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            // 解析 "OK distance=N threshold=N changed=N hash=XXXX"
            return [self _parseScreenDiffResponse:resp];
        }];
    diffCap.menuLevel = @"internal";
    diffCap.scenes = @[@"ai"];
    diffCap.batchSupport = NO;

    // screen.waitStable：等待画面稳定
    TRControlCap *waitCap = [self _registerControl:@"screen.waitStable" title:@"等待稳定" icon:@"⏳" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"maxMs",@"type":@"number",@"min":@0,@"max":@10000,@"default":@3000},
                 @{@"name":@"stableMs",@"type":@"number",@"min":@0,@"max":@5000,@"default":@500},
                 @{@"name":@"intervalMs",@"type":@"number",@"min":@50,@"max":@1000,@"default":@200},
                 @{@"name":@"threshold",@"type":@"number",@"min":@0,@"max":@64,@"default":@3}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSTimeInterval maxMs = [p[@"maxMs"] doubleValue];
            NSTimeInterval stableMs = [p[@"stableMs"] doubleValue];
            NSTimeInterval intervalMs = [p[@"intervalMs"] doubleValue];
            NSInteger threshold = [p[@"threshold"] integerValue];
            NSString *cmd = [NSString stringWithFormat:@"screen.waitStable %.0f %.0f %.0f %ld",
                             maxMs, stableMs, intervalMs, (long)threshold];
            // waitStable 超时 = maxMs + 2000ms 缓冲（含取帧/计算/网络耗时），最少 5 秒
            // 避免默认 3 秒 socket 超时截断 maxMs=3000 的调用
            NSTimeInterval timeoutMs = MAX(maxMs + 2000, 5000);
            NSString *resp = [self _executeLocalCmd:cmd timeoutMs:timeoutMs error:e];
            if (!resp) return nil;
            if ([resp hasPrefix:@"ERR"]) {
                *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                return nil;
            }
            return [self _parseScreenWaitStableResponse:resp];
        }];
    waitCap.menuLevel = @"internal";
    waitCap.scenes = @[@"ai"];
    waitCap.batchSupport = NO;

    // screen.subscribe：开启/关闭屏幕变化推送
    TRControlCap *subCap = [self _registerControl:@"screen.subscribe" title:@"变化推送" icon:@"📡" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"enable",@"type":@"bool",@"required":@YES},
                 @{@"name":@"throttleMs",@"type":@"number",@"min":@0,@"max":@5000,@"default":@150},
                 @{@"name":@"minDistance",@"type":@"number",@"min":@0,@"max":@64,@"default":@8}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            BOOL enable = [p[@"enable"] boolValue];
            if (enable) {
                NSTimeInterval throttleMs = [p[@"throttleMs"] doubleValue];
                NSInteger minDistance = [p[@"minDistance"] integerValue];
                NSString *cmd = [NSString stringWithFormat:@"screen.subscribe on %.0f %ld",
                                 throttleMs, (long)minDistance];
                NSString *resp = [self _executeLocalCmd:cmd timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
                if (!resp) return nil;
                if ([resp hasPrefix:@"ERR"]) {
                    *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp}];
                    return nil;
                }
                return @{@"ok":@YES, @"enabled":@YES};
            } else {
                NSString *resp = [self _executeLocalCmd:@"screen.subscribe off" timeoutMs:kLocalCmdDefaultTimeoutMs error:e];
                if (!resp) return nil;
                return @{@"ok":@YES, @"enabled":@NO};
            }
        }];
    subCap.menuLevel = @"internal";
    subCap.scenes = @[@"ai"];
    subCap.batchSupport = NO;
}

/**
 * 解析 screen.diff 命令响应（"OK distance=N threshold=N changed=N hash=XXXX"）。
 * 功能：将 46752 端口返回的文本响应解析为字典。
 * 参数：resp - 响应字符串
 * 返回值：NSDictionary* - {ok, distance, threshold, changed, currentHash}
 */
- (NSDictionary *)_parseScreenDiffResponse:(NSString *)resp {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ok"] = @YES;
    NSArray *tokens = [resp componentsSeparatedByString:@" "];
    for (NSString *token in tokens) {
        if ([token hasPrefix:@"distance="]) {
            result[@"distance"] = @([[token substringFromIndex:9] integerValue]);
        } else if ([token hasPrefix:@"threshold="]) {
            result[@"threshold"] = @([[token substringFromIndex:10] integerValue]);
        } else if ([token hasPrefix:@"changed="]) {
            result[@"changed"] = @([[token substringFromIndex:8] integerValue] != 0);
        } else if ([token hasPrefix:@"hash="]) {
            result[@"currentHash"] = [token substringFromIndex:5];
        }
    }
    return result;
}

/**
 * 解析 screen.waitStable 命令响应（"OK stable=N frames=N durationMs=N hash=XXXX"）。
 * 功能：将 46752 端口返回的文本响应解析为字典。
 * 参数：resp - 响应字符串
 * 返回值：NSDictionary* - {ok, stable, frameCount, durationMs, lastHash}
 */
- (NSDictionary *)_parseScreenWaitStableResponse:(NSString *)resp {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ok"] = @YES;
    NSArray *tokens = [resp componentsSeparatedByString:@" "];
    for (NSString *token in tokens) {
        if ([token hasPrefix:@"stable="]) {
            result[@"stable"] = @([[token substringFromIndex:7] integerValue] != 0);
        } else if ([token hasPrefix:@"frames="]) {
            result[@"frameCount"] = @([[token substringFromIndex:7] integerValue]);
        } else if ([token hasPrefix:@"durationMs="]) {
            result[@"durationMs"] = @([[token substringFromIndex:11] doubleValue]);
        } else if ([token hasPrefix:@"hash="]) {
            result[@"lastHash"] = [token substringFromIndex:5];
        }
    }
    return result;
}

/**
 * 注册控制型能力表项（内部辅助）
 * 功能：创建 TRControlCap 表项并存入注册表；若未显式指定 category，按 capId 前缀 + route 类型自动推断。
 *       Phase 11.1：menu/scenes/batch 默认值按 category 映射表自动填充。
 * 参数：capId    - 能力 ID
 *       title   - 能力标题（中文）
 *       icon    - 能力图标（emoji）
 *       route   - 路由类型（HID/Touch/LocalCmd/Native）
 *       params  - 参数 schema 数组
 *       executor- 执行 block
 * 返回值：TRControlCap* - 创建的表项（供调用方覆盖 menu/scenes/batch 等字段）
 */
- (TRControlCap *)_registerControl:(NSString *)capId title:(NSString *)title icon:(NSString *)icon
                  route:(TRCapRouteType)route params:(NSArray *)params
               executor:(NSDictionary * _Nullable (^)(NSDictionary *, NSError **))executor {
    TRControlCap *cap = [TRControlCap new];
    cap.capId = capId; cap.title = title; cap.icon = icon;
    cap.routeType = route; cap.params = params; cap.executor = executor;
    // Phase 10.3：未显式指定 category 时按 capId 前缀 + route 类型自动推断
    cap.category = [self _inferCategoryForCapId:capId route:route];
    // Phase 11.1：menu/scenes/batch 默认值按 category 映射表填充
    [self _applyDefaultSceneFields:cap];
    _controlCaps[capId] = cap;
    return cap;
}

/**
 * 为能力表项填充默认 menu/scenes/batch 字段（Phase 11.1）。
 * 功能：按 category 映射表自动设置场景字段，未显式指定时使用默认值。
 * 参数：cap - 控制型能力表项
 * 返回值：void
 */
- (void)_applyDefaultSceneFields:(TRControlCap *)cap {
    if (!cap.menuLevel) cap.menuLevel = [self _defaultMenuLevelForCategory:cap.category];
    if (!cap.scenes) cap.scenes = [self _defaultScenesForCategory:cap.category];
    if (!cap.batchSupport) cap.batchSupport = [cap.scenes containsObject:@"batch"];
}

/**
 * 按 category 返回默认 menu 层级（Phase 11.1 映射表）。
 * 功能：primary=一级菜单 / secondary=二级菜单 / internal=AI 专用隐藏。
 * 参数：category - 分类标识
 * 返回值：NSString* - primary/secondary/internal
 */
- (NSString *)_defaultMenuLevelForCategory:(NSString *)category {
    // 操作类一级：触控/硬件按键/文本/屏幕采集/应用启动
    if ([category isEqualToString:@"touch"] || [category isEqualToString:@"hid"] ||
        [category isEqualToString:@"text"] || [category isEqualToString:@"screen"] ||
        [category isEqualToString:@"app"]) {
        return @"primary";
    }
    // 管理类二级：客户端/服务/系统/网关/自动化编排
    return @"secondary";
}

/**
 * 按 category 返回默认 scenes 数组（Phase 11.1 映射表）。
 * 功能：标记能力在哪些场景下可用（single/batch/ai）。
 * 参数：category - 分类标识
 * 返回值：NSArray* - 场景字符串数组
 */
- (NSArray *)_defaultScenesForCategory:(NSString *)category {
    // 批量有意义：硬件按键/屏幕采集/应用启动/客户端/服务/自动化编排
    if ([category isEqualToString:@"hid"] || [category isEqualToString:@"screen"] ||
        [category isEqualToString:@"app"] || [category isEqualToString:@"system"] ||
        [category isEqualToString:@"service"] || [category isEqualToString:@"macro"]) {
        return @[@"single", @"batch", @"ai"];
    }
    // 批量无意义：触控/文本/网关（查询类）
    if ([category isEqualToString:@"gateway"]) {
        return @[@"single", @"ai"];
    }
    // 默认：单控 + AI
    return @[@"single", @"ai"];
}

#pragma mark - 配置 Schema 注册（覆盖 Root.plist 全字段）

/** 注册所有配置项 schema（含 type/min/max/enum/reload，供前端自动生成表单） */
- (void)_registerConfigSchemas {
    // 画面与性能（hot）
    [self _registerConfig:@"Scale" title:@"输出缩放" type:@"number" min:@0.1 max:@1.0 step:@0.1 reload:TRConfigReloadHot];
    [self _registerConfig:@"FrameRateSpec" title:@"帧率" type:@"string" reload:TRConfigReloadHot];
    [self _registerConfig:@"OrientationSync" title:@"方向同步" type:@"bool" reload:TRConfigReloadHot];
    [self _registerConfig:@"OrientationPadFix" title:@"方向偏移" type:@"enum"
        enumValues:@[@0,@1,@2,@3] enumTitles:@[@"禁用",@"90°",@"180°",@"270°"] reload:TRConfigReloadHot];
    [self _registerConfig:@"ServerCursor" title:@"服务端光标" type:@"bool" reload:TRConfigReloadHot];
    // 进阶画面
    [self _registerConfig:@"DeferWindowSec" title:@"延迟窗口" type:@"number" min:@0 max:@0.5 step:@0.005 reload:TRConfigReloadHot];
    [self _registerConfig:@"MaxInflight" title:@"最大并行帧" type:@"number" min:@0 max:@8 step:@1 reload:TRConfigReloadHot];
    // Phase 8.3：PerformanceMode 枚举合并（替代 TileSize/MaxRects/FullscreenThresholdPercent/AsyncSwap 独立配置）
    // 4 项底层参数仍保留注册，仅在 custom 模式下由 UI 暴露（见 TVNCSettingsViewController visibleWhen 标记）
    [self _registerConfig:@"PerformanceMode" title:@"性能模式" type:@"enum"
        enumValues:@[@"balanced", @"quality", @"performance", @"custom"]
        enumTitles:@[@"均衡", @"画质", @"性能", @"自定义"] reload:TRConfigReloadHot];
    [self _registerConfig:@"TileSize" title:@"分块大小" type:@"number" min:@8 max:@128 step:@1 reload:TRConfigReloadRestart];
    [self _registerConfig:@"FullscreenThresholdPercent" title:@"脏区阈值" type:@"number" min:@0 max:@100 step:@1 reload:TRConfigReloadHot];
    [self _registerConfig:@"MaxRects" title:@"最大矩形数" type:@"number" min:@1 max:@4096 step:@1 reload:TRConfigReloadRestart];
    [self _registerConfig:@"AsyncSwap" title:@"非阻塞交换" type:@"bool" reload:TRConfigReloadRestart];
    // Phase 10.6：卡片墙帧获取间隔（web/IPA 原硬编码 5s/10s，现可配置，instant 级别即时生效）
    [self _registerConfig:@"ThumbInterval" title:@"卡片墙帧获取间隔(秒)" type:@"number" min:@1 max:@60 step:@1 reload:TRConfigReloadInstant];
    // 输入
    [self _registerConfig:@"NaturalScroll" title:@"自然滚动" type:@"bool" reload:TRConfigReloadInstant];
    [self _registerConfig:@"ModifierMap" title:@"修饰键映射" type:@"enum"
        enumValues:@[@"std",@"altcmd"] enumTitles:@[@"标准",@"Alt→Cmd"] reload:TRConfigReloadHot];
    [self _registerConfig:@"AutoAssistEnabled" title:@"辅助触控" type:@"bool" reload:TRConfigReloadInstant];
    [self _registerConfig:@"WheelStepPx" title:@"滚轮步进" type:@"number" min:@0 max:@1000 step:@1 reload:TRConfigReloadHot];
    [self _registerConfig:@"WheelTuning" title:@"滚轮调优" type:@"string" reload:TRConfigReloadHot];
    // 安全
    [self _registerConfig:@"ViewOnly" title:@"全局只读" type:@"bool" reload:TRConfigReloadInstant];
    [self _registerConfig:@"ClipboardEnabled" title:@"剪贴板同步" type:@"bool" reload:TRConfigReloadInstant];
    [self _registerConfig:@"FullPassword" title:@"完全访问密码" type:@"password" reload:TRConfigReloadRestart];
    [self _registerConfig:@"ViewOnlyPassword" title:@"只读密码" type:@"password" reload:TRConfigReloadRestart];
    // 连接
    [self _registerConfig:@"Port" title:@"TCP 端口" type:@"number" min:@1 max:@65535 step:@1 reload:TRConfigReloadRestart];
    [self _registerConfig:@"BindHost" title:@"绑定地址" type:@"string" reload:TRConfigReloadRestart];
    [self _registerConfig:@"BonjourEnabled" title:@"自动发现" type:@"bool" reload:TRConfigReloadGateway];
    [self _registerConfig:@"HttpPort" title:@"HTTP 端口" type:@"number" min:@0 max:@65535 step:@1 reload:TRConfigReloadRestart];
    [self _registerConfig:@"HttpDir" title:@"HTTP 根目录" type:@"string" reload:TRConfigReloadRestart];
    // Phase 8.1 补齐：网关与 SSL（服务开关 / 网关接入 / SSL 证书）
    [self _registerConfig:@"Enabled" title:@"服务启用" type:@"bool" reload:TRConfigReloadRestart];
    [self _registerConfig:@"GatewayHost" title:@"网关地址" type:@"string" reload:TRConfigReloadGateway];
    [self _registerConfig:@"GatewayPort" title:@"网关端口" type:@"number" min:@1 max:@65535 step:@1 reload:TRConfigReloadGateway];
    [self _registerConfig:@"GatewayToken" title:@"网关令牌" type:@"password" reload:TRConfigReloadGateway];
    [self _registerConfig:@"SslCertFile" title:@"SSL证书文件" type:@"string" reload:TRConfigReloadRestart];
    [self _registerConfig:@"SslKeyFile" title:@"SSL私钥文件" type:@"string" reload:TRConfigReloadRestart];
    // 高级
    [self _registerConfig:@"KeepAliveSec" title:@"保活间隔" type:@"number" min:@0 max:@300 step:@1 reload:TRConfigReloadHot];
    // Phase 8.2：Notifications 枚举合并（替代 SingleNotifEnabled/ClientNotifsEnabled 独立开关）
    [self _registerConfig:@"Notifications" title:@"通知模式" type:@"enum"
        enumValues:@[@"all", @"connectOnly", @"silent"]
        enumTitles:@[@"全部通知", @"仅连接通知", @"静默"] reload:TRConfigReloadInstant];
    [self _registerConfig:@"KeyLogging" title:@"键盘日志" type:@"bool" reload:TRConfigReloadInstant];
    // 附录 E：Watchdog / HID 活属性配置（hot 级别，setConfig 时即时应用到对象属性）
    [self _registerConfig:@"WatchdogThrottleInterval" title:@"重启节流间隔" type:@"number" min:@1 max:@300 step:@1 reload:TRConfigReloadHot];
    [self _registerConfig:@"WatchdogKeepAlive" title:@"崩溃自动重启" type:@"bool" reload:TRConfigReloadHot];
    [self _registerConfig:@"WatchdogExitTimeout" title:@"退出超时" type:@"number" min:@1 max:@60 step:@1 reload:TRConfigReloadHot];
    [self _registerConfig:@"HIDKeepAliveInterval" title:@"HID防休眠间隔" type:@"number" min:@0 max:@300 step:@1 reload:TRConfigReloadHot];
}

/** 注册配置 schema 表项（内部辅助） */
- (void)_registerConfig:(NSString *)key title:(NSString *)title type:(NSString *)type
                    min:(NSNumber *)min max:(NSNumber *)max step:(NSNumber *)step
             enumValues:(NSArray *)enumValues enumTitles:(NSArray *)enumTitles
                 reload:(TRConfigReload)reload {
    TRConfigCap *cap = [TRConfigCap new];
    cap.key = key; cap.title = title; cap.type = type;
    cap.min = min; cap.max = max; cap.step = step;
    cap.enumValues = enumValues; cap.enumTitles = enumTitles; cap.reload = reload;
    _configCaps[key] = cap;
}

/** 无枚举的简化注册重载 */
- (void)_registerConfig:(NSString *)key title:(NSString *)title type:(NSString *)type
                    min:(NSNumber *)min max:(NSNumber *)max step:(NSNumber *)step
                 reload:(TRConfigReload)reload {
    [self _registerConfig:key title:title type:type min:min max:max step:step
             enumValues:nil enumTitles:nil reload:reload];
}

/** 无 min/max 的简化注册重载 */
- (void)_registerConfig:(NSString *)key title:(NSString *)title type:(NSString *)type reload:(TRConfigReload)reload {
    [self _registerConfig:key title:title type:type min:nil max:nil step:nil reload:reload];
}

#pragma mark - 能力查询

/** 所有控制型能力 ID（供上报 capabilities[]） */
- (NSArray<NSString *> *)allCapabilityIds {
    return _controlCaps.allKeys;
}

/** 所有控制型能力完整元数据（含 id/title/icon/route/params） */
- (NSArray<NSDictionary *> *)allControlMetadata {
    NSMutableArray *arr = [NSMutableArray array];
    for (TRControlCap *cap in [_controlCaps allValues]) {
        [arr addObject:[self _controlMetadata:cap]];
    }
    return arr;
}

/** 按能力 ID 查询元数据 */
- (NSDictionary *)metadataForId:(NSString *)capId {
    TRControlCap *cap = _controlCaps[capId];
    return cap ? [self _controlMetadata:cap] : nil;
}

/**
 * 构建控制型能力元数据字典
 * 功能：将 TRControlCap 表项转为对外暴露的元数据字典，包含 id/title/icon/category/categoryTitle/params/route。
 *       Phase 11.1：新增 menu/scenes/batch 三字段，供前端菜单分层与批量过滤。
 * 参数：cap - 控制型能力表项
 * 返回值：NSDictionary* - 元数据字典
 */
- (NSDictionary *)_controlMetadata:(TRControlCap *)cap {
    NSString *category = cap.category ?: @"control";
    return @{
        @"id": cap.capId,
        @"title": cap.title,
        @"icon": cap.icon,
        @"category": category,
        @"categoryTitle": [self _categoryTitle:category],
        @"params": cap.params ?: @[],
        @"route": @{ @"type": [self _routeTypeName:cap.routeType] },
        // Phase 11.1：场景化分层字段
        @"menu": cap.menuLevel ?: @"primary",
        @"scenes": cap.scenes ?: @[@"single"],
        @"batch": @(cap.batchSupport)
    };
}

/**
 * 按能力 ID 前缀 + route 类型推断 category
 * 功能：优先按 capId 前缀推断（覆盖 route 类型无法区分的情况，如 stylus.*/service.*/gateway.*/clients.*），
 *       Phase 11.3/11.4：新增 app.*/macro.*/screen.hash/diff/waitStable/subscribe 前缀推断。
 * 参数：capId - 能力 ID
 *       route - 路由类型
 * 返回值：NSString* - category 字符串
 */
- (NSString *)_inferCategoryForCapId:(NSString *)capId route:(TRCapRouteType)route {
    // 1. 按能力 ID 前缀优先推断
    if ([capId hasPrefix:@"stylus."]) return @"stylus";
    if ([capId hasPrefix:@"service."]) return @"service";
    if ([capId hasPrefix:@"gateway."]) return @"gateway";
    if ([capId hasPrefix:@"clients."]) return @"system";
    // Phase 11.3：应用与启动
    if ([capId hasPrefix:@"app."]) return @"app";
    // Phase 11.4：屏幕感知（screen.hash/diff/waitStable/subscribe）
    if ([capId hasPrefix:@"screen.hash"] || [capId hasPrefix:@"screen.diff"] ||
        [capId hasPrefix:@"screen.waitStable"] || [capId hasPrefix:@"screen.subscribe"]) {
        return @"screen";
    }
    // Phase 11.2：自动化编排
    if ([capId hasPrefix:@"macro."]) return @"macro";
    // 2. 按 route 类型推断
    switch (route) {
        case TRCapRouteHID:      return @"hid";
        case TRCapRouteTouch:    return @"touch";
        case TRCapRouteLocalCmd: return @"system";
        case TRCapRouteNative:   return @"native";
    }
    return @"native";
}

/**
 * category → 中文标题映射（供前端分组标题显示）
 * 功能：将 category 标识转为中文分组标题字符串。
 *       Phase 11：新增 app/macro/screen 扩展标题。
 * 参数：category - 分类标识
 * 返回值：NSString* - 中文标题字符串
 */
- (NSString *)_categoryTitle:(NSString *)category {
    NSDictionary *titles = @{
        @"hid": @"硬件按键",
        @"touch": @"触控操作",
        @"stylus": @"触控笔",
        @"system": @"系统管理",
        @"native": @"原生功能",
        @"service": @"服务管理",
        @"gateway": @"网关信息",
        // Phase 11 新增
        @"app": @"应用与启动",
        @"macro": @"自动化编排",
        @"screen": @"屏幕与采集",
        @"text": @"文本与剪贴板",
    };
    return titles[category] ?: category;
}

/** 路由类型转名称字符串 */
- (NSString *)_routeTypeName:(TRCapRouteType)t {
    switch (t) {
        case TRCapRouteHID:      return @"hid";
        case TRCapRouteTouch:    return @"touch";
        case TRCapRouteLocalCmd: return @"localcmd";
        case TRCapRouteNative:   return @"native";
    }
    return @"unknown";
}

#pragma mark - 配置查询

/** 所有配置项 schema（供前端生成表单） */
- (NSArray<NSDictionary *> *)allConfigSchema {
    NSMutableArray *arr = [NSMutableArray array];
    for (TRConfigCap *cap in [_configCaps allValues]) {
        [arr addObject:[self _configSchemaDict:cap]];
    }
    return arr;
}

/** 所有配置项当前值（读 NSUserDefaults，供上报 configs[]） */
- (NSDictionary *)currentConfigs {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    for (NSString *key in _configCaps) {
        TRConfigCap *cap = _configCaps[key];
        id v = [_defaults objectForKey:key];
        if (v) {
            cfg[key] = v;
        } else {
            // 回退 schema 默认（从 Root.plist 默认值）
            cfg[key] = [self _defaultForKey:key cap:cap] ?: [NSNull null];
        }
    }
    // 密码只报存在性，不上报明文
    NSString *fullPw = [_defaults stringForKey:@"FullPassword"];
    NSString *viewPw = [_defaults stringForKey:@"ViewOnlyPassword"];
    cfg[@"hasPassword"] = @(fullPw.length > 0);
    cfg[@"hasViewOnlyPassword"] = @(viewPw.length > 0);
    [cfg removeObjectForKey:@"FullPassword"];
    [cfg removeObjectForKey:@"ViewOnlyPassword"];
    // Phase 8.2：Notifications 枚举合并 - 读取底层 SingleNotifEnabled/ClientNotifsEnabled 反推 Notifications 枚举
    // 底层开关不再直接上报（schema 已移除），仅上报 Notifications 枚举值
    BOOL sn = [[_defaults objectForKey:@"SingleNotifEnabled"] boolValue];
    BOOL cn = [[_defaults objectForKey:@"ClientNotifsEnabled"] boolValue];
    NSString *notifMode = @"all";
    if (!sn && cn) notifMode = @"connectOnly";
    else if (!sn && !cn) notifMode = @"silent";
    cfg[@"Notifications"] = notifMode;
    // Phase 10.7：PerformanceMode 枚举合并 - 读取底层 4 参数（TileSize/MaxRects/FullscreenThresholdPercent/AsyncSwap）
    // 的实际值，与 setConfig 中的预设表比对反推 PerformanceMode 枚举，覆盖直接读取的字符串值
    // 解决：外部直接 setConfig("TileSize",99) 后 currentConfigs 仍上报 PerformanceMode="balanced" 的状态不一致问题
    NSInteger pmTileSize = [cfg[@"TileSize"] integerValue];
    NSInteger pmMaxRects = [cfg[@"MaxRects"] integerValue];
    NSInteger pmFullscreenThreshold = [cfg[@"FullscreenThresholdPercent"] integerValue];
    BOOL pmAsyncSwap = [cfg[@"AsyncSwap"] boolValue];
    NSString *perfMode = @"custom";
    if (pmTileSize == 32 && pmMaxRects == 512 && pmFullscreenThreshold == 50 && !pmAsyncSwap) {
        perfMode = @"balanced";
    } else if (pmTileSize == 64 && pmMaxRects == 2048 && pmFullscreenThreshold == 80 && !pmAsyncSwap) {
        perfMode = @"quality";
    } else if (pmTileSize == 16 && pmMaxRects == 128 && pmFullscreenThreshold == 30 && pmAsyncSwap) {
        perfMode = @"performance";
    }
    cfg[@"PerformanceMode"] = perfMode;
    return cfg;
}

/** 按配置 key 查询 schema */
- (NSDictionary *)schemaForKey:(NSString *)key {
    TRConfigCap *cap = _configCaps[key];
    return cap ? [self _configSchemaDict:cap] : nil;
}

/** 构建配置 schema 字典 */
- (NSDictionary *)_configSchemaDict:(TRConfigCap *)cap {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"key"] = cap.key; d[@"title"] = cap.title; d[@"type"] = cap.type;
    d[@"reload"] = [self _reloadName:cap.reload];
    if (cap.min) d[@"min"] = cap.min;
    if (cap.max) d[@"max"] = cap.max;
    if (cap.step) d[@"step"] = cap.step;
    if (cap.enumValues) d[@"enumValues"] = cap.enumValues;
    if (cap.enumTitles) d[@"enumTitles"] = cap.enumTitles;
    return d;
}

/** reload 枚举转名称字符串 */
- (NSString *)_reloadName:(TRConfigReload)r {
    switch (r) {
        case TRConfigReloadInstant: return @"instant";
        case TRConfigReloadHot:     return @"hot";
        case TRConfigReloadGateway: return @"gateway";
        case TRConfigReloadRestart: return @"restart";
    }
    return @"unknown";
}

/** 配置默认值回退（与 Root.plist 默认对齐） */
- (id)_defaultForKey:(NSString *)key cap:(TRConfigCap *)cap {
    if ([cap.type isEqualToString:@"bool"]) {
        // 与 Root.plist 默认值对齐
        NSDictionary *defs = @{
            @"Enabled": @YES, @"BonjourEnabled": @YES, @"OrientationSync": @YES,
            @"ClipboardEnabled": @YES, @"NaturalScroll": @YES, @"ServerCursor": @NO,
            @"ViewOnly": @NO, @"AsyncSwap": @NO, @"AutoAssistEnabled": @NO,
            @"SingleNotifEnabled": @YES, @"ClientNotifsEnabled": @YES, @"KeyLogging": @NO,
        };
        return defs[key] ?: @NO;
    }
    if ([cap.type isEqualToString:@"number"]) {
        NSDictionary *defs = @{
            @"Scale": @1.0, @"Port": @5901, @"HttpPort": @0, @"OrientationPadFix": @0,
            @"DeferWindowSec": @0.015, @"MaxInflight": @2, @"TileSize": @32,
            @"FullscreenThresholdPercent": @0, @"MaxRects": @256,
            @"WheelStepPx": @48.0, @"KeepAliveSec": @0,
            @"GatewayPort": @18081, @"ThumbInterval": @5,
        };
        return defs[key] ?: @0;
    }
    if ([cap.type isEqualToString:@"string"] || [cap.type isEqualToString:@"password"]) {
        NSDictionary *defs = @{
            @"FrameRateSpec": @"60", @"ModifierMap": @"std",
            @"GatewayHost": @"", @"GatewayToken": @"",
            @"SslCertFile": @"", @"SslKeyFile": @"",
        };
        return defs[key] ?: @"";
    }
    if ([cap.type isEqualToString:@"enum"]) {
        return cap.enumValues.firstObject ?: @0;
    }
    return nil;
}

#pragma mark - 能力调用（invoke 统一入口）

/**
 * 调用控制型能力（按 capId 查 route 自动分发）
 * @param capId  能力 ID
 * @param params 参数字典
 * @param error  失败错误
 * @return 成功结果字典，失败 nil
 */
- (NSDictionary *)invoke:(NSString *)capId params:(NSDictionary *)params error:(NSError **)error {
    TRControlCap *cap = _controlCaps[capId];
    if (!cap) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:1
                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"未知能力: %@", capId]}];
        return nil;
    }
    // 数据驱动执行：直接调 executor block，route 类型仅作元数据标记（供前端/网关展示）
    // 实际执行路径已封装在 block 内（HID/触控/原生），无需 if/else 分支
    if (cap.executor) {
        return cap.executor(params ?: @{}, error);
    }
    if (error) *error = [NSError errorWithDomain:@"TRCap" code:99
                        userInfo:@{NSLocalizedDescriptionKey:@"能力未实现执行器"}];
    return nil;
}

#pragma mark - 配置下发（set 统一入口）

/**
 * 设置配置项（写 NSUserDefaults + 按 reload 策略触发副作用 + 返回生效策略）
 * @param key   配置键
 * @param value 新值
 * @param error 失败错误（类型不符/超出范围）
 * @return reload 策略字符串（instant/hot/gateway/restart），失败 nil
 * 注：Phase 4.4 实现 hot/restart 分发；gateway/instant 无需显式处理
 *     - gateway：NSUserDefaults 变更触发 TRGatewayClient._defaultsChanged → worker 重发 register
 *     - instant：下次读取自动用新值
 */
- (NSString *)setConfig:(NSString *)key value:(id)value error:(NSError **)error {
    TRConfigCap *cap = _configCaps[key];
    if (!cap) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:1
                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"未知配置: %@", key]}];
        return nil;
    }
    // 类型与范围校验
    if (![self _validateValue:value forCap:cap error:error]) return nil;
    // Phase 8.2：Notifications 枚举合并 - 写入枚举值并映射到底层 SingleNotifEnabled/ClientNotifsEnabled
    // 底层开关仍保留在 NSUserDefaults 供 BulletinManager 读取，但 schema/UI 不再直接暴露
    if ([key isEqualToString:@"Notifications"]) {
        NSString *mode = [value isKindOfClass:[NSString class]] ? value : [NSString stringWithFormat:@"%@", value];
        BOOL singleNotif = YES;
        BOOL clientNotifs = YES;
        if ([mode isEqualToString:@"connectOnly"]) {
            singleNotif = NO;
            clientNotifs = YES;
        } else if ([mode isEqualToString:@"silent"]) {
            singleNotif = NO;
            clientNotifs = NO;
        } // all 模式两个都是 YES
        [_defaults setObject:@(singleNotif) forKey:@"SingleNotifEnabled"];
        [_defaults setObject:@(clientNotifs) forKey:@"ClientNotifsEnabled"];
        // 继续写入 Notifications 枚举值本身（下方通用写入逻辑）
    }
    // Phase 8.3：PerformanceMode 枚举合并 - 写入枚举值并按预设写入 4 个底层参数
    if ([key isEqualToString:@"PerformanceMode"]) {
        NSString *mode = [value isKindOfClass:[NSString class]] ? value : [NSString stringWithFormat:@"%@", value];
        // 按预设写入 4 个底层参数（custom 模式不写入，保留用户独立配置）
        NSDictionary *presets = @{
            @"balanced":   @{@"TileSize": @32, @"MaxRects": @512, @"FullscreenThresholdPercent": @50, @"AsyncSwap": @NO},
            @"quality":     @{@"TileSize": @64, @"MaxRects": @2048, @"FullscreenThresholdPercent": @80, @"AsyncSwap": @NO},
            @"performance": @{@"TileSize": @16, @"MaxRects": @128, @"FullscreenThresholdPercent": @30, @"AsyncSwap": @YES},
            @"custom":      @{}
        };
        NSDictionary *preset = presets[mode];
        if (!preset) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:3
                                userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"未知 PerformanceMode: %@", mode]}];
            return nil;
        }
        BOOL needRestart = NO;
        for (NSString *k in preset) {
            [_defaults setObject:preset[k] forKey:k];
            // 按底层参数的 reload 级别触发副作用
            TRConfigReload r = _configCaps[k].reload;
            if (r == TRConfigReloadHot) {
                // hot 级别：即时更新 C 全局变量
                tvReloadConfigForKey(k.UTF8String);
            } else if (r == TRConfigReloadRestart) {
                // restart 级别：标记需要重启（循环结束后统一触发一次，避免多次 restart）
                needRestart = YES;
            }
        }
        // 统一触发一次重启（避免多次 restart 调用）
        if (needRestart) {
            TRGatewayClient *gw = [TRGatewayClient sharedClient];
            TRWatchDog *wd = gw.watchdog;
            if (wd) {
                [wd restart];
            } else if (gw.restartHandler) {
                gw.restartHandler();
            }
        }
        // 继续写入 PerformanceMode 枚举值本身（下方通用写入逻辑）
    }
    // 写入 NSUserDefaults
    [_defaults setObject:value forKey:key];
    // 密码类特殊处理：同时更新存在性标记
    if ([key isEqualToString:@"FullPassword"] || [key isEqualToString:@"ViewOnlyPassword"]) {
        // currentConfigs 会动态计算 hasPassword/hasViewOnlyPassword，无需额外处理
    }

    // Phase 4.4：按 reload 策略分发副作用
    if (cap.reload == TRConfigReloadHot) {
        // hot 级别：先尝试 trollvncserver 的 key（更新 C 全局变量 + framebuffer 重建等）
        int rc = tvReloadConfigForKey(key.UTF8String);
        if (rc != 0) {
            // 非 trollvncserver 管理的 hot key → Watchdog/HID 活属性即时应用（附录 E）
            TRWatchDog *wd = [TRGatewayClient sharedClient].watchdog;
            if (wd) {
                if ([key isEqualToString:@"WatchdogThrottleInterval"]) wd.throttleInterval = [value doubleValue];
                else if ([key isEqualToString:@"WatchdogKeepAlive"]) wd.keepAlive = @([value boolValue]);
                else if ([key isEqualToString:@"WatchdogExitTimeout"]) wd.exitTimeOut = [value doubleValue];
            }
            if ([key isEqualToString:@"HIDKeepAliveInterval"]) {
                [STHIDEventGenerator sharedGenerator].keepAliveInterval = [value doubleValue];
            }
        }
    } else if (cap.reload == TRConfigReloadRestart) {
        // restart 级别：触发 watchdog 重启服务（端口/认证/RFB 协议头变更需重启生效）
        TRGatewayClient *gw = [TRGatewayClient sharedClient];
        TRWatchDog *wd = gw.watchdog;
        if (wd) {
            [wd restart];
        } else if (gw.restartHandler) {
            gw.restartHandler();
        }
    }
    // gateway/instant 无需特殊处理（见函数注释）
    return [self _reloadName:cap.reload];
}

/** 校验配置值类型与范围 */
- (BOOL)_validateValue:(id)value forCap:(TRConfigCap *)cap error:(NSError **)error {
    NSString *t = cap.type;
    if ([t isEqualToString:@"bool"]) {
        if (![value respondsToSelector:@selector(boolValue)]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"期望 bool 值"}];
            return NO;
        }
        return YES;
    }
    if ([t isEqualToString:@"number"]) {
        if (![value respondsToSelector:@selector(doubleValue)]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"期望 number 值"}];
            return NO;
        }
        double v = [value doubleValue];
        if (cap.min && v < [cap.min doubleValue]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"值 %@ 小于下限 %@", value, cap.min]}];
            return NO;
        }
        if (cap.max && v > [cap.max doubleValue]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"值 %@ 大于上限 %@", value, cap.max]}];
            return NO;
        }
        return YES;
    }
    if ([t isEqualToString:@"string"] || [t isEqualToString:@"password"]) {
        if (![value isKindOfClass:[NSString class]]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"期望 string 值"}];
            return NO;
        }
        return YES;
    }
    if ([t isEqualToString:@"enum"]) {
        if (![cap.enumValues containsObject:value]) {
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"值 %@ 不在枚举 %@", value, cap.enumValues]}];
            return NO;
        }
        return YES;
    }
    return YES;
}

#pragma mark - 触控坐标转换（归一化 0-1 → 原生像素）

/**
 * 归一化坐标转原生像素坐标
 * @param p     含 x(0-1)/y(0-1) 的字典
 * @param error 失败错误
 * @return 原生像素 CGPoint（失败返回 {-1,-1}）
 */
- (CGPoint)_denormalizePoint:(NSDictionary *)p error:(NSError **)error {
    id x = p[@"x"], y = p[@"y"];
    if (!x || !y) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"缺少 x/y 坐标"}];
        return CGPointMake(-1, -1);
    }
    double nx = [x doubleValue], ny = [y doubleValue];
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:3 userInfo:@{NSLocalizedDescriptionKey:@"坐标需在 0-1 范围"}];
        return CGPointMake(-1, -1);
    }
    UIScreen *s = [UIScreen mainScreen];
    CGFloat scale = [s respondsToSelector:@selector(nativeScale)] ? [s nativeScale] : [s scale];
    if (scale <= 0) scale = 1.0;
    CGFloat pw = s.bounds.size.width * scale;
    CGFloat ph = s.bounds.size.height * scale;
    return CGPointMake(nx * pw, ny * ph);
}

/** 执行本地控制端口命令（同步 socket 连 127.0.0.1:46752，自定义超时）
 功能：建立 TCP 连接，发送命令+\n，读取响应，关闭连接。
       Phase 11.4 统一接口：所有 46752 命令桥接均通过此方法，超时由调用方显式指定。
       短命令（count/list/disconnect/block/unblock/subscribe/blocked.list/screen.hash/screen.diff）
       使用 kLocalCmdDefaultTimeoutMs 常量；长耗时命令（screen.waitStable）传动态值 MAX(maxMs+2000, 5000)。
 参数：cmd       - 命令字符串（不含换行符，如 "count" / "screen.waitStable 3000 500 200 3"）
      timeoutMs - 收发超时毫秒数（<=0 时回退 kLocalCmdDefaultTimeoutMs）
      error     - 失败时设置错误（连接失败/发送失败/读取失败）
 返回值：NSString* - 响应字符串（已 trim 换行和空白）；失败返回 nil
 */
- (nullable NSString *)_executeLocalCmd:(NSString *)cmd timeoutMs:(NSTimeInterval)timeoutMs error:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:10 userInfo:@{NSLocalizedDescriptionKey:@"创建 socket 失败"}];
        return nil;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLocalCmdPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    // 自定义收发超时（毫秒 → 秒+微秒），防止 invoke 阻塞
    if (timeoutMs <= 0) timeoutMs = 3000;
    struct timeval tv = {
        .tv_sec = (time_t)(timeoutMs / 1000),
        .tv_usec = (suseconds_t)((fmod(timeoutMs, 1000.0)) * 1000)
    };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:11 userInfo:@{NSLocalizedDescriptionKey:@"连接 46752 控制端口失败（trollvncserver 可能未运行）"}];
        return nil;
    }
    // 发送命令 + \n
    NSString *line = [cmd stringByAppendingString:@"\n"];
    const char *data = [line UTF8String];
    size_t total = strlen(data);
    ssize_t sent = 0;
    while (sent < (ssize_t)total) {
        ssize_t n = send(fd, data + sent, total - sent, 0);
        if (n <= 0) {
            close(fd);
            if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"发送命令失败"}];
            return nil;
        }
        sent += n;
    }
    // 读取响应（遇到 \n 即结束，与 trollvncserver 命令处理协议一致）
    NSMutableData *resp = [NSMutableData data];
    char buf[1024];
    while (YES) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [resp appendBytes:buf length:n];
        if (memchr(resp.bytes, '\n', resp.length)) break;
    }
    close(fd);
    NSString *result = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
