# Microsoft Store 素材生成

适用对象：Windows 桌面 MSIX。官方规范核对日期：2026-10-04。

## 交付规格

| 物料 | 官方要求 / 建议 | 本项目输出 |
| --- | --- | --- |
| 桌面截图 | 至少 1 张，最多 10 张；PNG，至少 1366×768，单张不超过 50 MB | 6 张 1920×1080（16:9） |
| 应用图标 | 推荐单独提供 300×300 PNG；也可使用包内图标 | 复用 `assets/CodexMicro.png` |
| 视频（可选） | MP4/MOV，1920×1080，不超过 2 GB；建议不超过 60 秒 | 当前不生成 |
| 视频封面 | 1920×1080 PNG，另附不超过 255 字符的标题 | 随视频准备 |
| Hero 图（可选） | 1920×1080 或 3840×2160 PNG，不含文字，避免产品 UI | 当前不生成 |

截图建议不叠加额外 Logo、图标或宣传文字，重点放在上方三分之二区域。每张说明放在独立 caption，最多 200 字符。官方没有要求所有桌面截图只能用 16:9；这是本项目采用的统一比例。[微软 MSIX 素材规范](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images)

## 修改入口

- `scripts/store-assets.json`：全部中英文文案、截图顺序、状态灯、模型、推理强度、Pro 额度及品牌图标路径。
- `scripts/render-store-assets.py`：生成 SVG，再由 resvg 导出对应 PNG；`LAYOUT` 管理坐标，Pillow 测量字体并校验图片。
- `tools/CodexMicro.StoreAssets/Program.cs`：仅渲染现有 WPF XAML 与控件，不放宣传文案。产品样式调整后，重新运行即可。

先渲染第一屏控制页，再渲染第二屏监控页。随后提供 6 Astra / Ultra、5.6 Luna / Max、Pro 每周额度和 Fast 开启状态。模型强度圈直接由 `QuotaKnob` 生成；Pro 额度沿用 `CodexQuotaSnapshot` 的窗口选择，不在脚本中另画假圈。

## 运行

需要 Windows、现有项目要求的 .NET SDK、Python 3.10+、Pillow 和 `resvg-py`。当前本机已具备上述依赖；脚本不自动安装依赖，沿用仓库固定的本地 NuGet 依赖。

```powershell
python scripts/render-store-assets.py
```

只改文案、标题、caption、配图顺序或 Python 排版时，可以复用 XAML 渲染：

```powershell
python scripts/render-store-assets.py --compose-only
```

`--compose-only` 会检查渲染输入指纹；控件源码、模型、强度、额度或灯光有变更时要求重新渲染，防止沿用旧画面。另可指定 `--config` 和 `--output`。原有 PowerShell 入口转调此 Python 脚本。

默认输出至 Git 忽略的 `dist/store/listing/v2/`：

- `store/`：六张无附加宣传文案的商店截图，以及 Micro 的 300×300 图标。
- `captions.json`：两种语言的独立截图说明；相同图片可分别用于两个语言的提交。
- `review/zh-CN/`、`review/en-US/`：Micro 图标、产品画面和一句使用收益；首图附用户原话。每张标题与可选引用分别在语言资源的 `cards.*.title`、`cards.*.quote` 修改，不叠加操作说明或图例。
- `review.md`：短描述与宣传图预览；`renders/`：透明 XAML 原始渲染。

## 前三张图示与标题提案

`scripts/store-assets.v3.json` 保存前三张的独立提案，不覆盖原有文案配置：

```powershell
python scripts/render-store-assets.py --config scripts/store-assets.v3.json --output dist/store/listing/v3
```

`typography` 控制两行标题的字号与间距；其中 `stateLabelSize`、`actionLabelSize` 分别控制状态图例和操作说明字号。`stateLabels` 修改灯色状态标签，`modelActions` 修改点击与滚轮标签。图例继续使用 XAML 导出的真实控件。点击左下角 `SettingsKey` 切换快捷模型，滚轮调节推理强度；对应源码为 `MainWindow.xaml.cs` 的 `Settings_Click` 与 `MainWindow.Reasoning.cs` 的 `Settings_MouseWheel`。引线及点击光标按当前 590×610 面板中该旋钮的位置定位，面板布局变化后需重新核对位置。

标题排布的原始讨论材料留在本地，不属于公开构建输入。脚本输出继续保留产品控件原图及真实强度圈。只改文字与排版时，上述命令追加 `--compose-only`。

## SVG 复现

```powershell
python scripts/render-store-assets.py --config scripts/store-assets.v3.json --output dist/store/listing/svg
```

每张图同时输出 `.svg` 与从该 SVG 渲染的 `.png`，宣传图另导出无损 `.webp` 供 README 和插件预览使用，没有独立排版。WebP 使用 Pillow 的 `lossless=True, method=6`，保留原始尺寸和像素。商店上传继续使用 PNG，品牌图标也保留 PNG。前三张中英文文件位于 `review/zh-CN/` 与 `review/en-US/`。

- 标题、图例文字为可编辑的 `<text>`；鼠标图标、箭头与引线使用 `<path>`、`<rect>` 和 `<circle>`。
- `headline`、`product-panel`、`state-*`、`model-*` 等图层带稳定 ID，便于定位修改。
- 产品面板、状态键、旋钮和品牌图标保留 XAML 或现有素材的 PNG，并通过 data URI 内嵌；SVG 不依赖外部图片文件，但这些产品画面仍是位图。
- 中文使用 Microsoft YaHei，英文使用 Segoe UI；字体不内嵌。直接编辑 SVG 的设备需安装相应字体；脚本导出 PNG 时明确加载本机对应字体文件。
- `viewBox` 固定为 `0 0 1920 1080`；配置的画布宽高决定最终输出尺寸。调整文案或版式后可用同一命令追加 `--compose-only`。

脚本只生成本地文件，不上传、提交认证、修改账号数据或操作真实应用。所有灯光和数字均来自显式示例配置。

Pillow 字体测量、XML 序列化与 resvg 渲染使用同步接口；相关本地读写和计算在 Python 工作线程上按有限张数串行处理，理由是这些接口没有异步版本，且这是离线素材任务。嵌入素材按路径有界缓存，避免重复读取与编码。WPF 端异步读取配置、后台编码写入 PNG，不把图片文件操作放在产品 UI 流程中。
