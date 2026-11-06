# Tez

[English](README.md) · 简体中文

原生 macOS 网络代理客户端。SwiftUI 与 AppKit 构建界面，Rust 管理配置和连接，Mihomo 提供代理内核。

[下载](https://github.com/Strugg1e/Tez/releases/latest) · [更新日志](Changelog.md) · [构建指南](native/README.md)

## 安装

支持 **Apple Silicon，macOS 14 或更高版本**。

1. 从[最新版本](https://github.com/Strugg1e/Tez/releases/latest)下载 Apple Silicon ZIP。
2. 解压后将 `Tez.app` 放入“应用程序”。
3. 打开 Tez，在“连接”页配置后台服务，添加订阅或本地配置。

下载页提供 `SHA256SUMS.txt` 校验文件。

## 功能

| 页面 | 常用操作 |
| --- | --- |
| 连接 | 系统代理、PAC、TUN、分流模式、内核启停、本机保护与传输保护 |
| 线路 | 策略组切换、节点搜索、延迟采样、线路对比与代理链 |
| 配置 | 订阅导入与更新、本地 YAML 编辑、配置切换与排序 |
| 活动 | 查看连接来源应用、进程、命中规则与实际出口，搜索规则和日志 |
| 设置 | 端口与 DNS、界面外观、快捷键、本地备份与 WebDAV 备份 |

线路页将当前线路与预览目标分开呈现，延迟采样支持保持读数。活动页把连接来源、规则和出口放在同一条记录中，方便追踪流量去向。

界面支持深浅色外观、紧凑窗口和减少动态效果。常用操作留在首层，维护工具与低频选项收进展开区。

### 运行时保护

“连接 → 内核与服务”提供两个独立开关。本机保护使用临时内核副本；传输保护为兼容节点补充 Chrome 风格 TLS 握手，保留已有指纹。节点覆盖范围和 DNS 配置检查在同处查看。

两项默认关闭，仅本次内核会话有效。可以一起调整，确认一次后重启内核并应用设置。悬停开关可查看原理和作用范围。

## 开发

原生应用的构建、打包和测试命令见 [native/README.md](native/README.md)。

| 目录 | 内容 |
| --- | --- |
| `native/Sources/TezNative` | SwiftUI/AppKit 界面、组件与动效 |
| `src-tauri/src` | Rust 配置、订阅、连接与生命周期管理 |
| `native/core-service` | 内核服务与会话管理 |
| `native/backend-wire` | 本地通信协议 |
| `native/Tests` | 原生界面与连接测试 |
| `src` | React/Tauri 客户端与前端资源 |
| `crates` | 共享 Rust 模块 |

参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)，数据存储与网络连接见 [PRIVACY.md](PRIVACY.md)。

## 开源

Tez 基于 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 开发，采用 [GPL-3.0-only](LICENSE) 许可证。

感谢 [Mihomo](https://github.com/MetaCubeX/mihomo)、[Tauri](https://github.com/tauri-apps/tauri) 及项目依赖的开源作者。
