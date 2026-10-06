# Mac 隐私权限拖拽引导

调研日期：2026-10-05。范围是专用的隐私权限配置：打开正确的系统设置页面，把实际运行的应用拖入权限列表，并检测系统是否已经授权。

## 选型

采用 [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) 的设置跳转模块和原生拖拽实现思路。该库专门支持系统隐私设置、随设置窗口移动的浮窗、拖入 `.app` 及授权状态检测。核对的最新版本是 [v2.11.3](https://github.com/jaywcjlove/PermissionFlow/releases/tag/v2.11.3)，2026-09-26 发布，MIT 许可；[包清单](https://github.com/jaywcjlove/PermissionFlow/blob/v2.11.3/Package.swift)使用 Swift 6.1，支持 macOS 13 及以上，与本机 Xcode 16.3 / Swift 6.1 和原生 macOS 14 基线兼容。

通用欢迎页、功能高亮或幻灯片库不满足这次拖拽授权的需求。实现不包含欢迎页或一次性“已完成引导”记录，也不引入与 Micro 无关的隐私权限。

接入边界：

- 直接通过 SwiftPM 链接 `SystemSettingsKit`，精确固定版本 `2.11.3`。`apps/macos/Package.resolved` 锁定提交 `cb96db4bfd2342e8d8c56f2a7d51ca65b8aed6e2`。
- 将上游 `AppDropArea.swift` 的原生文件拖拽适配为纯 AppKit 卡片；将 `SettingsWindowTracker.swift` 的窗口几何读取适配为仅跟随系统设置的实现。
- 浮窗和权限状态使用 Micro 自己的 AppKit View、Model 和 Coordinator。不链接完整的 SwiftUI `PermissionFlow` UI，也不链接可选的其他权限检测模块。
- 完整 MIT 声明位于 `apps/macos/ThirdParty/PermissionFlow/LICENSE`，Xcode 和发布构建均将其复制到桥接 bundle 的 `Contents/Resources/ThirdParty/PermissionFlow-LICENSE`。适配范围另见同目录 `README.md`。

完整上游 UI 不能直接放入当前原生桥接：前一轮候选的隔离进程检查已证实 `NSHostingView` 无法加载。dyld 报告缺少 `SwiftUI.NSHostingView.init(rootView:)`，期望符号所在库实际为 `/System/iOSSupport/System/Library/Frameworks/SwiftUI.framework`。根因是 Catalyst 宿主加载 iOSSupport 的 SwiftUI，无法提供原生 macOS 的 SwiftUI 宿主符号。仅编译原生动态库会漏掉这一运行时问题。故本轮保留纯 AppKit 面板，仅复用无 SwiftUI 依赖的 `SystemSettingsKit`。先前的失败证据保留在 `dist/macos/permission-setup/loader-before-appkit-fix.log`；`Desktop` 使用 `Bundle.loadAndReturnError()` 记录实际加载失败原因。

## 交互和状态

1. 缺少辅助功能权限时显示紧凑权限面板；菜单始终保留“权限配置”入口。
2. 点击“打开辅助功能设置”才请求系统授权并跳转到对应隐私页面。面板保持非激活状态，放在系统设置窗口旁；外侧空间不足时限制在屏幕可见区域内。
3. 按住应用卡片，直接把当前运行的 `.app` 拖入系统设置的辅助功能列表，然后开启开关。系统可能要求用户认证。
4. 面板按实际 `AXIsProcessTrusted()` 结果更新为已授权。拖拽被接收、系统设置成功打开、列表出现条目，均不等同于授权生效。

如果旧条目已开启却仍未授权，面板提示移除旧条目后重新拖入。当前应用地址来自 `Bundle.main.bundleURL`，不会硬编码 `/Applications` 或把 Debug、Release、桥接 bundle 混为一谈。Finder 定位及手动重新检测作为辅助操作保留。

职责：

- `PermissionSetupModel`：独立于账号、IPC 和会话目录，用主 actor 上的真实系统权限作为唯一依据；设置打开失败单独呈现。
- `PermissionAppDragView`：校验当前应用为实际存在的 `.app` 目录；使用系统 `NSURL` 的 `NSPasteboardWriting` 实现输出文件 URL。仅允许复制操作；不声明尚未存在的 promised file，不修改或移动应用。
- `PermissionSettingsWindow`：通过窗口服务器读取系统设置窗口的位置及大小，不依赖尚未取得的辅助功能权限，不读取屏幕图像或其他应用内容。处理多显示器坐标及可见区域约束。
- `PermissionSetupCoordinator`：管理非激活浮窗、权限轮询和跟随生命周期。引导期间每 150 毫秒读取设置窗口几何，权限最多每秒查询一次。系统设置退到后台时隐藏浮窗，关闭后结束跟随；找不到设置窗口时有超时降级。拖拽期间停止重定位并让浮窗忽略鼠标，避免遮挡目标列表；结束或取消拖拽后恢复。
- `PermissionSetupView`：沿用 Micro 设置页配色，使用中英文资源，呈现当前状态、可拖拽应用、必要操作和旧条目恢复提示。
- `MicroDesktopBridge`：只在 GUI 窗口配置后创建引导；MCP 和设计导出不会初始化它。原生观察报告权限缺失时重新读取系统状态，避免迟到的失败结果覆盖恢复后的授权。

点击“稍后配置”只抑制本进程本轮缺失状态的自动展示。检测到真实授权后重新允许未来权限撤销时展示。关闭面板、隐藏 Micro 或系统休眠会停止跟随与轮询。没有持久化的完成标志。打开设置和 Finder 均由用户点击触发，不改写 TCC 数据库，不自动点击系统开关或重新启动程序。

现有桥接协议、实现、权限模型的依赖闭包均显式遵守 `@MainActor`，通知中心主队列回调在主 actor 内处理窗口与状态。

## 验证边界

遵循仓库要求，不新增测试代码，不操作真实 UI 或系统权限。运行既有 Swift 回归及打包后的隔离 MCP 进程检查，检查双架构、严格签名、ZIP、许可证及本地化资源。上述检查不能替代真实拖入系统设置和授权恢复的 UI 验收。

本轮候选输出到 `dist/macos/permission-drag/universal/`，使用本机既有 Apple Development 证书，不使用临时签名，不替换当前运行的 Xcode Debug 程序。验证结果和产物哈希记录在 `dist/macos/permission-drag/validation.json`。

本轮最终验证：352 项既有 Swift 测试、45 项打包后隔离进程场景全部通过；Universal 主程序和桥接、严格签名、ZIP、两份本地化资源、MIT 许可证入包及插件 15 文件同步均检查通过。原生桥接没有链接 SwiftUI。真实系统设置跳转、拖放、浮窗排版与 TCC 授权恢复尚未做 UI 验收。

## 2026-10-05 22:41 已开启但检查失败

实际运行的是 DerivedData 下 Xcode Debug 程序，PID 82936，Apple Development 稳定证书签名。只读系统日志显示：

- 22:40:30、22:40:59，系统设置向 `TCCAccessSetInternal` 传入了正确的 Debug `.app` URL，并写入当前开发者证书的 designated requirement。拖拽路径并没有指向另一应用。
- 后续检查仍命中了旧的临时签名要求 `03a77c…` / `cb9764…`，返回 `authValue=0, authReason=5`。
- 22:41:02、22:41:03，设置中的旧同名条目对 `dist/macos/mvvm-refactor/universal/` 副本执行关闭和开启，再把该 bundle ID 的记录覆盖成旧包的临时签名要求 `a8c4fc…` / `d12f2a…`。这两个哈希与旧候选包的实际签名一致。
- 22:41:04，当前 Debug 程序仍被 TCC 拒绝。不是把面板状态改为成功就能修复的问题；当前权限依据仍应使用系统真实返回值。

恢复需要只清除此 bundle ID 的辅助功能旧记录，再由用户添加当前应用并开启。可用系统命令 `tccutil reset Accessibility com.gantrol.codex-micro-monitor`，不重置其他应用或权限；执行需要用户明确授权。必要时重启 Micro 后重新检查，避免继续沿用旧状态。不要继续切换旧候选的同名开关，不改写 TCC 数据库，也不添加私有 entitlement。

本轮另外修正了实际日志中的 `NSFilenamesPboardType` 非法 UTI 警告：改用系统 `NSURL` 拖拽写入器。该警告与签名冲突分别处理，不能将其冒充为 TCC 拒绝的唯一原因。手动检查失败现在明确显示当前程序仍未授权及修复步骤，并记录当前程序路径、PID、实际检测结果；状态未变化时不持续刷权限日志。浮窗跟随也只在可见性需要变化时调整前后顺序，避免每 150 毫秒刷同一条窗口日志。

证据存于 `dist/macos/permission-recovery/tcc-evidence.log`。本轮仅从现有日志读取用户操作结果，未做真实 UI 自动操作；新代码和真实授权恢复的验证分别记录。

用户明确批准后，于 22:46:40 执行了上述限定 bundle ID 和 Accessibility 的重置，系统返回成功，详见候选目录 `reset.log` 与 `after-reset.log`。重新开启授权仍由用户操作；重置成功本身不等同于授权恢复。

恢复提示修订的最终候选位于 `dist/macos/permission-recovery/universal/`：352 项既有 Swift 测试、45 项隔离进程场景通过，Universal 架构、严格签名、ZIP、本地化、许可文件与插件同步检查通过。没有替换正在运行的 Debug 程序；重新授权结果尚未确认。

后续确认：用户重新运行的 Debug PID 84125 于 22:50:15 记录 `trusted=true`，原生观察也返回 `accessibility=true`。剩余间歇识别失败和唤起键失效另由前台观察限制、唤起与输入框 token 耦合、选择器兼容性缺口造成；详见 `macos-current-conversation-id.zh-CN.md`。此次无需再次重置权限。
