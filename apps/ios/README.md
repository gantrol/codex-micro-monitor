# Codex Micro iOS · 0.2.0

按 [iOS 远程控制产品规划](../../docs/architecture/ios-product-plan.zh-CN.md) 完成实现的 iOS / iPadOS 17+ 客户端（UIKit + Core Animation），同时支持连接 **macOS Host**（`apps/macos/Sources/MicroDesktop/RemoteHost.swift`）与 **Windows Host**（`src/CodexMicro.Remote/`），并支持外网连接方案 A（Tailscale 组网直连）与方案 B（Micro 自建 E2EE 中继）。

## 构建工程

在仓库根目录执行编译验证：

```sh
xcodebuild -project apps/ios/CodexMicro.xcodeproj \
  -scheme CodexMicro -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## 已实现的首版能力（R01–R13）

- **多电脑保存与切换**：Keychain 持久化多台电脑（`SavedHost`），区分 macOS / Windows 平台与方案 A / B 连接模式；顶部连接胶囊支持长按菜单一键切换电脑，切换电脑时自动清空旧任务选择、租约与状态缓存。
- **二维码配对与设备权限管理**：支持相机扫描 `codexmicro://pair` 配对二维码或从剪贴板导入配对链接，自动兑换长期 `deviceToken` 并绑定叶证书 SHA-256 指纹（方案 A）或 Curve25519 公钥（方案 B）。电脑端撤销设备后即时收到 `auth.revoked` 并停止重连。
- **两套外网连接方案**：
  - **方案 A（Tailscale 组网直连）**：WSS 直连电脑 Host，支持自签名叶证书 SHA-256 指纹固定校验。
  - **方案 B（Micro 自建中继）**：手机与电脑分别出站连接 `services/relay/`，所有业务帧经 `relay.envelope`（Curve25519 + HKDF-SHA256 + ChaCha20-Poly1305）端到端加密。
- **任务监控与防抖键位**：支持 `idle`、`running`、`completed`（完成未读）、`waiting`（待审批）、`question`（待回答）、`error`、`overloaded`（`server_overloaded`）、`unknown` 八种状态与 `hasDraft` 中心草稿点；手指按住键帽期间冻结 6 / 14 键位排序防止跳位；断线立即熄灭实时状态灯。
- **完整任务列表（搜索与分页）**：顶部任务列表按钮打开 `TaskListViewController`，通过 `threads.list` 搜索和分页浏览电脑上的全部任务。
- **模型、强度、Fast / Plan 控制**：以 Host 实时模型目录为准；未知的 `fast` / `plan` 状态保持 `nil`（显示“未知”而非伪装成关闭）；`ThreadDetailViewController` 提供非旋转分段控件调整推理强度。
- **单项与多项审批核验**：单条审批在主界面弹窗展示命令、工作目录与文件列表；多条待审批自动进入 `ThreadDetailViewController` 逐条选择，提交时校验 `approvalRequestID` 与 `approvalContentHash`。
- **停止当前回合**：绑定具体 `threadID` 与 `turnID` 停止运行中的回合。
- **按需查看最近助手回复与显式发送文字**：`ThreadDetailViewController` 按需调用 `thread.detail.read` 展示最新完整助手回复与待回答问题，并支持向空闲会话发送文字消息（`turn.sendText`，绝不误发电脑桌面输入框草稿）。
- **断线重连、按任务冲突锁定与 `unknown` 恢复**：前台指数退避抖动重连；未确认请求保存在受文件保护的本地日志中，重连后通过 `command.queryResult` 查询账本而不重放写操作；仅锁定对应 `(hostID, threadID)`，并提供显式解锁恢复入口。

## 代码结构

- [MicroRemoteProtocol.swift](../../packages/MicroRemote/Sources/MicroRemote/MicroRemoteProtocol.swift)：iOS 与 macOS 共用的 Protocol v2 模型、配对 URI 解析与 E2EE 加解密。
- [MicroModels.swift](CodexMicro/Core/MicroModels.swift) / [MicroStore.swift](CodexMicro/Core/MicroStore.swift)：多 Host 状态管理、按任务冲突锁定、触控防抖与未决命令恢复。
- [HostCredentials.swift](CodexMicro/Connection/HostCredentials.swift) / [WebSocketTransport.swift](CodexMicro/Connection/WebSocketTransport.swift)：Keychain 多电脑存储、证书固定、Protocol v2 握手、退避重连与中继 E2EE。
- [MicroDeviceView.swift](CodexMicro/UI/MicroDeviceView.swift) / [MicroViewController.swift](CodexMicro/UI/MicroViewController.swift)：590×610 双页键盘、快捷电脑切换菜单与主控交互。
- [TaskListViewController.swift](CodexMicro/UI/TaskListViewController.swift)：完整任务搜索与分页列表。
- [ThreadDetailViewController.swift](CodexMicro/UI/ThreadDetailViewController.swift)：最近回复查看、多审批选择、非旋转参数控制、文字发送与未知状态恢复。
- [ConnectionViewController.swift](CodexMicro/UI/ConnectionViewController.swift)：多电脑管理、二维码扫描配对与手动连接配置。
