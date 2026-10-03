# Codex Micro Monitor

A third-party Windows keypad and Codex plugin with control and chat-monitor panels, inspired by [Codex Micro](https://learn.chatgpt.com/docs/features/codex-micro).

[简体中文](README.zh-CN.md) · [Source provenance](SOURCE.md) · [Validation](docs/validation.zh-CN.md)

Chat selection, status lights, unread markers, Fast, Plan, model/reasoning controls, tray and custom keycaps use software interfaces and Windows UI Automation. No virtual HID driver or AgentController installation is required.

## Build and package

Requires Windows 10 19041+ / Windows 11 x64, .NET SDK 10.0.302, and a signed-in Codex / ChatGPT desktop app.

```powershell
dotnet build CodexMicro.slnx -c Release
dotnet run --project src/CodexMicro.Desktop -c Release
.\scripts\package.ps1
```

Quit an existing keypad normally before manually launching this build. Packaging does not install, replace or upload anything. `Version.props` supplies the version. `dist/<version>/` contains desktop/plugin ZIPs, a component NuGet package and ZIP checksums. Packaged applications require the .NET 10 Desktop Runtime x64.

Extract the whole plugin ZIP, including `.agents/plugins/marketplace.json` and `plugins/codex-micro-keypad/`. Plugin ID: `codex-micro-keypad`; local marketplace: `codex-micro-monitor`. Public installation has not been verified or released.

## Tests and limitations

Run `scripts/test.ps1` for migrated regression and behavior acceptance tests. Known failures remain visible and return a nonzero exit code. `scripts/test-micro-live.ps1` provides reversible desktop checks using explicit idle fixture and restoration chat IDs.

Native composer submit, choice menus, scrolling, some joystick navigation and skill insertion remain incomplete. MCP text submission is a separate operation. DeepSeek, external adapters, local speech/ASR and driver implementations have been removed; legacy voice settings survive only as inert compatibility data.

`apps/ios` is an unfinished committed source snapshot without a complete project or build validation. macOS is not implemented. Internal Codex desktop interfaces may require future adaptation.

AgentController retains its navigation executor and consumes a pinned component package. This repository has no source/project links back to AgentController.

Licensed under [PolyForm Noncommercial 1.0.0](LICENSE).
