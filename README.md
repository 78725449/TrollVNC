# SuperPhone

SuperPhone 是一套私有的 iOS 群控系统：安装在手机上的 App 自动注册到局域网网关，电脑/手机浏览器通过网页控制台实现设备墙、全屏控制与批量操作，整体通过 VNC 隧道传输。

- **App（iOS）**：本目录内源码，通过 `.github/workflows/build.yml` 构建出 `.tipa` 安装包。
- **网关（Gateway）**：`../trollvnc-farm`，软路由部署的 Node.js 服务，提供注册、心跳、设备墙与 VNC 桥接。
- **版本**：0.0.1

## 快速开始

1. 部署网关：`cd ../trollvnc-farm && npm install && FARM_TOKEN=... npm start`
2. 构建 App：推送后在 GitHub Actions 手动触发 `Build SuperPhone`，下载 bootstrap 方案的 `.tipa`。
3. 手机安装后，在 App 设置中填入网关地址，即可自动注册上线。
