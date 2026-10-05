# 让 Codex 安装并打开 Micro 插件

适用于 Windows x64 和 Codex Micro Monitor Plugin 1.0.0。需要已登录的 Codex 桌面客户端，以及 .NET 10 Desktop Runtime x64。

插件完整发布包已经带有 Micro 程序。安装插件后，可以让 Codex 打开 Micro 面板；无需再安装商店版。只使用独立桌面窗口时，也可以直接选择[商店版](https://apps.microsoft.com/detail/9NTVMG9QNMHC)。

## 复制给 Codex

在能执行本机命令的 Codex 聊天中发送：

```text
请在这台 Windows x64 电脑上安装 Codex Micro Monitor Plugin 1.0.0。

发布页：https://github.com/gantrol/codex-plugin-micro-keypad/releases/tag/v1.0.0

先检查 codex plugin add --help 是否可用，以及是否安装 .NET 10 Desktop Runtime x64。
从上述 Release 下载 codex-micro-monitor-plugin-1.0.0-win-x64.zip 和 SHA256SUMS.txt，核对 ZIP 的 SHA-256。
把完整 ZIP 解压到当前用户目录中的固定位置，保留 .agents/ 和 plugins/；已有安装先核对，不覆盖未知文件。
以包含 .agents/plugins/marketplace.json 的解压根目录注册 marketplace：
codex plugin marketplace add "<解压根目录的绝对路径>"
然后安装插件：
codex plugin add codex-micro-keypad@codex-micro-monitor
最后用 codex plugin list --marketplace codex-micro-monitor --json 检查安装结果。

如果缺少 CLI 命令、运行时或权限，请说明具体缺项和下一步。
完成后告诉我安装位置，以及是否需要手动重启 Codex。不要自行关闭当前客户端。
本次只安装插件，不发送消息、不停止任务、不替我批准命令。
```

重新打开客户端并新建聊天后，发送：

```text
请使用 Codex Micro Monitor 插件，先读取可用功能，再打开 Micro 面板。
```

此时插件应调用 `get_keypad_capabilities` 和 `show_keypad`。读取功能列表和打开面板不要求选择其他会话；读取或修改某个会话的状态时需要明确目标。

## 自己执行安装命令

1. 从[插件 Release](https://github.com/gantrol/codex-plugin-micro-keypad/releases/tag/v1.0.0)下载完整插件 ZIP 和 `SHA256SUMS.txt`。GitHub 自动生成的 Source code 压缩包不含可执行程序。
2. 使用 `Get-FileHash -Algorithm SHA256 -LiteralPath <ZIP路径>`，对照校验文件中该 ZIP 的条目。核对后完整解压到固定目录，例如 `%LOCALAPPDATA%\CodexPlugins\codex-micro-monitor\1.0.0`。
3. 确认该目录中存在 `.agents/plugins/marketplace.json` 和 `plugins/codex-micro-keypad/bin/CodexMicro.Plugin.exe`。
4. 在 PowerShell 中执行下面的命令，路径应与实际解压位置一致。

```powershell
$microPluginRoot = Join-Path $env:LOCALAPPDATA 'CodexPlugins\codex-micro-monitor\1.0.0'
codex plugin marketplace add "$microPluginRoot"
codex plugin add codex-micro-keypad@codex-micro-monitor
codex plugin list --marketplace codex-micro-monitor --json
```

上面的变量只是示例安装目录，不会自行下载或解压文件。插件名为 `codex-micro-keypad`，marketplace 名为 `codex-micro-monitor`；不要把两者互换。

这里的 CLI 安装语法已通过本机 `codex-cli 0.160.0` 的帮助信息核对。如果客户端没有 `plugin add` 命令，可在注册 marketplace 后重启桌面客户端，在插件目录选择 **Codex Micro Monitor** 来源并安装。官方 OpenAI documentation 说明了[本地 marketplace 注册](https://developers.openai.com/plugins/build/plugins#add-a-marketplace-from-the-cli)和[本地插件安装](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually)。

## 插件安装后，软件在哪里

当前完整 ZIP 包含面板程序和 MCP 服务，两者使用同一个 `CodexMicro.Plugin.exe`。`show_keypad` 会激活已有面板，或以窗口模式启动程序。

这属于随插件部署的便携程序，不会自动安装商店版，也不会自动创建 Windows 开始菜单入口。安装前先检查 .NET Desktop Runtime；商店版自带的运行时不等于系统已具备插件所需运行时。

仅把插件 GitHub 仓库地址添加为 marketplace 不能获得本次预编译程序：仓库只保存插件元数据、技能和素材。当前应使用 Release 完整 ZIP。

## 如果要做成“先装轻量插件，再安装软件”

这是后续可实现的分发方案，1.0.0 尚未提供：

1. 轻量插件提供独立安装技能；用户明确说“安装 Micro”后，技能检查当前版本和运行环境。
2. 安装技能调用安装脚本，从指定发布源下载软件，校验后部署到用户目录；需要系统级安装时处理系统安装器或商店流程。
3. 部署完成后配置程序路径和 MCP 入口，再由用户重启客户端并打开 Micro。

安装技能必须能在 Micro 尚未安装时运行。不能只把安装工具放在依赖 Micro 可执行文件启动的 MCP 服务里，否则缺少程序时就无法调用安装工具。

## 验证范围

本引导核对了 CLI 帮助、发布 ZIP 结构、marketplace 标识和 `show_keypad` 实现。此次仅编写文档，没有实际安装插件、修改本机 Codex 配置或进行界面验收。全新安装和真实 Codex 联调仍待单独验证。
