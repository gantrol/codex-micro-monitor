# Build and distribution

## Build locally

Requires Windows x64, .NET SDK 10.0.302 and the pinned `CodexControl` packages. Build those packages in the independent [codex-control repository](https://github.com/gantrol/codex-control) first, or download the pinned packages from its [Releases](https://github.com/gantrol/codex-control/releases); AgentController source is not required.

The current `1.0.0` candidate pins `CodexControl.1.0.0.nupkg` and `CodexControl.Windows.1.0.0.nupkg`. Build that exact version in the control repository and pass its package directory to `scripts/import-control-packages.ps1`. The published [0.3.15 release](https://github.com/gantrol/codex-micro-monitor/releases/tag/v0.3.15) supplies the older `0.1.0-local.2` packages for its matching source, not this candidate. Do not rebuild and substitute different contents under an already imported package version.

For local development with `codex-control` checked out beside this repository, pass `-p:UseLocalCodexControl=true` to `dotnet build`, `dotnet run`, or `dotnet test`. This builds both shared control projects from source and avoids reusing a cached package with the same version. The workspace `debug:micro`, `build:micro:debug`, `test:micro`, and `manage.ps1` Micro Debug builds enable this option. Normal builds and release packaging continue to use pinned packages; the option is explicit and requires the sibling repository.

Run from this repository's root:

```powershell
.\scripts\import-control-packages.ps1 -PackageDirectory ..\codex-control\dist\1.0.0\packages
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
.\scripts\package-compact.ps1
```

Quit an existing Micro window normally before running another copy. `Version.props` supplies the package version. Packaging writes desktop/plugin ZIPs, control packages and checksums to `dist/<version>/`; it refuses to overwrite an existing version directory. Use `scripts/package.ps1 -OutputDirectory <new-directory>` to prepare another candidate without moving or replacing older artifacts. It does not install or publish anything. Both ZIPs require .NET 10 Desktop Runtime x64. The Store MSIX has a separate self-contained packaging path.

`scripts/test.ps1` runs the existing unit, component and isolated control tests. Automated tests and compilation do not replace live installation acceptance. Windows is the current runnable target; macOS is not implemented and `apps/ios` is a historical prototype. Start macOS work with the [development handoff](architecture/macos-development-handoff.zh-CN.md).

## Release version

The next desktop app and bundled plugin release is `1.0.0`; Windows assembly/file and Store package versions use `1.0.0.0`. Shared control packages are independently pinned to `1.0.0`. See the [candidate release notes](releases/1.0.0.md). Preparing this candidate does not publish it or change the approved Store package.

The Store catalog was checked on 2026-10-04 and served `0.3.15.0`. The initially published desktop binaries carry the historical `0.3.15-local.1` informational string while their file version is `0.3.15.0`. Keep those published artifacts unchanged.

For future submissions, recheck [Microsoft's package version guidance](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/package-version-numbering?pivots=store-installer-msix) and Partner Center validation. The published package's observed version is not a general guarantee about acceptance of other packages. Do not replace assets of an existing release with a different build under the same version.

## Codex compatibility

Driverless control belongs to this project's software adapter; it is not an OpenAI announcement that a particular Codex release introduced this third-party integration. The current baseline is **26.930.3930.0**, matching `src/CodexMicro.Windows/Services/CodexOfficialCatalog.json`. The adapter uses versioned desktop IPC and Windows accessibility interfaces, rather than a virtual HID driver. The earliest compatible desktop release has not been established; future desktop changes can require updates.

## Codex Plugin distribution

The existing `codex-micro-keypad` plugin packages the same Windows panel and control backend, a keypad skill, and a local stdio MCP process. The plugin archive includes `.agents/plugins/marketplace.json`, `plugins/codex-micro-keypad/plugin.json`, `mcp.json`, skills, visuals and `bin/CodexMicro.Plugin.exe`.

For a copyable prompt and installation steps, see [让 Codex 安装并打开 Micro 插件](plugin-installation.zh-CN.md). Extract the complete release plugin ZIP to a persistent directory, register its root with `codex plugin marketplace add <absolute-root>`, then install with `codex plugin add codex-micro-keypad@codex-micro-monitor`. This CLI syntax was checked against `codex-cli 0.160.0`; clients without `plugin add` can install from the **Codex Micro Monitor** marketplace in the desktop plugin directory after restarting. The repository alone has no bundled executable: use the complete release ZIP or build/package first. The marketplace workflow follows the [official package guide](https://developers.openai.com/plugins/build/plugins#add-a-marketplace-from-the-cli); full installation acceptance is still pending.

The release plugin already contains the Micro panel executable. After installation, ask Codex to read the plugin's capabilities and open the panel. This portable distribution does not install the Microsoft Store app or register a Windows Start menu entry. A lightweight plugin that downloads and installs Micro on demand would require a separate installer skill and script; that flow is not implemented in 1.0.0.

Local marketplace ZIP distribution is the current plugin route; public plugin-directory publication is still pending. For the universal public directory, OpenAI's guidance checked on 2026-10-04 asks MCP submissions to provide a remote HTTPS endpoint, or contact OpenAI about local MCP support. This plugin requires the user's Windows desktop and therefore needs that local-MCP route clarified before public submission. See [bundled MCP servers](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks) and [submission](https://developers.openai.com/plugins/deploy/submission). The desktop app is available on [Microsoft Store](https://apps.microsoft.com/detail/9NTVMG9QNMHC) with its .NET runtime included, and on [GitHub Releases](https://github.com/gantrol/codex-micro-monitor/releases/latest) as a compact ZIP requiring .NET 10 Desktop Runtime x64.

## README images

The six localized lossless WebP images are stored in `plugins/codex-micro-keypad/assets/screenshots/`; English is the plugin listing default. Their editable source is `scripts/store-assets.v3.json`, rendered through `scripts/render-store-assets.py`. After approved visual changes, copy the corresponding `.webp` files from `dist/store/listing/svg/review/<language>/` into that assets directory. Both README files and the plugin manifest use these copies. PNG and SVG originals remain in the render output; Store uploads continue to use PNG.
