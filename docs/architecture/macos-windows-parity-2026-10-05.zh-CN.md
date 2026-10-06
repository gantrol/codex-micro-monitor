# Mac / Windows 场景对照 · 2026-10-05

本轮结论：Mac 存在与 Windows 已修问题相同的风险，尤其是实时文档地址没有参与当前 ID 识别、离开对话后继续采用旧的 IPC 可见 ID、换键帽保留旧动作、连续 Fast 输入丢失。对应代码已修复，最新交付为 `1.0.0-macos-preview.32`。本报告区分已实现、隔离验证和真实 Codex 验收；没有把图标存在或夹具应答计为真实功能通过。

## 更新与基线

| 仓库 | 本轮拉取的远端 main | 处理 |
| --- | --- | --- |
| `codex-micro-monitor` | `4429ffe` | 合并到本地产品分支，合并提交 `dab94e1`；保留已有 Mac 改动 |
| `codex-control` | `775e9f9` | 已是最新；作为 Windows 共享控制实现参照 |
| `codex-plugin-micro-keypad` | `e4fbb40` | 合并提交 `9684e94`；保留本地源码归属说明及插件草稿 |

最新 fetch 的新增产品提交仅修改文档，但这不代表 Windows 没有功能修复。相对于旧审查点 `58b0244`，Windows 修复已包含在 `639e23f` 发布源码中；本轮以当前源码重新对照。未恢复或删除既有 stash，未初始化根目录 Git，未更改独立 AgentController 源码关系。

Windows 主要依据：`CodexSelectedThreadReader.cs`、`CodexDraftModelToggleService.cs`、`KeycapEditorWindow.xaml.cs`、`SoftwareMicroTransport.cs`、`MainWindow.Software.cs`，以及控制仓库的 `CodexUiComposerModes` 和 `KeypadController`。当前 Windows 编辑器已在选择不同键帽时选择默认动作，Mac 旧行为落后于该实现。

## 当前对话 ID 与目标切换

**2026-10-05 用户反馈后的更正：** preview.32 的“新建后旧 ID 退役”验证不完整。补上导航结束后的旧原生/IPC 连续轮询，以及原生读取失败和两秒过期后，首批 7 个回归用例中 6 个失败，共 40 处断言失败，旧 ID 还会重新获得控制目标。本次源码加入导航等待和原生身份优先权，并采用已确认草稿响应；11 个生命周期回归和完整 345 项 Swift 测试通过。当前运行的旧包尚未更新。下表原有组件通过不能作为真实新建链路已正确的结论。完整数据来源、缺陷时序和状态机见 [Mac 当前会话 ID UML](macos-current-conversation-id.zh-CN.md)。

证据缩写：**规则**＝Swift 局部解析；**组件**＝真实 MicroModel / Settings 与受控 Desktop 边界；**进程**＝安装包及真实原生桥接与受控 App Server / IPC；**界面**＝真实隔离 Micro 窗口，外部桥接替换为夹具；**原生回放**＝正式 MacUIController（N14 同时运行 MicroModel），仅替换操作系统边界；**源码**＝静态核对，尚未完成该路径运行验收。各层互不代替。

| 场景 | Windows 当前实现 | Mac 发现与修复 | 证据 |
| --- | --- | --- | --- |
| 启动时侧栏收起，当前对话不在最近列表 | 读取 Document 的实时 `IValuePattern` 地址 | 新增 WebArea 实时地址；不依赖标题或列表位置 | 规则、组件 |
| 两个对话同名 | 有实时 ID 则使用 ID；标题回退只接受唯一匹配 | 按精确 UUID 建立目标，同名不会混淆 | 规则、组件 |
| AXURL 为空，实时路由位于 AXValue | Windows 直接读 Document Value | 同时读取 AXURL、AXValue、AXDocument；空值不遮蔽有效值 | 规则；实际 AX 属性兼容性待验收 |
| bootstrap URL 带旧 `initialRoute` | 实时采集排除启动路由 | 忽略 index / detached bootstrap；不从 query 恢复旧 ID | 规则 |
| 对话 A 返回主页或设置页 | 已知非会话路由清除旧选中 | `selectionKnown` 显式否定旧目标，同时阻止 IPC 可见状态恢复 A | 规则、组件 |
| 首页但没有输入框 | 不能仅凭 ID 为空认定草稿 | 要求 home 容器与 composer 证据 | 规则 |
| 新建草稿，原对话仍被 IPC 订阅 | 新草稿退役旧 ID | 清除旧 ID；草稿不显示伪造持久 ID | 组件 |
| 两个草稿都没有持久 ID | 验证具体原生输入框身份 | 用原生 target token 区分，旧捕获动作失效 | 组件 |
| 路由指向 A，选中侧栏指向 B | 实时路由优先，原生操作另有身份检查 | 保守拒绝冲突，不选其中之一 | 规则 |
| 多个顶层实时文档路由冲突 | 拒绝不唯一地址 | 明确记录 conflict，禁止可见 ID 回退 | 规则 |
| 嵌入网页包含 `/local/<UUID>` | 仅接受 `app://-` 路由 | 排除嵌套 WebArea、外部网址、松散路径和非完整 UUID | 规则；树过滤为源码检查 |
| 原生路由不可读，但 IPC 仅一处可见 | 原生或精确上下文机制 | 本次改为仅在当前账号/生命周期尚未取得原生身份时接受唯一候选；曾有原生身份后读取失败或过期保持未知 | 组件；不代表前台焦点证明 |
| 点击后、写入前切换 A→B | 执行前重验目标版本 | 每次 IPC 写入前重新读取前台或唯一可见 ID | 组件 |
| A→B→A 后执行旧动作 | 原动作版本已过期 | selectionVersion 使旧捕获动作失效 | 组件 |
| 没有 ID，但可确认原生 composer | Windows 可对确认的原生输入框执行部分设置 | preview.12 已补齐：要求唯一选中侧栏项、同一窗口、输入框及模型选择器；原生设置不携带 thread_id | 规则、组件及隔离界面通过；真实 AX 身份仍待验收 |
| 原生 composer 变成另一个 composer、草稿或精确对话 | 原生身份或版本重验 | 令牌变化退役旧动作；变为草稿不虚构 ID，取得精确 UUID 后恢复 IPC | 组件通过 |
| 无 ID 且未配置原生设置快捷键 | 产品模型选择器使用 Power 原生控件；共享模式入口读取快捷键 | preview.14 改用观察到的 Power / Speed / Plan 控件；不再整体禁用，不改走旧 IPC ID | 原生回放通过 |
| 无 ID 原生设置目标按发送、审批、Stop、Fork 或 Review | 精确会话动作仍有身份门禁 | 保持禁用；显示当前输入框，复制 ID 禁用 | 组件覆盖全部门禁；隔离界面验证发送、审批、Fork 零派发 |

Mac 实现入口：`MicroCore/CurrentRoute.swift`、`MicroDesktop/MacAccessibility.swift`、`CodexMicroMac/MicroModel.swift`。不从标题、日志最后一个 ID、启动 query 或外部浏览器地址猜当前对话。

## 控制与反馈

| 场景 | 本轮处理 | 验证结果及边界 |
| --- | --- | --- |
| Fast 连续六次 | 按同一目标串行执行，每次用上次回读状态决定下一次 | 组件、进程通过；六次恢复原档位 |
| Fast 前几次操作很慢 | 排队预算从 5 秒改为 Windows 的 60 秒 | 组件用独立时钟模拟每次 10 秒，六次通过；超过预算取消余项 |
| Fast 期间换对话、失败或关闭 | 取消后续输入，不自动补发 | 组件通过 |
| Fast 中英文速度标签 | 增加英文、简体、繁体及分隔符处理；冲突值保持未知 | 规则通过 |
| 原生 Fast 需要模型菜单读值 | 三档速度逐次回读，菜单关闭后重新打开；在相同目标上清理菜单 | N03 / N04 / N17 / N18 原生回放通过 |
| Plan 往返 | 精确目标与原设置检查；保留 model / effort | 进程通过 |
| 模型、推理强度 | 验证目录与支持档位，回读结果；上下限不发送多余写入 | 组件、进程通过 |
| Fast / Plan / MIND± 混合快速按键 | 三类按键共用目标队列，每次根据上次回读决定下一步；强度触顶不重复写入 | 组件通过；混合顺序、切换目标取消、草稿令牌更新均覆盖；连续旋钮手势仍采用合并输入 |
| Codex 在后台时按提交 | 第一按仅激活，即使空输入也可激活；前置检查决定只激活后，不因后续焦点改变升级为发送 | 组件通过；真实焦点与输入框路径待验收 |
| 从 Codex 点击 Micro 按提交 | 记录最近外部前台进程，Micro 自身获取前台不清除 Codex 来源；避免每按一次都只激活 | 焦点转换规则通过；其他应用介入、未知焦点及 Codex 进程变更均不会授权发送 |
| 发送 / 重复发送 / 停止 | 发送一次、拒绝未确认重复；按精确 turn ID 停止 | 进程通过，使用夹具文本及回合 |
| 命令审批、文件审批：同意与拒绝 | 精确 request ID 和请求内容，拒绝过期重放 | 四个进程场景通过 |
| 没有审批仍按 APPR / REJ | 首轮隔离 UI 发现空浮层；修复展示与动作准备门禁 | 真实隔离 UI 复验通过；无浮层、无派发 |
| mutation 应答丢失 | 结果未知，只读回，不重发原请求 | 进程通过，写入次数保持一次 |
| Fork 缺少 `deferGoalContinuation` | 创建前拒绝 | 进程通过；成功创建与真实导航未验收 |
| Skill 绑定 | 保留精确 skill name / path，路由到插入，不发送 | 组件通过；真实 mention 回读未验收 |
| 会话滚动旋钮短按 | 改为滚到底部，避免误切模型 A/B | 组件通过；原生滚动待验收 |
| 右键任务标未读 | 新增 exact row → IPC v3；按当前账号与本机 host 回读文件 | 组件、进程、隔离界面通过；出现 Unread 和绿灯 |
| 未读文件中当前账号 / host 桶缺失 | 有效现代结构下视为空集合；损坏结构保持未知 | 规则、进程通过 |
| Review | 现有深链打开与可见结果检查 | 隔离 UI 路由通过；Windows / Mac 均未实现关闭往返 |

## 每个可见备选键帽

以下 34 行在 preview.11–13 均经过实际隔离 Micro 编辑器的「搜索 → 选择 → 校验动作 → 保存 → 按压」。preview.14–18 新增功能另用组件及正式控制器回放验证，旧 UI 禁用记录不能证明新功能可用。**有通道**仅表示实现存在；真实 Codex 业务验收仍未运行。**未接入**行验证的是按压零派发及不继承旧的发送动作，不算功能成功。

| 键帽 | 默认动作 | Windows / Mac 支持及本轮结果 |
| --- | --- | --- |
| FAST | `composer.toggleFastMode` | 两端有通道；界面派发正确，组件与进程回读通过 |
| APPR | `approval.approve` | 两端有通道；空审批不弹窗，组件及进程精确请求通过 |
| REJ | `approval.decline` | 两端有通道；空审批不弹窗，组件及进程精确请求通过 |
| SPLIT | `forkThread` | 两端有通道；界面派发正确，进程验证缺 guard 时拒绝 |
| MIC | `dictation.pushToTalk` | Windows 未接入；Mac 原生听写条件可用，界面派发正确 |
| MIC1 | `dictation.pushToTalk` | 同 MIC；独立键位派发正确 |
| CODEX | `composer.submit` | 两端原生输入框通道；隔离界面派发正确 |
| SKETCH | `composer.sketch` | 两端原生菜单通道；隔离界面派发正确 |
| MIND+ | `composer.increaseReasoningEffort` | 两端有通道；界面、组件及进程通过 |
| MIND- | `composer.decreaseReasoningEffort` | 两端有通道；界面、组件及进程通过 |
| EMPT1 | 未分配 | 清除旧动作，按压零派发 |
| APPS | `openSkills` | Mac preview.14 已接入 `codex://skills`；独立键帽派发、固定深链和精确路由回放通过 |
| BRANCH | `git.createBranch` | Windows 未接入；Mac preview.18 调用原生命令并确认分支创建表单；G01 / G03–G06 覆盖 |
| BRCH | `git.createDraftPullRequest` | Windows 未接入；Mac preview.18 调用原生草稿 PR 命令；核对表单中草稿动作已选中，不提交 |
| BUG | `feedback` | Windows 未接入；Mac preview.17 打开原生反馈表单；T13 / T14 验证特定表单，不填写或提交 |
| DEL | `archiveThread` | Windows 未接入；Mac preview.15 原生归档并保留确认；T05 / T06 与只读归档列表进程场景覆盖精确回读 |
| DIFF | `toggleReviewTab` | 两端目前只打开 Review；隔离界面派发正确 |
| DWN | `copyConversationMarkdown` | Windows 未接入；Mac preview.15 原生复制；T02 / T03 覆盖 Markdown 格式、成功通知及并发复制保护 |
| FOLD | `openFolder` | Windows 未接入；Mac preview.13 已实现。精确对话记录读取 cwd；真实 Finder 打开隔离目录通过，真实对话目标仍待验收 |
| GIT | `git.commit` | Windows 未接入；Mac preview.20 打开原生提交／推送或前置分支表单，核对当前阶段；不提交 |
| LAB | `settings` | Mac preview.14 已接入 `codex://settings`；打开 Codex 自身设置，派发与页面回读测试通过 |
| MAGIC | `toggleThreadPin` | Windows 未接入；Mac preview.15 原生菜单置顶 / 取消置顶；T01 / T04 覆盖往返及切换目标取消 |
| MRG | `git.mergePullRequest` | Windows 未接入；Mac preview.21 打开原生合并确认并回读方法，不执行最终合并，不伪造 PR 身份 |
| NAV | `openBrowserTab` | Windows 未接入；Mac preview.16 原生浏览器命令；T10–T12 覆盖新页身份、旧页不能代替新建、目标变化 |
| NEW | `newTask` | 两端有通道；隔离 UI 保存、重启、按压仍正确 |
| OAI | `developers.openai.com` | Windows 未接入；Mac preview.13 已实现。无需对话 ID；实际默认浏览器 URL 验证通过 |
| PAINT | `composer.addPhotos` | Windows 未接入；Mac preview.21 通过照片菜单项或已配置专用快捷键打开 Select photos；不选文件、不借用 Files |
| PARTY | `openSideChat` | Windows 未接入；Mac preview.17 在精确父对话创建侧边聊天；T15 / T16 核对新页和可用输入框，不伪造子对话 ID |
| PLAY | `environmentAction1` | Windows 未接入；Mac preview.19 从原生 Project 命令组选配置首项；精确终端交接回读，执行完成未验证 |
| PR | `git.createPullRequest` | Windows 未接入；Mac preview.18 调用原生普通 PR 命令；与草稿 PR 分开回读，不提交 |
| SETUP | `settings` | Mac preview.14 同样打开 Codex 设置；此键帽独立验证默认动作、保存与按压 |
| TERM | `toggleTerminal` | Windows 未接入；Mac preview.15 原生终端命令；T08 / T09 覆盖打开 / 关闭与多终端可见性 |
| TIME | `manageTasks` | Windows 未接入；Mac preview.16 打开 Codex 任务管理页；精确路由及独立键帽保存 / 派发回放通过 |
| UPL | `composer.addFiles` | Windows 未接入；Mac preview.17 打开原生 Files and folders 选择器；F01–F05 验证交接，不代表附件添加完成 |

preview.21 已接入全部 33 个可见命令键帽，空白键保持零派发。原生入口仍受当前上下文、控件或专用快捷键配置限制；未知结果不自动补发。Mac 可保存配置并在条件不满足时禁用或拒绝执行；Windows 编辑器直接阻止保存未支持动作，这是保留的配置层差异。

preview.22 补齐 EMPT2–5、YOLO、YEET 后，Mac 图标库包含全部 40 个目录 ID：33 个命令默认、5 个空白、2 个固定预置文本。YOLO / YEET 写入 `:yolo:` / `:yeet:`，不触发发送或权限变更；更换为空白键清除旧动作。各项换绑和保存均经组件验证，原生文本插入另有 C01–C12 回放。

此外覆盖全部 8 个稳定命令槽位（包括合并 / 拆分语音槽）的保存、重新加载和实际路由；显式自定义动作重新打开后不变，选择不同键帽后重置；Esc 取消不落盘，拆分 / 合并不丢绑定。主键盘名称及提示依据实际动作，不用键帽 ID 冒充功能。

## 验证记录与交付

| 层级 | 结果 | 可复现入口 / 记录 |
| --- | --- | --- |
| 规则、组件与原生回放 | 316 tests，0 failures | `swift test --package-path apps/macos`；`apps/macos/Tests/MicroCoreTests/` |
| 原生流程日志 | N01–N19（N19 含中英文） | `dist/macos/parity-native-settings-replay.jsonl`、`parity-swift-tests.log` |
| 会话菜单 / 面板日志 | T01–T16，24 条流程记录 | `dist/macos/parity-thread-menu-replay.jsonl`；25 个测试，不含真实剪贴板内容 |
| 附件选择器日志 | F01–F15，28 条流程记录 | `dist/macos/parity-file-picker-replay.jsonl`；16 个测试，只验证文件／照片选择器入口 |
| Git 表单日志 | G01–G20，80 条流程记录 | `dist/macos/parity-git-workflow-replay.jsonl`；21 个测试，尚未实际提交、推送、创建或合并 |
| 环境动作日志 | E01–E07，19 条流程记录 | `dist/macos/parity-environment-action-replay.jsonl`；7 个测试，仅确认原生执行交接 |
| 固定文字日志 | C01–C12，40 条流程记录 | `dist/macos/parity-preset-text-replay.jsonl`；12 个测试，不发真实键盘输入 |
| 自定义任务映射 | R01–R11，11 条流程记录 | `dist/macos/parity-task-mapping-replay.jsonl`；另有 6 项目录规则测试和 P18–P21 进程场景 |
| 固定任务来源 | S01–S08，8 条流程记录 | `dist/macos/parity-pinned-task-replay.jsonl`；另有 7 项目录规则与 P22–P25 进程场景 |
| 优先级任务与活动流 | Q01–Q09，9 条流程记录 | `dist/macos/parity-priority-task-replay.jsonl`；另有 10 项规则与 P26–P31 正式进程场景 |
| 灯态与前台未读显示 | L01–L09，9 条流程记录 | `dist/macos/parity-task-lamp-replay.jsonl`；P32 正式 IPC 六步切换 |
| 自定义任务命令 | U01–U15，15 条流程记录；46 项命令派发 | `dist/macos/parity-task-command-replay.jsonl`；U14 含正式模型到原生控制器 |
| 固定项目混排 | V01–V14，14 条流程记录 | `dist/macos/parity-pinned-project-replay.jsonl`；13 项规则、1 项正式模型及 P33–P39 进程场景 |
| 客户端路由与 host 范围 | W01–W13，13 条流程记录 | `dist/macos/parity-client-route-replay.jsonl`；7 项规则与 6 项正式控制器／模型测试 |
| 正式桌面派发入口 | X01–X06，6 条记录；N14／U14／W08 扩展入口覆盖 | `dist/macos/parity-desktop-backend-replay.jsonl`；另保留修复前失败日志 |
| 客户端与正式 UUID 关联 | Y01–Y13，13 条记录 | `dist/macos/parity-client-binding-replay.jsonl`；P40–P45 正式包进程场景 |
| 热键与项目草稿 | Z01–Z11，11 条记录 | `dist/macos/parity-draft-route-replay.jsonl`；6 项规则／AX 投影及 5 项正式桌面回放 |
| 全部键帽离屏绘制 | 40 个键帽及 FAST_ON 状态，164 项尺寸检查 | `tests/macos/design_e2e.py`；`dist/macos/parity-design-e2e.json` |
| 设置 / 技能 / 任务管理页 | 3 个固定深链与精确路由 | `dist/macos/parity-page-replay.jsonl`；系统打开边界回放 |
| 安装包进程 E2E | 45 scenarios 通过 | `tests/macos/process_e2e.py`；`dist/macos/parity-process-e2e.json` |
| 隔离 Micro UI | 34 可见键帽 + 空审批修复复验、未读、Esc、重启持久化 | `tests/macos/prepare_ui_fixture.py`、`ui_journey.cua.js`；`dist/macos/parity-ui-e2e.json` |
| 实际派发记录 | 与预期操作序列一致；未支持项零派发 | `dist/macos/parity-ui-actions-first-run.jsonl`、`parity-ui-actions-final.jsonl` |
| 无 ID 隔离 Micro UI | 当前输入框 / 无可复制 ID；Fast → Plan → MIND+ 回读 high；发送 / 审批 / Fork 零派发 | `dist/macos/parity-native-composer-ui.json`、`parity-native-composer-actions.jsonl` |
| OAI / FOLD 系统打开 | 正式路径校验及系统打开逻辑；真实 Chrome URL 与 Finder 隔离目录通过 | `dist/macos/parity-workspace-ui.json`、`parity-workspace-actions.jsonl` |
| Universal Release | 主程序、桥接 arm64 / x86_64 | `dist/macos/universal/Codex Micro Monitor.app` |
| 应用 / 插件 ZIP | 本地预览交付，未安装或发布 | `dist/macos/universal/codex-micro-macos-preview.zip`、`codex-micro-keypad-macos.zip` |
| Windows 构建 | 未运行；本机无 dotnet | 不引用本轮 Windows 运行通过率 |
| 真实 Codex 联调 | **未运行** | 用户要求不再访问，改用源码及 E2E 日志推进 |

原始拒绝信息：`Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.` 未改用另一条 UI 通道绕过限制。没有向真实对话发送消息、审批、停止或测试未读写入。

隔离界面的替换桥接只存在于 `/tmp/micro-ui-e2e-*` 复制应用中；正式 ZIP 包含真实 MicroDesktop。UI 验证早于最后的设置队列及提交焦点修正；随后重新跑规则 / 组件与进程 E2E，并重新打包。后续改动由慢回读 / 过期、混合输入、草稿令牌更新、焦点转换及空输入提交门禁场景覆盖，不将先前 UI 检查表述为最终包的完整真实联调。

preview.12 的无 ID 回退已单独跑过隔离 UI：正式 MicroModel 和 UIKit 通过替换桥接收到无 ID、唯一原生目标状态，按钮派发日志只包含三条原生设置操作，全部带 `native_composer=true`，均无 `thread_id`。已知非会话 / 冲突路由、令牌替换和模式切换由新增规则 / 组件场景覆盖。没有用夹具代替真实 AX 采集验收。

preview.13 对 OAI / FOLD 重新执行编辑、默认动作切换、保存和实际按压。OAI 不要求当前对话或 Codex 连接；FOLD 按精确 UUID 读取 `thread/read.cwd`，缺失、非绝对路径、不是目录或目标切换均拒绝。系统拒绝不重试。通用打开改为 Finder 专用路径，避免 cwd 恰为应用包时执行它。按钮结果只报告 `launch_requested`；本轮通过 CUA 独立核对浏览器最终 URL 和 Finder 标记文件，不靠该返回字段自证。夹具仅替换对话目录来源，正式安装包不包含夹具。

剩余验收应逐项在允许的真实 Codex 环境中运行：AX 实时路由属性及无 ID 原生身份、后台首按激活、草稿模式和菜单清理、Skill mention 回读、听写 / Sketch、滚动 / 导航、成功 Fork 及 Review 可见结果。可见命令键帽的派发通道已补齐，已实现通道的实际原生行为与最终业务结果仍待逐项验证。

## preview.14：新会话、模型与操作映射

本次再次 fetch 三个远端，基线未变化。重点对照 Windows 产品层 `Services/CodexDraftComposerModelSelector.Context.cs`、`.Observation.cs`、`.Reasoning.cs` 与模型选择主流程，以及共享控制层 `CodexUiComposerModes.cs`。只看共享模式的快捷键入口会遗漏产品层 Power 原生控制，这是先前结论的不足。

只读检查本机安装包静态资源：命令定义中 Fast 的含义已是 Standard / Fast / Ultrafast 三档循环；四个草稿模式命令没有默认绑定，本机也未配置这四个绑定。Power 为可聚焦控件，包含模型 / 强度 / 位置总数的可访问播报并处理左右箭头；Plan 徽标可退出模式，新增候选列表使用“Plan mode / 计划模式 / 計劃模式 / 規劃模式”。这些是静态证据，不是读取真实 AX 树，也没有修改安装包或用户快捷键。

| 场景 | 旧 Mac 问题 / Windows 依据 | preview.14 与回放 |
| --- | --- | --- |
| N01 / N19：新会话无快捷键、触发器只写 Select model | Mac 依赖模型文本与快捷键，按钮不可用 | Plan 不依赖已知模型；识别原生菜单及新版候选列表；中英文回放，保持草稿原文 |
| N02：Plan 快捷键焦点 | Windows 先定位 composer；Mac 曾直接发送 | 先聚焦同一输入框并回读，再发送 |
| N03 / N04：Fast → Ultrafast | Bool 将两种速度折叠，变化无法确认 | 保留三档状态，菜单或快捷键路径都逐次回读 |
| N17 / N18：指定关闭 Fast、菜单自动收起 | 一次循环可能只到 Ultrafast；关闭后通用触发器无读值 | 每次确认后继续到 Standard；必要时重开 Speed 读取 |
| N05 / N06 / N12：MIND± | Windows Power 原生强度路径无需用户快捷键 | 按目录校验播报位置与总数，使用范围值或聚焦后的左右键；中英文与最高档无多写 |
| N07 / N14：A/B 当前模型不可读 | 闭合触发器缺模型时猜 A/B 初值 | 打开 Power 读取真实初值后选择，N14 贯穿面板队列至原生控制器 |
| N08：模型支持集不同 | 组合请求可能部分写入 | 先验证目标模型支持请求强度，再换模型 |
| N09 / N15：Power 冲突或外部换模型 | 旧触发器 / 缓存不能授权写入 | 权威 Power 冲突拒绝；已验证结果最多短暂保留 15 秒，后续写入必须重开回读 |
| N10 / N11 / N13：目标切换、权限弹窗、缺菜单 | 与 Windows 一样保持精确目标 | 不向另一目标发键，不自动批准弹窗；只关闭自己打开且仍属于原目标的菜单 |
| N16：选择模型二级菜单，选择后关闭 | Windows 进入 Select model 子菜单并回读 | Mac 补齐二级菜单；关闭后重开 Power 核对目标模型与强度 |
| 白旋钮连续滑动、反向 | Mac 控制期间丢弃导航输入 | 同一原生目标排队及回读，反向保序、过期 / 切换目标取消 |
| 右键、滚轮、触控板 | 次要按钮可能进入主按压追踪 | 主控件拒绝次要按钮，菜单取消待定主按；6 点阈值 / 12 点档距 / 默认方向与 Windows 一致 |
| LAB / SETUP / APPS | Mac 未接入；安装包支持 settings / skills 深链 | 三键帽分别验证默认动作与保存后路由；指定 Codex 应用打开，页面回读与启动接受分开 |

操作映射详见 [Mac 操作映射](settings-interaction.zh-CN.md#mac-操作映射preview14)。本轮不访问 Codex UI；正式控制器回放、安装包进程测试与静态证据互相补充。实体触控板事件、实际 AX 属性及页面可见性仍没有现场验收证据。

## preview.15：会话菜单与终端

重新 fetch 三个仓库后基线未变。Windows 目录提供 TERM、MAGIC、DWN、DEL 的默认绑定，当前 Windows 执行器尚无对应通道，因此 Mac 根据本机 Codex 安装包中的实际命令、菜单和 schema 实现。仅读取静态资源，没有向 Codex 发送 UI 操作。

| 场景 | 静态证据与修复 | 回放 / 进程证据 |
| --- | --- | --- |
| T01 置顶 / 取消置顶 | 当前会话入口名为 Chat actions / 聊天操作；操作后重新打开，必须显示相反动作 | 中英文往返，重复入口及冲突状态不派发 |
| T02 Markdown 复制 | 使用 Codex 的 Copy → Copy as Markdown，不自行拼装对话文本 | 原生成功通知、新一次剪贴板写入和格式回读；输出只含字符数 |
| T03 复制期间外部写入 | 单次 changeCount 与新通知共同确认 | 两次写入保持未知，不恢复或覆盖其他程序复制的内容，不重试复制 |
| T04 菜单打开后 A→B | 菜单项目、窗口、路由和文本身份逐次重验 | 不置顶 B，也不发送 Esc 关闭 B 的菜单 |
| T05 归档需要确认 | 调用 Codex 原生 Archive，保留运行任务及工作树相关确认 | 确认仍显示，不自动接受，不以消失的菜单当作完成 |
| T06 归档后导航离开 | `thread/read` 核对 UUID，再按 `thread/list(archived=true)` 分页只读回查 | 同一 UUID 的 archived=true 才成功；延迟回读、ID 不匹配和未知均覆盖 |
| T07 输入框或模型选择器隐藏 | 当前会话菜单不依赖 composer 可见性 | 仅有精确会话和 Chat actions 入口仍能置顶、复制 |
| T08 TERM 打开 / 关闭 | 原生应用菜单 Open Terminal 控制 Codex 内终端面板 | 唯一菜单命令身份、同一会话、可见终端页数量变化；不发送猜测的快捷键 |
| T09 多终端、零尺寸输入节点 | xterm helper textarea 本来就是零尺寸；可见性取外层 app-shell-tab-panel | 两个面板关闭一个、隐藏面板、无 composer、缺菜单与切换目标均覆盖 |
| P13 / P14 归档只读查询 | 当前 App Server schema 支持 archived、游标和 useStateDbOnly | 跨页精确结果；超过 1000 条保持未知；重复 / 非法游标拒绝，不发送归档写入 |
| 四个键帽的保存与按压 | 更换键帽自动采用对应动作 | TERM、MAGIC、DWN、DEL 分别检查精确 ID / 令牌；归档成功清除旧目标和列表 |

复制不会读取或恢复用户的原剪贴板；日志不记录复制出来的对话文本。原生菜单兼容性、实际终端页 AX 暴露及归档最终业务行为仍需允许的真实环境验收。

## preview.16：浏览器页与任务管理

| 场景 | 实现依据与行为 | 验证 |
| --- | --- | --- |
| T10 NAV 新增浏览器页 | 安装包的 Open Browser Tab 命令调用内置浏览器；用 app-shell 页身份和原生地址输入框回读 | 中英文；已有一个浏览器页后再建新页；输入框隐藏仍保留精确会话 |
| T11 错误回读 | 旧浏览器页或无页面容器的同名地址输入框不能证明新建 | 各发出一次命令，结果未知，不补发 |
| T12 命令后换会话 | 终端 / 浏览器的后置观察允许 composer 隐藏，但必须仍属同一 UUID 和窗口 | 两种命令均拒绝确认另一会话的面板，且不重试 |
| TIME 任务管理 | 静态命令 manageTasks 跳转 automations；原生深链解析器支持 `codex://automations` | 打开接受与 `page:/automations` 回读分开；旧页、伪前缀和无确定路由不确认 |
| NAV / TIME 换键帽 | 选择时默认绑定 openBrowserTab / manageTasks | 独立保存和按压；NAV 携带精确 ID / 令牌，TIME 离开会话后退役旧目标 |

任务管理深链只进入原生管理界面，不创建、运行或修改计划任务。NAV 不导航任意 URL。安装包进程检查还核对新增工具的必填参数和非幂等声明；归档标记为可能破坏状态的操作。实际 Codex 浏览器 AX 树和系统接受深链后的真实页面仍未做现场验收。

## preview.17：反馈、侧边聊天与文件选择器

三个远端基线保持不变。Windows 的 BUG、PARTY、UPL 当前只有目录默认动作，执行器未接入。Mac 实现依据本机安装包中的原生菜单、命令处理和组件标签，没有执行安装包脚本或访问真实 Codex UI。

| 场景 | 实现与发现 | 证据及边界 |
| --- | --- | --- |
| T13 BUG 反馈 | Send Feedback 进入 Share feedback 表单；核对必填详情与 Feedback options 组 | 中英文及已知设置页无 composer 均可进入；不填写、改变上传选项或提交 |
| T14 错误反馈回读 | 其他模态窗口不能代替特定反馈表单；命令后转到另一目标不能确认 | 保留窗口，不发 Esc、不补发；缺少命令或写入前目标变化零派发 |
| T15 PARTY 侧边聊天 | 当前会话菜单中的 New side chat；已有侧边页不妨碍新增 | 同一父 UUID，新的 app-shell 页身份及可用输入框；返回父 ID 与面板 ID，不冒充子对话 ID |
| T16 旧页 / 加载中页 | 仅现有侧边页或新页没有输入框不能确认创建完成 | 结果未知，创建动作只发一次；缺入口只清理自己的菜单 |
| F01 UPL 文件选择 | 原生 Files and folders 打开独立 Select files 窗口；补齐港繁添加按钮标签 | 四种语言，无模型选择器仍可操作；模拟取消后恢复原对话和原文 |
| F02 新草稿添加文件 | 已确认主页草稿及输入框可打开文件选择器 | 不要求或伪造 thread ID |
| F03 缺少文件入口 | Codex 根据能力显示 Files and folders 或 Add photos，它们不是同一动作 | 缺少 Files 时不选 Photos；只收起自己打开的候选列表 |
| F04 / F05 目标与窗口歧义 | 添加菜单后换目标、无新选择窗口或多个新选择窗口 | 不向另一输入框输入，不自动补发，不关闭原生文件选择窗口 |
| 模态窗口遮蔽当前 ID | 选择器可能没有聊天路由；过去未知原生路由可能重新采用旧 IPC 可见 ID | 模态状态显式否定可用对话；面板测试覆盖后续轮询仍不恢复旧 ID |
| 三个键帽换绑 | BUG、PARTY、UPL 均自动采用其默认动作 | 保存后派发正确操作与目标；不沿用 CODEX 的发送动作 |

静态安装包的文件选择实现没有传父窗口；这与 [Electron 的 macOS 文件对话框实现](https://github.com/electron/electron/blob/main/shell/browser/ui/file_dialog_mac.mm)相符：无父窗口时以独立模态窗口运行。因此 UPL 读取同一 Codex 进程的新窗口身份，不要求它与原聊天 AXWindow 相同，也不遍历其中的用户文件。这里只确认选择器交接（`awaitingSelection=true`、`attachmentVerified=false`），文件实际选中和附件进入输入框仍未验收。preview.17 时 PAINT 尚未接入；preview.21 已补专用照片入口，仍不能用普通文件选择器替代。

## preview.18：分支、普通 PR 和草稿 PR

再次 fetch 后，三个仓库基线未变。Windows 当前只有三项目录动作，没有执行通道。本机 Codex 的 `local-conversation-git-actions` 注册了三个不同命令：分支命令要求适用的工作树并打开 Work here；普通 / 草稿 PR 分别打开同一创建表单并默认选择不同动作。不能把打开任意 Git 菜单当作完成，也不能点“Create draft PR”表单按钮来模拟“打开草稿 PR”命令——那个按钮会真正提交。

实现通过原生应用菜单 Open command menu 进入 Codex 命令菜单，限定全局命令菜单容器、精确本地化标题、唯一可用选项及同一窗口 / 对话；不猜快捷键，不输入搜索词或 Git 表单值。命令存在且打开后，必须读到预期表单，才返回 `workflowOpened=true`；返回 `mutationCompleted=false`，不宣称分支或 PR 已创建。

| 场景 | 行为与结果 |
| --- | --- |
| G01 BRANCH | 四种语言，输入框隐藏也可打开；核对 Work here、Branch name 和 Create；创建按钮不被按下 |
| G02 PR / BRCH | 四种语言，核对 `create-pr-title` / `create-pr-message` 及普通 / 草稿选项的真实选中态；两个命令不互相替代 |
| G03 命令缺失、禁用、重名 | 不选择备用命令；只关闭本次打开、仍属于原对话的命令菜单 |
| G04 A→B | 命令菜单打开后及选中命令后两阶段均重验 UUID；不确认 B 的表单，也不向 B 发 Esc |
| G05 错误结果 | 未出现表单、其他表单、普通 / 草稿默认选项不符均保持未知；只派发一次 |
| G06 权限弹窗 | 同时出现其他模态窗口时不继续操作，不关闭或接受权限提示 |
| 键帽与工具合同 | 三个键帽分别换绑、保存及派发；要求精确 thread ID / target token；安装包只枚举工具，不调用真实 UI |

GIT 的原生命令会按提交 / 推送条件选择行为，MRG 则先进入特定 PR 的合并界面，两者继续单独实现。PLAY 已定位到当前环境的动作注册及终端执行逻辑：`environmentAction1` 对应按平台过滤后的原始动作顺序，而主界面的 Run 按钮会按最近使用重排，不能直接点击它冒充第一个动作。还需把具体动作身份与运行回读接起来。上述发现均来自只读安装包静态资源；真实仓库最终创建结果没有被本轮回放证明。

本轮还修复回放证据输出：原先 stdout 的缓冲输出可能被 XCTest 诊断插入，造成 JSONL 记录截断。五类回放统一单次写入完整 JSON 行；重新运行全量测试后，77 条记录逐条解析并核对数量通过。

## preview.19：PLAY 配置动作与终端交接

Windows 仍只有 `environmentAction1` 目录默认值，没有执行通道。本机 Codex 静态资源表明，先按平台过滤配置动作，再按原始顺序注册 `environmentAction1` 等命令；工具栏 Run 按钮则会按最近使用排序。本轮使用未过滤的命令菜单 Project 组，选择配置首项，禁止借用 MRU 按钮。命令选择前再核对同一 AX 节点及其文本，避免菜单更新后点中变化的动作。

执行后要求同一窗口 / 对话中出现唯一可见的 `terminal-panel-environment-action:<thread>:<environment>:environmentAction1`，且所属 app-shell 面板可见并含 xterm 输入控件。允许用户明确再次按压时复用已有动作终端；没有 shell 退出状态证据，结果始终保留 `executionVerified=false`。这里不读取终端内容，不输入 shell 命令。

| 场景 | 行为与结果 |
| --- | --- |
| E01 配置首项与最近使用项 | 四种语言；配置 Build、最近使用 Test 时仍选 Build，不选聊天分组里的同名动作 |
| E02 再次明确按压 | 原生动作可复用既有终端；确认派发与指定终端，不把旧输出视为新执行完成 |
| E03 搜索不为空或不可读 | 不清空用户搜索，不从过滤后的结果猜槽位；不派发动作 |
| E04 配置入口缺失或歧义 | Project 缺失 / 重复、无动作、首项禁用均拒绝，不跳到第二项 |
| E05 菜单刷新 | 即使 AX 节点相同，动作名称变化仍取消派发 |
| E06 终端身份不符 | 错槽位、其他聊天、隐藏、重复或缺失终端均未知；不重试 |
| E07 中途切换聊天 | 打开菜单后或选动作后换目标均取消后续操作，不向另一聊天发 Esc |
| PLAY 换绑与工具合同 | 换键帽即默认换功能；保存后按压携带精确 ID / token，无任意命令参数；无 ID 草稿不可用 |

142 项 Swift 测试通过，六类回放共 96 条完整 JSON 记录。正式安装包继续运行 17 个进程 E2E；新增工具仅做参数合同检查，不访问真实 Codex。GIT、MRG、PAINT 仍分别推进；PLAY 的实际脚本运行与退出结果保留真实业务验收项。

## preview.20：GIT 与 Git 工作流前置分支

完整追踪 `git.commit` 注册到 `jn` 及表单组件后确认，“Commit or push”是一个表单入口：它可以先打开 Work here，也可以打开包含 Commit、Commit and push、Push 三个选项的表单。没有改动、只有待推送提交时，提交信息输入框和 Include unstaged changes 不显示，不能把缺少这两个字段误判为错误表单。GIT 现在只选中命令菜单入口，回读三个选项的唯一身份和表单容器，不按任何最终动作，不更改范围或信息。

另修复命令菜单歧义：原来的全局标题匹配可能命中名为 Create PR / Commit or push 的聊天结果。Git 现在与 PLAY 一样限定唯一 Project 分组，只从该分组选择命令。

同一追踪发现 preview.18 的 PR 适配遗漏：`Mn` 在需要分支时，普通和草稿 PR 都先进入 Work here。现已接受这个明确的原生前置步骤，分别返回 `workflowStage=branchSetup`、`commitForm` 或 `pullRequestForm`。只有最终 PR 表单的普通／草稿默认选项确实回读通过，`prDefaultVerified` 才为 true；前置分支阶段为 false。所有阶段保持 `mutationCompleted=false`。

| 场景 | 行为与结果 |
| --- | --- |
| G07 提交及推送表单 | 四种语言 × 完整／仅推送状态，均确认原生表单；不点 Commit、Commit and push 或 Push |
| G08 分支前置 | 四种语言 × GIT、PR、BRCH，确认 Work here 并报告 branchSetup；不创建分支，不误报 PR 默认值 |
| G09 表单错误 | 错标题、缺命令表单容器、缺选项或重复选项均保持未知，动作只发一次 |
| G10 命令不可用 | 缺失、禁用、重复均不派发；不尝试其他 Git 动作 |
| G11 目标变化 | 打开菜单后或选择命令后切换会话，不重发，不向其他目标发 Esc |
| G12 权限弹窗 | 表单上方另有权限窗口则不报告完成，不关闭或接受提示 |
| G13 / G14 命令分组 | 四种 Git 命令均只在唯一 Project 组查找；同名聊天不能成为动作，分组缺失或重复即拒绝 |
| GIT 键帽 | CODEX 换成 GIT 自动绑定 git.commit；保存后仅派发 open_keypad_commit 和精确 ID / token；无 ID 草稿禁用 |

完整验证为 150 项 Swift 测试、17 项安装包进程 E2E、133 条 JSON 回放记录。Windows 最新执行器中这几项仍只有目录默认值；GIT 的实际提交、推送结果仍需允许环境中的隔离仓库验收。

## preview.21：MRG 合并确认与 PAINT 独立照片选择器

三个仓库重新 fetch 后基线未变。MRG / PAINT 在 Windows 当前目录中有默认动作但未接入执行器；Mac 按本机 Codex 实际原生命令定义补齐。

MRG 从唯一 Project 组选择 Merge PR，回读 Merge pull request 确认框、取消按钮和唯一的最终确认按钮。Squash and merge / Create merge commit 分别标识当前原生方式；仓库只允许一种方式时没有方法选择器，因此不强求该控件。实现不改方法、不按最终按钮。`workflowStage=mergeConfirmation`、`mergeCompleted=false` 区分入口与最终结果。静态源码显示 app-shell 面板 ID 使用内部随机 `dndId`，且确认表单没有 PR 编号；返回 `pullRequestIdentityVerified=false`，不将面板 ID 冒充 PR 身份。

PAINT 使用原生 Add photos → `imagesOnly=true` → Select photos 路径。本机源代码的添加菜单会根据文件能力二选一显示 Files and folders / Add photos；`composer.addPhotos` 没有默认快捷键，也不在命令菜单。因此支持已观察到的独立照片项，或用户已经配置的专用快捷键；输入前重读配置并核对同一输入框、窗口、进程与前台，拒绝裸 Return 等内容按键，不猜快捷键、不修改用户配置。

照片入口必须交接到同一 Codex 进程中新出现的 Select photos 原生窗口；Select files 不算成功。共享选择器回读同时收紧为仅一个新模态窗口，权限叠层或多个窗口保持未知。返回 `pickerKind=photos`、`pickerEntryPoint=menu|configuredShortcut`、`imagesOnlyRequested=true`，但仍是 `awaitingSelection=true`、`attachmentVerified=false`。快捷键结果未知不会再尝试菜单。

| 场景 | 行为与结果 |
| --- | --- |
| G15 合并方式 | 四种语言 × squash / merge commit；支持没有方法选择器的单一方法仓库；只打开确认表单 |
| G16–G17 不可用或错误结果 | 命令缺失、禁用、重复不派发；错误／歧义表单及分支表单不冒充合并确认 |
| G18–G20 目标与弹窗 | 命令前后换聊天、权限弹窗、错误 UUID 或无原生命令都不重发、不关闭其他目标 |
| G13 同名聊天 | MRG 同样限定 Project 组，不选名为 Merge PR 的聊天 |
| F06–F08 照片菜单 | 四种语言及已确认草稿；缺照片项不选 Files；模拟取消后保留原文 |
| F09–F11 明确配置的快捷键 | 专用快捷键成功交接；配置或目标中途变化取消；裸 Return 不发送 |
| F12–F15 选择器结果 | 缺失、错误类型、重复或权限叠层保持未知；已有附件窗口阻止再次操作；菜单换目标或快捷键未知均不回退、不重发 |
| MRG / PAINT 键帽 | 从 CODEX 更换即默认切到对应功能；保存后派发各自原生操作；模态状态清除旧目标，无 ID 未确认输入框不可用 |

preview.21 当时验证为 168 项 Swift 测试、17 项安装包进程 E2E、174 条 JSON 回放记录。测试没有访问真实 Codex UI，没有合并 PR、选择图片或发送消息。33 个可见命令键帽均已有明确派发路径，另一个空白键保持零派发；这不代表所有原生入口在任意上下文可用，也不等于 34 项真实业务验收通过。

## 后续场景

继续使用 Windows 实现、安装包静态协议 / 控件定义、正式控制器回放及进程日志推进。MRG / PAINT 不再是缺少派发通道，但仍保留以下业务层验证；无法访问真实 UI 不作为停止其他源码修复的条件。

| 能力 | 尚需验证的结果 |
| --- | --- |
| PAINT / UPL | 选择测试文件后，正确附件实际进入当前输入框；PAINT 的常见文件菜单场景需已有专用快捷键，不能假装默认可用 |
| MRG | 原生命令关联的具体 PR 身份、必要确认及最终合并结果；使用明确的隔离测试目标 |
| GIT / BRANCH / PR / BRCH | 一次性仓库中实际提交、推送、创建分支及普通／草稿 PR 的最终状态 |
| PLAY | 实际脚本执行与退出状态，不能用已有终端身份替代完成证据 |
| BUG / PARTY | 真实原生反馈表单及侧边聊天的界面、焦点与最终状态 |
| 其他 Windows 差异 | preview.23 已补自定义任务映射；固定任务来源与侧栏排序继续逐项核对 |
| 新会话设置与模型 | 原生 Fast / Plan / MIND、A/B 与模型菜单在实际安装版本中的端到端结果；现有控制器回放继续维护 |


## preview.22：预置文字与全部空白键

重新 fetch 三个仓库后，远端基线仍为产品 `4429ffe`、控制 `775e9f9`、插件 `e4fbb40`。Windows `CodexOfficialCatalog.json` 定义 YOLO / YEET 为 `composer-text`，文字分别为 `:yolo:` / `:yeet:`。当前 `SoftwareMicroTransport.TapKeyAsync` 会拒绝非 command / skill 类型，因此目录定义不等于 Windows 软件执行器已实现该路径。Mac 按目录语义补上固定文字插入；不把 YOLO 名称解释为权限切换。

| 场景 | Mac 实现与验证 |
| --- | --- |
| 全部 40 个键帽可选 | 33 命令、5 空白、2 预置文字；EMPT2–5 复用空白轮廓，保留独立目录 ID；文字图案使用字体矢量轮廓 |
| CODEX 换成 YOLO / YEET | 默认动作替换为对应 composer-text，保存、重新载入后派发固定 preset + 当前 token；不保留 Submit |
| 空白、居中光标、替换选中文字 | C01 分别运行两个预置；只进行一次定向 Unicode 输入，读回完整文字及最终光标 |
| emoji、组合字符、多行文字 | C02 按 AX 的 UTF-16 范围处理，不把字符数当作 UTF-16 偏移 |
| 选区缺失、负数、越界、溢出或拆开 emoji 代理对 | C05 全部拒绝且零输入；回放发现并修复了原 Swift Range 转换接受半个代理对的问题 |
| 已确认新草稿 | C03 允许写入，无持久 thread ID，不沿用上一会话 ID |
| 输入框失焦 | C04 先聚焦并重新读取选区；C06 聚焦失败不输入，不替换整份草稿 |
| 输入前文字、光标、会话、输入框、焦点、菜单、前台、模态或模型变化 | C07 每项单独回放，最后一次检查失败即取消 |
| 输入结果未知或读回不符 | C08 只输入一次并使旧 token 失效；没有重试、快捷键或剪贴板回退 |
| 输入后切换会话 | C09 不能用另一个会话证明成功 |
| 两次独立按压 | C10 第二次使用新 token 和当前光标，旧 token 不能重放 |
| 未知 preset、无 ID 回退、已有菜单 | C11–C12 拒绝；只有已确认草稿或精确会话可写入 |
| EMPT1–5 | 每个都验证换绑、保存、重载，保持空动作和零派发 |

本轮新增 12 项原生文字回放测试、4 项面板测试；全量 184 项 Swift 测试、17 项安装包进程 E2E。新增 40 条 `PRESET-TEXT-TRACE`，总计 214 条 JSON 回放记录。P01 还核对安装包内新工具的两值枚举、必填参数和非幂等声明，不调用真实 UI。图案经正式包的离屏导出核对；没有打开 Codex 界面，也没有发送消息或读写剪贴板。真实输入法、富文本输入框 AX 选区兼容性仍属原生业务验收范围。

离屏绘制检查另发现并修复两类问题：新空白键曾假定存在 EMPT1 生成资源，实际资源没有该键，导致图案初始化崩溃；现在五个空白键直接绘制 Windows 对应的小圆角轮廓。BRANCH 与 UPL 的 Windows 通用导出只有未描边的开放路径，绘制器却按填充处理，分别丢失分支节点、竖线和上传箭头。Mac 使用 `KeycapIcon.DrawBranch` 的完整三节点矢量及 `DrawCloudUpload` 的带描边路径，不复制这处上游缺陷。其余通用导出开放路径只有已被原生 MIND 滑块替换的旧 brain 图案。

`design_e2e.py` 用最终安装包的 `--export-design` 入口创建全新离屏产物，核对 40 个键帽加 FAST_ON 的四档缩放、居中、非空图案和双主题 PNG，能够捕获只有运行绘制器才出现的初始化崩溃。正式 100% 图案另经目视核对；不创建应用窗口或连接 Codex。


## preview.23：按账号保存的自定义任务槽位

Windows 设置包含 recent / pinned / priority / custom，但 `CodexAgentRosterObserver` 对不能从本机证明的非 recent 来源返回空列表。因此本轮分别核对“菜单选项”“可证明的数据”和“按下后实际打开的 ID”，不把 Windows 选项当作已有完整执行器。Mac 新增 14 个本机自定义槽位，主键盘使用前 6 个、监控页使用全部 14 个；最近任务与优先级模式保留。

设置中的“自定义映射”显示 14 个任务选择器，可明确“使用最近任务”建立初始映射、选择带完整 UUID 的任务，或清空单个槽位。持久化只存槽位和 ID，使用账号身份、本机执行 host 与存储根目录派生的稳定 scope；进程重启的 contextID 不用于保存映射。老版布局缺少新字段仍能解码，原键帽覆盖和单击设置继续保留。

| 场景 | 处理与证据 |
| --- | --- |
| 同名任务、稀疏槽位、最近列表重新排序 | R01 保留 AG00–AG13 的位置；空位不压缩；只打开该槽位的精确 UUID |
| 保存的任务不在最近 100 条内 | 正式只读 thread/read 按 ID 获取元数据，不依赖名称搜索或列表位置；P18 核对去重、请求顺序和返回 ID |
| 任务已删除或读取被拒绝 | R02 保留空位及原 ID；P18 验证单项 RPC 拒绝不重启健康目录连接、不丢弃其他映射 |
| 退出并重新启动 Micro | R03 先获得稳定账号 scope，再读取该 scope 的已存 ID |
| 切换账号及切回 | R04 / P19 不读取旧账号的保存 ID；切回恢复自己的映射 |
| 按住期间修改映射 | R05 旧按压失效；冻结画面的新按压也核对当前绑定 |
| 悬停冻结位置时切账号 | R11 不能从旧槽位准备新按压；离开悬停后显示当前账号映射 |
| 旧映射的读取晚于新选择返回 | R06 丢弃旧结果，重新观察当前映射 |
| 显式复制最近任务、清空单键 | R07 只更新本机设置，不执行任务；空键没有最近任务回退 |
| 账号身份不可用、读取失败 | R08–R09 无映射派发，不猜 scope |
| 旧版设置或非法新数据 | R10 保留原设置；拒绝超出 14 槽、非法 UUID 或 scope |
| 工具输入非法或服务端返回了其他 ID | P20 / P21 在读取前拒绝非法输入，ID 冲突使结果失败，不替换成另一个任务 |

此功能不会修改 Codex 的固定任务、侧栏分组、归档状态或配置；保存绑定也不会打开会话。已保存且仍可读取的任务可继续按 ID 解析，原生打开仍沿用精确导航回读。Windows pinned 模式与当前 Codex section_position 排序及旧版 pins 的兼容仍是后续独立对照项，未伪装成已接入。

本轮 201 项 Swift 测试、21 个安装包进程场景、225 条 JSON 回放记录通过。正式包进程检查曾发现工具通用校验器把字符串数组当作字符串拒绝，现已支持有上限的字符串数组并覆盖非法类型、空项及超过 14 项的输入。另修复 `thread/read.name=null` 遮蔽 preview 标题的问题；精确 ID 始终是绑定身份。最终 Universal 包通过离屏 40 键帽、164 项指标、签名与 ZIP 检查。新设置面板已编译，但未称为真实界面或 Codex 业务验收。


## preview.24：固定任务来源与分组顺序

当前 Windows 本机观察器仍只证明 recent；pinned 选项依赖 Codex 渲染器侧数据。安装包静态源码 `pI.findPinnedSectionId` 与 section engine 显示：现代固定分组有稳定 UUID `01984de2-8f74-7c91-a3b2-5c5e937cf318`，分组可改名；查询使用 `section_position`、`modelProviders=[]`、`useStateDbOnly=true`，不显式覆盖排序方向。CLI 生成的 ThreadList schema 同时确认 sectionId、非归档默认及 Thread.section。Mac 现在按这些协议读取本机固定任务，不按“Pinned”名称或最近更新时间猜测。

| 场景 | 处理与证据 |
| --- | --- |
| 固定分组改名，另有自定义分组同名 Pinned | 按稳定 ID 查找；目录规则和 P22 跨分组分页验证 |
| 固定任务比最近列表更旧、两个任务同名 | S01 / P22 保持服务器顺序并派发精确旧 UUID；读取元数据不打开或恢复任务 |
| 分组与任务分多页 | 只读获取，最多 14 个槽位；S01、目录规则和 P22 不按时间重新排序 |
| 固定任务超过 14 个 | 取已证明的前 14 个，P25 确认不继续扫描后续页 |
| 当前固定列表为空 | S02 / P23 返回已知空列表，不用最近任务补位 |
| 服务不支持 section 或 section_position、固定分组不存在 | P23 返回不可用，保留健康目录连接；不读取旧全局 pins 充当当前账号证据，不执行迁移 |
| 按住期间重新排序 | S03 冻结画面，但旧按压和新按压均不能打开旧位置任务；释放后采用新顺序 |
| 悬停期间取消固定，该任务仍在最近列表 | S04 即使任务仍可访问，也不能按旧槽位打开 |
| 切账号、身份缺失 | S05 / P25 清除固定槽位，未知身份不枚举固定分组 |
| 固定读取尚未完成就切回最近任务 | S06 丢弃旧结果，不覆盖新来源 |
| 重启 Micro | S07 保留本机来源选择，重新查询当前固定顺序，不持久化旧快照 |
| 错误分组、重复 ID、非法／循环游标、读取失败 | S08 / P24 不能显示部分错误结果；目录规则覆盖 10 页上限 |

此实现只涵盖本机现代分组协议。旧 Codex 的全局 pins、跨 host 固定任务和云端会话仍是明确差异；没有读取其他 host 或通过 UI 工具绕过限制。

进一步核对 renderer 的 `codex-micro-slot-signals`：官方 pinned 来源还会按侧栏规则混排固定项目中的任务，priority 先排序完整侧栏候选再取前 6 项，custom 还支持命令与新草稿待绑定。Mac 本轮只接入本机固定会话、14 个直接 ID 槽位；这些差异仍未完成，不能将当前支持写成官方 roster 全量对齐。

优先级排序还确认了一处实质差异：renderer 的 `f7n` 按 waiting → unread → active → idle，再按 recencyAt 降序排列；Mac 目前把运行中排在未读前，并只排序最近 14 条。下一轮需拆分灯光状态与注意力排序，覆盖第 15 条之后的待处理任务、运行中未读以及时间相同的稳定顺序。

preview.24 最终验证：216 项 Swift 测试、25 项正式安装包进程场景、233 条 JSON 回放日志通过。40 个键帽／164 项离屏指标、Universal 双架构、plist、ad hoc 签名、ZIP 完整性及 15 文件单向同步均通过。P22 首次暴露只读目录缺少 `threadSection/list` 允许项，补齐后最终包已复测通过；未访问真实 Codex UI、未迁移或修改固定任务。


## preview.25：优先级候选范围、注意力与活动流

静态核对 `codex-micro-slot-signals.Ie` → `app-initial.f7n`：排序字段为 attentionState 的 waiting、unread、active、idle，同档按 recencyAt 降序。`Lk` / `p7n` 保留待处理请求的最高优先级，但运行中可以同时未读；普通错误灯本身不是一个等待用户回应的请求。`Ebn` / `Dbn` 的时间回退为 recencyAt、updatedAt、createdAt。旧 Mac 把灯光枚举直接拿来排序，将运行中放在未读前，而且先截断最近 14 项。

本轮使用独立 TaskAttention，完整读取本机交互任务目录后再取前 14 项，控制页仍展示前 6 项。MCP 的 `include_priority` 才启动跨页枚举；普通 recent 查询保留单页行为。未知／冲突页不返回可用的部分排名；100 页／10,000 项及操作时限是异常边界，遇到未完目录即失败。仍未将本机目录声称为包含云端、远程 host 或渲染器尚未持久化的新草稿。

| 场景 | 处理与证据 |
| --- | --- |
| 运行中未读、运行中已读、普通错误、空闲 | Q01 分离灯光与注意力：未读先于运行，错误本身不挤到待处理请求前 |
| 第 115 条任务正在等审批 | Q02 使用完整候选并进入首键，按精确 UUID 打开；P26 验证实际目录跨页、attention 与 recency 字段 |
| 审批与问题同时在列表，或时间相同 | Q03 二者同为 waiting，再按时间；完全相同的排名保持目录顺序 |
| 旧任务的 IPC 待处理状态稍后到达 | Q04 与 P27 覆盖第一百条之后的请求，不只观察可见灯位 |
| 只有未读发生变化，运行灯未变 | P28 验证 attention 变化也递增 revision，避免 UI 排名永远不刷新 |
| 悬停中另一个任务变得更紧急 | Q05 冻结键位身份，按压仍打开看到的原任务；离开悬停后采用新排名 |
| 目录不完整、换账号或旧账号状态流 | Q06–Q07 拒绝旧按压／旧状态，不用部分结果冒充完整排序 |
| 同一连接中账号范围改变、旧读取晚到 | Q09 用账号 scope 与连接代次共同退役旧排序；慢成功和慢失败都不能覆盖新账号 |
| 切回最近任务 | Q08 / P30 恢复目录顺序，停止完整优先级枚举 |
| 错误 ID、重复条目、重复／非法游标、空中间页 | 目录规则与 P29 拒绝错误结果，空中间页仍继续读取 |
| 旧未加载任务只有 rollout 中的异步问题 | P31 检查正式文件观察、问题进入注意力以及完成后清除 |

同时改进观察性能：状态请求最多 64 个并发，每批 8 个、半秒轮换，单个任务至少隔五秒再次发现，并交错读取 IPC；当前选中会话优先。文件观察在独立队列内按两秒预算轮换，保留增量解析状态；只给当前前 14 项安装文件事件监听，其余候选由轮询发现，不在控制操作队列里扫描全部日志。目录状态现在也作为活动流的有效回退，不再被没有 rollout 的 unknown 覆盖。真实 Codex UI 仍未访问。

P27 的首轮正式进程运行捕获了 IPC 双向缓冲区拥塞：一次连续写入 64 项发现请求，来不及消费服务端应答，连接在第 46 个不同目标附近反复超时。现在小批查询与非阻塞读取交错，避免只修改排序公式却永远发现不了后面的旧任务；该场景保留在进程套件中。

preview.25 最终结果：235 项 Swift 测试、31 项正式包进程场景、242 条 JSON 回放日志通过；其中 P27 已在修复后验证第 135 条的实际 IPC 问题状态，P28 验证第 145 条只有未读变化仍刷新排名，P31 验证第 149 条日志中的问题与完成。40 键帽／164 项离屏指标、双架构、签名、ZIP 和 15 文件单向同步通过。新排序不等于真实 Codex UI 验收；固定项目混排、跨 host／云端、渲染器待持久化草稿和自定义任务命令仍继续对照。

## preview.26：灯态优先级与当前未读显示

继续核对安装包静态 `codex-micro-slot-signals` 的 Le / Pe：错误优先于审批，审批优先于待回应；运行中的未读仍显示运行。只有当前任务且应用窗口获得焦点时，未读灯才按空闲显示。Mac 之前让待回应先于错误与审批，并且没有区分“提交焦点记忆”与实时应用焦点。

现在目录、当前状态与独立活动观察共用 TaskLampSignal：错误 → 审批 → 待回应 → 运行 → 未读 → 空闲。注意力排序仍独立，运行未读可以参与未读优先级。原生观察新增 appFocused；原来的 foreground 继续承担从 Codex 点进 Micro 后保留提交目标的用途，不作为未读显示依据。控制页和设置预览采用同一个显示规则，不新增操作按钮或说明元素。

| 场景 | 处理与证据 |
| --- | --- |
| 错误、审批、问题同时出现 | L06 目录和当前状态一致；P32 经正式桥接 IPC 验证错误优先 |
| 审批与问题同时出现，随后依次消失 | L06 / P32 确认审批 → 问题 → 运行的变化 |
| 当前精确会话在 Codex 前台且已未读 | L01 显示空闲，但原始 unread 和注意力均保留；其他会话仍显示未读 |
| 点击 Micro 保留提交焦点、Codex 已不在前台 | L02 / L09 显示未读；六次 PID 变换验证物理焦点与提交记忆独立 |
| 老桥接没有 appFocused 字段 | L02 不推断焦点，不隐藏未读 |
| 路由冲突、缺失、不可用或选中状态未知 | L03 不隐藏未读 |
| 草稿、文件弹窗、IPC 可见回退和手选任务 | L04 不把它们视为当前原生前台会话 |
| 焦点观察满两秒或时钟倒退 | L05 恢复未读灯，新观察到来后重新判断 |
| 当前会话仍在运行、审批、待回应或报错 | L07 即使在前台也不隐藏这些灯态 |
| 已移出目录或连接断开的旧行仍有缓存颜色 | L08 先检查目录和连接有效性，不再显示旧颜色 |
| 实际流只改变视觉状态或注意力 | P32 连续验证六种状态，每次 revision 增长，全程零业务写入 |

新增 L01–L09 九条 JSON 回放，保存为 `dist/macos/parity-task-lamp-replay.jsonl`。这些是正式模型、控制器与操作系统边界回放；P32 是打包进程和独立 IPC 夹具。没有访问真实 Codex，也没有清除 unread、发送消息或确认已读。固定项目混排、自定义任务命令、跨 host／云端及未持久化草稿仍保留为后续差异。

preview.26 最终结果：244 项 Swift、32 项正式包进程 E2E、251 条 JSON 回放通过；40 键帽／164 项离屏指标、Universal 双架构、签名、ZIP 完整性和 15 文件单向同步通过。完整机器记录为 `dist/macos/parity-validation.json`，preview.25 验证记录已独立保留。

## preview.27：自定义任务命令与最近会话槽位

再次 fetch 三个 origin，基线仍是产品 4429ffe、控制 775e9f9、插件 e4fbb40。Windows `CodexOfficialCommands.g.cs` 定义 recentThread1–6；Windows 本机 roster 仍仅证明 recent。安装包 `codex-micro-commands` 严格把这六个命令映射为索引 0–5，`codex-micro-slot-signals` 则区分固定 threadKey 与 command，并在重新分配固定会话时移除同 host 的旧槽位。

Mac 增加独立、可选的 taskCommands 偏好，保留已有 taskMappings 格式。每个账号／host／存储范围下，14 个槽位可混合固定精确 ID、最近会话命令和普通命令；同槽命令与 ID 互斥。设置菜单列出 46 个当前 Mac 支持的命令，包括六个最近位置及兼容别名；这不是声称支持全部官方命令。普通命令不虚构任务 ID 或灯态，显示原任务键编号并提供相应无障碍名称。命令不送入 mapped_thread_ids，也不额外写 Codex 配置。

| 场景 | 处理与验证 |
| --- | --- |
| 固定会话、最近位置、普通命令混排到第 14 键 | U01 保持 14 位和空位，目录查询只带精确固定 UUID |
| 最近顺序改变 | U02 更新最近命令目标，固定 ID 不跟随变化 |
| 悬停／按住时顺序改变 | U03 保留所见精确 ID，离开悬停后才更新位置 |
| 命令换为会话、会话换为命令、清空、同会话移位 | U04 保存互斥配置，移除同范围的旧固定槽位，全程零动作派发 |
| 全部支持命令逐个按压 | U05 逐一验证 46 条命令到正式 MicroModel 操作的映射；涉及 ID、token、审批请求的参数单独核对 |
| 按住命令键后编辑绑定 | U06 旧动作失效，冻结旧画面期间无法准备新的旧命令 |
| 两个账号都绑定相同命令或相同最近位置 | U07 连同显示快照的账号与连接范围一起校验，不能复用旧悬停状态 |
| 旧目录读取晚于重新绑定完成 | U08 版本保护保留新命令 |
| 重启、切换来源、显式复制最近列表 | U09 还原命令、来源隔离；复制列表会用固定 ID 替换该范围的命令 |
| 越界最近命令、未知命令、ID 与命令冲突 | U10 拒绝保存，加载冲突配置时保留原 ID 并退役冲突命令 |
| 捕获 Fast 动作后切换会话 | U11 不向旧对话写入 |
| 最近第六项不存在、双击模式的第一次选择 | U12 不补另一条会话，第一次选择不执行普通命令 |
| 新建会话命令 | U13 清除旧当前 ID，保留命令绑定，不猜草稿身份 |
| 自定义任务键控制新草稿 | U14 经正式模型队列和 MacUIController，依次打开原生 Fast / Plan / Power 控件并回读；三条写操作均无 thread_id |
| 导入的普通动作键绑定 recentThread2 | U15 保留捕获的精确 ID，换账号后旧动作失效 |

U01–U15 共 15 条 JSON 记录保存于 `dist/macos/parity-task-command-replay.jsonl`；U05 含完整的 46 项派发表。U14 只替换操作系统和目录边界，其他映射用正式模型配受控 Desktop 边界。没有访问真实 Codex 界面，UIKit 新命令菜单只完成编译验证。

仍未完成的草稿自动绑定需要源代码中 ke 所要求的匹配 clientThreadId→conversationId 证据；现有新建深链只证明导航请求，不能用时间相邻的新 UUID 代替该关系。固定项目混排、跨 host／云端、渲染器未持久化任务，以及更多尚未实现的官方命令继续保留为差异。

preview.27 最终结果：259 项 Swift、32 项正式包进程 E2E、266 条 JSON 回放通过；40 键帽／164 项离屏指标、双架构、签名、ZIP 和 15 文件单向同步通过。完整记录为 `dist/macos/parity-validation.json`，preview.26 记录已独立保留。

## preview.28：固定项目成员与侧栏混排

静态核对 `codex-micro-slot-signals` 的 mxn／$Fn／Fe、侧栏的 eIn／m3n／g3n／b3n，以及主进程项目同步层。固定来源会保留项目在整体手动顺序中的位置，但本机单独固定会话的相对顺序仍由服务端 section_position 决定；项目内任务另按手动顺序或 recency 排列，单独固定的会话从项目成员里排除。ProjectList／ThreadList schema 确认只读 project/list、projectId 过滤和返回的 canonical projectId。

现在读取同一 `.codex-global-state.json` 中的 pinned-project-ids、相关持久排序字段及当前本机存储范围的项目 ID 映射，只把它们当作选择与排序偏好。项目存在性由 project/list 确认，成员由 thread/list(projectId) 确认，每个返回行都要与查询的 projectId 一致；不通过目录名前缀、标题或最近列表猜归属。映射范围使用初始化响应原样返回的 codexHome，同时保留已存在的规范化真实路径核验，避免符号链接导致找错迁移范围。没有执行项目或 pins 迁移。

| 场景 | 处理与证据 |
| --- | --- |
| 固定项目插在两个同名固定会话之间 | V01 / P33 核对精确成员、跨页项目列表与服务端固定会话顺序 |
| 会话既单独固定又属于固定项目 | V01 / V07 / P33 从项目组排除，避免重复占键 |
| 第 15 个固定会话最近活跃 | V02 / P38 先读完并排序，再取前 14 项 |
| 第 15 个固定会话属于最前方的项目 | V07 读齐 pin 身份后排重，不把它误放进项目第一键 |
| 项目内显式手动顺序，随后该字段消失 | V03 / P34 使用保存顺序或同账号、同连接上次验证顺序，新成员追加 |
| 切回最近活动排序 | P34 重新使用 recency，不继续套旧手动列表 |
| 旧手动版本、布尔值或旧全局排序设置 | V04 按官方回退规则使用最近活动，不误接受布尔值为版本 1 |
| 旧项目 ID 属于另一存储根 | V05 / P37 不拿该映射选取成员；服务端原始 codexHome 与文件真实根分开核验 |
| 返回错误项目、重复成员／项目或游标循环 | V06 / V09 / P35 拒绝不完整结果，不返回可执行的局部混排 |
| 项目协议不支持 | V08 / P35 返回不可用，不伪装成只有单独固定任务的完整列表 |
| 项目已删除或为原生 ChatGPT 镜像目录 | V10 不根据同名路径补成员 |
| 配置格式损坏或项目迁移映射冲突 | V11 拒绝不唯一身份与错误排序数据 |
| 账号不可确认、相同 recency | V12 跳过枚举；相同时间保留来源顺序 |
| 只固定项目，没有单独固定会话分组 | V13 / P39 以完整 section 列表证明没有单独 pins，继续显示项目成员 |
| 读取期间偏好改变 | P36 回读规范化偏好并拒绝旧结果，不混用两个版本 |
| 项目重排／移除发生在按住期间 | V14 从正式组合逻辑进入 MicroModel，旧按压失效，松开后新键打开新精确 ID |

V01–V14 日志位于 `dist/macos/parity-pinned-project-replay.jsonl`；P33–P39 使用正式包、原生桥接和独立 App Server／IPC。P33 检查全局状态文件字节与业务写入计数均未变化；P36 的状态修改只由故障夹具触发。

范围仍是本机现代项目和 canonical 服务端成员关系。缺少所需协议／完整页的来源不可用；跨 host、云端、旧 pins、尚未迁移的项目成员，以及 Micro 首次观察前仅保存在官方渲染器内存中的手动次序仍未对齐。项目读取有 100 页／10,000 行边界，已选项目成员总数最多 10,000；单独 pin 枚举保留 10 页边界，超限不返回看似完整的局部结果。真实 Codex 界面未访问。

再次 fetch 三个 origin，产品 4429ffe、控制 775e9f9、插件 e4fbb40 均未变化。preview.28 最终结果：273 项 Swift、39 项正式包进程 E2E、280 条 JSON 回放通过；40 键帽／164 项离屏指标、Universal 双架构、plist、签名、两个 ZIP 的完整性及 15 文件单向同步通过。完整记录为 `dist/macos/parity-validation.json`，preview.27 记录已独立保留。

## preview.29：客户端会话路由与 host 范围

验证更正：preview.30 发现客户端设置仍被正式 DesktopBackend 的旧规则拒绝；本节当时的 W08 只到原生控制器，未覆盖这一层。修复与完整入口回放见 preview.30。

继续核对 Windows `CodexSelectedThreadReader.ResolveDocumentThreadId`、`CodexDraftModelToggleService.DraftThreadPrefix`，以及官方静态 `app-shared` 的 N1 / hM / dht / gNn 和 `codex-micro-slot-signals` 的 ke / Ae / Me。Windows 选择器只提取 `/local/<UUID>`，没有检查 hostId；Mac 原来也丢掉查询参数，存在同类范围风险。官方客户端路由还包括 `/local/client-new-thread:<UUID>` 与 `/hotkey-window/thread/<identity>`，以前 Mac 将它们当普通页面，Fast / Plan / MIND 与模型控制因此不可用。

现在 CurrentRoute 保留 host 范围参与冲突判断：省略 hostId 与单个 `hostId=local` 等价；远程、durable、空值和重复参数不授权本机控制，也不能恢复旧的 IPC 可见会话。热键窗口的本机精确 UUID 路由可正常识别。客户端身份单独返回为 clientThreadId，threadId 仍为空；只有同一原生窗口、输入框、模型入口和匹配路由身份才能进入已有的原生设置队列。切换客户端路由后，即使 AX 元素完全复用，旧 token 也失效。

客户端 ID 可以在正式会话创建后继续存在，因此不能直接视为“尚未发送的空白草稿”。这一层只启用模型、Fast、Plan、MIND；发送、Stop、审批、Fork 等仍要求各自的正式身份。没有删除前缀后假装得到服务端 UUID，也没有按创建时间绑定任务槽位。

| 场景 | 处理与证据 |
| --- | --- |
| 普通／热键窗口客户端路由，冒号 URL 编码 | W01 独立客户端身份；不是服务端 UUID，也不宣称尚未发送 |
| 热键窗口精确会话与显式本机 host | W02 支持精确 UUID，统一大小写 |
| 远程、durable、空 host 或重复参数 | W03 覆盖 32 种组合，不能回退旧侧栏或首页草稿 |
| 同一 UUID 的侧栏项属于另一 host | W04 拒绝冲突；bootstrap initialRoute 不恢复旧目标 |
| 畸形客户端 ID、额外路径及外部网址 | W05 不赋予客户端身份 |
| 文档／侧栏客户端身份冲突 | W06 不选择任意一个；已知客户端首页容器也不冒充空白草稿 |
| 多个文档仅有无关查询参数变化 | W07 保持本机身份；host 变化则冲突 |
| 两类路由的 Fast → Plan → MIND → 模型 | W08 正式 MicroModel 队列到 MacUIController，共八次原生设置派发及回读，均无 thread_id |
| 同一 AX 节点中途切换客户端 | W09 在键盘写入前拒绝，未向新输入框补发或清理菜单 |
| 客户端路由切到正式 UUID | W10 退役旧 token，再从新的实时地址显示 UUID |
| 客户端身份尝试发送／Stop／审批／Fork | W11 按钮与原生控制器两层拒绝，零派发 |
| 远程地址与旧本机 IPC 可见状态并存 | W12 用实际控制器投影进入模型，清除旧本机目标 |
| 桥接投影的 clientThreadId 缺失或不匹配 | W13 不启用客户端设置，仅精确匹配时可用 |

W01–W13 日志保存为 `dist/macos/parity-client-route-replay.jsonl`；七项路由规则与六项控制器／模型测试。W08–W12 注入操作系统边界，其余使用纯规则或受控 Desktop 边界，没有访问真实 Codex 界面。Windows 代码仅作静态对照；本轮没有 Windows 构建或运行结论。

自动绑定仍需继续完成：官方通过匹配 clientThreadId 的创建事件更新槽位，持久层包含 `client-thread-bindings-v1` 与 `thread-client-id-v1:<encoded local key>`；首页的 `draft-thread-identities-v1` 只在特定运行模式启用，不能把全局磁盘值直接当成当前窗口身份。Mac 本轮不读取这些记录来推断当前草稿、不绑定空任务键；尚未完成这部分账号／host／窗口及正式成员交叉核验。

preview.29 最终结果：286 项 Swift、39 项正式包进程 E2E、293 条 JSON 回放通过；40 键帽／164 项离屏指标、Universal 双架构、plist、签名、ZIP 完整性和 15 文件源码同步通过。完整记录为 `dist/macos/parity-validation.json`，preview.28 记录已独立保留。

preview.29 再次 fetch：三个 origin/main 均未变化；上述两个 Windows 源文件与远端字节一致。核对的三个官方静态模块也与当前已安装 app.asar 字节一致，SHA-256 已写入验证记录。

## preview.30：补齐正式桌面入口的客户端设置校验

继续沿原生派发链复核时发现 preview.29 的遗漏：MicroModel 与 MacUIController 接受了明确客户端路由，但 DesktopBackend.acceptsNativeSettings 仍要求 selectionKnown=false，正式入口会拒绝 selectionKnown=true 的客户端设置。之前 W08 的边界直接进入 MacUIController，没有经过 DesktopBackend，因此没有捕获这一层；preview.29 的真实界面验收一直未通过，不能把该控制器回放当成正式入口可用的证据。

本轮先把原有回放接到正式 DesktopBackend，只替换 App Server 目录及操作系统边界，成功复现 W08 的 16 个断言失败：Fast 和模型操作被拒绝，其余队列被取消。失败记录保存在 `dist/macos/parity-backend-regression-before-fix.log`。随后增加 NativeComposerIdentity，供模型与桌面总入口共用：已知客户端路由要求 clientThreadId、路由、可用性和原生类型精确匹配；旧无 ID 回退必须没有已知路由和客户端身份。有效 token 仍由入口与控制器分别校验。

DesktopBackend 的默认构造仍使用正式 CodexClient 和 MacUIController；测试只注入其 Core 读取接口，未增加可由环境变量或 MCP 开启的测试后门。N14、U14、W08 现在都经过完整桌面入口，日志显式包含 desktopBackend=true。W08 修复后验证两类客户端路由上的八次 Fast／Plan／MIND／模型操作及回读。

| 场景 | 处理与证据 |
| --- | --- |
| 客户端 ID、路由、token 或类型不一致 | X01 检查 12 种拒绝变体，并保留正常客户端和旧无 ID／草稿规则 |
| 面板显示模型后，该模型从最新目录移除 | X02 每次写入重读目录，原生输入零次 |
| 最新目录读取失败，但存在旧缓存 | X03 清空旧模型信息；无输入、无自动重试 |
| 查询目录期间切到另一客户端 | X04 入口重新观察后拒绝旧 token，原生输入零次 |
| 模型仍在，但请求强度已不支持 | X05 在切模型前拒绝组合，不留下只完成一半的模型切换 |
| 第一次操作等待目录时收到第二次写入 | X06 第二次被拒绝；第一次恢复后仅执行 Fast，Plan 不变 |
| 普通首页、自定义任务键、客户端路由 | 既有 N14／U14／W08 改为经过正式 DesktopBackend，再到原生控制器 |

X01–X06 日志为 `dist/macos/parity-desktop-backend-replay.jsonl`。这些仍是受控 Core／OS 边界回放，不是实际 Codex 界面点击；正式包进程套件另行运行。自动槽位绑定与客户端关联记录读取仍未完成，本轮先修复了实际派发入口，未用磁盘草稿 ID 或时间相邻 UUID 补位。

preview.30 最终结果：292 项 Swift、39 项正式包进程 E2E、299 条 JSON 回放通过；40 键帽／164 项离屏指标、Universal 双架构、plist、签名、ZIP 完整性和 15 文件单向源码同步通过。完整记录为 `dist/macos/parity-validation.json`，preview.29 记录已独立保留。


## preview.31：客户端路由关联正式会话 ID

重新 fetch 三个仓库后远端提交未变。继续对照客户端运行时代码发现：`client-thread-bindings-v1` 保存 client→UUID，`thread-client-id-v1:local%3A<UUID>` 保存反向关联；多个 client 可以指向同一 UUID。客户端路由在创建后仍可能保留，所以不能截取其 UUID 部分作为正式会话 ID，也不能把 client 身份直接认作未提交草稿。

新增只读 `get_keypad_client_thread`：要求已观察到的 rosterScope，先校验账号与本地存储，再读取关联及精确 thread/read(includeTurns=false)，最后重新校验账号、连接代次、存储和关联。结果只返回 ID 与名称，不回传聊天预览或正文。正反向关联指向不同会话、错误回读 ID、账号切换或读取期间的绑定变化都拒绝；缺失或已删除的关联返回未解析，不推断草稿。

面板只对当前明确 client 路由查询关联，异步读取后再次观察原生窗口与 token。验证过的 UUID 可以在现有“当前会话”区域显示／复制，也加入显式任务绑定候选；原生 Fast／Plan／MIND／模型设置仍使用输入框 token 和 native_composer，不把关联升级为发送、Stop、审批、Fork 的控制凭据。关联随目标、账号、生命周期变化或两秒观察过期而失效。

| 场景 | 验证与结果 |
| --- | --- |
| 正向、反向或一致的双向记录 | Y01／Y02、P40：解析精确旧 UUID，不修改状态或桌面 |
| 多个客户端曾打开同一个会话 | Y02、P40：接受有效正向关联，不要求反向记录仍保存旧客户端 |
| 正反向冲突、非法 UUID、错误 server 回读 | Y03／Y06、P42／P45：拒绝；无证据时不查询任意 UUID |
| 首页全局草稿记录、远程记录或没有关联 | Y04／Y12、P41：不据此推断当前窗口或未提交草稿 |
| 读取期间账号切换、关联被移除或替换 | Y05、P43／P44：前后校验拒绝旧结果 |
| 关联后显示 ID、加入显式绑定候选 | Y07：selectedID 仍为空，native-composer 控制身份保留 |
| 异步查找期间切换窗口、过期、停止或错误响应 | Y08–Y11：不发布旧 UUID |
| 正式 DesktopBackend、原生控制器和设置队列 | Y13：关联后 Plan 只派发一次原生操作，thread_id 零次 |

`CLIENT-BINDING-TRACE` 保存到 `dist/macos/parity-client-binding-replay.jsonl`；P40–P45 运行安装包及桥接进程，使用隔离 App Server 和临时存储。Y13 使用正式 DesktopBackend、MicroModel 和 MacUIController，只注入目录及 OS 边界；这些证据不代替真实 Codex 界面验收。

自动填入空任务键仍未完成：官方空键行为先捕获首页当前 runtime client ID，再等待匹配创建事件。已检查的 home wrapper 没有提供可据此确认当前窗口 client 的属性；pending home textarea 使用固定入口 ID 且未传 conversationId，不能拿全局磁盘草稿记录替代。当前完成的是明确客户端路由的关联读取和用户显式绑定候选。

preview.31 最终结果：305 项 Swift、45 项正式包进程 E2E、312 条 JSON 回放全部通过。40 键帽／164 项离屏指标、Universal 双架构、plist、签名、ZIP 完整性、插件内嵌源码／二进制和 15 文件镜像同步检查通过。preview.30 清单已保留，最新完整记录为 `dist/macos/parity-validation.json`。


## preview.32：热键窗口与项目草稿

继续沿用 preview.31 已 fetch 的远端基线。静态读取当前安装包的精确模块（未启动或控制界面）确认：N1 将 `/hotkey-window` 分类为 home，`/hotkey-window/new-thread` 为 new-thread-panel；热键专用 HomePage／NewThreadPage 都渲染正式 composer，但没有主窗口 `[container-name:home-main-content]` 标记。`/projects?projectId=…` 也属于 home 范围。普通旧 `new-thread-panel-page` 则直接重定向到 `/`，不能与热键专用页混为一谈。

Mac 原先只在 `/` 加主窗口容器证据时识别草稿，三个实际入口都会被当作普通页面。项目查询参数也没有参与草稿身份，使项目 A→B 复用 AX 节点时保留旧 token。新增回放通过正式 MicroModel、DesktopBackend 和 MacUIController 复现 5 个场景、9 个失败断言，保存在 `dist/macos/parity-draft-route-regression-before-fix.log`。

修复后热键页要求当前唯一可用输入框及找到 composer 容器，不要求主窗口的 home 类名；具体操作仍要求原生模型选择器、可用状态和当前 token。项目草稿仍要求 home 容器，并要求单一非空本地 projectId，将该范围纳入 route key；切换项目、窗口草稿入口或创建出 client 路由时使旧 token 失效。多个文档必须指向同一个范围。没有输入框的加载页、重复／空项目参数、远程 host、旧重定向、云端及其他页面不扩展为本机草稿。

| 场景 | 证据 |
| --- | --- |
| 热键首页与独立新建页，旧侧栏仍选中会话 | Z01：需要输入框，清除旧 UUID；两个草稿入口有不同身份 |
| 项目 A/B、新 query 顺序、显式本机 host | Z02：同范围保持身份，切项目改变身份 |
| 非法参数、远程／durable host、其他页面 | Z03：27 个变体不获得草稿控制 |
| 多个实时文档范围不同 | Z04：拒绝；同项目等价 URL 接受 |
| 原生 AX 观察没有主窗口 home 类名 | Z05：正式 observeRoute 使用热键输入框；没有输入框／容器不视为草稿 |
| 项目 AX 范围与嵌套网页 | Z06：项目变化可见，嵌入页面不能贡献草稿路由 |
| 热键首页 Fast／Plan／MIND／模型 | Z07：正式桌面入口与设置队列完成四次原生操作并回读 |
| 热键新建页四项设置 | Z08：同上，零会话 ID 派发、零发送 |
| 项目草稿四项设置 | Z09：同上 |
| 项目变化但复用同一窗口、输入框 | Z10：旧 token 被拒绝，原生输入零次 |
| 查模型期间草稿已变成 client 路由 | Z11：不把旧草稿设置落入新客户端 |

日志为 `dist/macos/parity-draft-route-replay.jsonl`。Z05／Z06 使用注入的 AX 属性运行正式路由观察方法；Z07–Z11 贯穿正式桌面入口，只替换目录和 OS 边界，未向 Codex 发送输入。真实热键窗口的 AX 暴露和交互仍待现场验收。

本轮也检查了保留 client 路由而侧栏出现正式 UUID 的过渡条件；当前仍按冲突拒绝，尚未把经过关联验证的等价身份接入原生 lease，不能声称该过渡已修复。首页 client 自动绑定同样仍未完成。两个剩余项继续保留，不从标题、时间或全局磁盘首页标识猜测。

preview.32 最终结果：316 项 Swift、45 项正式包进程 E2E、323 条 JSON 回放全部通过。40 键帽／164 项离屏指标、Universal 双架构、plist、签名、ZIP 完整性、插件内嵌源码／二进制和 15 文件单向同步检查通过。preview.31 清单已独立保留；最新完整记录为 `dist/macos/parity-validation.json`。
