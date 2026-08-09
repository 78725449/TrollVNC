/*
  TRDaemonBridgeManager.mm - 守护进程桥接函数的 Manager 降级实现

  背景：
  TRCapabilityRegistry 调用的 tvGetInflightStats / tvGetBonjourTXT / tvReloadConfigForKey
  原本定义在 trollvncserver.mm（VNC 守护进程）中，依赖守护进程持有的 C 全局状态
  （gInflight/gMaxInflightUpdates、Bonjour TXT 记录、gScale/gRotationQuad 与 rfb 帧缓冲）。

  在 bootstrap 构建中，TRCapabilityRegistry 被编译进 trollvncmanager（网关 Agent 进程），
  该进程不持有上述守护进程状态，因此提供本降级实现：
    - tvGetInflightStats / tvGetBonjourTXT：返回空数据（守护进程才有真实值）
    - tvReloadConfigForKey：返回 -1（未知 key），调用方 TRCapabilityRegistry 已对
      非 0 返回值做 Watchdog/HID 属性兜底处理
  本文件仅加入 trollvncmanager 的编译（Makefile），与 trollvncserver 为独立二进制，无符号冲突。
*/

#import <Foundation/Foundation.h>
// Control.h 声明的全局变量，Manager 端默认赋 0（守护进程负责实际旋转修正）
int gOrientationFixQuad = 0;

NSDictionary *tvGetInflightStats(void) {
    return @{ @"current": @0, @"max": @0 };
}

NSDictionary *tvGetBonjourTXT(void) {
    return @{};
}

int tvReloadConfigForKey(const char *key) {
    (void)key;
    // 未知 key：调用方回退到 Watchdog/HID 直接应用
    return -1;
}
