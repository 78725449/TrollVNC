// 5801 直连页按钮元数据（独立于网关 web/caps.js，2026-08-13 起两份已分叉：本文件仅服务设备端 5801 页面的按键标题覆盖）
// 新增能力 = 设备端注册 executor + 前端加定义（不做运行时发现）
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
