# 可更换按键与 Sketch

更新：2026-10-05。适用于 Windows 免驱 Micro。官方命令与键帽基线为 Codex `26.930.3930.0`；声明的执行通道不代表所有界面状态下均可执行。

## Sketch

Codex 输入框的添加菜单将绘图入口命名为 **Sketch**，中文为“绘图”。它打开草图编辑器，由用户绘制并选择附加到输入框。Micro 新增 `SKETCH` 键帽和 `composer.sketch` 动作；这是 Micro 扩展动作，未冒充官方键盘命令注册项。官方 `PAINT` 键帽仍对应 `composer.addPhotos`，保留原有配置含义。

Windows 控制组件的 `OpenSketch` 操作观察当前前台 Codex 输入框，打开“添加文件等内容”菜单，再调用其中的绘图项。支持英文、简体中文和繁体中文控件名称。已有绘图编辑器时不重复打开；菜单项缺失或不可用时拒绝执行。只在观察到绘图编辑器后确认成功；切换目标、取消或无法确认结果时不重发。该操作不改写草稿、不附加图片、不发送消息。

动作经过原有会话身份检查、串行操作和取消通道。原生界面适配由独立的 `CodexControl.Windows` 组件维护；Micro 发布构建固定引用 `1.0.0`，本地调试可通过已有 `UseLocalCodexControl` 开关引用控制组件源码。

## 语音区拆分

软件设置的“布局”中提供“拆分语音键”开关，沿用 `separateMicrophoneKeys` 保存字段：

- 关闭：显示双宽 `ACT10_ACT11`。
- 开启：显示独立的 `ACT10`、`ACT11`，两个设置预览入口分别打开各自编辑器。
- 拆分后的两键沿用普通命令按钮的点击与键盘操作，可分别选择图标、命令或技能。
- 切换布局仅改变拆分字段；三个位的绑定和本地图标设置都保留，合并后再拆分仍能恢复。

拆分状态和按钮动作保存在用户目录的 `.codex/config.toml`，位于 `desktop.codex-micro-layout` 下；免驱键帽图标单独保存在 Micro 的本地配置中。保存动作仍需要写入 Codex 配置，但更换按钮不需要 Codex 提供额外的权限或开关。

配置写入前后都由 TOML 解析器校验；损坏配置拒绝保存。修改内联表时，仅展开本次修改所在的内联祖先，保留其他配置和注释，避免追加重复定义。图标保存失败时恢复动作配置的原始字节，图标配置只有持久化成功后才更新内存和通知界面；恢复期间若遇到外部修改或文件锁，则保留备份并报告失败，不覆盖外部改动。

拆分设置异步读写配置、原子替换并异步重新读取；写入期间同一配置写入器不并行修改文件，观察到外部编辑时拒绝覆盖。保存失败时恢复已读取的布局并保留错误状态。

## 全部键帽的默认动作

当前 40 个可选键帽包括官方 39 个与 Micro 扩展的 `SKETCH`。其中 10 个默认动作有执行通道，30 个默认动作尚未接入或未绑定。所有官方命令型键帽的默认动作均与导出的官方目录一致。

图标与动作分别保存，但在编辑器选择键帽时会同时选中它的默认动作，避免外观改变而点击仍执行旧功能。选好键帽后仍可在动作下拉框中另选命令或技能；打开编辑器、语言切换及技能目录加载不改变已有选择。编辑器禁用不支持的命令，并阻止保存不支持的动作。主键盘的提示和无障碍名称读取实际绑定的动作；未支持或未分配的动作禁用，并保留简短原因。依赖已有会话的动作在没有已确认会话或导航期间禁用；Fast、Plan 和推理强度支持已确认的空白草稿。缺少会话 ID 本身不能证明当前页面是草稿，须确认前台首页输入框及其模型选择器身份。

此选择规则适用于已有按钮与尚未配置的占位键（例如刚拆分的 `MIC1`、`EMPT1`）。再次选择不同键帽会重新选中该键帽的默认动作。不支持的动作显示“此动作尚不支持”，保持禁用保存。

| 键帽 | 默认动作 | Windows 免驱通道 |
| --- | --- | --- |
| FAST | `composer.toggleFastMode` | 已有会话 IPC；草稿原生命令快捷键 |
| APPR | `approval.approve` | IPC；只处理唯一待审批项 |
| REJ | `approval.decline` | IPC；只处理唯一待审批项 |
| SPLIT | `forkThread` | IPC / App Server |
| MIC、MIC1 | `dictation.pushToTalk` | 未接入 |
| CODEX | `composer.submit` | 原生输入框 |
| BUG | `feedback` | 未接入 |
| OAI | `developers.openai.com` | 外链动作未接入 |
| TERM | `toggleTerminal` | 未接入 |
| DWN | `copyConversationMarkdown` | 未接入 |
| DEL | `archiveThread` | 未接入 |
| NEW | `newTask` | 创建空白会话 |
| NAV | `openBrowserTab` | 未接入 |
| MAGIC | `toggleThreadPin` | 未接入 |
| DIFF | `toggleReviewTab` | 原生链接打开 Review；尚非开关往返 |
| PLAY | `environmentAction1` | 未接入 |
| GIT | `git.commit` | 未接入 |
| BRCH | `git.createDraftPullRequest` | 未接入 |
| BRANCH | `git.createBranch` | 未接入 |
| MRG | `git.mergePullRequest` | 未接入 |
| PR | `git.createPullRequest` | 未接入 |
| PAINT | `composer.addPhotos` | 未接入；与 Sketch 分开 |
| SKETCH | `composer.sketch` | 原生添加菜单 → 绘图编辑器 |
| LAB、SETUP | `settings` | 未接入 |
| PARTY | `openSideChat` | 未接入 |
| TIME | `manageTasks` | 未接入 |
| MIND+ | `composer.increaseReasoningEffort` | 已识别会话 IPC；草稿原生命令快捷键 |
| MIND- | `composer.decreaseReasoningEffort` | 已识别会话 IPC；草稿原生命令快捷键 |
| EMPT1、EMPT2、EMPT3、EMPT4、EMPT5 | `unassigned` | 未绑定；可另选命令或技能 |
| FOLD | `openFolder` | 未接入 |
| UPL | `composer.addFiles` | 未接入 |
| APPS | `openSkills` | 未接入；技能插入是独立的技能绑定 |
| YOLO、YEET | 官方预置输入文本 | 未接入 |

另有 `composer.togglePlanMode`、`toggleSidebar`、`navigateBack`、`navigateForward` 和 `turn.cancel` 可绑定到这些键帽。合计 15 个有通道的命令（官方 13 个、Micro 扩展 2 个），技能绑定走独立的原生输入框插入通道。官方目录中的其他 140 个命令未声明免驱支持。

已识别会话的 Fast、Plan、MIND± 通过 IPC 操作对应 ID，并在写入前重新校验目标及预期设置。无需配置这四项快捷键；IPC 拒绝或结果未知时不再改走原生按键，避免重复切换。

点击 Agent 时保存其会话 ID，模型、Fast、推理强度与当前键位灯光共用该目标。没有实时 Document 路由时，读取标题栏工具栏中的可见文本及页面标识，兼容标题按钮与普通文本容器；侧栏收起不会单独清空目标。在 Codex 内切换页面后，能唯一恢复新 ID 就更新；页面改变且身份不明时清除旧目标，旧的排队操作不得继续派发。已有 ID 的 IPC 设置不必等待导航确认，原生输入仍须等待。具体状态处理与验证边界见[会话定位](session-targeting.zh-CN.md)。

草稿及已确认原生输入框的 Fast／Plan／MIND± 读取当前 `CODEX_HOME`（未配置时为用户目录 `.codex`）下的 `keybindings.json`，通过对应原生命令的实际快捷键切换。这些命令不预设产品快捷键；缺少绑定、显式禁用、绑定冲突、配置无效或组合不受支持时拒绝发送并显示原因，不改写用户绑定。支持 F1–F24 及带 Ctrl／Alt 的字母、数字单段快捷键，可组合 Shift；多段按键序列和直接产生文本的按键不派发。无修饰键的 F13–F24 直接向经确认的 Codex 前台焦点窗口派发按键消息，避免输入法将注入事件转换为 `VK_PROCESSKEY`；派发前再次校验窗口、焦点和物理修饰键。其他快捷键继续使用系统输入通道。

Fast、Plan、MIND± 与推理旋钮输入共享串行执行通道，等待前序动作最多 60 秒，以容纳连续六次、每次最多十秒的原生操作。执行前重新验证会话 ID、草稿模型选择器或原生输入框身份及目标版本；目标切换后排队动作不得写入，关闭 Micro 会取消等待。发送、审批等动作不排队，忙碌时明确返回未发送。原生 UI 请求最多等待 10 秒；UIA 提供方尚未返回时继续保留原生执行锁，防止第二个原生动作越过未完成调用。超时不会自动重发。

重复标题不能唯一映射会话 ID 时，若能确认前台窗口、实际选中侧栏项的运行时身份、输入框及模型选择器，四项设置动作可走该原生输入框；不猜测会话 ID，也不向同名会话之一发送 IPC。侧栏选中状态按 UIA 运行时 ID 匹配，不能将同名条目都标成选中。Document 的实时路由可提供 ID；bootstrap URL 中的 `initialRoute` 只表示窗口启动位置，不作为后续 IPC 写入的目标依据。四项设置动作在既无可靠 ID、又无已确认原生目标时禁用。Fast 指示灯只消费当前目标的设置或原生操作读回，不将未知结果显示为成功。

Fast 按 Codex 原生命令循环速度档位，连续点击保持串行并读回实际变化。部分布局只有模型菜单内提供可读取的速度名称，此时只打开一次模型菜单，在同一菜单内读取初始状态、执行原生快捷键、确认变化，然后关闭；不为第二次读回重新打开菜单。Plan 直接切换并读回计划状态，不插入 `/p`、不编辑现有文本。Chromium 的文本读取会包含空输入框占位提示；适配器通过原始 UIA 树中唯一的空段落 `placeholder` 标记识别空内容，避免 Plan 切换占位提示时误报用户文本变化。两项操作派发前核对前台窗口及输入框身份；Fast 在已确认模型菜单内派发时保持该菜单焦点，其他情形校验输入框焦点。按键与摇杆共用这套路由。导航未确认、目标版本变化、输入框身份丢失时不派发；操作后的状态变化无法读回时返回结果未确认，不重复执行。取消或目标改变后不向新目标补发菜单清理操作。

模型相关原生命令包括 `composer.openModelPicker`、`composer.openRecentModels` 和推理强度增减／循环；前两项只打开选择入口，不携带指定模型 ID。指定模型切换保留已有会话 IPC 与新会话原生选择器路径。Codex 自身的 Ultra 确认对话框仍由用户处理，适配器不将打开对话框视为推理强度已经切换成功。

目录位于 [CodexKeycapCatalog.cs](../../src/CodexMicro.Windows/Services/CodexKeycapCatalog.cs) 与 [CodexActionCatalog.cs](../../src/CodexMicro.Windows/Services/CodexActionCatalog.cs)，执行映射位于 [SoftwareMicroTransport.cs](../../src/CodexMicro.Windows/SoftwareControl/SoftwareMicroTransport.cs)。[官方目录](../../src/CodexMicro.Windows/Services/CodexOfficialCatalog.json) 继续由导出脚本生成，并单独记录 Micro 扩展，不能仅因出现图标或命令名称就将其列为已实现。

## 操作反馈（2026-10-04）

发送动作在 Codex 不处于前台时，第一次点击仅将 Codex 置前；再次点击才按当前目标与输入框状态发送。已有会话、目标未改变、唯一待审批项等执行前检查继续保留。

最近操作灯用绿色表示已确认交付，黄色表示暂不可执行或结果未确认，红色表示失败。绿灯在 650 毫秒后恢复空闲；红灯与黄灯在 5 秒后恢复空闲。后来的状态会取消旧状态的复位，复位后保留最近事件的提示内容。未分配动作不报错，不自动重试任何发送操作。

按键与摇杆的失败提示包含返回的具体原因。按键结果及摇杆失败通过现有 `SoftwareControlDiagnostics` 记录操作、结果分类与详情；同步轮转写入在后台线程执行，不占用界面 Dispatcher。此修正不新增语音执行通道，未接入的语音绑定保持禁用。
