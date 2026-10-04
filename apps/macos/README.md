# Codex Micro macOS · 控制预览版

macOS 14+，UIKit / Mac Catalyst；AppKit 仅用于桌面桥接。无外部 Swift Package 依赖。**当前版本 `0.3.15-macos-preview.5`；已移除 Mac 源码中的 SwiftUI 界面。编译、打包与真实视觉 / Codex 业务验收分开记录。**

界面从当前 Windows 提交 `58b0244` 的[测量账本](../../docs/design/windows-micro/index.html)重建，没有复用历史 iOS 的布局或 WSS 后端。

## 本轮范围

- Catalyst 透明无边框窗口、菜单栏显示/隐藏/退出、置顶、大小、窗口位置与显示器工作区适配；空白处拖动，长按空白处或 Cmd+, 打开窗口菜单，Cmd+W 隐藏。隐藏和休眠停止轮询，恢复后重新读取。**Catalyst 窗口点击可能激活应用；旧 NSPanel 的不抢焦点行为未作为已实现能力保留。**
- Windows 590×610 比例的外壳、顶部双页、6 个任务的控制页、14 个任务的监视页、常驻额度按钮；默认命令键位置保留。
- `UIView` / `UIControl` / Core Graphics 原生绘制。任务键表面96×96，命令键95×93.5，命令图案上移.75；页签中心y=67。矢量图标逐层生成 `CGPath`，保留 EvenOdd / Nonzero 规则及 Fast 开关图案。菜单栏使用 Micro 圆角框 ∞ 的小尺寸单色模板。
- 所有宽、近光晕位于全部实体键帽之下。键帽染光、圆形光场、圆井染光分层；选中空闲使用白光、四层薄荷回光与中心点，并减弱阴影。共享光晕、接缝光不跟随键帽按压位移。源 Alpha、ARGB 渐变与中性选中态例外分别处理。
- 模糊以 Accelerate 的分离卷积实现有限高斯核；按 [WPF 实现](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/WpfGfx/core/resources/BlurEffect.cpp)使用半径/3标准差、归一化权重及半径取整。没有套用 CALayer.shadowRadius。抗锯齿、颜色合成、文字字体与实机扩散范围仍需标定，不能据此宣称像素一致。
- 本机只读任务列表、模型目录、额度与所选任务状态；点击任务键请求打开该准确 ID。悬停/按压/打开/写操作期间冻结任务键身份，避免刷新换位。
- 额度旋钮默认显示七段额度，悬停显示模型版本 / 系列和推理强度双环，加载弧周期820ms。账户额度缺失显示 `—`；未加载任务保持状态未知；没有未读证据就不显示绿色。当前任务选择是显式读取目标，不代表已经确认 Codex 的前台选择。
- 英文与简体中文资源跟随系统语言。MCP 与 GUI 共用可执行文件，MCP 模式不初始化应用窗口。

## 已有对话控制

界面和控制层独立推进，不以外观定稿为前置条件。

- 点击任务选择准确对话。额度钮短按切快捷模型 A/B，滚动或拖动调推理强度；右键或长按打开原有的对话控制清单，可选择单次模型/强度、Fast、Plan、停止和 A/B 偏好。
- 白旋钮默认跟随 Codex 保存的 `encoderMode`；本机未配置时回退为输入区导航，该模式尚未支持。右键或长按白旋钮可将 Mac 本地模式设为推理，或恢复跟随 Codex。没有写入或覆盖 Codex 的配置文件。
- 推理模式的白旋钮短按也切 A/B，拖动/滚动调强度。右/上拖动为顺时针，默认降低强度；可反转。拖动越过6个设计点锁定主轴，之后每12点一格；UIKit 鼠标/触控板滚动使用12个设计点一格，不冒用 Windows 的120原始滚轮单位。档位按实时目录顺序夹在两端，不循环。
- A/B 各自保存模型和可选强度，未指定强度采用该模型默认值；支持同一模型的两个强度。默认ID来自当前 Windows：A=`gpt-5.6-sol`、B=`gpt-5.6-luna`。目录不支持的模型/强度不会偷偷替换，须在额度钮控制清单中重新选择。Mac 偏好独立保存在 UserDefaults 的 `dialProfile.v1`。
- 摇杆遵循 Codex 的方向绑定；已接入 `composer.togglePlanMode`（默认向上）。可点对应箭头或拖动，输入半径24、激活距离12、最大视觉位移13个设计点。一次按压固定目标，只发一次已支持动作。Plan/Default 切换保留模型、强度和权限，采用目标模式默认指令，回读匹配才确认。
- Fast 键切换所选对话的服务档位，按模型目录判断支持性。模型切换优先保留兼容的推理强度；不兼容时采用目录默认值，目标模型不支持 Fast 时清除该档位。
- 批准/拒绝键展示当时的命令或文件审批详情，对单个请求操作，不批量批准未来请求。
- 点下时固定对话、设置或请求；写入前重新发现桌面 owner 并读取状态。设置条件不匹配、审批内容变化、回合 ID 变化都会拒绝操作。双击不并发提交，切换/隐藏后旧读取不覆盖新目标。
- 模型/强度/Fast 回读匹配、审批请求明确消失、停止回合回读空闲或终态后，才报告已验证。写操作超时或无法确认结果会提示结果未知，不自动重试；界面需重新读取控制状态才恢复写操作。
- MCP 公开 15 个工具：观察/导航、模型、推理强度、Fast、Plan、单请求审批、准确回合停止，以及明确文本发送。新增 `get_keypad_layout` 只返回编码旋钮与摇杆绑定，不泄露其余配置；`toggle_keypad_plan` 只作用于准确已有对话。发送仅对确认空闲的已有对话，通过其桌面 owner 发起；返回区分 `acknowledged` 与 `verified`，不把传输应答冒充消息业务结果。

连续旋钮输入先合并80ms，后续输入更新唯一目标档位；前一次回读确认后才发送下一次。输入有效期5秒，在本机后端写入前也检查期限，避免排队后执行过期手势。切页、换任务、隐藏、取消或失败会丢弃尚未发送的输入；已经发出的写操作保留回读/结果未知语义，不承诺撤销。VoiceOver 支持增加/减少档位与快捷模型操作。

摇杆侧栏/前进/后退、输入区导航、对话滚动、麦克风、前台输入框发送与分叉仍未接入；不能把 MCP 明确文本发送等同于 Codex 输入框发送。新草稿控制和完整叠层设置继续跟随 Windows。当前右键控制清单只承接已有对话与必要偏好，不是新版叠层交互的完成声明。

## 构建与打包

从仓库根目录执行：

```sh
scripts/package-macos.sh universal
```

需要完整 Xcode 16+。也支持 `scripts/package-macos.sh arm64` 或 `x86_64`。脚本用 Xcode 构建 Catalyst GUI，再由构建阶段用 SwiftPM 编译并嵌入原生 `MicroDesktop.bundle`；生成应用图标、临时签名和 ZIP，不启动应用或发布。

Xcode 工程为 `CodexMicroMac.xcodeproj`，选择 **My Mac (Mac Catalyst)**。工程的构建阶段也会嵌入桥接包，因此 Xcode Run 不依赖之前的打包目录。只检查原生后端时可运行 `swift build --package-path apps/macos`；这条命令不再构建 GUI。新增文件后运行 `python3 scripts/generate-macos-project.py` 更新工程。

产物：

- `dist/macos/universal/Codex Micro Monitor.app`
- `dist/macos/universal/codex-micro-macos-preview.zip`

使用的是本地 ad-hoc 签名，未做 Developer ID 签名或公证。资源放在 `Contents/Resources`，不依赖原机器的构建目录。尺寸百分比以 590×610 画布为准：默认 75%，当前 60%–105%，屏幕不足时只限制实际尺寸，不覆盖用户偏好。

需用户自行启动查看时：

```sh
open 'dist/macos/universal/Codex Micro Monitor.app'
```

命令行支持 `--version`、`--capabilities`、`--mcp`。MCP 可执行入口为应用内的 `Contents/MacOS/CodexMicroMac --mcp`；本轮尚未改动分发插件的 Windows 清单。

## 等待 Windows 更新

1. 设置改为**叠层，点哪设置哪**。旧分类设置窗口方案已停止，不先补另一套设置导航。等待具体进入、退出、层间返回和保存合同。
2. 新对话系列修复：等待新版草稿身份、模型/强度/Fast、切换与回读逻辑，不把旧问题移植到 Mac。
3. 测试按单元、组件、内部 E2E、Codex 联调与业务结果划分职责，且与开发独立。等待 Windows 最新规划，当前不自行新增测试套件。见 [验证边界](../../docs/architecture/verification-boundaries.zh-CN.md)。
4. 已有对话写操作已接入，等待独立的联调与业务验收；桌面前台观察、全量任务未读、完整状态同步和插件发行仍需继续实现。所选对话的未读灯只使用桌面 snapshot 的明确 `hasUnreadTurn` 值。

2026-10-04 已获取远端：产品 `58b0244`、控制 `d54e55a`、插件 `7fa04d9`，尚无上述新实现。没有覆盖本地改动、提交或推送。

## 验证记录

构建环境：macOS 15.5、arm64、Xcode 16.3、Swift 6.1。原生桥接 Debug 构建、Catalyst Universal Release 构建、Info.plist 与资源检查、嵌套 ad-hoc 签名校验通过。主程序与桥接包均包含 arm64 和 x86_64。完整包的 `--version`、`--capabilities`、MCP initialize / tools/list / capabilities 通过，桥接类成功加载，15 个工具可枚举；没有触及真实会话写操作。

preview.4 修复了模糊输入缓冲区未清零导致的矩形脏色块：输入、输出工作内存显式初始化，输入图像使用 copy 混合，返回图像独立持有像素。任务键和命令键的非对称内沿改为连续的内外轮廓填充，消除半区裁剪断点。

增加 `--export-design <目录>`，用正式 UIKit 绘制代码离屏导出整机、透明麦克风键和状态光效。导出在 UIApplicationMain 之前完成，不创建窗口、菜单栏或 Codex 连接；图中状态为示例数据。修复前的导出复现了矩形色块；修复后查看了浅色、深色背景及1×/1.5×/2×输出。

preview.5 接入旋钮/A/B/Plan，Universal 构建、资源解析、签名与无窗口协议检查通过；`get_keypad_layout` 已只读访问本机 Codex 配置。旋钮手感、快速反转/排队、A/B 同模型不同强度、Plan 切换与取消后的真实业务结果尚未联调。

本轮未启动 GUI 或新增测试代码。实机外观、透明窗口、点击激活、拖动、休眠恢复、多显示器以及 Codex 业务结果仍需独立验收。Segoe UI Variable Text 在 Mac 缺失时使用系统字体，丝印字形不会完全相同。

## 维护入口

- `Sources/CodexMicroMac/Entry.swift`：UIKit 入口、Scene、URL 与无窗口命令行分流。
- `Sources/MicroDesktop/Bridge.swift`：AppKit 菜单栏 / 窗口、原生通信调用、取消与休眠。`MicroShared/DesktopServices.swift` 只通过 Objective-C / Foundation 值跨平台边界，不传递 UIKit / AppKit 视图。
- `DesktopClient.swift`：UIKit 异步适配，保留结果未知错误和取消语义。
- `MicroSurfaces.swift`：测量几何、分层光效、有限高斯卷积及有界图像缓存。
- `MicroView.swift`：双页键盘、已有对话控制与单请求审批；控件设置后续按叠层方案接入。
- `MicroModel.swift`：状态刷新、控制目标快照、串行写入、旋钮绝对目标合并、身份冻结与生命周期代次。
- `DialInput.swift`：Windows 拖动阈值、UIKit 滚动归一化、点击/拖动分离、长按与辅助功能输入。`Settings.swift` 保存独立 Mac 旋钮偏好。
- `Sources/MicroCore/`：本机传输、只读目录、桌面 owner 控制与能力门控。
- `scripts/export-macos-artwork.py`：从 Windows 矢量生成 `MicroArtwork.generated.swift`；Windows 图标变更后显式重新生成。
- [Windows 基线审查](../../docs/architecture/windows-baseline-macos-review.zh-CN.md)记录旧提交的来源；新方向以[平台方向](../../docs/architecture/platform-direction.zh-CN.md)为准。
