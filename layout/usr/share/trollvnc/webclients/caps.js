// 5801 直连页按钮元数据（独立于网关 web/caps.js，2026-08-13 起两份已分叉：本文件仅服务设备端 5801 页面的按键标题覆盖）
// 新增能力 = 设备端注册 executor + 前端加定义（不做运行时发现）
// 2026-08-14 方案 A：顺序与网关 KEY_DEFS 对齐（power 上、mute 在 voldn 上），新增 snapshot/spotlight
// 2026-08-15：clipboard → paste（剪贴板按钮改为粘贴输入，见 index.vnc）
export const DEFAULT_CAPS = ['power', 'home', 'volup', 'mute', 'voldn', 'briup', 'bridn', 'snapshot', 'spotlight', 'keyboard', 'paste'];

export const CAP_META = {
  power:     { op: 'power',     label: '电源',      icon: '⏻',    title: '电源' },
  home:      { op: 'home',      label: 'Home',      icon: '🏠', title: 'Home' },
  volup:     { op: 'volup',     label: '音量 +',    icon: '🔊', title: '音量 +' },
  mute:      { op: 'mute',      label: '静音',      icon: '🔇', title: '静音' },
  voldn:     { op: 'voldn',     label: '音量 −',    icon: '🔉', title: '音量 −' },
  briup:     { op: 'briup',     label: '亮度 +',    icon: '☀️', title: '亮度 +' },
  bridn:     { op: 'bridn',     label: '亮度 −',    icon: '🌙', title: '亮度 −' },
  snapshot:  { op: 'snapshot',  label: '截屏',      icon: '✂️', title: '截屏' },
  spotlight: { op: 'spotlight', label: '搜索',      icon: '🔍', title: '搜索' },
  keyboard:  { op: 'kb',        label: '键盘',      icon: '⌨️', title: '键盘' },
  paste:     { op: 'paste',     label: '粘贴',      icon: '📋', title: '粘贴输入到设备' },
};
