# 本地仓库与源码归属

| 仓库 | 职责 |
| --- | --- |
| AgentController | 实体手柄、输入状态机、Overlay、Agent 路由和产品动作合同 |
| codex-micro-monitor | 小键盘、键帽、灯效、设置、监控、桌面与插件入口 |
| codex-control | Codex 控制接口、Desktop IPC / App Server、目录与 Windows 操作适配 |
| codex-plugin-micro-keypad | 插件分发入口；镜像产品仓库的插件元数据、技能和资源，承载插件 Release |

## 本地目录

三个 Micro 相关仓库统一放在 `AgentTools/` 下，各自保留独立 `.git` 和 `origin`：

```text
ai/
├── AgentTools/                   # Codex 项目的主工作目录
│   ├── AGENTS.md                 # 工作区级维护约定
│   ├── AgentTools.code-workspace # 本地多仓库入口
│   ├── codex-micro-monitor/      # Micro 产品源码；Mac 开发在此进行
│   │   ├── codex-micro.code-workspace
│   │   ├── apps/macos/           # 原生 Mac 工程的约定位置，尚未交付
│   │   ├── plugins/codex-micro-keypad/ # 插件文件的唯一编辑源
│   │   └── scripts/             # 产品构建、打包、分发同步
│   ├── codex-control/            # 共享控制组件
│   └── codex-plugin-micro-keypad/ # 插件分发镜像
├── agent-controller/             # 独立手柄产品，保留已有开发分支
└── agent-controller-ios-remote-micro/ # AgentController 的旧 Git worktree
```

本地打开 `AgentTools/AgentTools.code-workspace` 可同时查看工作区根目录及三个仓库；产品仓库内的 `codex-micro.code-workspace` 也继续可用。工作区文件使用相对路径，不依赖机器用户名。AgentController 和它的 worktree 保留原位置，不包含在这个 Micro 工作区内。

`AgentTools/` 自身不是 Git 仓库，不增加聚合提交或 submodule。Git 操作在对应子仓库执行，例如 `git -C codex-micro-monitor status`。Codex 项目应将 `AgentTools/` 设为主文件夹，子仓库按需附加为其他文件夹；移动磁盘目录或创建 `.code-workspace` 文件不会自动修改 Codex 的项目设置。已有聊天可能仍保留原工作目录，后续命令应明确使用新路径。

| 本地目录 | `origin` |
| --- | --- |
| `codex-micro-monitor` | `https://github.com/gantrol/codex-micro-monitor.git` |
| `codex-control` | `https://github.com/gantrol/codex-control.git` |
| `codex-plugin-micro-keypad` | `https://github.com/gantrol/codex-plugin-micro-keypad.git` |
| `agent-controller` | `https://github.com/gantrol/AgentController.git` |

两个产品只引用固定版本包，不互相引用项目，不使用 Git submodule。`CodexControl` 的已有命名空间暂时保留；程序集名称兼容不代表仍由 Micro 产品维护。

## 更新顺序

1. 在 `codex-control` 修改共享实现，更新 `Version.props` 并执行 `scripts/package.ps1`。
2. 两个产品分别更新 `Directory.Packages.props` 的 `CodexControlVersion`，执行 `scripts/import-control-packages.ps1 -PackageDirectory <包目录>`。
3. 各产品独立构建、验证与发布。包版本确定后不得覆盖为其他内容。

Micro 的新功能只在此仓库维护。AgentController 的 `virtual-micro` 桌面和插件目录是历史保留区；仍在使用的 HID / DeepSeek 旧代码不属于此免驱产品。

这里描述的是拆分后的依赖方式。本地 AgentController 的较早分支可能仍保留项目内的 `virtual-micro` 引用；不能据此把它作为独立 Micro 的构建依赖，也不在整理目录时改写那条开发分支。

## 插件单向同步

以下文件先在 **codex-micro-monitor** 编辑，再同步到 **codex-plugin-micro-keypad**：

- `plugins/codex-micro-keypad/` 内的 manifest、MCP 配置、技能、图片与许可证。
- `.agents/plugins/marketplace.json`。
- 根目录 `LICENSE`。

分发仓库的根 README 和仓库维护说明独立维护。可执行文件只由产品仓库打包生成，不从已安装插件缓存拷回源码，也不提交到分发仓库的 `bin/`。两边不能分别维护同一份插件实现。

在产品仓库运行（需要 Python 3）：

```bash
python3 scripts/sync-plugin-source.py --check
python3 scripts/sync-plugin-source.py --apply
```

默认目标是相邻的 `../codex-plugin-micro-keypad`，也可通过 `--destination <目录>` 指定。脚本只处理产品仓库已经纳入 Git 的文件；新增插件文件先 `git add` 再同步。默认只检查差异。应用时会验证目标仓库、拒绝覆盖目标中未提交的插件文件，并拒绝自动删除分发侧的多余文件。它不构建、不提交、不推送，也不发布插件。

产品源码 → 平台构建 → 桌面/插件 ZIP 是构建方向；产品插件文件 → 插件分发仓库是源码同步方向。分发仓库不是产品的依赖项。

## 公开接口

- `ICodexControlClient` / `CodexSoftwareClient`：按 `CodexOperation` 执行，保留目标检查、取消、服务端条件和未知结果语义。
- `ICodexDesktopConnection`：带协议版本的状态观察连接。
- `ICodexUiController`：Windows 前台控件操作与结果回读。AgentController 自己将结果映射到 ActionResult，Micro 自己映射到呈现反馈。
- 公共模型目录、可执行文件发现和请求卡取消辅助由组件提供，产品不链接另一仓库的源码。

Micro 的键位/灯效 DTO 留在产品 `Core`，没有移入共用控制层。生产客户端通过公开接口工作；原有测试的内部访问仅用于维持验证兼容。

## macOS

Windows 与 macOS 在本仓库作为同一个 Micro 产品维护，平台代码、构建和安装包分别管理。共同维护动作与状态语义、配置格式、设计和可复用资源；现阶段尚无两端共同消费的运行时核心，也没有 macOS 工程。

macOS 技术栈与平台实现尚未完成。若使用 Swift，以命令/状态合同和 macOS 适配器或明确需要的本机 Host 连接；NuGet 并非 Swift 运行时依赖。尚未实现该 Host，也不恢复 Avalonia Foundation Preview。设置方案见[交互提案](architecture/settings-interaction.zh-CN.md)。

暂不设计 iOS 产品；`apps/ios` 仅保存历史原型。手机远程与蓝牙仅是未来连接方式的候选，不纳入本次桌面发布承诺。
