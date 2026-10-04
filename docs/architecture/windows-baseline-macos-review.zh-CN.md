# Windows Micro 基线与 Apple 实现审查

2026-10-04。依据本仓库 Windows 源码 `58b0244`、仓库内三张产品截图、历史 iOS 原型和本地未提交的 macOS 草稿。源码行为、宣传截图与设计提案分别判断；本次没有启动 Windows/iOS/macOS 界面，也没有操作真实会话。

## 后续更新

用户已说明 Windows 正在改为“叠层，点哪设置哪”，并已修复新对话系列问题、重新规划正交的测试边界。2026-10-04 执行 `git fetch origin` 后，产品远端仍为 `58b0244`，共享控制仍为 `d54e55a`，插件仍为 `7fa04d9`；下文是这些旧提交的源码审查，不能代表尚未同步的新实现。设置方向以 [最新记录](settings-interaction.zh-CN.md) 为准，Mac 当前进度以 [工程说明](../../apps/macos/README.md) 为准。

同日针对用户报告的 Mac“启动无法判定当前会话、Plan 弹 alert 后卡死”，新增 [Windows 全界面操作清单](windows-ui-operations.zh-CN.md)，覆盖实际入口、手势、目标、配置、失败反馈与未接通项，并附全部 154 个动作和 39 个键帽的分类。此轮未复现或修复这两项 Mac 问题。操作清单修正了下文旧审查中的概括，尤其是两页任务身份冻结的差异、标题匹配的限制及新对话 null 导航确认缺口。

## 快照结论

macOS 应继续做 **Windows Micro 的桌面移植**：保留悬浮键盘、双页、键位、旋钮模式、状态灯与任务操作语义。用户已指定 UIKit；当前采用 UIKit／Mac Catalyst，原生桌面能力由桥接提供，不改成常规任务列表或标准面板。

iOS 是可编译的远程控制原型，不能直接作为 Mac 产品基础。初次审查时的本地 Mac 草稿只是适配实验；后续已有可运行预览包，但真实功能仍有用户报告的问题。下面的历史审查不能作为当前完成度结论。

## 证据优先级

1. 当前软件产品的实际入口与执行路径：`CreateSoftwareControlled`、`ApplyCoreSurface`、`SoftwareMicroTransport`。历史 HID、多 Harness、额外键盘的字段、注释和分支不代表当前支持。
2. 当前 XAML、绘制代码、设置与状态投影。
3. [控制页截图](../../plugins/codex-micro-keypad/assets/screenshots/zh-CN/01-controls.webp)、[监视页截图](../../plugins/codex-micro-keypad/assets/screenshots/zh-CN/02-monitor.webp)、[模型截图](../../plugins/codex-micro-keypad/assets/screenshots/zh-CN/03-models.webp)。它们说明产品外观和信息层级，示例数据不证明实时功能；图标等细节可能落后于当前源码。
4. 设计文档。提案中的尺寸、设置布局和未来连接方式不能当作已实现功能。

图标要追踪实际绘制优先级：`KeycapIcon` 对多数键优先调用 `CodexOfficialArtwork.Draw`，`PaperForkGeometry` 等字段只是后备路径；FAST 则使用本地轮廓。Mac 通过源码生成器复用实际使用的矢量，不能看到一个路径常量就认定它是当前图案。

## Windows 的产品结构

### 窗口与键盘

| 项目 | 当前基线 | Mac 的落地约束 |
| --- | --- | --- |
| 窗口 | 透明、无边框、默认置顶，不出现在任务栏；普通点击不激活窗口 | 使用 AppKit 非激活浮动窗口承载键盘；设置窗口单独接受焦点 |
| 尺寸 | 590×610 设计画布；默认 442.5×457.5 DIP | 以逻辑点保持比例，不能把设备当作可任意重排的表单 |
| 缩放 | 当前设置显示 80%–140%，基准是默认窗口；相当于画布的 60%–105% | 先明确百分比基准。文档的画布 60%–125% 仍是候选，不能声称与 Windows 当前范围相同 |
| 外壳 | 浅色水晶边缘、近白面板、克制的深度阴影 | 保留外缘与键帽层次；不要用整块偏绿灰的渐变替代全部材质 |
| 键帽 | 96×96，步距 106；纸白底、圆形凹槽、细白边和低位投影 | 任务键和命令键共用材质，图标与状态光分别绘制 |
| 任务标识 | 键面为圆点；标题与状态放在悬停提示及无障碍名称中 | 不擅自改成编号或把标题塞入每个键帽；保留可读的悬停信息 |
| 页面 | 顶部分页控件；6 个任务的控制页和 14 个任务的监视页 | 不新增常驻顶栏，也不把监视页改成列表 |
| 常驻部件 | 左下模型/额度旋钮与右下 Codex 键跨页保持原位 | 共享实例与状态，不随整页切换闪烁或重置 |
| 动效 | 按任务 ID 匹配跨页位置；外壳固定；降低动态效果时停用动画 | 动效必须跟随任务身份，不能按数组下标误配 |

控制页：

|  |  |  |  |
| --- | --- | --- | --- |
| 白色编码旋钮 | 任务 1 | 任务 2 | 黑色摇杆 |
| 任务 3 | 任务 4 | 任务 5 | 任务 6 |
| Fast | 批准 | 拒绝 | 分叉 |
| 模型/额度旋钮 | 双宽麦克风键 | ← | Codex |

监视页占用第 1–3 行全部位置及第 4 行中间两格，共 14 个任务键。麦克风的外形不等于语音能力已实现，Windows 软件版也不提供原生语音。

来源：[MainWindow.xaml](../../src/CodexMicro.Windows/MainWindow.xaml)、[MicroSurfaceResources.xaml](../../src/CodexMicro.Windows/MicroSurfaceResources.xaml)、[NonActivatingWindow](../../src/CodexMicro.Windows/Services/NonActivatingWindow.cs)、[MicroWindowLayout](../../src/CodexMicro.Windows/Services/MicroWindowLayout.cs)、[PageMotion](../../src/CodexMicro.Windows/MainWindow.PageMotion.cs)、[KeycapIcon](../../src/CodexMicro.Windows/Controls/KeycapIcon.cs)。

### 白旋钮与额度按钮：模式和快捷入口有重叠

不能概括为“白旋钮只做输入区导航，黑旋钮才负责模型和推理”。白旋钮是可配置的选择/确认控件，推理模式本身就支持调强度与切模型。`composer-navigation` 是没有有效配置时的回退值；运行时读取 `~/.codex/config.toml` 的 `[desktop.codex-micro-layout].encoderMode`，本次没有取得用户 Windows 安装的实际配置，不能将回退值当作该安装的当前行为。

左下外形像旋钮的 `QuotaKnob` 是额度/模型显示按钮，注册短按、滚轮和右键等快捷操作；它不是模型/推理控制的唯一入口。两个部件必须分别核对手势和模式，不能按“一个导航、一个调模型”分配排他职责。

| 控件 | Windows 实际行为 | 需要纠正的 Apple 草稿理解 |
| --- | --- | --- |
| 白旋钮的选择模式 | `composer-navigation`：没有打开菜单时遍历输入区控件；有菜单时优先遍历菜单项；按压打开或确认 | “输入区导航”不是聊天列表导航，也不排除通过菜单选择模型或强度；需要保留菜单上下文 |
| 白旋钮的推理模式 | `reasoning`：旋转直接调推理强度，按压切快捷模型 A/B | 这是已有的完整交互路径，不能因代码回退值不同就认定 iOS 的这组交互错误；需要补齐模式配置 |
| 白旋钮的对话滚动模式 | 旋转上下滚动，按压到对话底部 | 依赖本机 UI 适配，Mac 未实现前保持不可用 |
| 左下额度/模型按钮 | 短按切换快捷模型 A/B，滚轮调当前模型支持的推理档位；显示额度、模型与短暂强度反馈 | 它提供直接快捷入口，与白旋钮的部分能力重叠；模型与额度合用显示区是基线设计 |
| 黑旋钮右键 | 打开软件设置，定位相关 Agent 设置 | 不能只打开模型弹出表 |
| 黑旋钮长按 | 650 ms 后调用官方设备设置路径；当前软件传输返回不支持 | 这是遗留但未接通的路径，不能写成已可用能力；Mac 可保留为禁用项，或另行明确产品改动 |

快捷模型 A/B 各自有推理强度偏好，即使模型相同，也可以切换不同强度。连续旋转需要累积步数、限制队列时间、处理反向输入；切页、换任务、失去有效目标时取消旧输入。不能每一帧拖动都独立发写请求。

来源：[SoftwareMicroTransport](../../src/CodexMicro.Windows/SoftwareControl/SoftwareMicroTransport.cs)、[布局加载与回退值](../../src/CodexMicro.Windows/Services/CodexMicroLayoutObserver.cs)、[旋钮与按压处理](../../src/CodexMicro.Windows/MainWindow.xaml.cs)、[Reasoning](../../src/CodexMicro.Windows/MainWindow.Reasoning.cs)、[共享控制层的菜单/控件选择](../../../codex-control/src/CodexControl.Windows/CodexUiController.cs)。

### 按键和目标

| 输入 | Windows 软件版执行语义 |
| --- | --- |
| 任务键单击 | 打开该键当时对应的准确任务；软件执行路径不被旧双击聚焦偏好吞掉 |
| 任务键右键 | 标记指定任务未读；不是泛用的连接或设置菜单 |
| 摇杆上/下/左/右 | Plan / 侧栏 / 后退 / 前进；支持已实现动作的自定义绑定 |
| Fast | 对准确目标切换服务档位；处理中反馈和已生效反馈分开 |
| 批准/拒绝 | 当前仅有一个明确的命令或文件审批请求时回复；多个请求不猜测 |
| 分叉 | 使用 Windows 控制层的分叉路径；Mac 本机协议兼容性必须另外确认 |
| Codex 键 | 当前默认绑定 `composer.submit`，走本机输入区提交；不能只根据旧激活提示文案理解成“打开聊天” |

任务按 `thread/list` 的 `recency_at` 排序。监视页在鼠标悬停／捕获、打开任务或页面运动期间冻结身份分配，随后恢复最近顺序。控制页仍会替换 roster，主要通过运动期间抑制输入、排序改变时释放按压捕获来保护操作；未找到相同的悬停冻结实现。不能把两页合称为完全相同的身份冻结。Mac 应确保标题、颜色和回调指向同一个任务 ID。

“已请求打开”与“已确认当前任务”分开：Windows 保留上一个确认状态用于呈现，导航中拦截控制并重新观察窗口选择；确认循环约 4 秒后仍不匹配则报告未确认，这不是对底层 UIA 调用的硬性总时限。当前观察靠侧栏标题唯一匹配，重名或隐藏侧栏会失败；新对话导航还存在 null 对 null 即清 pending 的缺口。捕获目标、发送前复核及 `NotSent`、`Accepted`、`OutcomeUnknown` 的区分应保留，这些旧实现限制不能作为 Mac 的正确行为照搬。

来源：[Software](../../src/CodexMicro.Windows/MainWindow.Software.cs)、[Monitor](../../src/CodexMicro.Windows/MainWindow.Monitor.cs)、[RecentThreads](../../src/CodexMicro.Windows/Services/CodexRecentThreadsService.cs)、[当前动作目录](../../src/CodexMicro.Windows/Services/CodexOfficialCatalog.json)、[软件能力声明](../../src/CodexMicro.Plugin/KeypadCapabilities.cs)。

### 状态不能只换一种颜色

| 信息 | Windows 表现与依据 |
| --- | --- |
| 进行中 | 蓝色；本地 rollout 的未结束回合可能仍在等待输入，提示语不保证正在计算 |
| 等待输入 | 橙色；有明确等待状态 |
| 待回答 | 黄色；独立的 `HasPendingQuestion` 观察，不能并入一般等待 |
| 未读 | 绿色；依赖未读状态或明确确认的手动标记，不从“回合完成”自行推断 |
| 错误 | 红色 |
| 空闲 | 不亮任务状态光；当前空闲任务可用白/薄荷色选中效果 |
| 当前选中 | 独立于任务状态，改变边缘、凹槽和键帽光照；不把最近任务当作正在运行 |
| 未知/过期 | 保留身份但降低可信度、禁用相应操作；不能伪装成空闲、完成或额度为零 |

状态光分为宽光晕、近光晕、键帽染色、凹槽染色等载体，选中与未选中的强度不同。Mac 应先复现状态与材质的关系，再调光晕数值；不能只在普通按钮下方加一个彩色小点。

来源：[AgentLightingAppearance](../../src/CodexMicro.Windows/Services/AgentLightingAppearance.cs)、[任务状态合成](../../src/CodexMicro.Windows/Services/CodexTaskMonitorService.cs)、[Monitor](../../src/CodexMicro.Windows/MainWindow.Monitor.cs)。

### 设置的现状与提案

当前 Windows 设置是单列桌面窗口：160×166 DIP 的实时键盘预览、大小、交互、快捷模型和连接。冷白底、石墨文字与鼠尾草绿交互状态，采用轻分隔；它与主键盘材质是两套用途不同的样式。

当前软件版键位编辑已经把图标存在本地外观偏好、动作存在 Codex 配置；换图标不会重新选择动作。旧文档所述“换图标连带重置动作”不再描述当前软件路径。保存依然跨两个存储步骤，动作保存成功后图标保存失败可能造成部分提交；Mac 应明确保存结果，而不是照搬为一个无条件成功的按钮。

此前 Mac 的分类栏和右侧常驻预览提案已被用户的新方向取代：采用叠层、点哪设置哪。等待 Windows 新实现；不移植 iOS 的 WSS 设置表单。

来源：[MicroSettingsWindow](../../src/CodexMicro.Windows/MicroSettingsWindow.xaml)、[KeycapEditorWindow](../../src/CodexMicro.Windows/KeycapEditorWindow.xaml.cs)、[MicroProfileSettings](../../src/CodexMicro.Windows/Services/MicroProfileSettings.cs)、[设置设计](settings-interaction.zh-CN.md)。

## iOS 完成度：按 Windows 基线重新判断

| 范围 | 已有内容 | 缺口及处理 |
| --- | --- | --- |
| 编译 | 修正 `UIControl` 已继承的菜单委托重复声明后，Xcode 16.3 的 iOS Simulator Debug 构建成功 | 编译通过不代表运行、视觉或实机验收 |
| 视觉骨架 | 590×610 坐标、控制/监视页、圆形凹槽、六个命令矢量资源、状态光 | 可对照几何和品牌资源；不把 UIKit 材质参数当作 Mac 的视觉标准 |
| 任务识别 | 圆点键帽、VoiceOver 标题、底部已选任务信息、长按菜单 | Windows 的无标题键帽依赖悬停提示；手机没有同等发现方式。问题是信息通路缺失，不能据此断言 Windows 也应在每个键帽写标题 |
| 状态 | 空闲、运行、完成、等待、错误 | 缺黄色待回答；将 `completed` 显示为“完成未读”，没有单独未读证据；选中灯光细节也与 Windows 不同 |
| 交互 | 两个旋钮都能切模型，白旋钮调强度；摇杆只有上方向 | 白旋钮实现了 Windows 推理模式的一部分，缺少模式配置与上下文菜单导航，不能直接判为错误模式；其余摇杆方向、前台目标确认、未读操作和完整设置仍缺失；Codex 键被改成打开任务 |
| 任务稳定性 | 渲染时为当前列表项建立回调 | 没有 Windows 的悬停/按压身份冻结；刷新可能在触摸期间替换回调，应单独处理触摸目标捕获 |
| 小屏适配 | 整机 transform 缩放，横屏可滚动 | 图标、数字、分页一起缩小；不能直接成为 Mac 的字号和命中区域规则 |
| 连接 | WSS、Keychain、租约、取消、单在途、未知结果查询而不重放 | **没有 Host 服务**；每次启动 DEMO，不能实际控制本机 Codex；没有配对、增量更新、完整重连等闭环 |

因此不宜给一个“已完成百分比”：它的演示、传输协议和真实产品可用性是不同维度。适合保留的是防过期响应、取消和未知结果处理等思想；Mac 应直接连接本机接口，不引入 iOS 远程 Host 链路。

关于“丑”：目前有证据的是缩放、信息获取和交互缺口；没有运行截图，不把代码层数或饱和色本身当作审美结论。Windows 本来也有多层材质和鲜明状态光。后续视觉判断应以同尺寸、同状态的 Windows/Mac 对照为依据。

## 本轮实现前的 Mac 草稿审查（历史）

以下是本地草稿现状，不是已交付能力：

- 可继续审查的部分：Unix socket 帧传输、CLI App Server 只读目录、串行后台 I/O、取消、准确任务 ID 和结果未知处理。`MicroCore` 已编译；尚无真实写操作验收。
- 必须重做的界面部分：新增顶栏、底部分页、任务编号、列表式监视页、用摇杆切任务/页面，以及用“刷新”替代默认分叉键。白旋钮还需补齐按压/旋转语义、模式配置与菜单上下文，不能硬编码成单个推理菜单。
- 必须补齐的产品部分：应用入口、非激活窗口与菜单栏生命周期、正式资源、设置与键位编辑、任务身份冻结、桌面目标观察、状态观察和分发打包。
- 不能宣称兼容的部分：Mac 前台输入区操作、Plan/侧栏/历史导航、未读、空白草稿模型设置、分叉。分叉尤其需要检查当前安装版本的合同；本机生成的 schema 没有 Windows 路径要求的 `deferGoalContinuation`，不能直接发送并期待相同行为。
- 未支持的默认键保留位置与图标并禁用，原因放在悬停或设置中；不要偷偷换成别的功能。只有用户自己重新绑定，含义才改变。

## 后续实现顺序与完成条件

1. **基线外观与窗口**：建立能编译的 AppKit/SwiftUI 应用壳，按 Windows 几何、矢量和材质实现双页；普通点击不抢焦点，隐藏和退出区分，设置单独开窗。预览只用明确的示例状态。
2. **只读状态**：任务顺序、准确 ID、额度、连接与失效状态；补足正在运行、待回答、未读的可靠来源后再点亮相应颜色。刷新期间保持按键身份。
3. **逐项控制**：模型/强度/Fast、打开/新建、审批和停止，各自验证目标、版本、取消和回执。前台 UI 能力另建 Mac 适配层；未验证能力不靠重绑定掩盖。
4. **设置与发行**：按既有桌面设置提案完成草稿编辑和资源本地化，再做插件平台入口及安装包。分发镜像只从产品仓库单向同步。

本节记录开始实现前的审查，后续已完成基础观察、已有对话控制预览版构建与本地打包；并根据用户实机截图修正键帽、透明壳体、图标填充规则、七段读数与 Micro 菜单栏标志。叠层设置、新对话修复和完整测试规划等待 Windows 更新。真实 UI 与 Codex 业务验收仍未执行，详见 Mac 工程说明。
