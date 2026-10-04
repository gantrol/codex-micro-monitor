# Build and distribution

## Build locally

Requires Windows x64, .NET SDK 10.0.302 and the pinned `CodexControl` packages. Build those packages in the independent `codex-control` repository first; AgentController source is not required.

Run from this repository's root:

```powershell
.\scripts\import-control-packages.ps1 -PackageDirectory ..\codex-control\dist\0.1.0-local.2\packages
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
```

Quit an existing Micro window normally before running another copy. `Version.props` supplies the package version. Packaging writes desktop/plugin ZIPs, control packages and checksums to `dist/<version>/`; it refuses to overwrite an existing version directory. It does not install or publish anything. Both ZIPs require .NET 10 Desktop Runtime x64. The Store MSIX has a separate self-contained packaging path.

`scripts/test.ps1` runs the existing suite; known failures remain. Current evidence and limitations are recorded in `docs/migration-validation-2026-10-03.md` and `docs/micro-behavior-acceptance.md`. Do not treat compilation as complete UI acceptance. Windows is the current runnable target; macOS is not implemented and `apps/ios` is a historical prototype.

## Codex compatibility

Driverless control belongs to this project's software adapter; it is not an OpenAI announcement that a particular Codex release introduced this third-party integration. The current baseline is **26.930.3930.0**, matching `src/CodexMicro.Windows/Services/CodexOfficialCatalog.json`. The adapter uses versioned desktop IPC and Windows accessibility interfaces, rather than a virtual HID driver. The earliest compatible desktop release has not been established; future desktop changes can require updates.

## Codex Plugin distribution

The existing `codex-micro-keypad` plugin packages the same Windows panel and control backend, a keypad skill, and a local stdio MCP process. The plugin archive includes `.agents/plugins/marketplace.json`, `plugins/codex-micro-keypad/plugin.json`, `mcp.json`, skills, visuals and `bin/CodexMicro.Plugin.exe`.

After extracting the complete plugin archive, register its root with `codex plugin marketplace add .`, restart Codex, and install from the **Codex Micro Monitor** marketplace. The repository alone has no bundled executable: build/package before installing. The marketplace workflow follows the [official package guide](https://developers.openai.com/plugins/build/plugins#add-a-marketplace-from-the-cli); full installation acceptance is still pending.

Local marketplace ZIP distribution is the current route. For the universal public directory, OpenAI's guidance checked on 2026-10-04 asks MCP submissions to provide a remote HTTPS endpoint, or contact OpenAI about local MCP support. This plugin requires the user's Windows desktop and therefore needs that local-MCP route clarified before public submission. See [bundled MCP servers](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks) and [submission](https://developers.openai.com/plugins/deploy/submission). No public listing or Store release has been submitted.

## README images

The six localized lossless WebP images are stored in `plugins/codex-micro-keypad/assets/screenshots/`; English is the plugin listing default. Their editable source is `scripts/store-assets.v3.json`, rendered through `scripts/render-store-assets.py`. After approved visual changes, copy the corresponding `.webp` files from `dist/store/listing/svg/review/<language>/` into that assets directory. Both README files and the plugin manifest use these copies. PNG and SVG originals remain in the render output; Store uploads continue to use PNG.
