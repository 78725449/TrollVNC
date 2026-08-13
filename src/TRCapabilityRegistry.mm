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
#import "Logging.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>

// trollvncserver.mm 公开访问函数（供系统查询能力调用）
extern NSDictionary *tvGetInflightStats(void);
extern NSDictionary *tvGetBonjourTXT(void);
// Phase 4.4：trollvncserver 配置热重载入口（hot 级别 key 更新 C 全局变量 + 副作用）
extern int tvReloadConfigForKey(const char *key);

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
// Phase 2：RFB 端口（原 46752 控制端口已收敛，能力经 5901 RFB 扩展消息 type 0x50/0x80 承载）
static const int kRfbPort = 5901;
// RFB 扩展消息超时常量（毫秒，统一管理）
// 短命令默认超时：count/list/disconnect/block/unblock/blocked.list/screen.hash/screen.diff 等
// 本地回环实际响应 <50ms，3 秒超时已含极端 CPU 满载余量
static const NSTimeInterval kRfbDefaultTimeoutMs = 3000;

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

#pragma mark - 自签证书生成辅助（对齐 app 侧 ZTSelfSignedCertificate.m，仅依赖系统 Security 框架）
// 说明：ZTSelfSignedCertificate 仅编译进 TrollVNC app target（TrollVNC.xcodeproj），
//       trollvncmanager（本文件所在二进制，见 Makefile）无法链接该类，故按同目录
//       ZTSelfSignedCertificate.m 逐行对齐移植等价逻辑（同为 Security 私有函数路径）。

// Security 私有符号（与 ZTSelfSignedCertificate.m 一致，SecGenerateSelfSignedCertificate 为私有函数）
extern SecCertificateRef SecGenerateSelfSignedCertificate(CFArrayRef subject, CFDictionaryRef __nullable parameters,
                                                          SecKeyRef publicKey, SecKeyRef privateKey);
extern const CFStringRef kSecOidCommonName;
extern const CFStringRef kSecCSRBasicContraintsPathLen;
extern const CFStringRef kSecCertificateKeyUsage;
extern const CFStringRef kSecCertificateExtensionsEncoded;

// keyUsage bit 定义（对齐 SecCertificatePriv.h / ZTSelfSignedCertificate.m）
enum {
    kTRKeyUsageDigitalSignature = 1 << 0,
    kTRKeyUsageKeyEncipherment = 1 << 2,
    kTRKeyUsageKeyCertSign = 1 << 5,
    kTRKeyUsageCRLSign = 1 << 6,
};

/** DER → PEM（64 字符折行，对齐 ZTSelfSignedCertificate.m 的 ZTPEMFromDER） */
static NSString *TRPEMFromDER(NSData *der, NSString *header, NSString *footer) {
    if (!der) return nil;
    NSString *b64 = [der base64EncodedStringWithOptions:0];
    NSMutableString *pem = [NSMutableString string];
    [pem appendFormat:@"-----BEGIN %@-----\n", header];
    const NSUInteger lineLen = 64;
    for (NSUInteger i = 0; i < b64.length; i += lineLen) {
        NSUInteger len = MIN(lineLen, b64.length - i);
        [pem appendFormat:@"%@\n", [b64 substringWithRange:NSMakeRange(i, len)]];
    }
    [pem appendFormat:@"-----END %@-----\n", footer];
    return pem;
}

/** 手工构造 EKU = { serverAuth, clientAuth } 的 DER（对齐 ZTSelfSignedCertificate.m 的 ZTExtendedKeyUsageDER） */
static NSData *TRExtendedKeyUsageDER(void) {
    // 30 14       SEQUENCE, length 0x14
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 01   (1.3.6.1.5.5.7.3.1 serverAuth)
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 02   (1.3.6.1.5.5.7.3.2 clientAuth)
    static const uint8_t ekuBytes[] = {0x30, 0x14, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03,
                                       0x01, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02};
    return [NSData dataWithBytes:ekuBytes length:sizeof(ekuBytes)];
}

/**
 * 生成 RSA2048 自签 CA 证书 + 私钥（PEM）
 * 功能：等价 ZTSelfSignedCertificate generateWithCommonName 的核心逻辑
 *      （同 certParams/同 subject 结构/同 EKU，CA:TRUE pathLen=0），供 settings.generateKeys 复用。
 * 参数：commonName - 证书 CN 字符串
 *      certPEM - 输出：证书 PEM（-----BEGIN CERTIFICATE-----）
 *      keyPEM  - 输出：私钥 PEM（-----BEGIN RSA PRIVATE KEY-----，PKCS#1）
 * 返回值：BOOL - 生成成功
 */
static BOOL TRGenerateSelfSignedCert(NSString *commonName, NSString **certPEM, NSString **keyPEM) {
    OSStatus status = errSecSuccess;
    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    SecCertificateRef cert = NULL;
    CFMutableDictionaryRef certParams = NULL;
    CFMutableDictionaryRef encodedExts = NULL;
    CFArrayRef subject = NULL;
    CFArrayRef cnPair = NULL;
    CFArrayRef cnRDN = NULL;
    CFStringRef cfCommonName = (__bridge CFStringRef)commonName;
    BOOL ok = NO;

    // 1. 生成 RSA key pair (2048 bit)
    {
        CFMutableDictionaryRef keyParams =
            CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                      &kCFTypeDictionaryValueCallBacks);
        if (!keyParams) goto cleanup;
        CFDictionaryAddValue(keyParams, kSecAttrKeyType, kSecAttrKeyTypeRSA);
        int keySize = 2048;
        CFNumberRef keySizeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keySize);
        CFDictionaryAddValue(keyParams, kSecAttrKeySizeInBits, keySizeNum);
        CFRelease(keySizeNum);
        CFDictionaryAddValue(keyParams, kSecAttrLabel, cfCommonName);
        status = SecKeyGeneratePair(keyParams, &publicKey, &privateKey);
        CFRelease(keyParams);
        if (status != errSecSuccess || !publicKey || !privateKey) goto cleanup;
    }

    // 2. 构造 certParams：CA:TRUE pathLen=0 + keyUsage + EKU(serverAuth+clientAuth)
    certParams = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    if (!certParams) goto cleanup;
    {
        CFIndex pathLenValue = 0;
        CFNumberRef pathLen = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &pathLenValue);
        CFDictionarySetValue(certParams, kSecCSRBasicContraintsPathLen, pathLen);
        CFRelease(pathLen);
    }
    {
        int keyUsageValue = kTRKeyUsageDigitalSignature | kTRKeyUsageKeyEncipherment |
                            kTRKeyUsageKeyCertSign | kTRKeyUsageCRLSign;
        CFNumberRef keyUsageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyUsageValue);
        CFDictionarySetValue(certParams, kSecCertificateKeyUsage, keyUsageNum);
        CFRelease(keyUsageNum);
    }
    {
        encodedExts = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
        if (!encodedExts) goto cleanup;
        NSData *ekuDER = TRExtendedKeyUsageDER();
        CFDataRef ekuData = CFDataCreate(kCFAllocatorDefault, ekuDER.bytes, (CFIndex)ekuDER.length);
        if (!ekuData) goto cleanup;
        CFDictionarySetValue(encodedExts, CFSTR("2.5.29.37"), ekuData); // id-ce-extKeyUsage
        CFRelease(ekuData);
        CFDictionarySetValue(certParams, kSecCertificateExtensionsEncoded, encodedExts);
    }

    // 3. 构造 subject（三层数组结构，仅一个 CN）
    {
        const void *cnFields[2] = {kSecOidCommonName, cfCommonName};
        cnPair = CFArrayCreate(kCFAllocatorDefault, cnFields, 2, &kCFTypeArrayCallBacks);
        if (!cnPair) goto cleanup;
        const void *cnRDNFields[1] = {cnPair};
        cnRDN = CFArrayCreate(kCFAllocatorDefault, cnRDNFields, 1, &kCFTypeArrayCallBacks);
        if (!cnRDN) goto cleanup;
        const void *rdnList[1] = {cnRDN};
        subject = CFArrayCreate(kCFAllocatorDefault, rdnList, 1, &kCFTypeArrayCallBacks);
        if (!subject) goto cleanup;
    }

    // 4. 生成自签 CA 证书
    cert = SecGenerateSelfSignedCertificate(subject, certParams, publicKey, privateKey);
    if (!cert) goto cleanup;

    // 5. 导出证书（DER → PEM）
    {
        CFDataRef certData = SecCertificateCopyData(cert);
        if (!certData) goto cleanup;
        NSData *derCert = (__bridge_transfer NSData *)certData;
        NSString *pem = TRPEMFromDER(derCert, @"CERTIFICATE", @"CERTIFICATE");
        if (!pem) goto cleanup;
        if (certPEM) *certPEM = pem;
    }

    // 6. 导出私钥（DER → PEM，PKCS#1 RSA PRIVATE KEY）
    {
        CFErrorRef error = NULL;
        CFDataRef keyData = SecKeyCopyExternalRepresentation(privateKey, &error);
        if (!keyData) {
            if (error) CFRelease(error);
            goto cleanup;
        }
        NSData *derKey = (__bridge_transfer NSData *)keyData;
        NSString *pem = TRPEMFromDER(derKey, @"RSA PRIVATE KEY", @"RSA PRIVATE KEY");
        if (!pem) goto cleanup;
        if (keyPEM) *keyPEM = pem;
    }

    ok = (*certPEM != nil && *keyPEM != nil);

cleanup:
    if (cert) CFRelease(cert);
    if (publicKey) CFRelease(publicKey);
    if (privateKey) CFRelease(privateKey);
    if (subject) CFRelease(subject);
    if (cnRDN) CFRelease(cnRDN);
    if (cnPair) CFRelease(cnPair);
    if (encodedExts) CFRelease(encodedExts);
    if (certParams) CFRelease(certParams);
    return ok;
}

#pragma mark - 网关搜索辅助（对齐 TVNCRootListController searchGateway 非 UI 核心逻辑）

/** 从 NSNetService 提取 IPv4 地址（对齐 TVNCRootListController ipAddressOfService，跳过 169.254.* 链路本地） */
static NSString *TRIPAddressOfService(NSNetService *service) {
    for (NSData *address in service.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)address.bytes;
        if (sa->sa_family != AF_INET) continue;
        char host[NI_MAXHOST];
        if (getnameinfo(sa, (socklen_t)address.length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            NSString *ip = [NSString stringWithUTF8String:host];
            if (![ip hasPrefix:@"169.254."]) return ip;
        }
    }
    return nil;
}

/** 网关搜索收集对象（NSNetServiceBrowserDelegate/NSNetServiceDelegate，生命周期限于单次搜索） */
@interface TRGatewaySearchHelper : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic, strong) NSNetServiceBrowser *browser;               // 搜索器（强持有防释放，delegate 为弱引用）
@property(nonatomic, strong) NSMutableArray<NSNetService *> *services;   // 发现的 service（resolve 后取 IPv4）
@end

@implementation TRGatewaySearchHelper
- (instancetype)init {
    self = [super init];
    if (self) _services = [NSMutableArray<NSNetService *> array];
    return self;
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [_services addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:3.0];
}
@end

/**
 * 同步执行一次局域网网关搜索（_superphone-farm._tcp）
 * 功能：在独立串行队列线程驱动 run loop，收集 3.5s 内发现的网关，返回第一个有 IPv4 地址的 {host, port}。
 *      对齐 TVNCRootListController searchGateway + saveGateway 语义（原实现为 UI 弹窗选择，
 *      invoke 无 UI 场景直接取第一个可用网关）。
 * 参数：无
 * 返回值：NSDictionary* - {host, port}；未发现网关返回 nil
 */
static NSDictionary *TRSearchGatewaySync(void) {
    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("com.82flex.trollvnc.gateway-search", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        TRGatewaySearchHelper *helper = [TRGatewaySearchHelper new];
        helper.browser = [[NSNetServiceBrowser alloc] init];
        helper.browser.delegate = helper;
        [helper.browser searchForServicesOfType:@"_superphone-farm._tcp" inDomain:@"local."];
        // 驱动 run loop 让 delegate 回调与 resolve 完成（3.5s 上限，bonjour 局域网响应远快于此）
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.5];
        while ([deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [helper.browser stop];
        helper.browser.delegate = nil;
        // 取第一个已 resolve 的 IPv4 网关（对齐 presentFoundGateways 的 ready 过滤逻辑）
        for (NSNetService *svc in helper.services) {
            NSString *host = TRIPAddressOfService(svc);
            if (host) {
                result = @{@"host": host, @"port": @(svc.port)};
                break;
            }
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    return result;
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
    [self _registerSettingsActions];
    [self _registerBulletinCapabilities];
    [self _registerWatchdogCapabilities];
    [self _registerLocalCmdCapabilities];
    [self _registerSystemQueryCapabilities];
    [self _registerScreenExtCapabilities];
    [self _registerGatewayCapabilities];
    [self _registerScreenHashCapabilities];
    [self _registerConfigSchemas];

    // 调试/运维向能力：菜单不显示（internal），invoke 仍可用（运维/自动化可调）
    // 2026-08-12：卡片 ⋯ 菜单收窄为「常用管理」，调试类收敛出菜单
    NSSet *debugCaps = [NSSet setWithArray:@[
        @"service.signal", @"service.state", @"service.info", @"service.isActive",
        @"service.isThrottled", @"service.validate",
        @"sys.configSnapshot", @"sys.stats.inflight",
        @"notify.banner", @"notify.banner.update", @"notify.revoke", @"notify.revokeAll",
        @"gateway.deviceInfo",
        @"screen.forceRefresh",
        @"clients.freeze", @"clients.unfreeze",
    ]];
    for (TRControlCap *cap in [_controlCaps allValues]) {
        if ([debugCaps containsObject:cap.capId]) cap.menuLevel = @"internal";
    }
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
        @{@"id":@"home.down",   @"title":@"Home按下",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuDown)), @"menu":@"internal"},
        @{@"id":@"home.up",     @"title":@"Home抬起",   @"icon":@"🏠",  @"sel":NSStringFromSelector(@selector(menuUp)), @"menu":@"internal"},
        @{@"id":@"power.down",  @"title":@"电源按下",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerDown)), @"menu":@"internal"},
        @{@"id":@"power.up",    @"title":@"电源抬起",   @"icon":@"⏻",  @"sel":NSStringFromSelector(@selector(powerUp)), @"menu":@"internal"},
        @{@"id":@"volup.down",  @"title":@"音量+按下",  @"icon":@"🔊",  @"sel":NSStringFromSelector(@selector(volumeIncrementDown)), @"menu":@"internal"},
        @{@"id":@"volup.up",    @"title":@"音量+抬起",  @"icon":@"🔊",  @"sel":NSStringFromSelector(@selector(volumeIncrementUp)), @"menu":@"internal"},
        @{@"id":@"voldn.down",  @"title":@"音量−按下",  @"icon":@"🔉",  @"sel":NSStringFromSelector(@selector(volumeDecrementDown)), @"menu":@"internal"},
        @{@"id":@"voldn.up",    @"title":@"音量−抬起",  @"icon":@"🔉",  @"sel":NSStringFromSelector(@selector(volumeDecrementUp)), @"menu":@"internal"},
        @{@"id":@"mute.down",   @"title":@"静音按下",   @"icon":@"🔇",  @"sel":NSStringFromSelector(@selector(muteDown)), @"menu":@"internal"},
        @{@"id":@"mute.up",     @"title":@"静音抬起",   @"icon":@"🔇",  @"sel":NSStringFromSelector(@selector(muteUp)), @"menu":@"internal"},
        @{@"id":@"briup.down",  @"title":@"亮度+按下",  @"icon":@"☀️",  @"sel":NSStringFromSelector(@selector(displayBrightnessIncrementDown)), @"menu":@"internal"},
        @{@"id":@"briup.up",    @"title":@"亮度+抬起",  @"icon":@"☀️",  @"sel":NSStringFromSelector(@selector(displayBrightnessIncrementUp)), @"menu":@"internal"},
        @{@"id":@"bridn.down",  @"title":@"亮度−按下",  @"icon":@"🌙",  @"sel":NSStringFromSelector(@selector(displayBrightnessDecrementDown)), @"menu":@"internal"},
        @{@"id":@"bridn.up",    @"title":@"亮度−抬起",  @"icon":@"🌙",  @"sel":NSStringFromSelector(@selector(displayBrightnessDecrementUp)), @"menu":@"internal"},
        @{@"id":@"hwlock",      @"title":@"硬件键盘锁", @"icon":@"🔒",  @"sel":NSStringFromSelector(@selector(hardwareLock))},
        @{@"id":@"hwunlock",    @"title":@"硬件键盘解锁",@"icon":@"🔓", @"sel":NSStringFromSelector(@selector(hardwareUnlock))},
        @{@"id":@"releasekeys", @"title":@"释放所有按键",@"icon":@"🙊", @"sel":NSStringFromSelector(@selector(releaseEveryKeys))},
    ];
    for (NSDictionary *item in hidNoParam) {
        SEL sel = NSSelectorFromString(item[@"sel"]);
        NSString *capId = item[@"id"];
        TRControlCap *cap = [self _registerControl:capId title:item[@"title"] icon:item[@"icon"] route:TRCapRouteHID params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            ((void(*)(id,SEL))[hid methodForSelector:sel])(hid, sel);
            return @{@"ok":@YES};
        }];
        // 按下/抬起原语为 AI 自动化专用，不进人工菜单（数组内其余条目保持默认菜单层级）
        if (item[@"menu"]) cap.menuLevel = item[@"menu"];
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
        TRControlCap *cap = [self _registerControl:capId title:(i==0?@"Consumer按下":(i==1?@"Consumer按下":@"Consumer抬起"))
                          icon:@"🎛" route:TRCapRouteHID
            params:@[@{@"name":@"usage",@"type":@"number",@"min":@0,@"max":@0xFFFFFFFF,@"required":@YES}]
            executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                uint32_t usage = (uint32_t)[p[@"usage"] unsignedIntValue];
                ((void(*)(id,SEL,uint32_t))[hid methodForSelector:sel])(hid, sel, usage);
                return @{@"ok":@YES, @"usage":@(usage)};
            }];
        // Consumer 用法原语为 AI 自动化专用，不进人工菜单
        cap.menuLevel = @"internal";
    }
    // 任意页+用法（3 项）：params {page:int, usage:int}
    NSArray *hidPageIds = @[@"hid.press", @"hid.down", @"hid.up"];
    NSArray *hidPageSels = @[@"otherPage:usagePress:", @"otherPage:usageDown:", @"otherPage:usageUp:"];
    for (NSUInteger i = 0; i < hidPageIds.count; i++) {
        NSString *capId = hidPageIds[i]; SEL sel = NSSelectorFromString(hidPageSels[i]);
        TRControlCap *cap = [self _registerControl:capId title:(i==0?@"HID按下":(i==1?@"HID按下":@"HID抬起"))
                          icon:@"🕹" route:TRCapRouteHID
            params:@[@{@"name":@"page",@"type":@"number",@"min":@0,@"max":@0xFFFF,@"required":@YES},
                     @{@"name":@"usage",@"type":@"number",@"min":@0,@"max":@0xFFFF,@"required":@YES}]
            executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                uint32_t page = (uint32_t)[p[@"page"] unsignedIntValue];
                uint32_t usage = (uint32_t)[p[@"usage"] unsignedIntValue];
                ((void(*)(id,SEL,uint32_t,uint32_t))[hid methodForSelector:sel])(hid, sel, page, usage);
                return @{@"ok":@YES, @"page":@(page), @"usage":@(usage)};
            }];
        // HID 页/用法原语为 AI 自动化专用，不进人工菜单
        cap.menuLevel = @"internal";
    }
    // 键盘按下/抬起（2 项）：params {char:string(1)}（AI 自动化原语，不进人工菜单）
    TRControlCap *keyDownCap = [self _registerControl:@"key.down" title:@"按键按下" icon:@"⬇" route:TRCapRouteHID
        params:@[@{@"name":@"char",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *c = p[@"char"];
            if (c.length != 1) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"char 需为单字符"}]; return nil; }
            [hid keyDown:c]; return @{@"ok":@YES};
        }];
    keyDownCap.menuLevel = @"internal";
    TRControlCap *keyUpCap = [self _registerControl:@"key.up" title:@"按键抬起" icon:@"⬆" route:TRCapRouteHID
        params:@[@{@"name":@"char",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *c = p[@"char"];
            if (c.length != 1) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"char 需为单字符"}]; return nil; }
            [hid keyUp:c]; return @{@"ok":@YES};
        }];
    keyUpCap.menuLevel = @"internal";
}

/** 注册触控类能力（归一化 0-1 坐标，设备侧转原生像素） */
- (void)_registerTouchCapabilities {
    STHIDEventGenerator *hid = [STHIDEventGenerator sharedGenerator];
    // 单点触控：params {x:0-1, y:0-1}（画布直操语义：触控能力不进人工菜单，AI/画布经 invoke 使用）
    TRControlCap *tapCap = [self _registerControl:@"touch.tap" title:@"点击" icon:@"👆" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid tap:pt]; return @{@"ok":@YES};
        }];
    tapCap.menuLevel = @"internal";
    // 滑动：params {x1,y1,x2,y2,duration}（画布直操语义：不进人工菜单，AI/画布经 invoke 使用）
    TRControlCap *swipeCap = [self _registerControl:@"touch.swipe" title:@"滑动" icon:@"↔" route:TRCapRouteTouch
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
    swipeCap.menuLevel = @"internal";
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
        TRControlCap *cap = [self _registerControl:tapIds[i] title:tapTitles[i] icon:tapIcons[i] route:TRCapRouteTouch
            params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                CGPoint pt = [self _denormalizePoint:p error:e];
                if (pt.x < 0) return nil;
                ((void(*)(id,SEL,CGPoint))[hid methodForSelector:sel])(hid, sel, pt);
                return @{@"ok":@YES};
            }];
        // 手势原语为画布直操/AI 自动化专用（双击/双指/三指/长按），不进人工菜单
        cap.menuLevel = @"internal";
    }
    // 曲线滑动：params {x1,y1,x2,y2,duration?}（AI 手势原语，不进人工菜单）
    TRControlCap *curveCap = [self _registerControl:@"touch.curveSwipe" title:@"曲线滑动" icon:@"〰" route:TRCapRouteTouch
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
    curveCap.menuLevel = @"internal";
    // 捏合缩放：params {bounds:{x,y,w,h}, scale, angle, duration}（AI 手势原语，不进人工菜单）
    TRControlCap *pinchCap = [self _registerControl:@"touch.pinch" title:@"捏合缩放" icon:@"🤏" route:TRCapRouteTouch
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
    pinchCap.menuLevel = @"internal";
    // 触摸按下/抬起：params {x,y}（AI 自动化原语，不进人工菜单）
    TRControlCap *touchDownCap = [self _registerControl:@"touch.down" title:@"触摸按下" icon:@"👇" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid touchDown:pt]; return @{@"ok":@YES};
        }];
    touchDownCap.menuLevel = @"internal";
    TRControlCap *touchUpCap = [self _registerControl:@"touch.up" title:@"触摸抬起" icon:@"👆" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid liftUp:pt]; return @{@"ok":@YES};
        }];
    touchUpCap.menuLevel = @"internal";
    // 多指同点按下/抬起：params {x,y,count}（AI 自动化原语，不进人工菜单）
    TRControlCap *downMultiCap = [self _registerControl:@"touch.downMulti" title:@"多指按下" icon:@"👥" route:TRCapRouteTouch
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
    downMultiCap.menuLevel = @"internal";
    TRControlCap *upMultiCap = [self _registerControl:@"touch.upMulti" title:@"多指抬起" icon:@"👥" route:TRCapRouteTouch
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
    upMultiCap.menuLevel = @"internal";
    // Batch 4：多指异点按下/抬起（每个触点独立坐标，params {points:[{x,y},...]}，AI 自动化原语，不进人工菜单）
    TRControlCap *downMultiAtCap = [self _registerControl:@"touch.downMultiAt" title:@"多指异点按下" icon:@"🖐️" route:TRCapRouteTouch
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
            CGPoint *locations = (CGPoint *)malloc(count * sizeof(CGPoint));
            if (!locations) { *e = [NSError errorWithDomain:@"TRCap" code:4 userInfo:@{NSLocalizedDescriptionKey:@"内存分配失败"}]; return nil; }
            for (NSUInteger i = 0; i < count; i++) {
                locations[i] = [self _denormalizePoint:pts[i] error:e];
                if (locations[i].x < 0) { free(locations); return nil; }
            }
            [hid touchDownAtPoints:locations touchCount:count];
            free(locations);
            return @{@"ok":@YES, @"count":@(count)};
        }];
    downMultiAtCap.menuLevel = @"internal";
    TRControlCap *upMultiAtCap = [self _registerControl:@"touch.upMultiAt" title:@"多指异点抬起" icon:@"🖐️" route:TRCapRouteTouch
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
            CGPoint *locations = (CGPoint *)malloc(count * sizeof(CGPoint));
            if (!locations) { *e = [NSError errorWithDomain:@"TRCap" code:4 userInfo:@{NSLocalizedDescriptionKey:@"内存分配失败"}]; return nil; }
            for (NSUInteger i = 0; i < count; i++) {
                locations[i] = [self _denormalizePoint:pts[i] error:e];
                if (locations[i].x < 0) { free(locations); return nil; }
            }
            [hid liftUpAtPoints:locations touchCount:count];
            free(locations);
            return @{@"ok":@YES, @"count":@(count)};
        }];
    upMultiAtCap.menuLevel = @"internal";
    // Batch 4：重置触摸状态（清除所有触点，AI 自动化原语，不进人工菜单）
    TRControlCap *resetCap = [self _registerControl:@"touch.reset" title:@"重置触摸" icon:@"🔄" route:TRCapRouteTouch params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [hid dispatchHandResetEvent]; return @{@"ok":@YES};
        }];
    resetCap.menuLevel = @"internal";
    // Batch 4：单事件派发（透传 eventInfo 字典，AI 自动化原语，不进人工菜单）
    TRControlCap *eventCap = [self _registerControl:@"touch.event" title:@"单事件派发" icon:@"🎞️" route:TRCapRouteTouch
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
    eventCap.menuLevel = @"internal";
    // 通用N击M指：params {x,y,tapCount,touchCount,delay}（AI 自动化原语，不进人工菜单）
    TRControlCap *tapsCap = [self _registerControl:@"touch.taps" title:@"通用N击M指" icon:@"👆✖️N" route:TRCapRouteTouch
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
    tapsCap.menuLevel = @"internal";
    // 自定义事件流：params {eventInfo}（透传给 STHIDEventGenerator.sendEventStream:，AI 自动化原语，不进人工菜单）
    TRControlCap *eventStreamCap = [self _registerControl:@"touch.eventStream" title:@"自定义事件流" icon:@"🎞️" route:TRCapRouteTouch
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
    eventStreamCap.menuLevel = @"internal";
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
    [self _registerControl:@"screenshot" title:@"屏幕快照" icon:@"📷" route:TRCapRouteNative params:@[] executor:^NSDictionary *(NSDictionary *p, NSError **e) {
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

/**
 * 注册设置页动作项（07 §7：Root.plist PSButtonCell 动作暴露为可 invoke 能力）
 * 功能：settings.generateKeys 生成自签 CA + SSL 证书；settings.searchGateway 触发网关搜索/设置。
 * 参数：无
 * 返回值：void
 */
- (void)_registerSettingsActions {
    // settings.generateKeys：生成自签证书（对齐 TVNCRootListController generateKeys 核心逻辑，
    // 复用本文件顶部 TRGenerateSelfSignedCert，等价 ZTSelfSignedCertificate generateWithCommonName）
    [self _registerControl:@"settings.generateKeys" title:@"生成证书" icon:@"🔐" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            // 对齐 TVNCRootListController _reallyGenerateKeys（L457-526）：
            // 1) commonName = "SuperPhone " + UUID 后 8 位
            // 2) 生成 RSA2048 自签 CA（等价 ZTSelfSignedCertificate generateWithCommonName）
            // 3) 写 cacertPath/cakeyPath（Library/Preferences/com.82flex.trollvnc.ca-{cert,key}.pem），chmod 0600
            // 4) 写 defaults SslCertFile/SslKeyFile = 路径（等价 setPreferenceValue:specifier: 效果）
            // 跳过 UI 部分：覆盖确认弹窗/成功提示/导出证书（invoke 为无 UI 场景，直接执行覆盖生成）
            NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
            NSString *commonName = [NSString stringWithFormat:@"SuperPhone %@", randomUUID];
            NSString *certPEM = nil, *keyPEM = nil;
            if (!TRGenerateSelfSignedCert(commonName, &certPEM, &keyPEM)) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:99
                            userInfo:@{NSLocalizedDescriptionKey:@"证书生成失败"}];
                return nil;
            }
            NSError *werr = nil;
            NSString *cacertPath =
                [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
            NSString *cakeyPath =
                [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
            BOOL ok = [certPEM writeToFile:cacertPath atomically:YES encoding:NSUTF8StringEncoding error:&werr];
            if (ok) ok = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600}
                                                           ofItemAtPath:cacertPath error:&werr];
            if (ok) ok = [keyPEM writeToFile:cakeyPath atomically:YES encoding:NSUTF8StringEncoding error:&werr];
            if (ok) ok = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600}
                                                           ofItemAtPath:cakeyPath error:&werr];
            if (!ok) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:98
                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"证书保存失败: %@",
                                                                  werr.localizedDescription]}];
                return nil;
            }
            // 写 defaults（对齐 certSpecifier/keysSpecifier 的 SslCertFile/SslKeyFile 键，
            // reload=restart，setConfig 链路会在重启时生效）
            [_defaults setObject:cacertPath forKey:@"SslCertFile"];
            [_defaults setObject:cakeyPath forKey:@"SslKeyFile"];
            [_defaults synchronize];
            return @{@"ok":@YES, @"certFile":cacertPath, @"keyFile":cakeyPath};
        }];
    // settings.searchGateway：触发网关搜索（对齐 TVNCRootListController searchGateway + saveGateway 语义）
    [self _registerControl:@"settings.searchGateway" title:@"搜索网关" icon:@"🔍" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            // 对齐 TVNCRootListController searchGateway（L636-716）：NSNetServiceBrowser 搜索
            // _superphone-farm._tcp local. 域，过滤 IPv4 地址。
            // 原实现为 UI 弹窗选择（搜索 alert → 网关 ActionSheet → saveGateway:port: 写 defaults），
            // invoke 无 UI 场景取第一个可用网关自动保存（与 saveGateway 落盘逻辑一致）。
            NSDictionary *found = TRSearchGatewaySync();
            if (!found) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:14
                            userInfo:@{NSLocalizedDescriptionKey:@"未找到网关，请检查软路由是否运行 superphone-farm"}];
                return nil;
            }
            // 对齐 saveGateway:port:（L709-716）：写 defaults + synchronize
            // （GatewayHost reload=gateway，TRGatewayClient 观察 defaults 变更会自动重发 register；
            //   GatewayPort 固定 18081 不可调，不写入，TRGatewayClient 固定读取）
            [_defaults setObject:found[@"host"] forKey:@"GatewayHost"];
            [_defaults setInteger:18081 forKey:@"GatewayPort"];
            [_defaults synchronize];
            return @{@"ok":@YES, @"host":found[@"host"], @"port":@18081};
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
        TRControlCap *cap = [self _registerControl:stylusIds[i] title:stylusTitles[i] icon:@"✏️" route:TRCapRouteTouch
            params:stylusParams executor:^NSDictionary *(NSDictionary *p, NSError **e) {
                CGPoint pt = [self _denormalizePoint:p error:e];
                if (pt.x < 0) return nil;
                CGFloat az = [p[@"azimuth"] doubleValue] ?: 0;
                CGFloat alt = [p[@"altitude"] doubleValue] ?: M_PI_2;
                CGFloat pressure = [p[@"pressure"] doubleValue] ?: 1.0;
                ((void(*)(id,SEL,CGPoint,CGFloat,CGFloat,CGFloat))[hid methodForSelector:sel])(hid, sel, pt, az, alt, pressure);
                return @{@"ok":@YES};
            }];
        // 触控笔原语为 AI 自动化专用，不进人工菜单
        cap.menuLevel = @"internal";
    }
    // stylus.up 只需坐标（AI 自动化原语，不进人工菜单）
    TRControlCap *stylusUpCap = [self _registerControl:@"stylus.up" title:@"触控笔抬起" icon:@"✏️" route:TRCapRouteTouch
        params:@[@{@"name":@"x",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES},
                 @{@"name":@"y",@"type":@"number",@"min":@0,@"max":@1,@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            CGPoint pt = [self _denormalizePoint:p error:e];
            if (pt.x < 0) return nil;
            [hid stylusUpAtPoint:pt]; return @{@"ok":@YES};
        }];
    stylusUpCap.menuLevel = @"internal";
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

/** 注册本地命令能力（Batch 2：8 项，经 5901 RFB 扩展消息桥接 clients.* 命令） */
- (void)_registerLocalCmdCapabilities {
    // clients.count：客户端数量
    [self _registerControl:@"clients.count" title:@"客户端数量" icon:@"🔢" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *resp = [self _rfbCommand:@"clients.count" params:@{} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.count 失败"}];
                return nil;
            }
            return @{@"ok":@YES, @"count":resp[@"count"]};
        }];
    // clients.list：客户端列表（服务端扩展 handler 已返回 JSON 数组，无需 TSV 解析）
    [self _registerControl:@"clients.list" title:@"客户端列表" icon:@"📋" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *resp = [self _rfbCommand:@"clients.list" params:@{} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.list 失败"}];
                return nil;
            }
            NSArray *clients = resp[@"clients"] ?: @[];
            return @{@"ok":@YES, @"clients":clients};
        }];
    // clients.disconnect：断开客户端 params {clientId}（支持 "ALL"）
    [self _registerControl:@"clients.disconnect" title:@"断开客户端" icon:@"🔌" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"clientId",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *cid = p[@"clientId"];
            if (!cid) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"clientId 缺失"}]; return nil; }
            NSDictionary *resp = [self _rfbCommand:@"clients.disconnect" params:@{@"id":cid, @"block":@NO} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.disconnect 失败"}];
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
            NSDictionary *resp = [self _rfbCommand:@"clients.block" params:@{@"id":cid} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.block 失败"}];
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
            NSDictionary *resp = [self _rfbCommand:@"clients.unblock" params:@{@"host":host} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.unblock 失败"}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // Batch 3：黑名单列表（服务端扩展 handler 已返回 JSON 数组）
    [self _registerControl:@"clients.blocked.list" title:@"黑名单列表" icon:@"📜" route:TRCapRouteLocalCmd params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *resp = [self _rfbCommand:@"clients.blocked.list" params:@{} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.blocked.list 失败"}];
                return nil;
            }
            NSArray *hosts = resp[@"hosts"] ?: @[];
            return @{@"ok":@YES, @"hosts":hosts};
        }];
    // clients.freeze：冻结客户端 params {clientId}
    // 语义：与 clients.block 等价（断开 + 加入黑名单，客户端下次无法自动注册），服务端无独立 freeze op
    // 与 TVNCClientListController.freezeClientWithId: 行为对齐，提供网关 invoke API 入口
    [self _registerControl:@"clients.freeze" title:@"冻结客户端" icon:@"🧊" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"clientId",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *cid = p[@"clientId"];
            if (!cid) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"clientId 缺失"}]; return nil; }
            NSDictionary *resp = [self _rfbCommand:@"clients.block" params:@{@"id":cid} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.freeze 失败"}];
                return nil;
            }
            return @{@"ok":@YES};
        }];
    // clients.unfreeze：解冻客户端 params {host}
    // 语义：与 clients.unblock 等价（移除黑名单，释放客户端，下次可自动注册），服务端无独立 unfreeze op
    // 与 TVNCClientListController.unfreezeHost: 行为对齐，提供网关 invoke API 入口
    [self _registerControl:@"clients.unfreeze" title:@"解冻客户端" icon:@"🔥" route:TRCapRouteLocalCmd
        params:@[@{@"name":@"host",@"type":@"string",@"required":@YES}]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSString *host = p[@"host"];
            if (!host) { *e = [NSError errorWithDomain:@"TRCap" code:2 userInfo:@{NSLocalizedDescriptionKey:@"host 缺失"}]; return nil; }
            NSDictionary *resp = [self _rfbCommand:@"clients.unblock" params:@{@"host":host} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"clients.unfreeze 失败"}];
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
    // screen.capture.start：开始流式采集（传 no-op block，RFB 内核有自己的帧处理；AI 专用，不进人工菜单）
    TRControlCap *captureStartCap = [self _registerControl:@"screen.capture.start" title:@"开始采集" icon:@"▶️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [cap startCaptureWithFrameHandler:^(CMSampleBufferRef sb){}];
            return @{@"ok":@YES};
        }];
    captureStartCap.menuLevel = @"internal";
    // screen.capture.stop：停止流式采集（AI 专用，不进人工菜单）
    TRControlCap *captureStopCap = [self _registerControl:@"screen.capture.stop" title:@"停止采集" icon:@"⏹️" route:TRCapRouteNative params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            [cap endCapture]; return @{@"ok":@YES};
        }];
    captureStopCap.menuLevel = @"internal";
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
 * 注册屏幕感知能力（Phase 11.4：3 项，route=LocalCmd 转发到 5901 RFB 扩展消息）
 * 借鉴 hermes-android screen_hash/diff_screen/wait/event_stream。
 * pHash 计算在 trollvncserver 进程内执行（TRScreenHasher），经 5901 扩展消息桥接。
 * 全部标记为 internal（AI 专用，不进人工菜单），scenes=[ai]。
 */
- (void)_registerScreenHashCapabilities {
    // screen.hash：当前屏幕 pHash（16 字符 hex）
    TRControlCap *hashCap = [self _registerControl:@"screen.hash" title:@"屏幕哈希" icon:@"#" route:TRCapRouteLocalCmd
        params:@[]
        executor:^NSDictionary *(NSDictionary *p, NSError **e) {
            NSDictionary *resp = [self _rfbCommand:@"screen.hash" params:@{} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"screen.hash 失败"}];
                return nil;
            }
            NSString *hex = resp[@"hash"];
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
            NSDictionary *resp = [self _rfbCommand:@"screen.diff" params:@{@"baseline":baseline, @"threshold":@(threshold)} timeoutMs:kRfbDefaultTimeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"screen.diff 失败"}];
                return nil;
            }
            // 服务端 tvExtOk 将 data 平铺到顶层；hash → 保持旧返回键 currentHash（兼容既有消费方）
            return @{@"ok":@YES,
                     @"distance":resp[@"distance"],
                     @"threshold":resp[@"threshold"],
                     @"changed":resp[@"changed"],
                     @"currentHash":resp[@"hash"]};
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
            // waitStable 超时 = maxMs + 2000ms 缓冲（含取帧/计算/网络耗时），最少 5 秒
            // 避免默认 3 秒 socket 超时截断 maxMs=3000 的调用
            NSTimeInterval timeoutMs = MAX(maxMs + 2000, 5000);
            NSDictionary *resp = [self _rfbCommand:@"screen.waitStable"
                                             params:@{@"maxMs":@(maxMs), @"stableMs":@(stableMs),
                                                      @"intervalMs":@(intervalMs), @"threshold":@(threshold)}
                                          timeoutMs:timeoutMs error:e];
            if (!resp) return nil;
            if (![resp[@"ok"] boolValue]) {
                if (e) *e = [NSError errorWithDomain:@"TRCap" code:13 userInfo:@{NSLocalizedDescriptionKey:resp[@"error"] ?: @"screen.waitStable 失败"}];
                return nil;
            }
            // 服务端 tvExtOk 将 data 平铺到顶层；frames/hash → 保持旧返回键 frameCount/lastHash（兼容既有消费方）
            return @{@"ok":@YES,
                     @"stable":resp[@"stable"],
                     @"frameCount":resp[@"frames"],
                     @"durationMs":resp[@"durationMs"],
                     @"lastHash":resp[@"hash"]};
        }];
    waitCap.menuLevel = @"internal";
    waitCap.scenes = @[@"ai"];
    waitCap.batchSupport = NO;
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
    // 4 项底层参数仍保留注册，仅在 custom 模式下由设置页 UI 暴露（visibleWhen 标记）
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
    // 连接（端口固定不可调：5901/5801/18081 写死，不注册 Port/HttpPort/GatewayPort）
    [self _registerConfig:@"BindHost" title:@"绑定地址" type:@"string" reload:TRConfigReloadRestart];
    [self _registerConfig:@"BonjourEnabled" title:@"自动发现" type:@"bool" reload:TRConfigReloadGateway];
    [self _registerConfig:@"HttpDir" title:@"HTTP 根目录" type:@"string" reload:TRConfigReloadRestart];
    // Phase 8.1 补齐：网关与 SSL（服务开关 / 网关接入 / SSL 证书）
    [self _registerConfig:@"Enabled" title:@"服务启用" type:@"bool" reload:TRConfigReloadRestart];
    [self _registerConfig:@"GatewayHost" title:@"网关地址" type:@"string" reload:TRConfigReloadGateway];
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

/** 无 min/max 但含枚举的注册重载 */
- (void)_registerConfig:(NSString *)key title:(NSString *)title type:(NSString *)type
             enumValues:(NSArray *)enumValues enumTitles:(NSArray *)enumTitles
                 reload:(TRConfigReload)reload {
    [self _registerConfig:key title:title type:type min:nil max:nil step:nil
             enumValues:enumValues enumTitles:enumTitles reload:reload];
}

/** 无 min/max 的简化注册重载 */
- (void)_registerConfig:(NSString *)key title:(NSString *)title type:(NSString *)type reload:(TRConfigReload)reload {
    [self _registerConfig:key title:title type:type min:nil max:nil step:nil reload:reload];
}

#pragma mark - 能力查询

/** 所有控制型能力完整元数据（含 id/title/icon/route/params） */
- (NSArray<NSDictionary *> *)allControlMetadata {
    NSMutableArray *arr = [NSMutableArray array];
    for (TRControlCap *cap in [_controlCaps allValues]) {
        [arr addObject:[self _controlMetadata:cap]];
    }
    return arr;
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
 * 功能：优先按 capId 前缀推断（覆盖 route 类型无法区分的情况，如 stylus、service、gateway、clients 等），
 *       Phase 11.3/11.4：新增 app、macro、screen.hash/diff/waitStable/subscribe 前缀推断。
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
    // Phase 11.4：屏幕感知（screen.hash/diff/waitStable）
    if ([capId hasPrefix:@"screen.hash"] || [capId hasPrefix:@"screen.diff"] ||
        [capId hasPrefix:@"screen.waitStable"]) {
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
            @"Scale": @1.0, @"OrientationPadFix": @0,
            @"DeferWindowSec": @0.015, @"MaxInflight": @2, @"TileSize": @32,
            @"FullscreenThresholdPercent": @0, @"MaxRects": @256,
            @"WheelStepPx": @48.0, @"KeepAliveSec": @0,
            @"ThumbInterval": @5,
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

#pragma mark - RFB 扩展消息桥接（5901，type 0x50/0x80）

/** 持久 RFB 连接状态（管理客户端连接，复用直至断开/失败；invoke 在网关 worker 串行执行，无需加锁） */
static int sRfbFd = -1;

/**
 * 建立 RFB 连接（含握手：ProtocolVersion → Security → ClientInit → ServerInit → cap.hello）
 * 功能：连接 127.0.0.1:5901，完成 RFB 3.8 握手并以管理客户端身份发送 cap.hello
 *      （服务端据此标记豁免：不计入客户端数、不推帧）。握手完成后连接保持复用。
 * 参数：error - 失败时设置错误（任一步失败均 close(fd) 并返回 -1）
 * 返回值：int - 成功返回连接 fd；失败返回 -1
 */
static int tvRfbConnect(NSError **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:10
            userInfo:@{NSLocalizedDescriptionKey:@"创建 socket 失败"}];
        return -1;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kRfbPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:11
            userInfo:@{NSLocalizedDescriptionKey:@"连接 5901 RFB 端口失败（trollvncserver 可能未运行）"}];
        return -1;
    }
    // --- RFB 握手 ---
    char buf[256];
    // 1. 读 ProtocolVersion（12 字节 "RFB 003.008\n"）
    ssize_t n = recv(fd, buf, 12, MSG_WAITALL);
    if (n != 12 || strncmp(buf, "RFB", 3) != 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:12
            userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：ProtocolVersion"}];
        return -1;
    }
    // 发送 ProtocolVersion
    send(fd, "RFB 003.008\n", 12, 0);
    // 2. 读 Security types（1 字节 count + count 字节 types；LibVNCServer 3.8 始终发送 count+list）
    uint8_t secCount = 0;
    if (recv(fd, &secCount, 1, MSG_WAITALL) != 1) { close(fd); if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：Security types"}]; return -1; }
    if (secCount > 0) {
        // 读 secCount 字节，选 type=1（None）；clamp 防越界（自有服务端最多 2 种）
        uint8_t secTypes[32] = {0};
        uint8_t readCount = MIN(secCount, (uint8_t)sizeof(secTypes));
        recv(fd, secTypes, readCount, MSG_WAITALL);
        uint8_t chosen = 1; // SecurityTypeNone（无认证）
        send(fd, &chosen, 1, 0);
        // 读 SecurityResult（4 字节，0=OK）
        uint32_t secResult = 0;
        if (recv(fd, &secResult, 4, MSG_WAITALL) != 4) { close(fd); if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：SecurityResult"}]; return -1; }
        if (ntohl(secResult) != 0) { close(fd); if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：认证未通过"}]; return -1; }
    }
    // 3. ClientInit（shared=1）
    uint8_t shared = 1;
    send(fd, &shared, 1, 0);
    // 4. 读 ServerInit：width(2) + height(2) + pixformat(16) + nameLen(4) + name
    uint8_t initBuf[24];
    if (recv(fd, initBuf, 24, MSG_WAITALL) != 24) { close(fd); if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：ServerInit"}]; return -1; }
    uint32_t nameLen = 0;
    memcpy(&nameLen, initBuf + 20, 4);
    nameLen = ntohl(nameLen);
    if (nameLen > 0 && nameLen < sizeof(buf)) {
        recv(fd, buf, nameLen, MSG_WAITALL);
    }
    // 5. 发送 cap.hello 标记为管理客户端
    NSDictionary *hello = @{@"op": @"cap.hello", @"params": @{@"mgmt": @YES}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    uint8_t header[8];
    header[0] = 0x50;
    memset(header + 1, 0, 3);
    uint32_t payloadLen = htonl((uint32_t)json.length);
    memcpy(header + 4, &payloadLen, 4);
    send(fd, header, 8, 0);
    send(fd, json.bytes, json.length, 0);
    // 读 cap.hello 响应（8 字节头 + payload）
    uint8_t respHeader[8];
    if (recv(fd, respHeader, 8, MSG_WAITALL) != 8) { close(fd); if (error) *error = [NSError errorWithDomain:@"TRCap" code:12 userInfo:@{NSLocalizedDescriptionKey:@"RFB 握手失败：cap.hello 无响应"}]; return -1; }
    uint32_t respLen = 0;
    memcpy(&respLen, respHeader + 4, 4);
    respLen = ntohl(respLen);
    if (respLen > 0 && respLen < sizeof(buf)) {
        recv(fd, buf, respLen, MSG_WAITALL);
    }
    TVLog(@"RFB 管理连接已建立 (fd=%d)", fd);
    return fd;
}

/**
 * 发送 RFB 扩展消息并读取响应（复用持久连接）
 * 功能：以 JSON 请求 {op, params} 封装为 0x50 帧发送到 5901，读取 0x80 帧解析 JSON 响应。
 *      连接失效（sRfbFd<0 或发送失败）时自动重连一次再发送。持久连接跨多次调用复用。
 * 参数：op        - 扩展操作名（如 "clients.count" / "screen.hash"）
 *      params    - 请求参数字典（可为空）
 *      timeoutMs - 收发超时毫秒数（<=0 时回退 kRfbDefaultTimeoutMs）
 *      error     - 失败时设置错误（连接失败/发送失败/读取失败/响应异常）
 * 返回值：NSDictionary* - 服务端 JSON 响应（含 ok 字段）；失败返回 nil
 */
- (nullable NSDictionary *)_rfbCommand:(NSString *)op
                                 params:(NSDictionary *)params
                              timeoutMs:(NSTimeInterval)timeoutMs
                                 error:(NSError **)error {
    // 确保连接存活
    if (sRfbFd < 0) {
        sRfbFd = tvRfbConnect(error);
        if (sRfbFd < 0) return nil;
    }
    // 设置超时
    if (timeoutMs <= 0) timeoutMs = kRfbDefaultTimeoutMs;
    struct timeval tv = {
        .tv_sec = (time_t)(timeoutMs / 1000),
        .tv_usec = (suseconds_t)(fmod(timeoutMs, 1000.0) * 1000)
    };
    setsockopt(sRfbFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sRfbFd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    // 构造消息
    NSDictionary *req = @{@"op": op, @"params": params ?: @{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:req options:0 error:nil];
    if (!json) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:13
            userInfo:@{NSLocalizedDescriptionKey:@"JSON 序列化失败"}];
        return nil;
    }
    uint8_t header[8];
    header[0] = 0x50;
    memset(header + 1, 0, 3);
    uint32_t payloadLen = htonl((uint32_t)json.length);
    memcpy(header + 4, &payloadLen, 4);
    // 发送
    if (send(sRfbFd, header, 8, 0) != 8 ||
        send(sRfbFd, json.bytes, json.length, 0) != (ssize_t)json.length) {
        // 连接断开，重连一次再发
        close(sRfbFd); sRfbFd = -1;
        sRfbFd = tvRfbConnect(error);
        if (sRfbFd < 0) return nil;
        // 重连后重新设置收发超时（tvRfbConnect 内部固定 5 秒，按调用方 timeoutMs 重设）
        setsockopt(sRfbFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(sRfbFd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        send(sRfbFd, header, 8, 0);
        send(sRfbFd, json.bytes, json.length, 0);
    }
    // 读响应
    uint8_t respHeader[8];
    ssize_t n = recv(sRfbFd, respHeader, 8, MSG_WAITALL);
    if (n != 8 || respHeader[0] != 0x80) {
        close(sRfbFd); sRfbFd = -1;
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:14
            userInfo:@{NSLocalizedDescriptionKey:@"读取扩展响应失败"}];
        return nil;
    }
    uint32_t respLen = 0;
    memcpy(&respLen, respHeader + 4, 4);
    respLen = ntohl(respLen);
    if (respLen == 0 || respLen > 1024 * 1024) {
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:15
            userInfo:@{NSLocalizedDescriptionKey:@"响应长度异常"}];
        return nil;
    }
    NSMutableData *respData = [NSMutableData dataWithLength:respLen];
    if (recv(sRfbFd, respData.mutableBytes, respLen, MSG_WAITALL) != (ssize_t)respLen) {
        close(sRfbFd); sRfbFd = -1;
        if (error) *error = [NSError errorWithDomain:@"TRCap" code:14
            userInfo:@{NSLocalizedDescriptionKey:@"读取响应 payload 失败"}];
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
}

@end
