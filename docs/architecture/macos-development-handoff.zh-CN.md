# Codex Micro Monitor：macOS 开发交接

2026-10-04 更新：Mac 已重建为 UIKit / Mac Catalyst 本地控制预览版 preview.5，构建与交付说明见 [apps/macos/README.md](../../apps/macos/README.md)。按 Windows 测量账本重建几何与光效；应用生命周期、双页、菜单栏、状态观察、已有对话模型/强度/Fast/Plan/审批/停止控制、旋钮连续输入与快捷 A/B和 Universal `.app` 已落地。尚未做真实 UI 或 Codex 联调业务验收。

Windows 最新设置改为**叠层、点哪设置哪**，新对话问题和测试规划也在更新。远端仍是原交接快照，因此旧分类设置方案与旧新对话逻辑暂不继续移植。参见 [设置方向](settings-interaction.zh-CN.md)、[验证边界](verification-boundaries.zh-CN.md)。

<details>
<summary>原始源码交接记录（早于本地 Mac 实现，状态以顶部链接为准）</summary>


更新：2026-10-04。本文描述源码现状和下一阶段工作，不代表已有 macOS 安装包。

## 接手结论

当前可运行产品是 Windows WPF 版。[Microsoft Store](https://apps.microsoft.com/detail/9NTVMG9QNMHC) 已发布包为 **0.3.15.0**，对应 [GitHub 发布](https://github.com/gantrol/codex-micro-monitor/releases/tag/v0.3.15) **v0.3.15**。本轮保留已审核通过的商店包与已发布精简包，补齐公开源码、依赖和交接资料，不升级到 1.0.0。

macOS 工程尚未建立。当前 Apple 目标是本机桌面客户端，建议以 SwiftUI 组织窗口、设置和状态，以 AppKit 实现确有需要的窗口、菜单和输入行为。第一步应验证 macOS 上的 Codex 控制适配，不能把 Windows IPC 名称或 UIKit 原型直接当成可用后端。

## 仓库与职责

| 仓库 | 接手范围 |
| --- | --- |
| [codex-micro-monitor](https://github.com/gantrol/codex-micro-monitor) | Windows/macOS 同一产品；键盘外观、键帽、旋钮、灯效、设置、监控与插件入口。macOS 新工程建议放在 `apps/macos/`，目前此目录尚不存在。 |
| [codex-control](https://github.com/gantrol/codex-control) | `ICodexControlClient`、动作合同、Desktop IPC、App Server 和 Windows UI 适配；独立包版本由两个产品精确固定。 |
| [AgentController](https://github.com/gantrol/AgentController) | Windows 实体手柄、输入状态机、Overlay 和 Agent 路由；不是 Micro 的源码依赖。 |
| [codex-plugin-micro-keypad](https://github.com/gantrol/codex-plugin-micro-keypad) | 插件分发入口；共享面板与后端的权威源码仍在 Micro 产品仓库。 |

不要恢复 AgentController 的 Avalonia Foundation Preview。`apps/ios/` 只保存历史 UIKit 原型，可参考图标和状态建模；它的 WSS 连接方案不是已经存在的本机 Host，也不意味着当前要开发 iOS 产品。

## 应先读的源码

| 入口 | 可借鉴内容与限制 |
| --- | --- |
| [平台方向](platform-direction.zh-CN.md)、[设置交互](settings-interaction.zh-CN.md) | 当前平台决定、宽窗口设置、常驻预览、键位编辑草稿与尺寸设计。设计中的候选能力不能视作已实现。 |
| [MainWindow.xaml](../../src/CodexMicro.Windows/MainWindow.xaml)、[MicroSurfaceResources.xaml](../../src/CodexMicro.Windows/MicroSurfaceResources.xaml) | 整机比例、4×4 键位、双页、旋钮与材质的 Windows 基准；无需移植 WPF 运行时。 |
| [MicroProtocol.cs](../../src/CodexMicro.Core/MicroProtocol.cs) | 键位、灯效和发送结果的数据语义；这些类型属于产品，不应全部移入共享控制层。 |
| [SoftwareMicroTransport.cs](../../src/CodexMicro.Windows/SoftwareControl/SoftwareMicroTransport.cs) | 动作路由、目标捕获和结果反馈；包含 Windows 依赖，不能原样跨平台。 |
| [CodexModelToggleService.cs](../../src/CodexMicro.Windows/Services/CodexModelToggleService.cs) | 模型/推理/Fast 的状态、线程选择与过期结果防护。背景会话广播不能覆盖用户当前选中的操作目标。 |
| [CodexSelectedThreadReader.cs](../../src/CodexMicro.Windows/Services/CodexSelectedThreadReader.cs) | Windows UI 观察与本地索引的联合确认；重复标题、隐藏侧栏、空白草稿都可能得到未知目标。 |
| [CodexQuotaService.cs](../../src/CodexMicro.Windows/Services/CodexQuotaService.cs)、[CodexTaskMonitorService.cs](../../src/CodexMicro.Windows/Services/CodexTaskMonitorService.cs) | 额度与任务观察；读失败不能显示成额度为零或任务完成。 |
| [CodexRolloutStatusReader.cs](../../src/CodexMicro.Core/Status/CodexRolloutStatusReader.cs) | 有界读取 rollout 的状态语义；本地日志不能凭空推断未读、审批等私有状态。 |
| [MicroProfileSettings.cs](../../src/CodexMicro.Windows/Services/MicroProfileSettings.cs)、[MicroLocalization.cs](../../src/CodexMicro.Windows/Services/MicroLocalization.cs) | 稳定设置标识与中英文词义；macOS 采用自己的资源与存储机制。 |
| [CodexOfficialCatalog.json](../../src/CodexMicro.Windows/Services/CodexOfficialCatalog.json) | Windows 当前适配基线为 Codex **26.930.3930.0**，不代表 macOS 相同版本兼容。 |

共享仓库重点读 `src/CodexControl/CodexControlContracts.cs`、`DesktopIpc/CodexPeerClient.cs`、`KeypadController.cs` 和 `AppServer/LocalAppServer.cs`。当前传输使用 Windows 命名管道 `codex-ipc`，可执行文件发现寻找 `codex.exe`；`CodexControl.Windows` 使用 Windows UI Automation。目标框架为 `net10.0` 不等于传输已支持 macOS。

## 后端适配先行

1. 在 Mac 上记录 Codex 版本、安装位置、进程与本机通信机制；先确认只读的模型、额度和线程状态能否获取。不要猜测 socket 路径、IPC 版本或消息方法。
2. 将产品操作映射到实际可用能力。现有动作包含线程列表/打开/新建/分叉、模型与推理设置、Fast、Plan、发送、停止和审批。合同中有枚举不等于每项在 macOS 可用；未实现项应禁用并准确显示状态。
3. 优先采用明确可用的本机接口。需要辅助功能权限的操作单独封装，权限缺失、撤销或目标不唯一时返回可解释失败；不要全局模拟输入并假定焦点正确。
4. 每次变更捕获目标及其版本，发送前再次校验，观察结果前也校验。断开连接或请求超时后，将可能已经发出的变更标记为结果未知；不得自动重放发送、审批或模型变更。
5. 保留取消、订阅销毁、连接代次和重连边界。休眠唤醒、Codex 重启或切换会话后，丢弃上一代响应，重新获取状态。

Swift 客户端不能直接加载 NuGet 包。先实现最小 Swift 适配器并复用动作/状态语义；只有明确需要 .NET 后端时才引入本机 Host，并先定义进程生命周期、消息版本、鉴权、取消与打包方式。现有仓库没有可直接复用的跨平台 Host，不应先引入远程服务器或蓝牙层。

## 本机界面与数据

- 保留键盘外观与操作语义，窗口、设置、菜单和 Command 快捷键遵循 macOS。区分关闭窗口与退出程序；菜单栏入口和激活行为必须明确。
- 100% 为 590×610 逻辑点设计画布；默认 75%、60%–125% 是设计候选，实际范围须结合屏幕工作区与可读性验证。文字/图标下限和命中区域不能只依赖整机缩放。
- 按[设置设计](settings-interaction.zh-CN.md)维护分类与预览。图标和动作分别编辑，取消丢弃草稿，完成后才提交；预览不触发动作。
- 保留键盘焦点、VoiceOver 标签、系统文字大小、高对比度及减少动态效果。复用品牌资源，必要的新文案使用 String Catalog（`.xcstrings`），不在业务模型中拼接中英文。
- macOS 偏好使用用户应用支持目录；身份凭据如确有需要使用 Keychain。不要把 Windows `%LOCALAPPDATA%` 路径、注册表开机启动、原始账户文件或真实会话写入仓库。
- 配置迁移先读后校验，保留未知字段或明确版本策略；写入采用后台异步与原子替换。Windows 现有部分同步文件读写只是现状，不能照搬至 Mac 主线程。
- 文件观察、IPC 与解析放在后台，使用有界缓存、取消与资源释放；界面更新回到 MainActor。对同一数据集记录读取量、调用数、耗时和内存，不能用测试通过代替性能证据。

## 建议交付顺序

| 阶段 | 完成条件 |
| --- | --- |
| A：适配调查 | 有可复核的 Codex macOS 版本与能力表；只读探测明确区分可用、权限缺失、不支持和断连。 |
| B：最小客户端 | 建立 `apps/macos/`，完成应用/窗口生命周期、静态键盘、设置与本地化；无账号时仍能正常启动退出。 |
| C：只读监控 | 额度、任务和连接状态能更新；未知不伪装成成功；休眠与重连无过期回写。 |
| D：受控写操作 | 先接模型/推理/Fast，再逐项接线程与其他动作；每项都有目标检查、取消和结果回读。 |
| E：发行 | 在真实 Mac 完成批准范围内的验收，确定最低系统版本与架构，完成签名、公证、安装与升级验证。 |

GitHub 直接分发和 Mac App Store 的沙盒/权限条件不同，必须依据最终分发渠道配置。先验证控制所需权限是否适合沙盒，再决定上架路线；不要预先承诺 Mac App Store 通过。发布时保持同一产品版本语义，平台安装包分别编号与构建，不能将 Windows ZIP 重命名为 macOS 包。

## 验证与交接记录

Windows 基线构建方法见[构建与分发](../build-and-distribution.md)。在具备固定依赖包的 Windows 环境运行 `dotnet build CodexMicro.slnx -c Release` 和 `scripts/test.ps1`；`scripts/test-micro-live.ps1` 会操作真实 Codex，不属于默认验证，必须另有明确授权。

当前没有 macOS 构建命令、自动化测试或签名产物。本次交接不声称已在 Mac 编译、运行或安装。接手者遵守仓库 AGENTS.md：未经用户明确要求，不新增测试代码、不执行真实 UI 手动测试；可运行已有自动化测试并记录未覆盖范围。

下一次交接应给出：Mac 型号/架构与系统版本、Xcode/Swift 版本、Codex 版本、已实现能力表、构建命令、自动化验证结果、权限和签名状态、已知限制。真实账号、会话、令牌、完整本机日志与私有调试材料留在本地，公开文档只保留可复用结论。

</details>
