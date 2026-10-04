# 三仓库边界

| 仓库 | 职责 |
| --- | --- |
| AgentController | 实体手柄、输入状态机、Overlay、Agent 路由和产品动作合同 |
| codex-micro-monitor | 小键盘、键帽、灯效、设置、监控、桌面与插件入口 |
| codex-control | Codex 控制接口、Desktop IPC / App Server、目录与 Windows 操作适配 |

两个产品只引用固定版本包，不互相引用项目，不使用 Git submodule。`CodexControl` 的已有命名空间暂时保留；程序集名称兼容不代表仍由 Micro 产品维护。

## 更新顺序

1. 在 `codex-control` 修改共享实现，更新 `Version.props` 并执行 `scripts/package.ps1`。
2. 两个产品分别更新 `Directory.Packages.props` 的 `CodexControlVersion`，执行 `scripts/import-control-packages.ps1 -PackageDirectory <包目录>`。
3. 各产品独立构建、验证与发布。包版本确定后不得覆盖为其他内容。

Micro 的新功能只在此仓库维护。AgentController 的 `virtual-micro` 桌面和插件目录是历史保留区；仍在使用的 HID / DeepSeek 旧代码不属于此免驱产品。

## 公开接口

- `ICodexControlClient` / `CodexSoftwareClient`：按 `CodexOperation` 执行，保留目标检查、取消、服务端条件和未知结果语义。
- `ICodexDesktopConnection`：带协议版本的状态观察连接。
- `ICodexUiController`：Windows 前台控件操作与结果回读。AgentController 自己将结果映射到 ActionResult，Micro 自己映射到呈现反馈。
- 公共模型目录、可执行文件发现和请求卡取消辅助由组件提供，产品不链接另一仓库的源码。

Micro 的键位/灯效 DTO 留在产品 `Core`，没有移入共用控制层。生产客户端通过公开接口工作；原有测试的内部访问仅用于维持验证兼容。

## macOS

当前方向是独立 macOS 桌面产品，技术栈与平台实现尚未完成。若使用 Swift，以命令/状态 JSON 合同和 macOS 适配器或显式本机 Host 连接；NuGet 并非 Swift 运行时依赖。本轮未实现该 Host，也不恢复 Avalonia Foundation Preview。设置方案见[交互提案](architecture/settings-interaction.zh-CN.md)。
