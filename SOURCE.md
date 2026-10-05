# Source provenance

Codex Micro Monitor was extracted from [gantrol/AgentController](https://github.com/gantrol/AgentController) on 2026-10-03, starting from commit `7d4a3382a82c94adab853a924249ed9823be28f5` and reconciled with later changes through `92c9e8a`. Its original PolyForm Noncommercial 1.0.0 license is retained.

The independent product contains the Windows panel, desktop and plugin hosts, product state/lighting contracts, existing tests and a historical UIKit prototype. The current Apple target is macOS; no macOS client has been implemented.

Shared control implementations live in the independent `codex-control` repository. Both products consume exact-version `CodexControl` and `CodexControl.Windows` packages (`0.1.0-local.2`). Neither product references the other's projects or source files. Existing namespaces are retained for compatibility and do not imply repository ownership.

The extraction excludes the virtual HID broker/driver, DeepSeek setup and launch, external adapter dispatch and local speech capture/ASR. Legacy voice profile fields may remain as inert compatibility data; the product cannot start a speech provider. AgentController retains its own navigation and physical-controller integration.

Private migration records, raw source manifests, local validation logs and working-machine evidence are not part of the public release. See [repository boundaries](docs/repository-layout.zh-CN.md), [build and distribution](docs/build-and-distribution.md) and the [macOS handoff](docs/architecture/macos-development-handoff.zh-CN.md) for maintained instructions.
