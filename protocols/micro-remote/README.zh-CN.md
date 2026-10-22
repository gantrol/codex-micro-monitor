# Micro Remote Protocol v2 规范

本文定义 iOS 客户端、macOS Host、Windows Host 与公网 Relay 共用的版本化 JSON 协议（`protocolVersion = 2`），同时保留对历史 v0.1（`protocolVersion = 1`）的握手兼容。

- JSON Schema：[schema.v2.json](schema.v2.json)
- Swift 共享包：[packages/MicroRemote](../../packages/MicroRemote/Package.swift)
- Windows 远程组件：[src/CodexMicro.Remote](../../src/CodexMicro.Remote/CodexMicro.Remote.csproj)
- 公网中继服务：[services/relay](../../services/relay/CodexMicro.Relay.csproj)

## 1. 传输模式与外网链路

| 方案 | 传输标识 | 连接路径 | 身份与加密边界 |
| --- | --- | --- | --- |
| **方案 A：Tailscale 组网直连** | `direct` | iPhone 经同一 tailnet（或局域网）直接向 Mac / Windows Host 发起 `WSS` | 二维码携带 Host 叶证书 64 位 SHA-256 指纹完成首次信任绑定；Tailscale 在直连不可达时可能经 DERP / Peer Relay 转发加密流量 |
| **方案 B：Micro 自建公网中继** | `relay` | iPhone 与电脑 Host 各自向公网 Relay 发起出站 `WSS / 443` | Relay 仅按 `(hostID, deviceID)` 路由并校验撤销状态；业务帧封装在 `relay.envelope`（X25519 + HKDF-SHA256 + ChaCha20-Poly1305）端到端认证加密载荷中，Relay 不解密业务明文 |

## 2. 配对与设备撤销（R01）

电脑端打开限时配对窗口（默认有效期 120 秒、单次使用），生成 `codexmicro://pair` 二维码载荷（或等价 JSON）：

```json
{
  "version": 2,
  "transport": "direct",
  "endpoint": "wss://100.64.0.10:8443/micro",
  "hostID": "host-stable-uuid",
  "hostName": "MacBook Pro",
  "platform": "macos",
  "certificateSHA256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "pairingToken": "one-time-pairing-secret",
  "expiresAt": 1792639200,
  "hostPublicKey": "base64-x25519-public-key"
}
```

1. **首次兑换**：手机校验 Host TLS 叶证书指纹后建立 WSS，发送 `pair.exchange`（携带 `pairingToken`、`deviceID`、`deviceName`、可选 `clientPublicKey`）。
2. **签发凭据**：Host 核验配对窗口未过期且未兑换后，作废该一次性令牌，生成可独立撤销的 `deviceToken`，持久化设备记录并返回 `pair.exchanged`。
3. **即时撤销**：电脑端撤销某台手机时，立即断开该 `deviceID` 的活动连接（返回 `errorCode = "device_revoked"`），并拒绝后续携带该凭据的握手。

## 3. 会话、租约与状态同步（R02–R05, R10, R13）

1. **握手**：
   - 客户端发送 `hello`（`protocolVersion: 2`, `clientID`, `deviceName`）。
   - Host 验证 `Authorization: Bearer <device-token>` 后返回 `welcome`（`protocolVersion: 2`, `hostID`, `hostName`, `platform`, `hostEpoch`, `accountScope`, `codexStatus`）。
2. **控制租约**：
   - 客户端发送 `session.acquire`（可选 `takeover: true`）。
   - 每台 Host 同时只授予一个 `readWrite` 租约（TTL 5–300 秒）；第二台连接设备默认获得 `readOnly` 租约，须用户显式请求 `takeover: true` 才接管写权限。桌面本地操作不受远程租约阻塞。
3. **快照与分页**：
   - `state.subscribe` 触发完整 `state.snapshot`，包含前 14 个快捷槽及最近任务、模型目录、归一化额度（Pro 账号隐藏 5 小时窗口、耗尽时附带 `credits` 余额）与 `codexStatus` 运行边界。
   - `threads.list`（携带 `query`、`offset`、`limit`）返回 `threads.page`，支持超过 14 个任务的完整列表与搜索分页，不把完整聊天历史塞入列表快照。
4. **按需任务详情（R08, R09）**：
   - `thread.detail.read`（携带 `threadID`）返回 `thread.detail`，按需读取最近一条完整助手回复（`latestReply`）、全部待处理审批列表（`approvals`，含 `contentHash` 与 `approvable` 标记）、待回答问题（`pendingQuestions`）以及 `canSubmitText` 状态。

## 4. 命令、幂等账本与未知结果恢复（R06–R09, R11, R12）

| `kind` | 必填条件与校验边界 |
| --- | --- |
| `desktop.openThread` | 显式请求在电脑打开 `threadID`；手机端切换选择本身不触发电脑切窗 |
| `thread.setModel` | `value` 为当前 Host 模型目录中的有效模型 ID；按任务字段比较预期值 |
| `thread.setEffort` | `value` 为当前模型支持的推理强度；未知值不伪装为默认档 |
| `thread.setFast` / `thread.setPlan` | `value` 为 `"true"` 或 `"false"`；未知值保持 `null` |
| `turn.stop` | 必须携带当前活动回合 `turnID`；若回合已结束或进入新回合则拒绝 |
| `approval.accept` / `approval.decline` | 必须携带 `approvalID` 与 `approvalContentHash`；仅允许 `command` / `fileChange` 类型；内容变化或已在电脑处理则拒绝 |
| `turn.sendText` | 必须携带非空 `text`（≤ 100,000 字符）；目标任务必须空闲、无待审批且无未确认回合；绝不提交电脑端未发送草稿 |
| `thread.fork` | 调用安全 Fork 并回读新创建的 `createdThreadID` |

### 账本与状态收敛规则

1. **先写账本再调用适配器**：Host 按 `(deviceID, requestID)` 持久化 `payloadHash` 与 `accepted` 状态后再调用 Codex。
2. **跨重连 / 跨重启不重放**：
   - 相同 `(deviceID, requestID)` 且 `payloadHash` 一致时直接返回账本记录，不重复调用 Codex。
   - 相同 `(deviceID, requestID)` 但参数不同立即返回 `rejected`（`errorCode = "payload_conflict"`）。
   - Host 重启时将未完成的 `accepted` 记录转为 `unknown`。
3. **按任务隔离冲突写操作**：未确认或 `unknown` 的命令仅冻结同一 `(hostID, threadID)` 的后续写操作，不阻塞其他任务的监控或控制；用户在核实最新回复与状态后可显式解除该任务的本地 `unknown` 锁定，解除操作不重发原命令。
