#!/bin/bash
# Build a signed local preview. No install, launch, publish or notarization.
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_arch="${1:-universal}"
case "$task_arch" in
  arm64|x86_64) task_xcode_archs="$task_arch" ;;
  universal) task_xcode_archs="arm64 x86_64" ;;
  *) echo 'Usage: scripts/package-macos.sh [universal|arm64|x86_64] [candidate-tag] [signing-identity]' >&2; exit 2 ;;
esac

task_sign_identity="${3:-${MICRO_CODE_SIGN_IDENTITY:-}}"
if [[ -z "$task_sign_identity" ]]; then
  task_sign_identity="$(xcodebuild -project "$task_root/apps/macos/CodexMicroMac.xcodeproj" -scheme CodexMicroMac \
    -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' -showBuildSettings -json | \
    /usr/bin/python3 -c 'import json,sys; rows=json.load(sys.stdin); print(next(row["buildSettings"]["CODE_SIGN_IDENTITY"] for row in rows if row["target"] == "CodexMicroMac"))')"
fi
if [[ "$task_sign_identity" == - ]]; then
  echo 'Ad-hoc signing selected explicitly; Accessibility authorization may not survive a rebuild.' >&2
else
  task_sign_identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/python3 -c '
import re,sys
wanted=sys.argv[1]
rows=re.findall(r"([0-9A-Fa-f]{40}) \"([^\"]+)\"",sys.stdin.read())
matches=sorted({sha for sha,name in rows if sha.lower() == wanted.lower() or name == wanted or name.startswith(wanted+":")})
if len(matches) != 1:
    sys.exit("Select one valid signing identity; configure Apple Development in Xcode or supply its exact certificate name/hash.")
print(matches[0])' "$task_sign_identity")"
fi

task_output="$task_root/dist/macos/$task_arch"
if [[ -n "${2:-}" ]]; then
  [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid candidate tag.' >&2; exit 2; }
  task_output="$task_root/dist/macos/$2/$task_arch"
fi
mkdir -p "$task_output"
task_stage="$(mktemp -d "$task_output/.package.XXXXXX")"
trap 'rm -rf -- "$task_stage"' EXIT

xcodebuild -project "$task_root/apps/macos/CodexMicroMac.xcodeproj" -scheme CodexMicroMac \
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$task_root/apps/macos/.build/xcode-$task_arch" \
  "ARCHS=$task_xcode_archs" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  "MICRO_CODE_SIGN_IDENTITY=$task_sign_identity" \
  REGISTER_APP_WITH_LAUNCH_SERVICES=NO build
task_app="$task_stage/Codex Micro Monitor.app"
/usr/bin/ditto "$task_root/apps/macos/.build/xcode-$task_arch/Build/Products/Release-maccatalyst/Codex Micro Monitor.app" "$task_app"
task_bridge="$task_app/Contents/PlugIns/MicroDesktop.bundle"
cp "$task_root/LICENSE" "$task_app/Contents/Resources/LICENSE"

task_icons="$task_stage/AppIcon.iconset"
mkdir -p "$task_icons"
for task_size in 16 32 128 256 512; do
  /usr/bin/sips -z "$task_size" "$task_size" "$task_root/assets/CodexMicro.png" --out "$task_icons/icon_${task_size}x${task_size}.png" >/dev/null
  # The repository artwork is 512px. Keep the 512px 1x source instead of inventing a 1024px asset.
  if [[ "$task_size" -lt 512 ]]; then
    task_double=$((task_size * 2))
    /usr/bin/sips -z "$task_double" "$task_double" "$task_root/assets/CodexMicro.png" --out "$task_icons/icon_${task_size}x${task_size}@2x.png" >/dev/null
  fi
done
/usr/bin/iconutil -c icns "$task_icons" -o "$task_app/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$task_app/Contents/Info.plist"
/usr/bin/codesign --force --sign "$task_sign_identity" "$task_bridge"
/usr/bin/codesign --force --sign "$task_sign_identity" "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
/usr/bin/codesign --display -r - "$task_app"
/usr/bin/lipo -archs "$task_app/Contents/MacOS/CodexMicroMac"
/usr/bin/lipo -archs "$task_bridge/Contents/MacOS/MicroDesktop"

# Both destinations are generated build artifacts inside this repository.
if [[ -L "$task_output/Codex Micro Monitor.app" ]]; then
  echo 'Refusing to replace a symlinked app destination.' >&2; exit 1
fi
if [[ -e "$task_output/Codex Micro Monitor.app" ]]; then
  mv "$task_output/Codex Micro Monitor.app" "$task_stage/previous.app"
fi
mv "$task_app" "$task_output/Codex Micro Monitor.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$task_output/Codex Micro Monitor.app" "$task_stage/codex-micro-macos-preview.zip"
mv -f "$task_stage/codex-micro-macos-preview.zip" "$task_output/codex-micro-macos-preview.zip"
echo "App: $task_output/Codex Micro Monitor.app"
echo "ZIP: $task_output/codex-micro-macos-preview.zip"
