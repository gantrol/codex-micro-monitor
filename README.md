# Codex Micro Monitor

A third-party Windows keypad and Codex plugin with control and chat-monitor panels, inspired by [Codex Micro](https://learn.chatgpt.com/docs/features/codex-micro).

[简体中文](README.zh-CN.md) · [Source provenance](SOURCE.md) · [Validation](docs/migration-validation-2026-10-03.md)

Chat selection, status lights, unread markers, Fast, Plan, model/reasoning controls, tray and custom keycaps use software interfaces and Windows UI Automation. No virtual HID driver or AgentController installation is required.

## Build and package

Requires Windows 10 19041+ / Windows 11 x64, .NET SDK 10.0.302, and a signed-in Codex / ChatGPT desktop app.

Build the pinned packages in the independent `codex-control` repository, then import them. AgentController source is not required:

```powershell
.\scripts\import-control-packages.ps1 -PackageDirectory ..\codex-control\dist\0.1.0-local.2\packages
```

```powershell
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
```

Quit an existing keypad normally before manually launching this build. Packaging does not install, replace or upload anything. `Version.props` supplies the version. `dist/<version>/` contains desktop/plugin ZIPs, the referenced control packages and ZIP checksums. Packaged applications require the .NET 10 Desktop Runtime x64.

Extract the whole plugin ZIP, including `.agents/plugins/marketplace.json` and `plugins/codex-micro-keypad/`. Plugin ID: `codex-micro-keypad`; local marketplace: `codex-micro-monitor`. Public installation has not been verified or released.

## Tests and limitations

Run `scripts/test.ps1` for migrated regression and behavior acceptance tests. Known failures remain visible and return a nonzero exit code. `scripts/test-micro-live.ps1` provides reversible desktop checks using explicit idle fixture and restoration chat IDs.

Composer submit, choice menus, scrolling, sidebar/history navigation and skill insertion have been migrated. They have not received new live UI acceptance in this migration. MCP text submission is a separate operation. DeepSeek, external adapters, local speech/ASR and driver implementations remain removed; legacy voice settings survive only as inert compatibility data.

The current Apple target is macOS desktop, which is not yet implemented. `apps/ios` preserves the earlier UIKit prototype with its Xcode project; it has not been built with Xcode and is no longer the active delivery target. Internal Codex desktop interfaces may require future adaptation.

Both products consume pinned `CodexControl` and `CodexControl.Windows` packages from a third repository. This repository has no source/project links to either sibling repository. See the [repository boundaries](docs/repository-layout.zh-CN.md) and [migration validation](docs/migration-validation-2026-10-03.md).

Licensed under [PolyForm Noncommercial 1.0.0](LICENSE).
