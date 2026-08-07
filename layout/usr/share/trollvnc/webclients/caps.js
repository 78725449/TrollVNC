// 能力清单（宪法 4.2/5.2/6.6/7.3）— 与网关控制台 trollvnc-farm/web/caps.js 同源，禁止单侧改动
// 三处必须保持一致：本文件 caps.js、网关 web/caps.js、IPA TRGatewayClient.mm 的 _capabilities
// capabilities 固定枚举 = 仅 RFB 可注入的 9 项；适配/全屏/断开是控制台本地操作，不入清单。
export const DEFAULT_CAPS = ['home', 'power', 'volup', 'voldn', 'mute', 'briup', 'bridn', 'keyboard', 'clipboard'];

export const CAP_META = {
  home:      { op: 'home',      label: 'Home',      icon: '🏠', title: 'Home 键' },
  power:     { op: 'power',     label: '电源',      icon: '⏻',    title: '电源' },
  volup:     { op: 'volup',     label: '音量 +',    icon: '🔊', title: '音量 +' },
  voldn:     { op: 'voldn',     label: '音量 −',    icon: '🔉', title: '音量 −' },
  mute:      { op: 'mute',      label: '静音',      icon: '🔇', title: '静音' },
  briup:     { op: 'briup',     label: '亮度 +',    icon: '☀️', title: '亮度 +' },
  bridn:     { op: 'bridn',     label: '亮度 −',    icon: '🌙', title: '亮度 −' },
  keyboard:  { op: 'kb',        label: '键盘',      icon: '⌨️', title: '键盘' },
  clipboard: { op: 'clip',      label: '剪贴板',    icon: '📋', title: '粘贴剪贴板' },
};

// 设备能力列表：缺省 = 默认全集；空数组/未知项过滤；只返回已知枚举
export function deviceCaps(d) {
  const caps = (d && Array.isArray(d.capabilities) && d.capabilities.length) ? d.capabilities : DEFAULT_CAPS;
  return caps.filter((c) => CAP_META[c]);
}
