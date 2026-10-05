# Source provenance

Codex Micro Monitor was extracted from [gantrol/AgentController](https://github.com/gantrol/AgentController) on 2026-10-03, starting from commit `7d4a3382a82c94adab853a924249ed9823be28f5` and reconciled with later changes through `92c9e8a`. The extraction initially retained PolyForm Noncommercial 1.0.0. On 2026-10-04, the author relicensed the project-owned code under [GNU General Public License v3.0 only (GPL-3.0-only)](LICENSE). Third-party materials retain their own licenses and notices; this change does not establish permission for third-party visual assets whose licensing remains unverified.

The independent product contains the Windows panel, desktop and plugin hosts, product state/lighting contracts, existing tests and a historical UIKit prototype. The current Apple target is macOS; no macOS client has been implemented.

Shared control implementations live in the independent `codex-control` repository. The Micro release builds consume exact-version `CodexControl` and `CodexControl.Windows` packages (`1.0.1`); AgentController maintains its own independent dependency pin. Micro additionally supports an explicit sibling-source option for local development; releases use the pinned packages. Existing namespaces are retained for compatibility and do not imply repository ownership.

The extraction excludes the virtual HID broker/driver, DeepSeek setup and launch, external adapter dispatch and local speech capture/ASR. Legacy voice profile fields may remain as inert compatibility data; the product cannot start a speech provider. AgentController retains its own navigation and physical-controller integration.

Private migration records, raw source manifests, local validation logs and working-machine evidence are not part of the public release. See [repository boundaries](docs/repository-layout.zh-CN.md), [build and distribution](docs/build-and-distribution.md) and the [macOS handoff](docs/architecture/macos-development-handoff.zh-CN.md) for maintained instructions.
