# Source provenance

This independent repository was extracted from `gantrol/AgentController`, branch
`codex/micro-behavior-acceptance`, commit
`7d4a3382a82c94adab853a924249ed9823be28f5` on 2026-10-03.

`docs/source-files.json` records original paths, destination paths and SHA-256
hashes **before** namespace changes and removal of excluded features. It is a
provenance manifest, not a checksum of this repository's final files. Some listed
files were subsequently removed as described below. The original Git history
and uncommitted changes were not copied. The source license is retained.

| Source | Destination |
| --- | --- |
| `virtual-micro/src/CodexMicro.Desktop` and `AgentController.MicroSurface.Wpf` | `src/CodexMicro.Windows` |
| `src/AgentController.Adapters.Codex.Software` except navigation executor | `src/CodexMicro.Codex` |
| Micro status reader, thread state and transport result contracts | `src/CodexMicro.Core` |
| `virtual-micro/src/CodexMicro.DesktopHost` | `src/CodexMicro.Desktop` and shared Windows hosting |
| `micro-bridge/CodexPlugin` | `src/CodexMicro.Plugin` |
| `virtual-micro/tests` | `tests` |
| Committed `virtual-micro/ios` snapshot | `apps/ios` |

The extraction removes the virtual HID broker/driver, DeepSeek setup and launch,
external adapter dispatch, local speech capture/ASR, their settings pages and
audio/WinRT package dependencies. Old voice profile fields remain as inert data
for settings compatibility; no speech provider can be started by this product.
Legacy driver/external adapter/voice-specific test classes and visual assertions
for those removed surfaces were not retained. Software behavior acceptance tests
remain, including failures for unfinished controls.

`CodexThreadNavigationExecutor` stays in AgentController and consumes a pinned
`CodexMicro.Codex` NuGet package. The new repository has no source links or project
references back to AgentController. Settings paths and plugin ID remain compatible.

The iOS snapshot is unfinished and has not been built. Uncommitted iOS and Windows
edits in the source working tree belong to their ongoing work and are not part of
this frozen extraction. Nothing in this migration was uploaded or installed.
