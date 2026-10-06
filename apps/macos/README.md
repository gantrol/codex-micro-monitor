# Codex Micro macOS · 控制预览版

macOS 14+，UIKit / Mac Catalyst 与原生 AppKit 桥接，无外部 Swift Package 依赖。当前源码候选版本 **`1.0.0-macos-preview.34`**，新候选输出到 `dist/macos/preview.34/universal/`。保持 Windows Micro 的 590×610 画布、键帽、双页、旋钮和灯光设计。候选代码与构建检查不代表当前运行进程已更新或真实 Codex 已验收。

## 已知问题：新会话设置仍未联通（2026-10-06）

当前实机日志已能把新建页识别为 `kind=draft`，但同一快照仍为 `modelPickerAvailable=false`、`pickerCandidates=0`。因此模型、Fast 和思考强度在派发前就没有原生目标；[官方 Codex app-server 文档](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)也将 `model/list` 定义为目录而非授权判断，它不能替代当前 Codex 输入框里的模型控件。命令键为了保留右键编辑始终接收点击，但不可用动作的 `prepareKey` 为 `nil`，所以会出现“按得下去但没有业务效果”。Plan 有独立快捷键／添加菜单路径，不代表模型控件已经恢复。

本轮同 WebArea 回退与 `pickerSource` 诊断没有在当前 Codex 实机结构中找到候选，仍属于未完成的兼容尝试。摇杆导航的未知结果现会自动重新观察并解除全局控制锁，但不会重放动作，也不能证明原导航已生效。371 项 Swift 回归使用合成 AX 树，只验证控制器逻辑；当前新会话与摇杆仍需真实 AX 证据和端到端验收。

preview.34 处理新会话控制失效的三个边界：原生观察保留辅助功能拒绝及输入框／模型控件缺失的具体原因；支持主页内容旁的底部输入框，要求同一原生 WebArea、唯一主页容器和完整输入控件，排除面板输入框；IPC following 只用于监控，不再自动生成当前会话或控制目标。原生状态变化记录到 `com.gantrol.codex-micro-monitor` / `native-observation`，不记录输入文字、会话内容或 token 值。

本机 2026-10-05 的 preview.33 Debug 进程被 TCC 拒绝辅助功能读取；Codex 已切到 `/` 后 Micro 仍无法确认导航。preview.34 保留该原因，不以重试或旧 UUID 回退绕过授权。签名默认改为 Apple Development，但必须先安装有效证书并在系统设置中授权实际运行的程序；没有证书时只有显式选择的临时签名构建，不能宣称授权稳定性已解决。

preview.33 修复新建后旧会话 ID 被原生/IPC 轮询重新填回的问题。导航等待状态、原生身份优先权与异步观察代次一起阻止旧目标恢复；已确认草稿的返回值立即交接给面板。新增 14 个生命周期场景、4 个正式 DesktopBackend 新建链路场景；新建后 Fast、Plan、MIND 和模型切换均在新原生输入框上回读，不发送旧 UUID。完整 Swift 测试 352 项通过，不能据此声称真实 Codex 已验收。完整维护关系见 [当前会话 ID UML](../../docs/architecture/macos-current-conversation-id.zh-CN.md)。

本候选同时处理实时文档和侧栏使用 client ID / server UUID 别名的情况：经账号、绑定、精确 server 记录与原生窗口复核后启用原生设置；未验证的观察 token 不能控制，显示的 UUID 也不自动获得发送/审批等权限。

## MVVM 重构候选

当前工作区已将 UIKit 展示改为 `MicroViewModel` / `MicroViewState`，应用调度、身份与活动分别由 `MicroSession`、`ConversationContextStore`、`ActivityStore` 管理。原来的 `MicroModel` 仅保留兼容别名。未读状态由 `UnreadStateStore` 合并持久化及带 revision 的 IPC 证据；已确认的人工未读操作有回执屏障，client 关联与焦点绿灯判定共用身份层。具体根因、生命周期边界和诊断字段见[架构记录](../../docs/architecture/macos-current-conversation-id.zh-CN.md)。

本轮独立构建在 `dist/macos/mvvm-refactor/universal/`，仍沿用 preview.34 版本标识，没有发布新版本或替换运行中的应用。临时签名候选仅用于构建和隔离进程验证，未进行真实 UI 验收。

## 功能与门禁

| 功能 | macOS 路径 | 当前边界 |
|---|---|---|
| 最近会话、6 / 14 个 Agent 槽位 | App Server `thread/list` | 精确 UUID；交互期间固定键位身份 |
| 模型与推理强度目录 | App Server `model/list` | 按游标读取、过滤隐藏项；核对账号与目录进程代次；失败清空旧选项 |
| 额度 | App Server `account/rateLimits/read` | 与模型目录分别处理失败；未知额度显示 `—` |
| 当前对话、模型与强度 | 本机前台路由 + IPC following / state 订阅 | 区分前台与手动所选；following 只用于监控；显示并复制完整 ID；当前目标单独订阅，不受灯光列表限制 |
| 已有会话状态 | owner/follower IPC snapshot 11 | 精确 thread ID、local host 与 owner；不支持的消息版本拒绝使用 |
| 已有会话模型、effort、Fast、Plan | IPC settings 2 + App Server 目录 | 操作前重验 owner、设置、目录；已应答写入短暂等待状态回读，不重发写入 |
| 明确文本发送 | IPC start-turn | 精确 thread ID、空闲状态、无未确认提交；应答和业务确认分开 |
| Stop | IPC interrupt 4 | 精确 thread ID 和 turn ID；核对中断结果与回读状态 |
| 单请求同意、拒绝审批 | IPC approval 1 | 唯一 request ID；核对请求内容及请求消失；不批量审批、不自动重放 |
| Fork | 独立 App Server `thread/fork` | 运行时 schema 必须支持 `deferGoalContinuation`；回读新 ID 和来源 |
| 打开会话、新草稿、Review | `codex://` + Accessibility | 启动请求和导航回读分开；新草稿立即退役旧目标 |
| 前台目标与 Composer | 原生 Accessibility | 精确路由 UUID、同一窗口与输入框；草稿要求主页容器证据 |
| 当前输入框提交 | 原生发送控件 + IPC 空闲检查 | 15 秒目标令牌、原文重验；拦截待审批及未确认提交；观察输入清空与新回合 |
| 侧栏、前后导航、输入区选择、滚动 | Accessibility | 唯一控件、窗口身份和操作后回读；不猜坐标 |
| 空白草稿模型、effort、Fast、Plan | 原生菜单 / 用户配置的快捷键 | 设计路径；当前实机模型触发器为 0 个候选，模型、effort、Fast 尚不可用；Plan 有独立路径 |
| Skill 插入 | 原生 HTML 剪贴板 | 进程锁、changeCount 与格式恢复；插入后复制 mention atom，逐项核对 name / path；无法结构确认时结果未知且不重试 |
| Sketch | Composer 添加菜单 | 必须观察到绘图编辑器；菜单打开不算成功 |
| MIC | Codex 原生听写控件 | 控件及麦克风权限必须可用；实时语音未接入 |
| OAI 开发者网站 | 系统默认浏览器 | 固定 HTTPS 网址，不需要当前对话或 Codex 连接 |
| LAB / SETUP / APPS | Codex 设置 / 技能页原生深链 | 固定地址、指定 Codex 应用；打开接受和精确页面回读分别报告 |
| FOLD 项目目录 | 精确 `thread/read` 的 cwd + Finder | 操作前重验目标；路径必须是存在的本机目录，不以通用打开方式执行应用包 |
| MAGIC 置顶 / 取消置顶 | 当前会话的原生 Chat actions 菜单 | 精确 ID、窗口、菜单身份；重新打开菜单核对相反动作 |
| DWN 复制 Markdown | 原生 Copy as Markdown | 新成功通知及单次剪贴板变更回读；不返回或记录对话文本，不覆盖并发复制 |
| DEL 归档 | 原生 Archive + App Server 只读归档列表 | 保留 Codex 确认；精确 UUID 分页回读；离开页面不算归档成功 |
| TERM 终端 | Codex 原生 Open Terminal 菜单命令 | 可见终端页数量回读；不依赖零尺寸 xterm 输入框，不猜快捷键 |
| NAV 浏览器页 | Codex 原生 Open Browser Tab 菜单命令 | 同一精确会话中新可见页的身份与地址输入框；已有页不能确认新建 |
| TIME 任务管理 | `codex://automations` | 只打开管理界面并核对精确路由；不创建、运行或修改任务 |
| BUG 反馈 | Codex 原生 Send Feedback 菜单命令 | 必须读到反馈标题、必填文本框及选项组；不填写、勾选或提交 |
| PARTY 侧边聊天 | 当前会话 New side chat 菜单 | 同一父对话的新可见页及可用输入框；不把面板 ID 当成对话 ID |
| UPL 文件选择 | 当前输入框 Files and folders | 新的 Codex 原生选择窗口；报告等待选择，不冒充附件已添加 |
| BRANCH 创建分支 | 原生命令菜单的 Create branch | 验证 Work here 表单、分支名输入框及创建按钮；不填名称或提交 |
| PR / BRCH | 原生命令菜单的普通 / 草稿 PR | 核对标题、描述字段及实际选中的普通 / 草稿动作；不提交、推送或发布 |
| 任务状态与灯光 | App Server + rollout + 独立 IPC 订阅 | 有界文件增量读取；桌面状态补丁按 revision 连续应用 |
| 未读状态 | `.codex-global-state.json` + IPC | 精确账号 / 本机 host；未知不当作未读或已读 |
| 待回答问题 | rollout + IPC 已接受回答 | 按 question item ID 与 index 对应；只用已接受回答清除待回答 |
| Codex 插件入口 | 同一 `DesktopBackend`、本地 MCP | 独立 Mac 插件 ZIP；未自动安装或发布 |
| AgentController / XInput | 独立 Windows 产品 | 本目录没有手柄产品源码依赖；Mac 版未接入 |
| 完整硬件仿真 / VHF / UMDF | Broker + Windows 驱动路线 | 当前免驱产品不走这条路线 |

这些是实现路径和运行时条件，**不代表真实 Codex UI 联调全部通过**。用户已授权专用临时会话联调，但电脑操作工具拒绝访问 `com.openai.codex`，原文为 “Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.” 没有使用另一条 UI 通道绕过限制，未执行真实 UI 写操作验收。

### 2026-10-05 Windows 场景对照（preview.11–30）

本轮按用户要求新增场景测试，并逐个操作隔离版 Micro 的键帽编辑器。完整差异、40 个目录键帽的实现与历史 34 键界面验证、剩余能力及验证边界见 [逐项对照](../../docs/architecture/macos-windows-parity-2026-10-05.zh-CN.md)。

- 当前 ID 读取 WebArea 的实时文档地址；合并 AXURL、AXValue 和 AXDocument 证据，忽略 bootstrap `initialRoute`，拒绝冲突、外部网址和非精确 UUID。首页 / 设置页会清除旧目标；自动目标写入前重新核对原生前台 ID，IPC following 不生成控制目标。
- Fast、Plan、MIND± 按键共用设置队列，按目标逐次回读，最长排队 60 秒；切换目标、失败或过期后取消剩余输入，草稿逐次采用更新后的原生令牌。补齐中英文、繁体速度标签与原生菜单清理；后台提交第一次只置前。从 Codex 点击 Micro 时仍视为前台操作，避免每次按压都只激活而无法发送。
- 更换键帽自动选择对应默认动作，随后仍可另选命令或 Skill；取消、拆分 / 合并、保存和重启均保留正确绑定。未实现默认动作禁用，不再沿用旧的发送动作。
- 补齐任务右键标未读及账号 / host 范围的持久化回读；会话滚动旋钮短按滚到底部。修复无待审批请求时仍打开空审批浮层。
- preview.12 补齐无精确 ID 的原生设置回退：要求唯一选中侧栏项、同一窗口 / 输入框 / 模型选择器，已知非会话或冲突路由不回退。界面显示“当前输入框”、ID 为空；设置操作不携带 thread_id，发送 / 审批 / Fork 等依赖会话身份的动作保持禁用。
- preview.13 实现 OAI 和 FOLD。隔离 Micro 使用正式路径校验及系统打开逻辑，实际浏览器 URL 和 Finder 目录已核对；FOLD 的对话数据仍为夹具，真实当前对话链路待验收。打开请求被系统接受只返回 `launch_requested`，不冒充已验证目标内容。
- preview.14 修复通用模型触发器丢失当前模型、Power 回读、三档速度、Plan 输入框焦点和候选列表、模型子菜单以及 A/B 初值判断；补齐白旋钮连续输入队列。LAB、SETUP、APPS 分别接入 Codex 设置和技能页。
- preview.15 实现 TERM、MAGIC、DWN、DEL；菜单动作不依赖可见输入框或模型选择器。归档后立即退役旧对话目标；有原生确认时保留确认，不自动接受。
- preview.16 实现 NAV 与 TIME；NAV 要求新浏览器页身份，TIME 验证任务管理路由。打开终端或浏览器后输入框隐藏不误报，但转到另一会话仍不确认。
- preview.17 实现 BUG、PARTY 和 UPL 文件选择器入口；反馈不自动提交，侧边聊天要求新页和可用输入框，文件选择单独处理原生模态窗口。模态窗口路由不可读时，旧 IPC 可见 ID 也不能恢复为当前目标。
- preview.18 实现 BRANCH、PR、BRCH 的原生命令及表单回读；普通 / 草稿 PR 默认选择分别验证。未知结果不重发，权限弹窗不自动关闭。
- preview.19 实现 PLAY：从未过滤的 Project 命令组选择配置的首个适用动作；核对当前对话的 environmentAction1 终端标识，仅确认执行交接，不宣称脚本成功结束。E01–E07 覆盖四种语言、MRU 差异、变化的动作与未知结果。
- preview.20 实现 GIT 的原生提交／推送表单；修复普通／草稿 PR 先要求分支设置时被误判未知的问题。返回实际 workflowStage，不自动创建分支、提交或推送。
- preview.22 补齐 YOLO / YEET 固定文字插入及 EMPT2–5。文字写入观察到的 UTF-16 光标或选区，精确读回文本和光标，不发送、不改权限、不用剪贴板；12 项原生测试及 40 条日志验证正常与失败路径。40 个键帽的默认换绑和持久化均有组件覆盖。安装包离屏 E2E 覆盖全部图案及四档缩放，修复了空白资源初始化崩溃和 BRANCH / UPL 丢失描边。
- preview.21 实现 MRG 合并确认表单与 PAINT 独立照片选择器；不执行最终合并，不选择图片或发送消息。原生表单不能证明 PR 编号，照片选择器不等于附件已加入。
- preview.23 补齐按账号、host 与存储根目录保存的 14 个自定义任务槽位，支持稀疏位置、同名任务、旧任务精确读取、重新启动恢复和显式复制最近任务。切账号、修改映射、按住／悬停和晚到结果均重新核对绑定；不会改写 Codex 固定任务或执行保存的任务。
- preview.24 新增本机固定任务来源：读取现代固定分组的精确身份及服务端顺序，前 6 个控制键／最多 14 个监控键；空、不支持或身份不可用均不补最近任务。取消固定、重排、切账号及冻结按压分别验证；本机固定项目混排由 preview.28 补齐，旧全局 pins 和跨 host 仍未接入。
- preview.25 将优先级排序与灯光分离，按待处理、未读、运行、空闲及最近活动时间排序完整本机候选，再取前 14 项。支持第一百条后的任务状态、仅未读变化的排名刷新、账号范围变化与晚到观察隔离；修复批量 IPC 只写不读造成旧任务永远无法被发现的问题。
- preview.26 对齐错误、审批、待回应、运行与未读灯态顺序；只有新鲜且精确匹配的 Codex 实时前台观察才隐藏当前未读灯，保留原始未读和优先级，不确认已读。过期、冲突或缺失的焦点仍显示未读，连接断开和目录移除清除旧颜色。
- preview.27 的 14 个自定义任务槽位可混用固定 ID、最近第 1–6 个会话和 46 个支持命令；旧配置保留，命令与 ID 互斥，账号／连接变化和重新绑定退役旧按压。同一固定会话重新分配会移出原槽位，新草稿命令不推断持久 ID。
- preview.28 接入本机现代固定项目混排：只读确认项目与 canonical 成员关系，排除单独固定的重复会话，依侧栏偏好排序后再截取 14 项。项目 ID 映射限定服务端确认的本机存储范围；分页错误、读取期间偏好变化和旧按压均拒绝。没有迁移项目或修改 Codex 设置。
- preview.29 区分客户端 ID 与正式 UUID，接入普通及热键窗口客户端路由的原生设置控制器；正式桌面入口的接受规则由 preview.30 修正。hostId 参与当前身份判断，远程或冲突范围不再被当成本机；切客户端时，即使输入框节点复用，旧 token 也失效。客户端身份本身不证明尚未发送，自动槽位绑定仍未完成。
- preview.30 修复正式 DesktopBackend 仍拒绝已知客户端路由的问题；模型与入口共用身份规则。N14／U14／W08 回放接入真实桌面入口，另测目录失败／移除模型、查询期间换目标、无效强度组合和并发写入。修复前失败日志与验证范围更正已保留。
- preview.31 读取当前客户端与正式会话的精确关联，校验账号、存储、server 记录及查询后的原生窗口后显示／复制 UUID，加入显式任务候选。原生设置保持 token 身份；关联不启用发送、停止或审批。Y01–Y13 与 P40–P45 覆盖正常、冲突、过期和变化场景。空槽自动绑定仍等待可验证的首页 client 身份。
- preview.32 修复热键首页、热键独立新建页和项目草稿未被识别的问题；项目 query 范围加入输入框身份，切项目或创建出客户端路由使旧 token 失效。Z01–Z11 覆盖路由、正式 AX 属性投影及桌面入口的四项设置，保留修复前 5 场景／9 断言失败日志。
- 316 个 Swift 场景通过，其中 20 个设置控制器测试含 N01–N19，25 个会话菜单 / 面板测试含 T01–T16，16 个附件选择器测试含 F01–F15，21 个 Git 表单测试含 G01–G20。34 个可见键帽的隔离 UI 检查是 preview.11–13 历史记录；preview.14–32 新路径使用正式控制器回放与系统边界测试，未访问真实 Codex UI。40 个可选键帽包含 33 个命令、2 个固定文字动作及 5 个空白键；原生入口有各自可用条件，PAINT 需要照片菜单项或已配置的专用快捷键。文件实际选中和附件落入输入框仍待验证。45 项进程 E2E、323 条回放日志及逐项结果见对照报告。

测试入口及隔离方式见 [tests/macos](../../tests/macos/README.md)。

### 2026-10-05 功能核对与错误反馈修复（preview.7 历史记录）

- 删除操作失败时自动呈现的模态窗口。复用额度旋钮旁第三颗状态灯显示琥珀色；错误写入系统日志的 `com.gantrol.codex-micro-monitor` / `control` 分类，动态详情标为私密。没有新增常驻说明或确认按钮。
- 结果未知仍拦截后续控制，不自动重试。用户从现有菜单主动刷新后，重新读取前台与会话状态，再清除相应提示和门禁。
- 修正 `Extra high` 同时命中 `high` / `xhigh` 的草稿强度解析；缺少强度快捷键时不启用强度操作，也不先换模型再发现组合请求无法完成。
- 模型目录支持分页、账号代次检查及隐藏项过滤。目录、额度和 Fork 能力分别处理失败；配置失效时清除旧键位绑定，不继续使用过期动作。
- 已有会话设置、Stop 和审批增加约 3 秒预算的只读确认。当前输入框提交与明确文本发送共同检查运行状态、待处理请求和未确认提交。
- 界面读取深链返回的导航确认；Fork 已创建的 ID 保留。侧栏和主内容提供的会话 ID 相互冲突时不建立前台操作目标。
- 默认键位改用 Windows 动作目录的稳定 ID；补齐 Review、Fork、Stop、单请求审批、Sketch、听写以及 MIND± 的原生路由。Skill 插入通过剪贴板回读精确确认 mention name / path，并在其他进程改动剪贴板时拒绝覆盖。
- 33 个图标统一到同一可见 keyline，取消麦克风特例；缩小档按可见轮廓而不是 view 尺寸保证 24 点下限。

核对范围是当前 Mac 源码、共享 Windows 控制接口和插件分发配置。Windows 对应实现位于 `codex-control/src/CodexControl`、`CodexControl.Windows` 以及本仓库 `src/CodexMicro.Windows`；Mac 对应实现见下方维护入口。真实前台操作验收仍未完成，不能把入口存在当作功能验收通过。

本机 `codex-cli 0.160.0` 生成的 schema 包含 `model/list` 的 `cursor` / `nextCursor` 和 Fork 的 `deferGoalContinuation`；安装包内协议定义与 snapshot 11、settings 2、interrupt 4 一致。本轮 Swift 控制层、Catalyst Universal Release、plist、嵌套签名和插件源码同步检查通过。按仓库约定没有新增测试代码或执行真实 UI 手动测试；当前环境没有 `dotnet`，未重新构建 Windows。

## 状态灯刷新

`ActivityMonitor` 与控制 / 目录队列分离。桌面 snapshot 11 建立后，按 revision / baseRevision 连续应用状态补丁；只保留运行、请求、未读字段。收到已接受的回答时重新取快照核对 question item ID 和 index。连接断开、owner 改变、补丁断档或版本不兼容时丢弃对应桌面状态，重新订阅或回退到已观察的本地证据。owner 发现异步进行，未打开会话最长 10 秒的 broker 发现过程不会阻塞已订阅任务；读取保留半帧，缺少 `method` 的 `no-client-found` 负应答只影响对应线程。

rollout、未读全局文件和账号文件使用 vnode 事件监听，40 ms 合并变化；界面每 200 ms 读取内存中的紧凑状态。1 秒轮询补偿文件替换和漏掉的事件，8 秒目录刷新只负责最近会话和绑定。以上是调度参数，尚无实机端到端刷新延迟测量。

读取限定在当前用户的 `CODEX_HOME/sessions`（默认 `~/.codex/sessions`），校验文件类型、所有者及 session metadata 的精确线程 ID。每文件每次最多 2 MiB、单行 256 KiB、最多 24 个增量 cursor；截断、替换或证据不足时保持未知。未读只使用当前账号身份与本机 stdio host 的 SHA-256 桶，不合并其他账号、远程 host 或旧格式。令牌不返回、不保存。

## 图标与原生界面

- 32 个静态矢量图案由 Windows 权威源码生成（包括本地 SKETCH 与 FAST 状态），保留填充 / 描边规则。MIND± 复刻当前 `KeycapIcon.DrawReasoningSlider` 的蓝色滑轨、加减号、白色滑块和 180 ms 悬停动画，最高端变紫；不再导入旧脑形图案。合计 34 个绘制状态。
- 使用与 Windows 相同的 28 点图标框，一般图标可见最长边为 24 设计点；MIND± 按 Windows 滑轨的 1.35 倍视觉补偿绘制，为 32.4 设计点。Fast 两种状态使用同一基准；取消小窗口下强行放大图标的下限补偿，60% / 75% / 100% / 105% 下可见边分别为 14.4 / 18 / 24 / 25.2 逻辑点；MIND± 分别为 19.44 / 24.3 / 32.4 / 34.02 点，键盘、预览和图标选择器共用尺寸，命中区不变。
- 默认 75%，可选 60%–105%。无边框透明窗口支持拖动、置顶、尺寸和菜单栏；Cmd+W 隐藏，Cmd+, 打开设置。隐藏 / 休眠停止观察，显示 / 唤醒重新读取。
- 原生 UI 控制需在系统设置授予 Micro 辅助功能权限。启动缺少权限时显示“权限配置”，菜单栏保留同名入口。点击打开辅助功能设置后，可直接把浮窗中的当前应用拖入系统权限列表并开启开关；浮窗跟随设置窗口并检测实际授权。设置跳转复用 PermissionFlow 的 SystemSettingsKit，拖拽面板适配为兼容当前 Catalyst 桥接的 AppKit 实现。只有用户点击才请求授权。
- 白旋钮跟随 Codex 的 `encoderMode`，支持推理、输入区选择、会话滚动和已支持的自定义动作；右键 / Control＋单击 / 长按定位到交互设置。额度旋钮调强度、短按切 A/B、辅助点按定位到当前对话信息区，长按打开 Codex 官方 Micro 设置。
- 两个旋钮通过本窗口 AppKit 事件接收双指横向 / 纵向滑动及鼠标滚轮，锁定滑动主轴、累计小数位移，并消耗已处理事件避免 UIKit 重复派发；旋钮不响应松手后的惯性。设置页的滚动照常交给原控件。机身空白处辅助点按或长按就地打开窗口菜单。
- 摇杆读取新版 `analogStick` 与旧版 `analogActions`；一次按住可换方向或回中再拨，每次重新核对动作与目标。命令键读取保存的图案及 command / skill 绑定，不支持的绑定保持不可用。
- 已确认的原生 client 会话路由可使用白旋钮导航；每次操作重读原生目标并核对 token 和会话路由。只有输入框、没有明确路由的回退仍限于设置动作。
- 已有会话的强度手势合并 80 ms、唯一写入者、5 秒有效期、回读后继续。设置写入结果未知时只重新读取状态，成功后恢复控制；不重发原请求。发送、Fork、审批等其他结果未知仍需主动刷新。
- Windows 配置中空的默认动作按键帽解析；无效的显式绑定仍禁用。已有会话未显式保存 effort 时使用实时目录默认值，MIND± 在上下限显示当前档位；A/B 同模型不同强度也按有效值比较。不可用按键图标变淡，右键仍可编辑。
- 原生前台识别支持 Codex 去掉 GPT 前缀后的显示名和新版中英文强度名称；不把中文「极高」误识别成 Ultra。空白草稿的强度、Fast 和 Plan 支持原生 Power / Speed / Plan 控件；已配置快捷键仍可使用。

### 设置与键位编辑（preview.11）

- 菜单栏「Micro 设置」或 Cmd+, 打开 720×760 设置层。白旋钮右键 / 长按定位到交互设置，额度旋钮定位到当前对话；命令键右键进入该键编辑；关闭后恢复键盘位置与当前缩放。旧额度控制清单已删除。
- 复用 Windows 设置页的冷白底、石墨文字、鼠尾草绿强调色、单列设置、细分隔线及 160×166 键盘预览。点击预览中的命令键进入下一层，编辑期间不执行键盘动作。
- 布局包含 60%–105% 尺寸、重置布局、拆分语音键；交互包含最近任务 / 优先级排序、旋钮模式与方向、单击聚焦 Codex、置顶。preview.25 优先级排序读取完整本机候选后取前 14 项，鼠标交互期间继续固定键位身份。
- 当前信息显示对话标题、可点击复制的完整 ID、模型名称 / 原始 ID 和推理强度；按证据区分前台对话和手动所选对话。新草稿没有持久会话 ID，显示 `—`。
- 快捷模型 A/B 分别选择模型与思考强度，使用实时模型目录；目录不可用时保留已存值并禁用选择。连接区显示目录和所选会话的连接状态，并可刷新。
- 审批浮层复用设置页字体、颜色、分隔线和按钮，保留完整请求详情与精确请求校验，不在设置页重复审批操作。
- 键帽库支持搜索、33 个独立矢量图案及空白键；编辑先复制有效动作，选择不同键帽时自动改为对应默认动作，之后可另选命令或已有 Skill。再次打开编辑器或点击同一键帽保留自定义动作；空白键清除旧动作。保存一次提交本机覆盖，取消 / Esc 丢弃草稿，单键可恢复默认。
- Mac 设置使用本机 UserDefaults，不改写 Codex 配置。没有本机覆盖时继续读取 Codex 的键位与拆分语音键配置。自定义任务映射见 preview.23，本机现代固定任务见 preview.24；未接入的实时语音和 Windows 专属选项不显示为空控件。

AgentController 的手柄输入和驱动仿真保持独立。

## 构建与交付

从本仓库根目录执行，需要完整 Xcode 16+：

```sh
swift build --package-path apps/macos
python3 scripts/generate-macos-project.py
scripts/package-macos.sh universal
scripts/package-macos-plugin.sh universal
```

也可将 `universal` 改为 `arm64` 或 `x86_64`。脚本不启动 GUI、不安装、不发布。要保留正在使用的旧包，给两个脚本同时传第二个参数，例如 `scripts/package-macos.sh universal preview.34` 和 `scripts/package-macos-plugin.sh universal preview.34`；输出改为 `dist/macos/preview.34/universal/`。

Xcode 与打包默认使用 `Packaging/Signing.xcconfig` 的 Apple Development 身份。先在 Xcode → Settings → Accounts → Manage Certificates 创建证书。需要指定团队或证书时，在忽略的 `apps/macos/Packaging/Signing.local.xcconfig` 中设置 `DEVELOPMENT_TEAM` 和 `CODE_SIGN_IDENTITY`。打包脚本读取实际 Xcode 签名配置；也可用第三个参数或 `MICRO_CODE_SIGN_IDENTITY` 指定证书名称／SHA-1。多个匹配证书会拒绝自动选择。主程序与桥接使用同一身份，不创建证书、不修改钥匙串、不自动授权。

开发与分发签名可能具有不同身份，应分别授权。仅用于构建验证的临时签名需显式执行 `scripts/package-macos.sh universal preview.34 -`；这不解决跨构建的辅助功能授权。程序缺少授权时，使用“权限配置”打开 macOS 辅助功能设置，把浮窗中的实际运行程序拖入列表并开启开关；如果旧条目已开启但仍未授权，移除旧条目后重新拖入。浮窗自动检测实际授权，必要时重启 Micro。“稍后配置”不永久关闭后续权限恢复引导。库选型及状态边界见[权限引导调研](../../docs/architecture/macos-permission-setup.zh-CN.md)。

产物：

- `dist/macos/universal/Codex Micro Monitor.app`
- `dist/macos/universal/codex-micro-macos-preview.zip`
- `dist/macos/universal/codex-micro-keypad-macos.zip`

签名类型由实际构建参数决定，脚本不执行公证。Mac 插件 ZIP 与 Windows 包保持相同的 marketplace 根结构，包含 `.agents/plugins/marketplace.json` 和 `plugins/codex-micro-keypad/`；打包时复制产品拥有的插件源、嵌入完整应用并生成平台对应的 `mcp.json`，保留插件身份，不把源码中的 Windows MCP 入口改成 Mac 路径。解压后可将包含 `.agents` 与 `plugins` 的目录传给 `codex plugin marketplace add <绝对路径>`。

可执行入口 `Contents/MacOS/CodexMicroMac` 支持 `--version`、`--capabilities`、`--mcp`、`--export-design <目录>`。MCP 模式不创建 Catalyst 窗口。GUI 与 MCP 都调用 `DesktopBackend`，已有会话使用 `CodexClient`，前台操作使用 `MacUIController`。

## 验证记录

构建环境：macOS 15.5、arm64、Xcode 16.3、Swift 6.1。原生 Debug、Catalyst Universal Release、Info.plist 和嵌套签名检查通过。Swift / Xcode 构建成功不等于控件或会话写入已验收。

preview.34 使用本机有效的 Apple Development 证书（团队 `6ZBP55CAH3`）完成 Universal Release 打包及原生签名 Debug 构建。主程序与 MicroDesktop 桥接均通过深层严格签名检查；Debug 与 Release 的代码哈希不同，但各组件的 designated requirement 相同，均不再使用临时 cdhash 身份。应用 / 插件 ZIP 完整性、plist、脚本语法与 15 个插件源文件同步检查通过。本次没有安装、启动新版 GUI 或执行真实 Codex UI 验收；辅助功能权限仍须用户授权实际运行的新程序。

preview.34 执行了既有的 352 项 Swift 测试：351 项通过，`PanelScenarioTests.testVisibleFallbackOnlyBeforeNativeAuthorityHasBeenObserved` 的两条断言失败，因为它仍要求把唯一 IPC following 候选设为当前目标。preview.34 主动取消该回退；本次未修改或补写测试，完整测试结果仍记为失败，日志为 `apps/macos/.build/preview.34-tests.log`。

preview.7 时完整包的 MCP initialize / tools/list 通过，29 个工具可枚举。只读联调读取到当前账号 8 个模型、100 条最近会话、匹配的未读桶及 14 个灯光观察目标。首次持续观察发现未打开会话的 owner 查询导致订阅反复断开；修复后连续 14 秒、7 次采样均为 `streamConnected=true`，3 个桌面 owner 持续订阅，16 个文件被监听，运行态保持正确，stderr 为零。`refreshAgeMs` 为 0–982 ms；这只是内存状态年龄，不是事件到屏幕的端到端延迟。

离屏导出使用正式 UIKit 绘制代码，在 `UIApplicationMain` 之前运行，不创建窗口或 Codex 连接。已检查整机浅色 / 深色图及全部 34 个图标的 60% / 75% / 100% / 105% 图标表，并输出 `glyph-metrics.json`；preview.7 的四档最长可见边分别为 24 / 24 / 28 / 29.4 点；preview.8 已取消该下限放大，当前值见上方「图标与原生界面」，中心一致。图中的状态为示例。图标生成器不调用图像生成模型，不修改矢量来源。

私有协议静态基线：本机 Codex `26.930.31730`（12947）的 App Server schema 和 owner/follower 定义。公开接口依据 [App Server 文档](https://learn.chatgpt.com/docs/app-server)。Mac AX 属性依据 [Chromium 实现](https://chromium.googlesource.com/chromium/src/+/e102d7cb9bd8a6b610ca361cd9f07a7d434e9af6/ui/accessibility/platform/ax_platform_node_cocoa.mm)及 Apple ApplicationServices；属性缺失时拒绝猜测目标。

preview.9 对照最新 `origin/main`（4429ffe）的 Windows MIND 绘制与动作解析，并静态核对当前 Codex 安装包里的显示名与强度标签。离屏导出包括真实设置页、键位编辑器和 MIND± 静止 / 悬停终态，使用隔离偏好和示例数据、不启动观察或创建窗口；仍输出四档图标尺寸。构建和导出不证明真实点击与 Codex 写入通过验收。

preview.9 的 Universal Release、深层签名、plist、本地化文件、两个 ZIP 的完整性与 15 个插件源文件同步检查通过。中英文设置和编辑器离屏检查通过，34 个绘制状态在四档缩放下最长可见边分别为 14.4 / 18 / 24 / 25.2 点。Windows 共享控制层 `CodexUiComposerModes` 同样从 `keybindings.json` 读取草稿的 MIND± / Fast / Plan 快捷键，缺少绑定时不发送；这项前置条件不是 Mac 独有。

preview.10 补入独立的桌面可见会话订阅与当前操作目标的设置订阅。已有会话即使不在最近 14 个灯光位或 100 条目录页内也保留精确订阅；账号变化、失去自动目标或多个可见窗口无法唯一识别时清除旧的自动目标。手动选择按实际所选目标标注，不将它冒充前台对话。模型 / 强度从订阅更新，额度面板后台刷新不再用省略号遮住已有型号，强度环按当前模型目录的档位绘制。

preview.10 的 Universal Release、深层签名、plist、本地化文件、应用 / 插件 ZIP 完整性及 15 个插件源文件同步检查通过。离屏检查覆盖中英文当前信息区、完整 ID 单行复制入口、设置与编辑器；MIND± 四档尺寸见上方。示例 ID / 型号仅用于离屏排版，不是实时联调结果。

preview.10 阶段未新增测试套件或执行真实 UI 手动测试，未恢复旧 stash，未安装插件、提交或推送；本次 preview.11–13 的授权测试见上方场景对照。真实前台导航、草稿设置、发送 / 停止 / 审批、Skill / Sketch、休眠恢复与多显示器仍待可用的 Codex UI 联调通道验收。

## 维护入口

- `Sources/MicroCore/`：App Server、owner IPC、有界本地状态、独立活动监听。
- `Sources/MicroDesktop/DesktopBackend.swift`：GUI / MCP 共用分派；`MacAccessibility.swift`、`MacUIController.swift`、`MacShortcut.swift`、`MacSkillClipboard.swift`：原生目标、动作、快捷键和剪贴板保护。
- `Sources/CodexMicroMac/MicroModel.swift`：观察生命周期、目标代次、操作串行化；`MicroView.swift`：键盘、弹出控制与单请求审批。
- `SettingsView.swift`：设置层、键盘预览与键位草稿编辑；`Settings.swift`：本机偏好。
- `KeycapGlyph.swift`：可见轮廓尺寸；`DesignExport.swift`：离屏验收；`scripts/export-macos-artwork.py`：矢量源码生成器。
- `plugins/codex-micro-keypad/`：插件权威源；`scripts/sync-plugin-source.py` 单向同步到分发仓库。
