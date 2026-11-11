# Qv2ray for Mac

用 Swift + SwiftUI 从零实现的 [Qv2ray](https://github.com/Qv2ray/Qv2ray) 原生 macOS 客户端。菜单栏优先、零第三方依赖、中英双语，功能对标 Qv2ray v2.7.0，仅面向 macOS 14+。

## 特性

- **菜单栏优先** —— 控制中心风格面板：电源开关、当前节点与实时流量迷你图、路由模式与系统代理一键切换、分组节点列表点击即切换
- **原生界面** —— SwiftUI 窗口与设置，浅色 / 深色自适应；语言（中 / 英）独立于系统设置
- **协议支持** —— vmess（v2rayN / Qv2ray / Xray 链接格式）、vless、shadowsocks（SIP002 / SS-2022）、trojan（原生支持，含 Reality）
- **订阅管理** —— base64 / 纯链接 / SIP008 订阅，每组独立更新间隔与自动更新
- **导入方式** —— 分享链接（⌘V 粘贴）、二维码（屏幕框选 / 图片 / 剪贴板）、配置文件、Qv2ray 数据目录一键迁移
- **节点编辑** —— 表单编辑 + JSON 出站覆盖，或完整自定义配置（自动补全入站、日志与统计 API）
- **路由规则** —— 全局 / 规则 / 直连模式，自定义规则编辑器、domainStrategy、绕过局域网
- **系统代理** —— 自动配置绕过列表，异常退出后下次启动自动还原
- **TUN 模式** —— 基于 Xray 原生 `tun` 入站的虚拟网卡，接管所有应用（含不遵循系统代理的命令行工具、游戏等）的流量；自动添加路由、防回环、接管 DNS，断开或应用退出时自动还原
- **流量与延迟** —— 实时吞吐量图表（Swift Charts）、按出站统计流量、真实延迟测试（TCPing 回退）
- **内核管理** —— v2ray 4.x / 5.x 与 Xray 自动适配，崩溃自动重启、端口预检

## 系统要求

| | |
|---|---|
| 系统 | macOS 14 Sonoma 或更高 |
| 工具链 | Xcode Command Line Tools（Swift 5.9+） |
| 内核 | v2ray 或 Xray，应用不内置，需自行安装（如 `brew install xray`） |

## 快速开始

```bash
swift build -c release
./support/make-app.sh                  # 打包 .app（图标、Info.plist、ad-hoc 签名）
open build/Qv2ray-mac.app
```

内核会在 `/opt/homebrew/bin`、`/usr/local/bin` 与 `$PATH` 中自动检测，也可在「设置 → 内核」手动指定；geodata 会在内核同目录等常见位置自动查找。

## 使用

| 区域 | 说明 |
|---|---|
| 菜单栏面板 | 电源开关、当前节点与实时流量、路由 / 系统代理切换、当前分组节点列表 |
| 概览 | 连接状态、实时吞吐量图表、会话流量 / 延迟 / 直连流量、本地代理地址与终端代理命令 |
| 连接 | 可排序节点表格 + 检查器（二维码、分享链接、详情） |
| 路由 | 规则方案列表与分组表单编辑器 |
| 日志 | 级别着色与筛选、搜索、跟随输出、复制 / 导出 |
| 设置（⌘,） | 通用 / 网络 / 内核 / 订阅 / 高级，改动即时生效 |

**快捷键**：⌘↩ 连接/断开 · ⌘R 重新连接 · ⌘T 测延迟 · ⇧⌘P 系统代理 · ⇧⌘T TUN 模式 · ⌘1/2/3 切换路由模式 · ⌘N 新建节点 · ⌘I 导入

### TUN 模式

在菜单栏面板或「设置 → 网络 → TUN 模式」中开启。连接时会弹出管理员密码框（创建 utun 网卡与修改路由需要 root），之后：

- 内核以 root 运行，Xray 创建 utun 网卡并接管 IPv4 默认路由（`autoSystemRoutingTable`），出站绑定物理网卡防止回环（`autoOutboundsInterface: auto`）；
- 开启「接管 DNS」时，系统 DNS 临时改为设置中的地址（默认 8.8.8.8），进入 TUN 的 53 端口流量交给 Xray DNS 解析；原 DNS 在断开时还原；
- 断开连接无需再次输入密码；应用崩溃或被强制退出时，内核会在约 1 秒内自动停止，路由与 DNS 随之还原；
- 代理服务器域名在启用 TUN 前解析并写入 `dns.hosts`，避免「连接服务器需要 DNS、DNS 又要经过服务器」的死循环。

TUN 与系统代理相互独立，可以同时开启。自定义（完整 JSON）配置中若包含 `tun` 入站，也会以管理员权限启动。

主窗口打开时应用出现在 Dock 与 ⌘-Tab 中，关闭后退回纯菜单栏模式。

## 路线图

与 Qv2ray v2.7.0 相比暂未实现的功能：复杂配置可视化编辑器（多入站/出站、负载均衡、链式代理）、DNS 设置编辑器与 FakeDNS、分组级路由 / DNS 覆盖、前置代理、订阅关键字过滤、入站用户名密码认证、socks/http 出站、按连接累计流量、ICMPing、命令行参数与单实例。

## 开发

```bash
.build/release/Qv2rayMac --selftest             # 逻辑自测
.build/release/Qv2rayMac --snapshot /tmp/snaps  # 用演示数据截取全部界面（不触碰真实数据与系统代理）
```

数据位于 `~/Library/Application Support/Qv2ray-mac/`（可用 `QV2RAY_HOME` 覆盖）。无法解析的数据文件会被改名备份，而不会被覆盖。

## 已知限制

- 不内置 v2ray / Xray 内核；XHTTP 等 Xray 专属传输需配合 Xray 内核使用。
- 「扫描屏幕」首次使用时 macOS 会请求屏幕录制权限。
- TUN 模式需要支持 `tun` 入站的较新 Xray 内核（v2ray 不支持）；每次启动（含崩溃自动重启）都需输入管理员密码；目前仅接管 IPv4，IPv6 流量不经过 TUN（接管 DNS 时只返回 IPv4 地址以减少泄漏）。

## 致谢

- [Qv2ray](https://github.com/Qv2ray/Qv2ray) —— 本项目的功能参考与数据迁移来源。

## 许可

 [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) 
