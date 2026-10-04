# Codex Micro Monitor

Windows 桌面小键盘与 Codex 插件，保留控制页和任务监控页。外观灵感来自 [Codex Micro](https://learn.chatgpt.com/docs/features/codex-micro)。这是第三方项目。

[English](README.md) · [来源](SOURCE.md) · [验证与限制](docs/migration-validation-2026-10-03.md)

支持会话选择、状态灯、标记未读、Fast、Plan、快捷模型与推理强度，以及托盘、置顶和自定义键帽。通过 Codex 软件接口与 Windows UI Automation 适配，不需要虚拟 HID 驱动，也不需要 AgentController。

## 构建与打包

需要 Windows 10 19041+ / Windows 11 x64、.NET SDK 10.0.302，以及已登录的 Codex / ChatGPT 桌面应用。

先从独立 `codex-control` 仓库生成并导入固定组件包；不需要 AgentController 源码：

```powershell
.\scripts\import-control-packages.ps1 -PackageDirectory ..\codex-control\dist\0.1.0-local.2\packages
```

```powershell
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
```

正在运行旧版时，先正常退出旧小键盘，再手动启动新程序。打包脚本不会替换当前安装、上传或安装插件。

统一版本来自 `Version.props`。输出位于 `dist/<版本>/`，包括桌面 ZIP、插件 ZIP、所引用的控制组件包和 ZIP 校验值。运行打包后的程序需要 .NET 10 Desktop Runtime x64。

插件 ZIP 含 `.agents/plugins/marketplace.json` 与 `plugins/codex-micro-keypad/`，应完整解压。插件 ID 保持 `codex-micro-keypad`，本地市场名为 `codex-micro-monitor`。新的公开市场安装流程尚未验证，也尚未发布。

## 验证与范围

```powershell
.\scripts\test.ps1
# 使用不同的、空闲且已读的测试会话；结束后恢复原会话。
.\scripts\test-micro-live.ps1 -Lights -ThreadId <测试会话UUID> -RestoreThreadId <恢复会话UUID>
```

完整测试包含已知失败，会返回非零退出码。通过部分测试不代表所有按键能力均已实现。

- 已迁入输入框提交、选择菜单、对话滚动、侧栏/历史导航和技能插入；这些 UI 动作本轮没有重新实测，不能视为完整实机验收。MCP 指定文本发送是另一条接口。
- DeepSeek、外部应用适配、Qwen3 ASR、本地语音与驱动实现已移除；旧语音配置字段仅作兼容数据保留。
- 当前 Apple 平台目标是 macOS 桌面版，尚无可运行客户端；`apps/ios` 保留已补齐 Xcode 工程的历史 UIKit 原型，未经过 Xcode 编译，不作为当前交付目标。
- Codex 桌面内部接口变化可能需要适配。

`Core` 保存 Micro 状态与呈现合同，`Windows` 实现 WPF 面板，`Desktop` 和 `Plugin` 分别提供独立入口与 MCP 入口。控制客户端和 Windows 通用操作由固定版本 `CodexControl` / `CodexControl.Windows` 提供。

AgentController 和 Micro 分别引用共用组件；本仓库没有指向 AgentController 或组件仓库的源码链接、项目引用或 Git submodule。见[三仓库边界](docs/repository-layout.zh-CN.md)与[本次迁移验证](docs/migration-validation-2026-10-03.md)。

许可证沿用 [PolyForm Noncommercial 1.0.0](LICENSE)。
