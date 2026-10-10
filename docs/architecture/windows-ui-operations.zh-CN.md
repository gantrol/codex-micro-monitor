# Windows Micro 界面操作清单

审查日期：2026-10-04。范围是当前 **Windows 软件版 Micro**，从可见入口追踪到实际执行、目标确认和反馈。没有启动 Windows 界面，也没有操作真实 Codex 会话；“已接通”仅表示存在可达执行路径，不等于通过业务验收。

本次 fetch 后，产品 HEAD 与 origin/main 均为 `58b024408ec05189769a5b28959acd311bc9543f`，共享控制均为 `d54e55a8085cebd89f2954d43fbbee4e93339420`。用户说明的“叠层，点哪设置哪”、新对话修复及新测试规划尚未出现在这两个远端提交中；本文不推测新版本行为。

完整附表：[154 个动作定义](../design/windows-micro/windows-command-inventory.csv)、[39 个键帽及默认动作](../design/windows-micro/windows-keycap-inventory.csv)。动作目录、图标目录和实际支持能力分别统计，不能互相替代。

## 1. 实际产品入口与布局

桌面入口调用 `CreateSoftwareControlled`，采用 `SoftwareMicroTransport`，只启用 Codex 主键盘，不恢复额外 Harness 键盘。遗留 HID 文案、多 Harness 菜单构造函数和通用控制器接口不算当前可见功能。[S01][S02]

| 控制页 | 第 1 列 | 第 2 列 | 第 3 列 | 第 4 列 |
| --- | --- | --- | --- | --- |
| 第 1 行 | 白色编码旋钮 | AG00 任务 | AG01 任务 | 黑色四向摇杆 |
| 第 2 行 | AG02 任务 | AG03 任务 | AG04 任务 | AG05 任务 |
| 第 3 行 | ACT06 Fast | ACT07 批准 | ACT08 拒绝 | ACT09 分叉 |
| 第 4 行 | 额度／模型旋钮 | ACT10_ACT11 双宽麦克风 | ← | ACT12 Codex 发送 |

监视页有 14 个任务键；左下额度旋钮、右下 Codex 键是跨页共享实例。配置允许将双宽麦克风拆成 ACT10、ACT11，但当前本地设置中没有可见的拆分开关。任务键显示圆点，名称和状态通过悬停及无障碍信息提供。[S03][S04][S05]

## 2. 启动、当前会话与导航

这里是其余操作的前提。“当前任务”来自观察，不是最近列表第一项，也不是上一次点击的 ID。

| 编号 | 触发 | 当前代码行为 | 边界／反馈 |
| --- | --- | --- | --- |
| T01 | 启动主窗口 | 恢复位置、置顶、大小；启动配置观察、任务／额度／模型观察与连接 | 不能把连接成功等同于识别到会话 |
| T02 | 窗口可见期间，每 250 ms | 刷新前台状态，读取 Codex 当前会话，更新选中、模型等投影 | 单个读取在途；旧 generation 的结果丢弃 |
| T03 | 选择要观察的 Codex 窗口 | 优先前台 Codex 主窗口，其次先前匹配窗口，再其次唯一符合条件的窗口 | 多窗口且没有锚点时不猜；工具窗口、最小化等不作为该回退候选 |
| T04 | 从窗口识别已有会话 | UIA 查侧栏 `current=page`、`sidebar-item` 的标题，与 `session_index.jsonl` 的标题唯一匹配到 UUID | 标题重复、侧栏隐藏、索引缺失、无窗口会返回未知；这是当前基线的限制 |
| T05 | 读不到已有会话 | 另外捕获草稿输入区上下文 | `threadId == null` 本身不证明是新对话，也不能直接允许草稿写入 |
| T06 | Micro 请求打开任务 | 发 `codex://threads/<id>`；保存导航中的目标与版本，激活实际 Codex 主窗口，回读选中项 | 保留旧确认状态用于呈现；导航未确认时写操作被拦截 |
| T07 | 导航等待 | 循环间隔 60 ms；已有任务须观察到对应 ID | 约 4 s 的确认循环期限；未确认显示黄色 `Navigation unconfirmed`。底层窗口激活／读取本身不等于有硬性 4 s 总时限 |
| T08 | 在 Codex 中手动换聊天 | 后续观察更新 Micro 当前目标 | 不要求先在 Micro 点一次 |
| T09 | 执行控制前 | 捕获目标、布局、配置、选择 generation；已有聊天复核 ID，草稿复核 presentation | 目标改变或正在导航时拒绝旧操作；原生 UI 路由另验窗口／输入区 |
| T10 | 新聊天导航 | 打开 `codex://threads/new`，导航目标设为 null | **旧代码只用 `threadId == navigationTarget` 清 pending，null 对 null 也会显示 Opened，没有在此条件中验证草稿。不能把这一点当成正确的移植合同** |
| T11 | 已运行时再次启动应用 | Release 版请求现有实例显示面板，然后结束新进程 | 不创建第二个键盘实例；Debug 版只报告已有实例并结束 |
| T12 | 后台启动 `--background` | 不主动显示面板，保留托盘和后台服务入口 | 已有实例时也不请求显示；须通过托盘或其他显示入口打开面板 |

来源：[S02][S06][S07][S08][S16]。启动时主动观察是应保留的行为；标题匹配和 null 导航确认是实现局限。尚未同步的 Windows 新对话修复应在更新后复审。

## 3. 外壳、分页和窗口生命周期

| 编号 | 操作 | 效果／限制 |
| --- | --- | --- |
| W01 | 在外壳空白处按住左键拖动 | 移动整个窗口，按屏幕 DPI 换算；松开持久化位置。按钮区域不启动外壳拖动 |
| W02 | 拖动期间丢失捕获 | 停止拖动；不继续跟随鼠标 |
| W03 | 点击顶部控制页／监视页标记 | 切换 6 任务＋控制键／14 任务；点击当前页不做事 |
| W04 | 切页中的输入 | 暂停两页及共享部件命中；结束摇杆／旋钮手势、清待执行旋转、取消推理输入；完成后恢复命中 |
| W05 | 正在切模型或打开任务时切页 | 拒绝本次切页并恢复页标记；不叠加新的切页流程 |
| W06 | 外壳空白处右键 | 打开置顶、软件设置、重连、收起面板菜单 |
| W07 | 菜单切换置顶 | 立即改变并保存；置顶开启时维护窗口层级 |
| W08 | 菜单打开设置 | 打开唯一的软件设置窗口；已有窗口则恢复并激活，不重复创建 |
| W09 | 菜单重新连接 | 恢复 Codex 软件连接，更新状态；旧 XAML 的虚拟 HID 文案被运行时替换 |
| W10 | 菜单收起／关闭主窗口 | 隐藏面板，应用和托盘继续存在；窗口关闭事件在非退出流程中转为 Hide |
| W11 | 隐藏／重新显示 | 暂停／恢复相关观察计时器和刷新；隐藏取消推理输入 |
| W12 | 普通点击主面板 | 主窗口采用非激活风格，保留 Codex 焦点；设置和键帽编辑窗口会获得焦点 |
| W13 | 窗口失活／手势中断 | 结束摇杆拖动、取消白旋钮手势，并按语音释放逻辑清理按压 |
| W14 | 尝试拖窗口边缘缩放 | 当前 `ResizeMode=NoResize`，没有可达的边缘缩放功能；大小通过设置调整 |
| W15 | 系统关闭客户端区域动画 | 任务／分页运动按系统动态效果设置结束或跳过动画 |

不具备自身菜单的普通命令按钮会拦住外壳右键菜单；任务键、额度旋钮各自处理右键。主键盘没有已注册的自定义全局键盘快捷键；旋钮的非激活窗口鼠标钩子不等于全局键盘快捷键。[S03][S09][S10][S11]

## 4. 任务键：控制页和监视页

| 编号 | 操作 | 实际行为 | 边界 |
| --- | --- | --- | --- |
| A01 | 控制页任务键单击 | 读取当时 AG00–AG05 的映射，打开准确 thread ID，并进入导航确认 | 当前软件分支始终单击导航；旧“单击／双击聚焦”偏好不控制它 |
| A02 | 监视页任务键单击 | 捕获该键 `MonitorTask.Id` 并打开，更新导航状态 | 无任务、数据不新鲜、正在打开或运动时不可用 |
| A03 | 控制页空槽单击 | 控件仍可能可点击，传输层返回 `Empty agent slot` | 不能统一描述成“空槽都已灰掉” |
| A04 | 任务键右键 | 对准确 ID 发“标记未读”，等待 Codex 未读状态回读 | 仅无活跃彩色状态且未在标记中的任务可走；不是未读开关，也不弹通用菜单 |
| A05 | 未读请求处理中 | 临时降低键的不透明度；确认后绿色未读光 | 失败撤销临时标记并报状态；过程中左键打开已清标记时，迟到结果不重新点亮 |
| A06 | 打开任务 | 清相应的手动未读记录；继续依赖 Codex 状态观察 | 不把“发出了链接”当作已观察到目标 |
| A07 | 悬停任务键 | 显示标题、状态等提示，提供无障碍名称 | 运行光只能说明回合未结束，可能仍在等输入 |
| A08 | 监视页悬停／捕获，或打开任务／页面运动中刷新 | 保留已分配任务身份，按 ID 更新状态；离开后恢复最近顺序 | 明确的身份冻结实现存在于监视页 |
| A09 | 控制页刷新导致排序变化 | 更新 roster，运动期间抑制输入；排序变化时释放按键鼠标捕获／清正在按住的键盘焦点 | **未找到与监视页相同的悬停身份冻结；不能把两页说成完全相同** |
| A10 | 无数据／状态过期 | 监视页保留可呈现的身份但降低可信度并禁用不新鲜任务 | 不把未知状态解释为空闲或已完成 |

任务默认按 `thread/list` 的 `recency_at` 降序读取；任务观察约 2 s、待回答观察约 250 ms。设置中的 Agent 来源选项没有接入当前读取路径，见设置清单。[S04][S05][S06][S12][S13]

## 5. 白色编码旋钮

白旋钮按配置决定功能，并非固定只导航。没有有效配置时回退 `composer-navigation`；本次未读取用户 Windows 安装的实际 TOML，不能将回退值称为该安装正在使用的模式。

| 模式 | 正向／顺时针一步（未反转） | 反向／逆时针一步 | 按压并释放 |
| --- | --- | --- | --- |
| `reasoning` | 降低一个支持的推理档位 | 提高一个支持的推理档位 | 切换快捷模型 A/B，含各自强度偏好 |
| `composer-navigation` | 上一个输入区控件／菜单项 | 下一个输入区控件／菜单项 | 激活当前项；未聚焦时尝试首项 |
| `conversation-scroll` | 对话向上滚动 | 对话向下滚动 | 到对话底部 |
| `custom` | 返回未知绑定、不执行 | 返回未知绑定、不执行 | 当前代码却回退到输入区激活；没有完整自定义实现 |

| 编号 | 手势／场景 | 行为 |
| --- | --- | --- |
| D01 | 鼠标滚轮 | 累计 120 delta 为一步，保留零碎余量；有非激活窗口鼠标钩子及 WPF 回退路径 |
| D02 | 按住拖动 | 移动 6 设计点后认定拖动并锁主轴，再每 12 点一步；向右／向上为正向 |
| D03 | 按下后未形成拖动再释放 | 触发按压动作；没有独立白旋钮长按业务操作 |
| D04 | 失去捕获／切页／取消 | 不补发按压；取消相应待执行输入 |
| D05 | 连续旋转或反向旋转 | 合并净步数、最多 3 待执行步；反向抵消积压，过时输入丢弃；不逐鼠标帧发写请求 |
| D06 | 推理档位到边界 | 按模型支持的档位夹紧，不循环；未知当前强度不猜一个起点 |
| D07 | 输入区已有菜单 | 导航优先作用于已打开菜单项；无菜单才遍历输入区控件；不操作不相关菜单 |
| D08 | 点击／滚动后的确认 | 原生适配观察焦点、菜单开关、选中等变化；滚动观察百分比或内容位置；边界可确认无变化 |
| D09 | 白旋钮右键 | 当前没有它自己的模式菜单或设置叠层入口 |

全局“反转旋钮方向”影响上表报告方向。推理操作还检查前台 Codex 窗口／会话或草稿上下文；后台列表里留有一个 ID 不代表允许操作。旋转本体每步 18°，105 ms；这些动画不构成服务端成功确认。[S14][S15][S17][S18]

## 6. 左下额度／模型旋钮

| 编号 | 操作 | 实际行为 |
| --- | --- | --- |
| Q01 | 短按 | 快捷模型 A/B 切换；已有会话与空白草稿走不同路径 |
| Q02 | 滚轮 | 直接调推理强度，与白旋钮当前模式无关；仍受方向反转、模型支持范围和目标校验约束 |
| Q03 | 按住时滚轮再松开 | 抑制松开后的 A/B 点击，避免一次手势同时改强度又换模型 |
| Q04 | 长按至少 650 ms 后松开 | 调用官方设备设置；**软件传输明确返回不支持**。不是到 650 ms 就自动弹窗 |
| Q05 | 右键／请求上下文菜单 | 打开软件设置窗口，滚到快捷模型 A 行并聚焦下拉框；没有独立模型弹出表 |
| Q06 | 拖动该部件 | 未注册调档拖动处理；不能把 Mac 已加的拖动称为 Windows 基线 |
| Q07 | 悬停／键盘聚焦 | 切换为模型／推理显示；离开恢复额度，调档期间也会短暂显示强度反馈 |
| Q08 | 查看额度提示 | 读取各额度窗口、重置时间、可用重置额度及过期、更新时间和读取失败信息 |
| Q09 | 额度缺失 | 显示未知占位，不能显示为 0%；有两个窗口时分别显示 |
| Q10 | 尝试点击额度重置 | 当前提示是只读内容，没有“消费额度重置”的按钮或点击操作 |

### Credits 余额补充（2026-10-10）

本节依据当前源码补充，不改变上文 2026-10-04 操作清单的历史审查范围。

- 复用 `account/rateLimits/read`，从选中的 Codex 额度分组解析 `credits.hasCredits`、`credits.unlimited` 和字符串 `credits.balance`。余额使用 `decimal` 保留精度，与额度重置次数分别展示；不跨分组拼接数据，不假设余额上限。
- 任一实际展示的套餐窗口剩余值达到零时，中心显示余额及 `Credits` 单位；百分比取整到 `0%` 不触发切换。Pro 隐藏的五小时窗口不参与判断。外圈继续表示套餐窗口，恢复后中心自动回到百分比。
- 明确没有 Credits 时显示零，无限余额显示 `∞`；余额未知或矛盾时保留套餐读数，详情显示“余额暂不可用”。套餐窗口无法读取时继续使用原有未知状态。
- 小于 `0.01` 的正余额显示 `<0.01`，大额余额使用紧凑单位，极大数使用带近似标记的科学计数法。详情和无障碍名称保留完整余额，数值按界面语言格式化。
- 刷新失败保留上次成功快照及原有失败提示；下一次成功响应缺少余额时清除旧余额。悬停、键盘聚焦及调档反馈仍优先显示模型。
- 自动化覆盖解析、精度、语言格式、窗口耗尽边界、模型预览、额度恢复、刷新失败和字段缺失；组件测试只实例化控件及未显示的窗口，不操作真实 Codex 界面。

A/B 判断不仅比较模型：两个槽模型相同时，还比较 A 的有效推理强度，因此可以在同一模型的两档之间切换。已有会话中，未指定努力值会落到模型目录的默认值；设置界面却称其为“记忆上次”，存在文案与执行差异。草稿另有模型选择器路径，不能用已有会话路径证明它也有相同行为。

草稿模型切换会重新捕获输入区并确认 presentation；不存在 ID 时不能伪造 thread。模型／强度设置作用于后续提交，不追溯修改正在运行的回合。是否真正表现为预期业务结果仍需 Codex 联调。[S14][S15][S16][S19][S20]

## 7. 右上黑色摇杆

| 编号 | 操作 | 默认效果／规则 |
| --- | --- | --- |
| J01 | 点上箭头 | 已有当前会话的 Plan / Default 切换 |
| J02 | 点下箭头 | 切换 Codex 侧栏显示 |
| J03 | 点左箭头 | Codex 导航后退 |
| J04 | 点右箭头 | Codex 导航前进 |
| J05 | 拖动中心帽 | 相对按下点判断四向；输入半径 24、激活阈值 0.5，即约 12 点；没有对角业务动作 |
| J06 | 持续停在同一方向 | 不连发；回到中性区域后允许再次触发，换到另一方向可触发该方向 |
| J07 | 松手／丢捕获／失活／切页 | 回中并释放状态；没有中心短按业务动作 |
| J08 | 连续拖动事件 | 合并中间位置；手势之间的中性状态不能丢失，否则同方向下一次可能被吞掉 |
| J09 | 配置 `analogActions` | 四向可覆盖为实际支持的 command；当前本地设置未提供可见方向编辑器 |

Plan 路由：读当前模式 → 验证目标模式在目录内 → 保留模型／强度并将 `developer_instructions` 设为 null 采用目标模式默认 → 复核目标和设置条件 → 提交。返回 `applied:true` 才算协议已接受。该函数没有紧接着做模式语义回读，不能描述成已经证明 Codex 后续按 Plan 执行业务。

Plan 在这条 Windows 软件路径中通过活动灯和悬停／无障碍状态报告结果，**没有弹 modal alert 的流程**。侧栏和前后导航走原生 UI 适配：验证窗口、相关控件及实际变化；历史按钮不可用时拒绝，不用全局快捷键盲发。[S14][S16][S18][S21]

## 8. 默认命令键

以下是无覆盖配置时的动作。保存的 action 优先于旧 commandId，再回退键帽默认动作；软件版图标可独立修改，所以不能只看图标判断执行内容。

| 编号／位置 | 默认操作 | 目标与执行 | 限制／反馈 |
| --- | --- | --- | --- |
| K01 ACT06 | Fast | 对当前已确认会话切换服务档位，按目录选择 fast／priority | 处理中反馈与已生效图标分开；不支持的模型拒绝 |
| K02 ACT07 | 批准 | 当前会话恰好一个可处理的命令／文件审批请求，发送 accept | 0 个或多个均拒绝；不自选一条，不弹 Micro 审批列表 |
| K03 ACT08 | 拒绝 | 同上，发送 decline | 发送前复核该请求仍存在，需 acknowledgment |
| K04 ACT09 | 分叉 | `thread/fork`，`excludeTurns:true`、`deferGoalContinuation:true`，然后打开返回的准确 ID | 分叉成功与打开失败分开；Mac 协议支持须单独核对 |
| K05 ACT10_ACT11 | 双宽麦克风 | 默认 `dictation.pushToTalk` | **软件传输不实现原生语音**，不能因按压／释放代码存在就认为能录音 |
| K06 ACT10 | 拆分后的麦克风 | 默认同上 | 同样不支持；只在拆分配置下显示 |
| K07 ACT11 | 拆分后的空键 | 默认 `unassigned` | 不执行；可在编辑器重新绑定 |
| K08 ACT12 | Codex 发送 | 调用真实 Codex 输入区的 Send，保留当前文本／附件；观察开始忙碌或内容清空 | 不是打开聊天，不创建自己的消息文本；菜单打开、发送不可用或输入区改变时拒绝 |

麦克风外形的键使用按下即派发，以及 Space / Enter 首次按下派发；抬起、丢捕获、失活有清理路径，键盘重复按下被过滤。将其重绑到支持的 command／Skill 时，这些按下入口仍能调用映射动作；这不使默认语音动作变得可用。

普通命令键在软件呈现中通常仍启用，是否能执行由动作和当前上下文决定；“没有置灰”也不能作为支持证明。[S03][S14][S16][S18][S22]

## 9. 键位编辑器中的动作全集

源码有 153 个官方 command 定义，另加 `turn.cancel`，共 154。路由白名单为 **14 个 command：10 个标为 ipc、4 个 native-ui**；另支持动态 Skill 插入。`ipc` 在这里是目录分类，包含打开 URI 的动作，不表示每个动作都发 IPC 写入。

| action ID | 可见用途／实际动作 | 路由分类 |
| --- | --- | --- |
| `newTask` | 打开空白新聊天，未提交消息；见 T10 的旧确认问题 | ipc |
| `forkThread` | 分叉并打开返回的会话 | ipc |
| `composer.toggleFastMode` | 切换服务档位 | ipc |
| `composer.togglePlanMode` | 已有会话切换 Plan / Default | ipc |
| `toggleReviewTab` | 打开该会话的 `?view=review`；当前不是“再按关闭”的已观察 toggle | ipc |
| `approval.approve` | 批准唯一明确审批 | ipc |
| `approval.decline` | 拒绝唯一明确审批 | ipc |
| `composer.increaseReasoningEffort` | 提高支持档位；主窗口按键入口也经过推理输入处理 | ipc |
| `composer.decreaseReasoningEffort` | 降低支持档位 | ipc |
| `turn.cancel` | 读取并复核准确 active turn ID，再 `user-stop` | ipc |
| `composer.submit` | 提交当前真实输入区内容 | native-ui |
| `toggleSidebar` | 切换侧栏并观察控件变化 | native-ui |
| `navigateBack` | 可用时后退并观察导航变化 | native-ui |
| `navigateForward` | 可用时前进并观察导航变化 | native-ui |
| `type=skill`，动态名称／路径 | 向真实输入区插入 Skill 引用；不自动提交 | native-ui，非固定 command |

其余 140 个定义中，`codexMicroSettings` 在软件编辑器的目录列表隐藏，139 个无软件路由、在动作列表禁用。既有保存的 `codexMicroSettings` 仍可能按旧配置保留为禁用项。包括归档、删除、置顶、终端、Git、浏览器、语音等，不可因目录中有名字就列为已支持功能。`markThreadUnread` 的 command 绑定也不支持，但任务右键另有专用实现，两者不能混淆。

键帽默认表还有 `dictation.pushToTalk`、`unassigned` 等非这 154 个目录项的占位／旧动作，附表单列它们。编辑器支持“原始默认”选项并保留既有未知配置，这同样不代表这些动作有执行路由。[S14][S22][S23][S24]

## 10. 当前软件设置窗口（旧版，待叠层替换）

入口只有外壳菜单和额度旋钮右键。主键盘普通命令键右键不会直接编辑；“点哪设置哪”不是这份提交已经实现的能力。当前窗口单列、可滚动、无边框、不可调整窗口大小；顶部可拖动，右上关闭及 Escape 关闭。一般设置立即保存，关闭并非撤销。[S10][S25]

| 编号 | 可操作项 | 保存／实际效果 | 状态 |
| --- | --- | --- | --- |
| S01 | 预览图 ACT06／07／08／09／12 | 打开对应键帽编辑器 | 已接通 |
| S02 | 预览图双宽 MIC 或拆分 ACT10／11 | 编辑当前布局可见的键位 | 已接通；预览中的任务／旋钮／摇杆不是编辑入口 |
| S03 | 重置布局 | 重置归属 Micro 的 TOML 布局，再清本地图标覆盖 | 已接通；不重置整个 profile 的 A/B、语言、大小 |
| S04 | 大小滑块 | 80%–140%，步长 5%；100%=442.5×457.5 默认窗口 | 已接通，相当于 590×610 画布的 60%–105% |
| S05 | 大小复位 | 恢复 100% 默认窗口 | 已接通 |
| S06 | Agent 来源 | 最近／已固定／优先级／自定义写入本地 profile | **可见但当前 monitor 固定读取最近任务，未接通来源切换** |
| S07 | 白旋钮模式 | 写 Codex TOML：输入区导航／推理／对话滚动／custom | 前三项有执行路径；custom 不完整，见第 5 节 |
| S08 | 反转旋钮方向 | 写 profile，改变报告方向 | 已接通 |
| S09 | 单击任务聚焦偏好 | 写 profile | **软件任务键始终单击导航，此偏好未改变当前行为** |
| S10 | 快捷模型 A | 按当前模型目录选择，写 profile | 已接通 |
| S11 | A 的强度 | 支持档位或“记忆上次”；未指定用 null 保存 | 已有会话实际用模型默认值；文案不准确 |
| S12 | 快捷模型 B／B 强度 | 同 A，两槽可选同一模型不同档位 | 已接通，未指定的语义同上 |
| S13 | 重新连接 | 等待连接期间禁用按钮，完成后刷新连接状态 | 已接通；不替用户决定当前会话 |
| S14 | 键盘 Tab、滚动、Escape、关闭 | 设置区 Tab 循环；滚动浏览；关闭已即时保存的窗口 | 已接通；不是统一 Save / Cancel 表单 |
| S15 | 麦克风模式 | 有 handler，但设置行运行时隐藏 | 不可见，不算可操作 |
| S16 | 自动确认 Ultra Full Access | 有历史 profile 字段及草稿调用用途，设置行运行时隐藏 | 不可见，不算当前用户可设置项 |
| S17 | 打开官方设备设置 | 有 handler，但按钮运行时隐藏；传输不支持 | 不可见／未实现 |
| S18 | 拆分麦克风／摇杆方向映射 | 布局读取支持相应字段 | 未找到当前本地设置的可见编辑入口 |

本地窗口／图标／A/B 等偏好在 `%LOCALAPPDATA%/CodexMicro/micro-profile.json`；布局、动作和白旋钮模式在用户目录 `~/.codex/config.toml` 的 Micro 表中。当前布局观察器默认拼接用户目录 `.codex`，并非读取自定义 `CODEX_HOME`。

布局写入只改归属表并原子落盘，随后通知配置失效。落盘失败与通知失败要分开：后者可能是“已保存，但 Codex 未重载，需重连／重启”。profile 保存失败会提示改动仅在本次运行有效。[S05][S25][S26]

## 11. 键帽编辑窗口

| 编号 | 操作 | 行为／结果 |
| --- | --- | --- |
| E01 | 打开一个命令槽 | 从设置窗口以模态编辑窗口打开，加载当前图标和绑定；软件模式将图标与动作分开。这是设置编辑流程，与命令执行失败弹 alert 不同 |
| E02 | 搜索图标 | 按 ID 和目录英文 Label 不区分大小写过滤；没有另建中文语义搜索 |
| E03 | 选择图标 | 单宽槽只列单宽，双宽槽只列双宽；改变外观，不自动改已选动作 |
| E04 | 展开动作选择 | 原始默认＋官方 command＋动态读取的已安装 Skills；支持 command 排前，未支持项禁用并降低透明度 |
| E05 | 既有未知／旧动作 | 保留呈现以免默默覆盖；无路由时仍不可执行 |
| E06 | Skills 加载完成 | 刷新可选列表并保留当前选择；既有保存的 Skill 不因尚未加载而丢失 |
| E07 | 保存 | 先写 Codex 动作绑定，再写本地图标；两步都成功才关闭 |
| E08 | 保存失败 | 保留窗口并报告；动作已写而图标失败时可能部分保存，不能承诺原子撤销 |
| E09 | 取消／X／Escape | 丢弃尚未保存的编辑并关闭；无法回滚 E08 已经发生的前一步 |
| E10 | 拖标题、滚动图标列表、键盘选择控件 | 普通 WPF 窗口／列表交互；没有单键恢复默认按钮或自定义全局快捷键 |

来源：[S23][S24]。

## 12. Windows 托盘

| 编号 | 操作 | 行为 |
| --- | --- | --- |
| B01 | 双击托盘图标 | 显示／收起键盘；未定义单击切换处理 |
| B02 | 右键 → 显示／收起 | 与双击同一操作；菜单文案按当前可见性刷新 |
| B03 | 开机自启动 | 读取实际注册状态并切换；系统不允许变更时禁用，失败用托盘气泡报告 |
| B04 | 语言 → 自动 | 跟随 Agent Controller／Windows 的自动语言来源，保存并刷新 |
| B05 | 语言 → 简体中文／English | 固定选择并保存，刷新界面 |
| B06 | 重启 | 调用宿主重启流程，托盘气泡报告结果 |
| B07 | 退出 | 真正终止应用并清理；不同于主窗口关闭／收起 |

这份 Windows 托盘没有独立刷新、窗口缩放、居中菜单项；Mac 若提供属于平台新增项，不是基线操作。[S27]

## 13. 状态、失败与并发也是交互的一部分

| 场景 | 当前行为 | 不能误写成 |
| --- | --- | --- |
| 任务状态 | 进行中蓝、等待输入橙、独立待回答黄、已确认未读绿、错误红；选中有独立光照 | 回合结束自动等于未读，或未知等于空闲 |
| 三个状态灯 | 当前会话同步／等待、Codex IPC 连接、最近操作反馈 | 旧 HID 驱动连接含义 |
| 派发开始 | 活动灯蓝色 | 操作已成功 |
| `Accepted` | 绿色，状态写“已交付” | 所有业务效果都已回读验证；Plan 设置路径只确认 `applied` |
| `OutcomeUnknown` | 黄色，保留结果不明并不自动重试 | 明确失败、可以安全重放 |
| `NotSent`／`Rejected` | 红色＋具体原因，悬停／无障碍状态呈现 | 弹出阻塞主操作的警告框 |
| 同时触发动作 | 软件传输单在途；Fast 可等最多 6 s 保序，其他动作繁忙时拒绝排队 | 每个点击都立即并发写入 |
| 原生 UI 操作 | 窗口／输入区复核，调用后观察变化；观察循环约 1.2 s | UIA 提供程序本身必定在 1.2 s 返回，或反复重做点击来探测成功 |
| 输入积压／目标变化 | 旋转合并、过期丢弃、手势和目标版本失效清理 | 将旧任务的输入送到后来切换的任务 |

UIA 调用放到后台任务；无法立即取消的底层调用保留租约，避免后来的动作越过它。这个结构降低主界面阻塞风险，但静态审查不能保证 Windows 所有异常下都不会挂起。[S02][S12][S14][S18][S28]

## 14. 对当前 Mac 问题的约束

用户实机报告两项问题：**启动识别不到当前会话；点 Plan 后出现 alert 并卡死**。本轮只梳理 Windows，没有重现、定位或修复 Mac，不能把下列要求当成已经交付。

1. 当前目标要有独立、持续的桌面观察：冷启动识别已有会话，在 Codex 手动换聊天也同步；最近顺序、点击记录、连接成功都不能代替当前选择。区分已确认聊天、已确认草稿、正在导航和未知目标；不照搬 Windows 标题匹配或 null 等于新对话的漏洞。
2. Plan 应沿“捕获准确目标 → 读取当前模式 → 校验 → 有界异步提交 → 区分接受／未发送／结果未知 → 恢复控件 → 回读实际状态”闭环实现。普通失败采用非模态反馈；所有完成、失败、取消路径释放输入占用。Mac 的 alert／卡死根因仍待单独审查，不能仅归因于 IPC 或缺少目标。
3. 功能验收必须能说明是哪个窗口、哪个聊天／草稿、哪个动作，以及 Codex 中实际发生了什么。构建通过、工具返回值和图标变色都不能单独证明业务正确。
4. 新设置继续按“叠层，点哪设置哪”的方向，等待 Windows 更新后复核具体交互；本文旧设置清单用于覆盖项核对，不作为继续复制旧窗口的决定。

## 源码索引

下列链接固定到审查提交；行号定位入口，同一行列出的其他方法可在对应文件内检索。

| 索引 | 代码与关键入口 |
| --- | --- |
| S01 | [桌面启动](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Desktop/App.xaml.cs#L87)、[软件控制表面](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MicroSurfaceController.cs#L38) |
| S02 | [MainWindow.Software](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.Software.cs#L40)：ApplyCoreSurface、ReadSoftwareThreadSelectionAsync、ValidateSoftwareTargetAsync |
| S03 | [主窗口 XAML](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml#L1) |
| S04 | [监视页](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.Monitor.cs#L331)：ApplyMonitorSnapshot、RefreshMonitorPresentation、MonitorKey_Click |
| S05 | [布局读取与默认值](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexMicroLayoutObserver.cs#L48) |
| S06 | [导航与目标确认](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.Software.cs#L86) |
| S07 | [当前会话读取](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexSelectedThreadReader.cs#L17) |
| S08 | [窗口选择](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexWindowActivator.cs#L34) |
| S09 | [分页](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.PageMotion.cs#L66) |
| S10 | [外壳和设置入口](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L2943) |
| S11 | [启动／可见性／前台观察](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L423)、[关闭转隐藏](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L4297) |
| S12 | [任务读取](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexTaskMonitorService.cs#L51)、[标记未读](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L2062) |
| S13 | [任务运动与输入捕获](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.TaskMotion.cs#L115) |
| S14 | [软件派发与串行控制](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/SoftwareControl/SoftwareMicroTransport.cs#L82) |
| S15 | [旋钮按压／滚轮](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L1502)、[手势量化](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/DialGestureTracker.cs#L1)、[方向](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/DialDirectionSettings.cs#L1) |
| S16 | [共享控制后端](https://github.com/gantrol/codex-control/blob/d54e55a8085cebd89f2954d43fbbee4e93339420/src/CodexControl/KeypadController.cs#L68)：新建、分叉、Plan、设置、审批与停止 |
| S17 | [推理输入](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.Reasoning.cs#L1) |
| S18 | [原生 UI 适配](https://github.com/gantrol/codex-control/blob/d54e55a8085cebd89f2954d43fbbee4e93339420/src/CodexControl.Windows/CodexUiController.cs#L1)：Submit、导航、输入区选择、滚动、Skill |
| S19 | [草稿模型切换](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.Software.Draft.cs#L14) |
| S20 | [额度显示](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Controls/QuotaKnob.cs#L262)、[额度提示](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.QuotaHelp.cs#L1) |
| S21 | [摇杆手势](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L2573) |
| S22 | [键帽与默认动作](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexKeycapCatalog.cs#L17)、[命令键／麦克风输入](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L767) |
| S23 | [编辑器 XAML](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/KeycapEditorWindow.xaml#L1)、[编辑与保存](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/KeycapEditorWindow.xaml.cs#L249) |
| S24 | [动作路由白名单](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexActionCatalog.cs#L9)、[完整官方目录](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexOfficialCommands.g.cs#L1) |
| S25 | [设置 XAML](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MicroSettingsWindow.xaml#L1)、[可见性与设置保存](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MicroSettingsWindow.xaml.cs#L98) |
| S26 | [配置写入](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/CodexMicroConfigWriter.cs#L1)、[本地偏好](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Services/MicroProfileSettings.cs#L1) |
| S27 | [托盘](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/Hosting/MicroTrayIcon.cs#L1) |
| S28 | [结果反馈](https://github.com/gantrol/codex-micro-monitor/blob/58b024408ec05189769a5b28959acd311bc9543f/src/CodexMicro.Windows/MainWindow.xaml.cs#L2867) |
