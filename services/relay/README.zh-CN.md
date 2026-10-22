# Codex Micro Relay（方案 B 自建中继服务）

本目录实现 [iOS 远程控制产品规划](../../docs/architecture/ios-product-plan.zh-CN.md) 中的 **方案 B：Micro 自建中继** 服务端。

## 职责与边界

- 接受桌面端 Host（`role=host&hostId=<hostId>`）与 iOS 客户端（`role=device&hostId=<hostId>&deviceId=<deviceId>`）的主动出站 WebSocket 连接（`/ws/relay`）。
- 仅按外层路由元数据（`hostID`、`deviceID`、`sessionID`、`seq`）转发 `relay.envelope` 密文帧。
- **不持有业务解密密钥，不解析也不落盘任何任务标题、审批详情、命令输出或对话正文**。
- 每个连接独立维护有界发送通道（128 帧容量，超出时按 `DropOldest` 背压策略保护中继内存），单帧上限 256 KB。
- 提供 `/healthz` 健康检查端点。

## 本地运行与构建

```bash
dotnet build services/relay/CodexMicro.Relay.csproj
dotnet run --project services/relay/CodexMicro.Relay.csproj --urls "http://0.0.0.0:8080"
```
