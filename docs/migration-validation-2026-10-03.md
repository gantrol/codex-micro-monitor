# 三仓库迁移验证

日期：2026-10-03。Micro：`0.3.15-local.1`；共用组件：`0.1.0-local.2`。
产物仅保存在本机，尚未发布或安装。

## 迁移范围

- Micro 独立维护桌面、设置、键帽、官方图形目录、监控与插件入口。
- 共用客户端、协议连接、模型目录和 Windows 操作实现迁至 `codex-control`。
- AgentController 与 Micro 分别精确引用 `CodexControl` / `CodexControl.Windows`，没有跨仓库项目或源码引用，也没有 Git submodule。
- AgentController 的旧 Micro 桌面、宿主与插件退出当前构建/发布入口；仍被使用的 HID 协议与 Broker 留在原仓库。
- 合并源为 AgentController `92c9e8a` 工作树。25 个迁入文件的源哈希均与迁移后保留的原文件一致，记录见 [manifest](migration-2026-10-03.json)。其中三个原未提交的草稿模型/推理选择器修复已迁入，原文件未改写。
- 底部品牌图标不再套用键帽的最小 24 像素规则；采用 10×10 尺寸、5 像素间隔，与文字垂直居中。左右装饰文字保持原样。
- iOS Xcode 工程仅保留为历史原型。macOS 是当前 Apple 平台目标，客户端和本机 Host 均未实现；旧 Avalonia 预览已废弃。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `CodexControl.slnx` Release 构建与两个 NuGet 包 | 通过，0 警告、0 错误 |
| 两个产品的组件导入脚本与依赖还原 | 通过，固定为 `0.1.0-local.2` |
| `CodexMicro.slnx` Release 全方案构建 | 通过，0 警告、0 错误，包含现有测试项目编译 |
| AgentController 主程序 Release 构建 | 通过，0 警告、0 错误，输出至独立构建目录 |
| AgentController 全方案 Release 构建 | 未通过：未改动的 `ControllerTutorialViewDesignTests.cs` 有 11 处 CS1061，仍引用已移除的手柄教程控件；未修改测试或补回虚假控件 |
| 现有 `SoftwareControlRegressionTests` | 16/16 通过；隔离 named-pipe owner 与内存状态，不连接真实 Codex 界面 |
| Micro 桌面与插件发布、ZIP 打包 | 通过；需要 .NET 10 Desktop Runtime x64 |
| 迁移来源、依赖版本及 diff 空白检查 | 通过；本轮没有编写或修改测试代码 |

协议回归命令：

```powershell
dotnet test tests/CodexMicro.Desktop.Tests/CodexMicro.Desktop.Tests.csproj -c Release --no-build --filter FullyQualifiedName~SoftwareControlRegressionTests --logger "trx;LogFileName=software-regression.trx" --results-directory .artifacts/repository-separation/results --nologo -v minimal
```

回归结果位于 `.artifacts/repository-separation/results/software-regression.trx`。
本轮没有执行 UI 手动测试、浏览器测试、UIA 实机操作或物理手柄验收；未启动或替换正在运行的小键盘，未安装插件。
16 项协议回归不覆盖迁入的所有 UI 操作，也不能说明完整旧测试已全部通过。初次抽离时的历史结果见[旧验证报告](validation.zh-CN.md)。

## 本地产物

- `dist/0.3.15-local.1/codex-micro-monitor-0.3.15-local.1-win-x64.zip`
- `dist/0.3.15-local.1/codex-micro-monitor-plugin-0.3.15-local.1-win-x64.zip`
- ZIP 校验值：`dist/0.3.15-local.1/SHA256.json`
- 固定组件包：`dist/0.3.15-local.1/packages/`
- 组件原始产物与校验值：`D:\codex-control\dist\0.1.0-local.2\packages`

组件和产品包已有版本固定及同版本内容保护；新检出需先导入组件包，没有公网包源可供直接还原。构建方式见 [README](../README.zh-CN.md)。
