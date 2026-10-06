# macOS 场景验证

本目录依据用户 2026-10-05 的明确测试请求新增。工作目录始终为 `codex-micro-monitor`。不将 Swift 单测、夹具应答或隔离界面点击计作真实 Codex 业务验收；逐项结果见 [对照报告](../../docs/architecture/macos-windows-parity-2026-10-05.zh-CN.md)。

## 恢复验证与 E2E 归属（2026-10-06）

用户要求继续修复，且每种场景最多一种 E2E 测试。延续已有测试入口：协议行为仍由 `process_e2e.py` 负责；编辑器配置行为仍由隔离 Micro UI 旅程负责；真实桌面当前身份及唤起仅归属真实应用旅程。不为同一用户场景再建立一套脚本、第二种 UI 框架或复制进程场景。下表中的组件测试不是 E2E，也不作为真实桌面场景通过的替代证据。

| 场景 | 组件回归 | 唯一 E2E 归属 |
| --- | --- | --- |
| 缺少模型按钮或输入框，身份仍可显示但不能写入 | `RecoveryLifecycleTests`、`NativeComposerScopeTests` 分别验证状态交接和原生能力投影 | 真实应用旅程 |
| 慢观察、client 核验、人工选择与过期交错 | `RecoveryLifecycleTests` | 真实应用旅程 |
| 断线、导航与同账号重连保留未读回执 | `RecoveryLifecycleTests`；导航组合仅组件覆盖 | `process_e2e.py` 的持久化／活动协议场景；不另加 UI 未读 E2E，也不把协议测试记为导航验收 |
| 无身份或无布局时 CODEX 恢复、连按不发送 | `RecoveryLifecycleTests` | 真实应用旅程 |
| 系统唤起回调缺失、取消、重复完成 | `ApplicationRecoveryTests`，只注入 Launch Services 回调 | 真实应用旅程中的恢复失败分支，不建立第二种 E2E |
| 高输入框、侧聊天、嵌套网页、多个主输入框 | `NativeComposerScopeTests` | 真实应用旅程 |
| 唤醒合并、轮询停止后的迟到返回 | `ObservationCoordinatorTests` | 真实应用旅程中的生命周期分支 |
| AX 扫描未完成，保留 client 只读凭证但拒绝写入 | `ReadOnlyRouteRecoveryTests` | 真实应用旅程中的扫描失败分支 |
| 打开设置不等于授权，后续授予与撤销重新读取 | `PermissionRecoveryTests`，只注入系统信任结果 | 真实应用旅程中的权限恢复分支 |

本轮真实 UI 工具能读取 Micro 自身界面，但明确拒绝访问 `com.openai.codex`（`Computer Use is not allowed ... for safety reasons`）。因此不能操作 Codex 来完成窗口切换、最小化恢复或侧聊天验收；不会改用其他 UI 技术绕过限制，也不把注入式测试标记为已通过这些真实场景。执行证据保存在 `dist/macos/recovery-verification/`。

最终源码完整 Swift 回归 371 项、0 失败，其中本轮增加 19 项组件回归；最终 Universal 包的现有隔离进程 E2E 45 场景全部通过，没有新增第二套 E2E。新包 PID 94058 的 Micro 自身启动复核仍显示未知当前会话：运行日志确认权限已授予、输入框和容器存在，但模型选择器与精确路由未识别。此真实启动场景记为失败；其余需要操作 Codex 的分支记为受限未执行。测试全部通过不表示用户报告的问题已解决，结果与源码指纹见 `validation.json`，失败证据见 `runtime-evidence.log` 和 `micro-ui-acceptance.json`。

## preview.33 新建与身份生命周期

`CurrentIdentityLifecycleTests` 连续推进正式 MicroModel 的导航、原生和 IPC 观察，包含 14 个 AB 场景；修复前首批 7 项产生 40 处断言失败。`NativeNewConversationReplayTests` 的 AC01–AC04 再接入正式 DesktopBackend / MacUIController，Core 深链和 OS AX/输入才是替换边界。AC01 覆盖新建响应直接交接、旧动作失效以及 Fast/Plan/MIND/模型四类原生设置；AC02/AC03 覆盖导航未确认和原生观察丢失后旧 IPC 持续存在。`ClientAliasTests` / `ClientAliasReplayTests` 覆盖 AA01–AA18 的 client/server 路由别名、账号范围和并发失效。

完整测试 352 项、359 条 JSON 回放轨迹保存在 `dist/macos/preview.33/`。使用 `scripts/package-macos.sh universal preview.33` 与 `scripts/package-macos-plugin.sh universal preview.33` 可生成独立候选；进程 E2E 的 `--app` 必须指向这个候选路径，不能把旧包进程验证记在新源码上。旧 preview.32 包保持原路径。实际 Codex UI 未访问。

## 规则与组件

```sh
swift test --package-path apps/macos
```

`CurrentRouteTests` 覆盖精确路由、启动地址、负路由及冲突。`NativeModeTests` 覆盖速度标签、账号 / host 身份以及 Codex / Micro / 其他进程间的提交焦点转换。`PanelScenarioTests` 运行正式 MicroModel、Settings、UserDefaults，通过注入外部 Desktop 边界覆盖操作时目标重验、队列、40 个目录 ID、8 个槽位和持久化。慢回读场景使用时钟注入；不等待真实 60 秒，不放宽生产超时。

## 原生控制器流程回放（preview.14）

```sh
swift test --package-path apps/macos > dist/macos/parity-swift-tests.log 2>&1
rg '^NATIVE-TRACE |^PAGE-TRACE ' dist/macos/parity-swift-tests.log
```

`NativeComposerReplayTests` 注入捕获、按压、AX 设置、按键、前台进程等操作系统边界，实际运行 `MacUIController` 的目标令牌、菜单路径、焦点和状态回读。N14 还贯穿正式 `MicroModel` 设置队列与原生控制器。目录和 AX 树为受控夹具，不向任何 Codex 进程发送 AX 或键盘输入，也不依赖工具访问 Codex。

N01–N19 覆盖未知模型触发器下的 Plan、三档 Speed、Power 键盘 / 范围值、A/B、模型子菜单、切换后菜单关闭、无效组合请求、外部目标 / 设置变化、权限弹窗、简繁中文标签和新版 Plan mode 候选列表。输出逐项操作与最终状态；N19 分别输出中英文日志。`DialMappingTests` 对齐 Windows 拖动轴、6 点阈值、12 点档距、方向反转及触控板碎片滚动。面板导航队列另测连续六步、反向输入与目标切换取消。

`WorkspaceActionTests` 覆盖设置 / 技能页固定深链、旧页面等待、精确路由回读、系统拒绝不重试和观察失败不冒充成功。`PanelScenarioTests` 逐一将 CODEX 键帽换成 LAB、SETUP、APPS，保存后按压并检查动作和旧对话退役。

## 会话菜单与面板回放（preview.15–17）

`NativeThreadMenuTests` 继续运行正式 `MacUIController`，新增 T01–T09：中英文置顶往返、原生 Markdown 子菜单及成功通知、并发复制拒绝、切换目标时不关闭另一会话菜单、保留归档确认、精确归档状态回读、输入框隐藏时会话菜单仍可用、原生 Terminal 菜单往返、多终端与零尺寸 xterm 输入框。另测重复入口、冲突状态、旧通知、缺失终端命令、归档结果未知和 ID 不匹配。所有 AX、前台、按压、键盘和剪贴板边界均为夹具，不触达真实 Codex。各原生回放的快捷键读取也全部注入，不读取用户实际 keybindings.json。

preview.16 的 T10 验证中英文 NAV 原生命令、新浏览器页身份及打开后 composer 隐藏；T11 检查旧浏览器页和无面板身份的同名地址输入框不能确认新建；T12 验证发出一次面板命令后目标变化，不确认另一会话的面板，也不补发。TIME 加入页面回放，必须读到精确 `page:/automations`，不创建或运行任务。

preview.17 的 T13 验证中英文反馈表单及已知页面无输入框的入口；T14 拒绝其他模态窗口、变化的目标和缺失原生命令，不填写或提交。T15 要求原父对话下新出现的侧边聊天及可用 ProseMirror 输入框；T16 检查既有页或加载中空页不能确认新建，也不重复创建。

日志前缀为 `THREAD-MENU-TRACE`，保存到 `dist/macos/parity-thread-menu-replay.jsonl`，共 24 条记录。日志只含动作、夹具状态和变更次数，不含剪贴板文本。组件测试还分别将 CODEX 改为 TERM、MAGIC、DWN、DEL、NAV、PARTY，保存后验证实际派发的精确 ID 与令牌；归档成功清除旧目标和列表项。TIME、BUG 同样验证更换、保存、按压及离开对话后的目标清除。

## 文件／照片选择器回放（preview.17、21）

`NativeFilePickerTests` 注入同进程窗口枚举，运行正式 `NativeFilePicker` 和 `MacUIController`。F01 覆盖英文、简体、港繁、台繁的添加菜单、独立原生选择窗口及取消返回；F02 是没有对话 ID 的新草稿；F03 检查 Files and folders 缺失时不能选 Add photos；F04 在菜单打开后换目标时不选择也不清理另一输入框；F05 的无新窗口或多个新窗口保持未知。已有选择窗口也不能授权另一遍操作。文件选择器没有模型选择器依赖。

日志前缀为 `FILE-PICKER-TRACE`，保存到 `dist/macos/parity-file-picker-replay.jsonl`，共 28 条记录。UPL 更换、保存、按压另经面板测试，验证只派发当前令牌，进入模态窗口即清除旧 ID，后续 IPC 可见状态不能恢复它。此层只验证打开选择器，结果明确包含 `awaitingSelection=true`、`attachmentVerified=false`；没有选择测试文件，不等于实际附件添加验收。preview.21 当时总计 168 项 Swift 测试，preview.22 增至 184 项。

preview.21 的 F06–F15 继续使用正式选择器控制器：四种语言的 Add photos → Select photos；已确认草稿；缺少照片入口时不选普通文件；已有专用快捷键及发送前配置 / 目标重验；拒绝裸 Return；窗口缺失、普通文件窗口、重复窗口或权限弹窗；已有任一附件选择器；菜单打开后换目标；快捷键结果未知时不回退菜单、不重发。文件／照片共 16 项测试、28 条记录。返回 `pickerKind`、`pickerEntryPoint`、`imagesOnlyRequested`，仍为 `awaitingSelection=true`、`attachmentVerified=false`。PAINT 换绑、保存、按压及模态状态清除旧目标另有面板测试。

## Git 原生表单回放（preview.18–21）

`NativeGitWorkflowTests` 运行正式控制器与命令菜单适配器，只注入 AX、前台、按压和键盘边界。G01 是四种语言的分支表单；G02 是四种语言下普通 / 草稿 PR 的不同默认选项；G03 验证命令缺失、禁用、重名时不选备用动作；G04 覆盖打开命令菜单前后目标变化；G05 拒绝无表单、其他表单和错误的 PR 默认选项；G06 验证权限弹窗不会被当成命令菜单，也不发送 Esc。另测原生应用命令缺失和 thread ID 不匹配时零派发。

六类回放统一由 `ReplayTrace` 单次写入完整 JSON 行，避免重定向时被 XCTest 诊断插断。全量输出的 174 条记录分别解析并核对数量。

日志前缀为 `GIT-WORKFLOW-TRACE`，保存到 `dist/macos/parity-git-workflow-replay.jsonl`，共 80 条记录。MRG、GIT、BRANCH、PR、BRCH 分别从 CODEX 键帽换绑、保存、按压，核对精确 ID 和令牌；打开表单后旧令牌失效。确认的是 Codex 命令所定义的表单打开行为（`workflowOpened=true`、`mutationCompleted=false`）；测试不生成分支、提交、推送或 PR，最终创建仍属于真实业务验收项。

preview.20 增加 G07–G12：四种语言的完整提交表单和无提交信息字段的推送表单；GIT / PR / BRCH 三种命令的前置 Work here 分支表单；错误标题、容器、缺失 / 重复选项；命令不可用；选中前后切换会话；提交表单上方的权限弹窗。新增 8 项测试、37 条记录，Git 总计 15 项测试、58 条记录。控制器返回 `workflowStage=branchSetup|commitForm|pullRequestForm`；前置分支阶段的 `prDefaultVerified=false`，不误报已验证普通 / 草稿默认值。GIT 的键帽换绑、保存、ID / token 派发以及无 ID 草稿拒绝也纳入面板测试。不选择提交、推送或创建按钮，不更改文件范围。G13 验证四种 Git 命令与同名聊天并存时只选 Project 分组；G14 验证分组缺失或重复时不选聊天结果。

preview.21 的 G15–G20 验证 MRG：四种语言及 squash / merge commit 两种选择；没有方法选择器的单一方法仓库；缺失、禁用或重复命令；错误标题、缺取消按钮、重复或冲突确认按钮、误开的分支表单；选中前后换聊天；权限弹窗；ID 不匹配和应用命令缺失。G13 也加入 MRG 与同名聊天并存。Git 共 21 项测试、80 条记录。`workflowStage=mergeConfirmation` 只确认原生合并确认界面，`mergeMethod` 来自最终按钮；`mergeCompleted=false`、`pullRequestIdentityVerified=false`，不从随机面板 ID 推算 PR 编号。

## 环境动作回放（preview.19）

`NativeEnvironmentActionTests` 使用正式命令菜单与控制器，注入系统边界，不执行 shell。E01 验证四种语言下 Project 组中配置顺序的首个 Run 动作，不选工具栏最近使用项或同名聊天；E02 验证明确再次按压可复用既有动作终端；E03 拒绝非空或不可读搜索；E04 拒绝缺失 / 重复 Project 组、缺动作或禁用首项；E05 拒绝同一 AX 节点名称中途变化；E06 验证错误动作槽、其他聊天、隐藏 / 重复 / 缺失终端只派发一次且保持未知；E07 在打开菜单或派发后换聊天，不重发、不关闭另一聊天的菜单。

7 项测试产生 19 条 `ENVIRONMENT-ACTION-TRACE`，保存到 `dist/macos/parity-environment-action-replay.jsonl`。另有两个面板测试验证换为 PLAY 自动换绑、保存后精确 ID / token 派发，以及失败和不可用状态。结果的 `runRequested=true`、`terminalVerified=true` 只表示原生动作与指定终端交接；`executionVerified=false` 明确没有确认命令退出状态。六类回放共 174 条 JSON 记录均逐条解析。

## 安装包进程 E2E

```sh
scripts/package-macos.sh universal
python3 tests/macos/process_e2e.py \
  --app 'dist/macos/universal/Codex Micro Monitor.app/Contents/MacOS/CodexMicroMac' \
  --report dist/macos/parity-process-e2e.json
```

启动真实安装包的 `--mcp` 入口及真实 MicroDesktop 原生桥接，设置临时 `CODEX_HOME` 和夹具 CLI，连接临时 Unix IPC 服务。覆盖握手、分片帧、设置回读、提交 / 停止、四种审批、丢失应答、未读、Fork 前置条件及精确对话目录读取。目录场景检查正确 ID、返回 ID 不匹配和 cwd 缺失，仅调用只读接口，不启动 Finder。P13 / P14 验证归档列表的精确 ID、跨页结果、1000 条上限保持未知、重复 / 非法游标和 thread/read 返回 ID 冲突；不发送任何归档写入。P01 还核对正式包中会话菜单、面板、反馈、文件选择器、Git 表单及 PLAY 工具的必填参数和非幂等声明，只读取工具目录，不调用原生 UI 工具。所有 ID、令牌、文本和回合均为夹具数据，不打开 Codex、不发送深链、不读写用户实际会话。

## 隔离 Micro UI

```sh
python3 tests/macos/prepare_ui_fixture.py \
  --app 'dist/macos/universal/Codex Micro Monitor.app' --launch
```

命令输出临时文件夹。应用具有独立 bundle ID，移除 URL scheme 注册，保留正式 UIKit 编辑器和本地 UserDefaults；原生桥接替换为 `FixtureDesktopBridge.swift`。桥接不链接 MicroCore，仅返回受控状态并将操作写到 `actions.jsonl`。原始应用不变。

通过 CUA 选择输出目录里的 `Micro Isolated E2E.app`，读取工具文档后使用 `ui_journey.cua.js` 中的 helper，每批 3–4 个键帽。参数分别为已选择的 app、键帽 ID、当前图案的可访问名称、预期动作标签；搜索结果同名时使用 occurrence。helper 校验保存后的值并按压，随后必须独立检查 `actions.jsonl`：支持项仅有期望操作，不支持项没有操作。此脚本不作为 shell / Node 自动化脚本运行，不指向 `com.openai.codex`。

额外旅程：无审批的 APPR / REJ 不出现浮层；任务右键标未读后看到 Unread 与绿灯；编辑后 Esc 不落盘；保存 NEW 后终止并以相同环境重启同一复制应用，NEW 仍在且只派发一次。日志只记录夹具 ID，不含真实聊天内容。

结束时终止输出目录 `pid` 中的夹具进程，并删除 `bundle-id` 所指的专用 UserDefaults 域。保留验证所需日志后可删除该次临时目录。不要删除真实 Micro 的设置，不要操作其他会话的测试应用。

无 ID 回退场景使用 `--native-composer --launch`。状态中保留一个旧 IPC 可见线程，但原生输入框没有 threadId：Micro 应显示 Current composer，复制 ID 禁用；Fast、Plan、MIND+ 操作日志必须全部带 `native_composer=true` 且不含 `thread_id`；按发送、审批、Fork 不产生日志。将 ACT06 从 FAST 改成 MIND+，默认动作变为 More reasoning，按压后强度从 medium 回读为 high。此流程只验证 Micro 界面到替换桥接，未触达真实 Codex。

网站 / 目录场景显式使用 `--workspace-actions --launch`。这会将正式 `WorkspaceActions.swift` 编译进夹具桥接：OAI **实际打开默认浏览器**，FOLD **实际打开 Finder**，其余操作仍是夹具。目录在该次临时目录内创建，路径写入 `workspace-folder`，内含 `MICRO-E2E-ONLY.txt`。依次编辑 OAI、FOLD，核对自动切换的默认动作，保存并按压；通过 CUA 核对浏览器 URL 为 `https://developers.openai.com/`、Finder 为该次测试目录且包含标记文件。独立日志必须只有一次无参数网站操作和一次精确夹具 thread_id 的目录操作。关闭本次 Finder 窗口；不关闭无法证明属于本次测试的浏览器标签页。此模式不连接真实 Codex，也不证明实际对话的 cwd 识别通过。

`WorkspaceActionTests` 覆盖固定网站、系统拒绝后不重试、含空格及 URL 特殊字符的本机目录、相对路径 / 普通文件 / 缺失目录拒绝。组件场景另测无 Codex 连接打开 OAI、FOLD 操作前目标切换取消，以及无 ID / 草稿禁用。

## 真实 Codex 验收

此前工具拒绝访问 Codex；用户随后要求改用 E2E 日志及 Windows 源码推进，本轮未再尝试访问，也不把这一层作为源码修复的阻塞条件。无需为了运行前三层申请 Codex 辅助功能权限。只有在允许的联调环境中，才能验证原生 AX 树、焦点、实际模型 / 模式及最终业务结果；不得用备用 UI 通道绕过工具拒绝。


## 固定文字预置（preview.22）

`NativePresetTextTests` 运行正式 MacUIController / NativePresetText，捕获、聚焦及 Unicode 输入均为注入边界，禁止剪贴板、快捷键、窗口枚举和其他 AX 动作。12 项测试输出 40 条 `PRESET-TEXT-TRACE`，保存为 `dist/macos/parity-preset-text-replay.jsonl`。C01–C12 覆盖两个预置的空白／光标／选区、UTF-16 Unicode、多行草稿、聚焦、非法选区和半个代理对、输入前九种变化、五种未知结果、输入后换目标、新旧 token、非法预置和无身份目标。

4 项新增面板测试验证预置换绑、持久化、唯一派发、草稿、未知文字、错误无重试，以及每个空白键零派发。目录测试独立核对全部 40 个键帽。P01 核对正式包内新 MCP 工具的枚举、必填字段及非幂等声明。全量为 184 项 Swift 测试、17 项进程场景和 214 条可解析回放记录；未访问真实 Codex UI，未将窗口外输入或实际输入法兼容性列为已验收。


## 安装包离屏图案检查（preview.22）

```sh
python3 tests/macos/design_e2e.py \
  --app 'dist/macos/universal/Codex Micro Monitor.app/Contents/MacOS/CodexMicroMac' \
  --directory /tmp/micro-design-new-run \
  --report dist/macos/parity-design-e2e.json
```

输出目录必须为空，避免旧 PNG 掩盖新程序崩溃。正式 `--export-design` 入口先于 UIApplication 和 Desktop 桥接初始化：验证 40 个键帽与 FAST_ON、四档缩放下 164 项图案尺寸、中心和双主题 PNG。这项验收捕获并修复了 EMPT 资源假设造成的启动崩溃。离屏图案还发现 BRANCH / UPL 通用导出丢失描边，已换成完整矢量定义；不属于真实窗口交互测试。


## 自定义任务映射（preview.23）

`TaskMappingScenarioTests` 使用正式 MicroModel / Settings 与注入目录，R01–R11 共 11 项覆盖 14 个稀疏槽位、同名与旧任务、缺失条目、重启、账号切换、按住改绑、悬停冻结、晚到读取、显式最近快照／清空、未知身份和旧设置兼容。`TaskRosterTests` 另有 6 项验证稳定 scope、参数上限、去重读取、不同账号零旧 ID 查询、单项拒绝和返回 ID 冲突。11 条 `TASK-MAPPING-TRACE` 保存到 `dist/macos/parity-task-mapping-replay.jsonl`。

正式安装包 P18–P21 验证旧任务只读解析、缺失任务不重启健康连接、账号隔离、非法数组的 JSON-RPC 参数拒绝以及错误返回 ID 不冒充成功。夹具 `name=null` 验证 preview 标题回退。所有请求日志断言只读，不发送真实导航或更改 Codex 任务。全量 201 项 Swift、21 项进程场景和 225 条 JSON 日志；新增 UIKit 设置选择器已编译，未运行真实 UI 验收。


## 本机固定任务（preview.24）

`PinnedRosterTests` 的 7 项规则检查精确分组 ID、原生排序参数、分组／任务分页、前 14 个上限、未知身份、不支持协议、同名其他分组、缺失分组、错误 section、重复 ID、非法／重复游标与有界读取。`PinnedTaskScenarioTests` 的 S01–S08 运行正式 MicroModel，验证旧任务精确打开、空或不可用列表、按住重排、悬停取消固定、切账号、晚到结果、重启与失败清理，输出 8 条 `PINNED-TASK-TRACE`。

P22–P25 使用最终安装包真实只读目录和桥接，核对相同分页顺序、按需枚举、健康连接保持、拒绝错误页、十四项上限及身份缺失零固定查询，并检查全局状态字节与派发记录不变。进程测试发现并补上了只读目录允许清单中的 `threadSection/list`；没有加入任何分组或固定写入操作。新“固定任务”设置项通过 Catalyst 编译；未访问真实 Codex UI。

preview.24 最终全量为 216 项 Swift、25 项进程场景与 233 条 JSON 记录。安装包离屏图案检查仍为 40 键帽、164 项指标；最终包签名、Universal 与 ZIP 检查通过。


## 优先级与大列表活动流（preview.25）

`PriorityRosterTests` 的 10 项规则检查完整分页、空中间页、重复／非法 ID 和游标、异常目录上限、服务失败、灯光与注意力分离、有效时间回退、状态发现的批次／并发／轮转／冷却。`PriorityTaskScenarioTests` 的 Q01–Q09 使用正式 MicroModel，覆盖等待／未读／运行顺序、第 115 条任务精确打开、同档时间与稳定同值、活动流动态提级和中断、悬停身份、目录不完整、账号范围变化及晚到成功观察隔离；失败路径同样核对捕获范围（源码复核）、切回 recent。日志前缀为 `PRIORITY-TASK-TRACE`。

P26–P31 使用正式包和原生桥接读取 150 项目录，验证跨页元数据、第一百条之后的真实 IPC 问题状态、只有 unread 变化而 running 灯不变的补丁与 revision、错误分页、recent 恢复、旧未加载任务的 rollout 问题与完成。P27 曾复现连续发送 64 项查询引起的双向缓冲区拥塞；最终实现每批 8 项并交错读写，保留 64 个并发上限。夹具发送分片帧以保留这一覆盖，不访问真实 Codex、不发送任务消息。

preview.25 最终全量：235 项 Swift、31 项安装包进程 E2E、242 条解析成功的 JSON 回放。运行过失败的 P27 已在最终 Universal 包重测通过；40 键帽、164 项离屏指标及包完整性均通过。

## 灯态和实时前台焦点（preview.26）

8 项 TaskLampScenarioTests 与 1 项 NativeLampFocusTests 产生 L01–L09，保存为 `dist/macos/parity-task-lamp-replay.jsonl`。正式模型覆盖错误／审批／问题优先级、前台选中未读的显示隐藏、原始未读及其他任务保留、过期或倒退的观察时间、冲突路由、草稿／弹窗／可见回退／手选来源，以及目录移除和断开连接后的缓存退役。正式控制器在注入的六次 PID 切换中区分 appFocused 与保留提交焦点的 foreground，不访问实际应用窗口。

P32 使用打包桥接及分片 IPC 夹具，连续推进错误 → 审批 → 问题 → 运行未读 → 空闲未读 → 空闲，分别验证灯态、独立 attention 和 revision。所有读取／观察场景均断言零业务写入，不将显示隐藏转换为已读确认。

preview.26 最终全量：244 项 Swift、32 项安装包进程 E2E、251 条 JSON 回放；离屏 40 键帽／164 项指标、Universal、签名、ZIP 和插件源同步通过。没有真实 Codex 界面验收。

## 自定义任务命令（preview.27）

14 项 TaskCommandScenarioTests 与 1 项 NativeTaskCommandReplayTests 覆盖 U01–U15，日志为 `dist/macos/parity-task-command-replay.jsonl`。U05 在 AG13 逐个指定全部 46 个支持命令，核对派发操作及精确 ID／token／审批请求；U14 从混合自定义槽位进入正式 MicroModel 队列和 MacUIController，完成新草稿 Fast、Plan、MIND 的原生菜单回放与回读。其他场景包括固定／最近／命令混排、重新排序、按住身份、互斥配置、移动固定绑定、跨账号同名命令、晚到读取、重启、来源切换、清空、非法配置、目标变化和双击首击不执行命令。

preview.27 最终全量：259 项 Swift、32 项安装包进程 E2E、266 条 JSON 回放；离屏 40 键帽／164 项指标、双架构、签名、ZIP 和插件源同步通过。新增 UIKit 命令菜单仅完成编译，真实 Codex 仍未访问。新草稿自动绑定需要额外身份协议，当前没有用观察先后顺序代替身份关联。

## 固定项目混排（preview.28）

13 项 `PinnedProjectTests` 与 1 项 `PinnedProjectTaskScenarioTests` 产生 V01–V14，保存为 `dist/macos/parity-pinned-project-replay.jsonl`。规则覆盖项目／会话混排、重复排除、排序后取前 14 项、项目手动顺序、旧设置归一化、精确本机迁移范围、错误成员／项目／游标、协议不支持、已删除和原生镜像项目、未知账号与稳定同值。V14 经正式组合逻辑进入 MicroModel，验证按住期间重排及悬停期间移除时旧槽位不能导航。

正式包 P33–P39 覆盖跨页项目与成员、显式顺序切到同连接缓存再切回最近活动、错误页与不支持协议、枚举期间偏好变化、其他存储根映射隔离、首 14 条之后更活跃的 pin，以及没有单独固定分组时仅显示项目成员。P33 核对全局状态文件字节不变，所有新增场景均检查零业务写入；故障场景的配置变更只由夹具触发。项目存在性与 canonical 成员由只读 App Server 确认，不从工作目录或同名标题猜测。

preview.28 最终全量：273 项 Swift、39 项安装包进程 E2E、280 条 JSON 回放；40 键帽／164 项离屏指标、双架构、签名、ZIP 和 15 文件插件源同步通过。真实 Codex 未访问；旧项目迁移、跨 host／云端及 Micro 首次观察前仅在官方渲染器内存中的手动次序仍有差异。

## 客户端路由与 host（preview.29）

7 项 `ClientRouteTests` 和 6 项 `NativeClientRouteReplayTests` 产生 W01–W13，保存为 `dist/macos/parity-client-route-replay.jsonl`。覆盖本机／热键窗口、客户端与服务端 ID 分离、host 查询参数、文档与侧栏冲突、bootstrap 与旧 IPC 回退、畸形身份、AX 节点复用、客户端切换到正式 UUID、桥接投影一致性及业务动作门禁。W08 在两类客户端路由上实际运行正式 MicroModel 队列与 MacUIController，完成 Fast → Plan → MIND → 模型切换及回读；全部操作无 thread_id。W09 在聚焦期间改变客户端路由，确认不会继续键盘写入或清理新目标的菜单。

preview.29 最终全量：286 项 Swift、39 项正式包进程 E2E、293 条 JSON 回放；40 键帽／164 项离屏指标、双架构、签名、ZIP 和 15 文件源码同步通过。真实 Codex UI 和 Windows 执行均未验证；客户端持久关联记录和空槽位自动绑定仍未接入，不按会话创建先后猜测。

## 正式桌面派发入口（preview.30）

先将 N14／U14／W08 的 NativePanelBoundary 改为经过真实 DesktopBackend，仅注入 Core 目录与 OS 边界。W08 在旧规则下复现 16 个断言失败，日志为 `dist/macos/parity-backend-regression-before-fix.log`；这更正了 preview.29 只覆盖控制器、没有覆盖正式总入口的局限。修复后 N14、U14、W08 的日志均带 `desktopBackend=true`。

X01 的入口规则与 X02–X06 的五项实际桌面入口回放保存为 `dist/macos/parity-desktop-backend-replay.jsonl`：客户端身份／token 组合、最新目录移除模型、目录失败、查询期间换客户端、无效模型／强度组合，以及暂停第一次目录读取时并发第二次写入。拒绝路径检查零原生输入；并发场景只允许第一次 Fast 完成，Plan 保持不变。

preview.30 全量：292 项 Swift、39 项正式包进程 E2E、299 条 JSON 回放；离屏 40 键帽／164 项指标、双架构、签名、ZIP 和 15 文件源码同步通过。未访问真实 Codex UI，自动绑定仍未完成。


## 客户端与正式会话关联（preview.31）

`ClientThreadBindingTests` 的 Y01–Y06 核对正反向关系、同一会话的多个客户端、冲突和缺失记录；`ClientBindingPanelTests` 的 Y07–Y12 运行真实面板，验证当前 UUID、显式选择候选、失效／范围／生命周期防护及首页不猜测。`NativeClientRouteReplayTests` 的 Y13 经过正式 DesktopBackend 与原生控制器，验证关联后仍按 native_composer 令牌设置 Plan。P40–P45 使用正式包进程和临时 global state，验证精确 thread/read、账号切换、查找期间绑定变化及只读性。没有访问真实 Codex UI。


## 热键和项目草稿（preview.32）

`DraftRouteTests` 的 Z01–Z06 验证解析、项目范围和正式 AX 属性投影；`DraftRouteReplayTests` 的 Z07–Z11 贯穿正式 MicroModel、DesktopBackend、MacUIController，验证三个草稿入口的 Fast／Plan／MIND／模型与旧 token 拒绝。修复前 5 场景 9 断言失败保存在 `parity-draft-route-regression-before-fix.log`。这些是注入目录、AX 和输入的回放，不是实际 Codex 窗口验收。
