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
mkdir -p "$task_bridge/Contents/Resources/ThirdParty"
cp "$task_root/apps/macos/ThirdParty/PermissionFlow/LICENSE" "$task_bridge/Contents/Resources/ThirdParty/PermissionFlow-LICENSE"
/usr/bin/python3 - "$task_root" "$task_bridge/Contents/Resources/BuildIdentity.json" "$task_configuration" "${ARCHS:-arm64}" <<'PY'
import datetime, hashlib, json, sys
from pathlib import Path
root, output = Path(sys.argv[1]), Path(sys.argv[2])
sources = sorted((root/'apps/macos/Sources').rglob('*.swift'))
sources += [root/'apps/macos/Package.swift', root/'apps/macos/Package.resolved', root/'scripts/build-macos-desktop-bridge.sh']
digest = hashlib.sha256()
for source in sources:
    digest.update(str(source.relative_to(root)).encode()); digest.update(b'\0')
    digest.update(source.read_bytes()); digest.update(b'\0')
output.write_text(json.dumps({'sourceSHA256': digest.hexdigest(), 'builtAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                              'configuration': sys.argv[3], 'architectures': sys.argv[4].split()}, sort_keys=True)+'\n')
PY
# A packaging build can supply the already-resolved identity. An Xcode Run
# inherits its actual expanded signer, keeping the bridge and application equal.
task_sign_identity="${MICRO_CODE_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-Apple Development}}}"
/usr/bin/codesign --force --sign "$task_sign_identity" "$task_bridge"
