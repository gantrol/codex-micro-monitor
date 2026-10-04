#!/bin/bash
# Called by Xcode so Run and packaged builds contain the same native bridge.
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_configuration=debug
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then task_configuration=release; fi
task_arch_args=()
for task_cpu in ${ARCHS:-arm64}; do
  case "$task_cpu" in arm64|x86_64) task_arch_args+=(--arch "$task_cpu");; *) echo 'Unsupported architecture' >&2; exit 2;; esac
done
swift build --package-path "$task_root/apps/macos" -c "$task_configuration" "${task_arch_args[@]}"
task_bin="$(swift build --package-path "$task_root/apps/macos" -c "$task_configuration" "${task_arch_args[@]}" --show-bin-path)"
task_bridge="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/PlugIns/MicroDesktop.bundle"
mkdir -p "$task_bridge/Contents/MacOS"
cp "$task_bin/libMicroDesktop.dylib" "$task_bridge/Contents/MacOS/MicroDesktop"
cp "$task_root/apps/macos/Packaging/DesktopBridge.plist" "$task_bridge/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$task_bridge"
