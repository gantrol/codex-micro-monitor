# Codex Micro Monitor

[![中文 | 点我](plugins/codex-micro-keypad/assets/badges/zh-CN.svg)](README.zh-CN.md)

A Windows desktop companion for Codex. See task status, switch models and reasoning effort, check usage, and toggle Fast.

![Task status at a glance](plugins/codex-micro-keypad/assets/screenshots/en-US/01-controls.webp)

![Follow multiple tasks](plugins/codex-micro-keypad/assets/screenshots/en-US/02-monitor.webp)

![Switch models and adjust reasoning](plugins/codex-micro-keypad/assets/screenshots/en-US/03-models.webp)

## Install

Requires Windows 10 build 19041+ / Windows 11 x64, .NET 10 Desktop Runtime x64, and a signed-in Codex desktop app. The current driverless adaptation baseline is **Codex 26.930.3930.0**; use that version or newer. Earlier versions are unverified, and later desktop updates may require adaptation.

- **Desktop:** extract `codex-micro-monitor-<version>-win-x64.zip` and run `CodexMicro.exe`.
- **Codex Plugin:** extract the entire `codex-micro-monitor-plugin-<version>-win-x64.zip`, keeping `.agents/` and `plugins/`. From the extracted root, run `codex plugin marketplace add .` with the Codex CLI. Restart Codex, open **Plugins → Codex Micro Monitor**, and install `codex-micro-keypad`. In a new chat, ask it to open Codex Micro Monitor. See the [official marketplace guide](https://developers.openai.com/plugins/build/plugins#add-a-marketplace-from-the-cli).

Packages are currently local build outputs; Microsoft Store and public plugin-directory releases are pending. See [build and distribution](docs/build-and-distribution.md).

## Notice

Codex Micro Monitor recreates the interaction and visual style of [Codex Micro](https://learn.chatgpt.com/docs/features/codex-micro) in software. No Micro hardware or virtual HID driver required. Originally maintained as part of [AgentController](https://github.com/gantrol/AgentController), it is now maintained independently in this repository.

This is an independent third-party project, not affiliated with or endorsed by OpenAI or Work Louder. Product names and trademarks belong to their respective owners. Images show the software with example data; supported features differ from the hardware.

[PolyForm Noncommercial 1.0.0](LICENSE).
