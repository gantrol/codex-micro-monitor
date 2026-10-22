# 平台方向

> 2026-10-21 · iOS 规划重启；保留既有桌面方向

## Codex Micro

- Apple 平台继续维护 **macOS 桌面版**，同时启动 **iOS 远程控制端规划**；沿用 Windows 的键盘外观与操作语义。
- 2026-10-04 用户明确要求界面改用 **UIKit，不用 SwiftUI**。已完成当前 Windows 默认布局测量，并重建为 UIKit / Mac Catalyst；实机视觉验收尚未完成。测量入口：[尺寸与图层报告](../design/windows-micro/index.html)。
- Windows 与 macOS 在本产品仓库共同维护，平台实现、构建和安装包分别管理；`apps/macos/` 已有可编译、可本地打包的 UIKit / Mac Catalyst 控制预览版（原生 AppKit 桥接菜单栏与通信）；尚未进行真实 UI 或 Codex 业务验收。
- 2026-10-21 用户要求规划并实现 iOS 远程控制端，首版同时支持 Mac、Windows 和外网连接，并涵盖方案 A（Tailscale 组网直连）与方案 B（Micro 自建 E2EE 中继）。范围、选型与实现细节见 [iOS 产品规划](ios-product-plan.zh-CN.md)；蓝牙未纳入首版。
- `apps/ios` 已在 UIKit 原型基础上完成 Protocol v2、多电脑切换、扫码配对、完整任务列表、最近回复与文字发送、按任务冲突锁定实现，并新增 Mac Host（`apps/macos/Sources/MicroDesktop/RemoteHost.swift`）、Windows Host（`src/CodexMicro.Remote/`）、共享包（`packages/MicroRemote/`）与中继服务（`services/relay/`）。
- macOS 的窗口、双页键盘、菜单栏、数据观察与已有对话控制独立推进；新对话控制与设置等待 Windows 更新同步。当前构建和能力边界见 [Mac 工程说明](../../apps/macos/README.md)。iOS 的 WSS/Host 不作为 Mac 基础。
- 设置改为**叠层，点哪设置哪**；旧宽窗口分类方案停止实施，见[设置方向](settings-interaction.zh-CN.md)。
- 测试按单元、组件、内部端到端、Codex 联调和业务结果划清边界，并与开发过程独立；等待 Windows 最新测试规划对齐，见[验证边界](verification-boundaries.zh-CN.md)。
- Micro 在本仓库独立维护；共用组件归 `codex-control`，两个产品分别引用固定版本包。见[三仓库边界](../repository-layout.zh-CN.md)。

## AgentController 旧 Avalonia Foundation Preview

此路线已废弃，不再作为 macOS 交付计划或 Micro 的桌面实现基础。

- `AgentController.Desktop`、`AgentController.Platform.MacOS` 及对应平台测试退出默认解决方案。
- 删除 `release:macos` 工作区命令，旧 `publish-macos.ps1` 入口停止执行打包。
- 源码、测试和打包资源保留为历史参考；相关指南和路线图标为废弃。
- Windows WPF 客户端继续维护。Micro 的 macOS 方向独立推进，不受旧预览废弃影响。
