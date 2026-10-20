# Build and distribution

## Build locally

Requires Windows x64, .NET SDK 10.0.302 and the pinned `CodexControl` packages. Build those packages in the independent [codex-control repository](https://github.com/gantrol/codex-control) first, or download the pinned packages from its [Releases](https://github.com/gantrol/codex-control/releases); AgentController source is not required.

The `1.0.6` release pins `CodexControl.1.0.4.nupkg` and `CodexControl.Windows.1.0.4.nupkg`. Download those exact packages from the [control release](https://github.com/gantrol/codex-control/releases/tag/v1.0.4), or build the matching source tag, and pass its package directory to `scripts/import-control-packages.ps1`. Older Micro releases require their own pinned dependency versions. Do not substitute different contents under an already published package version.

For local development with `codex-control` checked out beside this repository, pass `-p:UseLocalCodexControl=true` to `dotnet build`, `dotnet run`, or `dotnet test`. This builds both shared control projects from source and avoids reusing a cached package with the same version. The workspace `debug:micro`, `build:micro:debug`, `test:micro`, and `manage.ps1` Micro Debug builds enable this option. Normal builds and release packaging continue to use pinned packages; the option is explicit and requires the sibling repository.

Run from this repository's root:

```powershell
.\scripts\import-control-packages.ps1 -PackageDirectory ..\codex-control\dist\1.0.4\packages
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
.\scripts\package-compact.ps1
```

Quit an existing Micro window normally before running another copy. `Version.props` supplies the package version. Packaging writes desktop/plugin ZIPs, control packages and checksums to `dist/<version>/`; it refuses to overwrite an existing version directory. Use `scripts/package.ps1 -OutputDirectory <new-directory>` to prepare another candidate without moving or replacing older artifacts. Release packaging isolates NuGet restore under `.artifacts/nuget-packages/` using the pinned control-package hashes, so a machine-wide cache cannot substitute different contents under the same version. It does not install or publish anything. Both ZIPs require .NET 10 Desktop Runtime x64. The Store MSIX has a separate self-contained packaging path.

`scripts/test.ps1` runs the existing unit, component and isolated control tests. Automated tests and compilation do not replace live installation acceptance. Windows release assets are built by the scripts above. The separate macOS preview uses UIKit / Mac Catalyst and an AppKit bridge; its build requires macOS and Xcode. `apps/ios` is a historical prototype. See the [macOS development handoff](architecture/macos-development-handoff.zh-CN.md) and the current source and packaging configuration.

## Release version

The desktop app and bundled plugin release is `1.0.6`; Windows assembly/file versions use `1.0.6.0`. Shared control packages are independently pinned to `1.0.4`. See the [release notes](releases/1.0.6.md). This GitHub release does not submit a Microsoft Store update or a public plugin-directory listing. The macOS preview keeps its independent version and requires a separate Mac build.

Release notes place the complete English section first, followed by Simplified Chinese.

The Store catalog was checked on 2026-10-04 and served `0.3.15.0`. The initially published desktop binaries carry the historical `0.3.15-local.1` informational string while their file version is `0.3.15.0`. Keep those published artifacts unchanged.

For future submissions, recheck [Microsoft's package version guidance](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/package-version-numbering?pivots=store-installer-msix) and Partner Center validation. The published package's observed version is not a general guarantee about acceptance of other packages. Do not replace assets of an existing release with a different build under the same version.

## Codex compatibility

Driverless control belongs to this project's software adapter; it is not an OpenAI announcement that a particular Codex release introduced this third-party integration. The current baseline is **26.930.3930.0**, matching `src/CodexMicro.Windows/Services/CodexOfficialCatalog.json`. The adapter uses versioned desktop IPC and Windows accessibility interfaces, rather than a virtual HID driver. The earliest compatible desktop release has not been established; future desktop changes can require updates.

## Codex Plugin distribution

The existing `codex-micro-keypad` plugin packages the same Windows panel and control backend, a keypad skill, and a local stdio MCP process. The plugin archive includes `.agents/plugins/marketplace.json`, `plugins/codex-micro-keypad/plugin.json`, `mcp.json`, skills, visuals and `bin/CodexMicro.Plugin.exe`.

For installation, use [让 Codex 安装并打开 Micro 插件](plugin-installation.zh-CN.md). The complete release plugin ZIP already includes Micro. Ask Codex to install the plugin, then open Micro in a new chat after restarting when prompted. Full installation acceptance is still pending.

Local marketplace ZIP distribution is the current plugin route; public plugin-directory publication is still pending. For the universal public directory, OpenAI's guidance checked on 2026-10-04 asks MCP submissions to provide a remote HTTPS endpoint, or contact OpenAI about local MCP support. This plugin requires the user's Windows desktop and therefore needs that local-MCP route clarified before public submission. See [bundled MCP servers](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks) and [submission](https://developers.openai.com/plugins/deploy/submission). The desktop app is available on [Microsoft Store](https://apps.microsoft.com/detail/9NTVMG9QNMHC) with its .NET runtime included, and on [GitHub Releases](https://github.com/gantrol/codex-micro-monitor/releases/latest) as a compact ZIP requiring .NET 10 Desktop Runtime x64.

## README images

The six localized lossless WebP images are stored in `plugins/codex-micro-keypad/assets/screenshots/`; English is the plugin listing default. Their editable source is `scripts/store-assets.v3.json`, rendered through `scripts/render-store-assets.py`. After approved visual changes, copy the corresponding `.webp` files from `dist/store/listing/svg/review/<language>/` into that assets directory. Both README files and the plugin manifest use these copies. PNG and SVG originals remain in the render output; Store uploads continue to use PNG.
