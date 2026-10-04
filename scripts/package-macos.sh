#!/bin/bash
# Build a local, ad-hoc signed preview. No install, launch, publish or notarization.
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_arch="${1:-universal}"
case "$task_arch" in
  arm64|x86_64) task_xcode_archs="$task_arch" ;;
  universal) task_xcode_archs="arm64 x86_64" ;;
  *) echo 'Usage: scripts/package-macos.sh [universal|arm64|x86_64]' >&2; exit 2 ;;
esac

task_output="$task_root/dist/macos/$task_arch"
mkdir -p "$task_output"
task_stage="$(mktemp -d "$task_output/.package.XXXXXX")"
trap 'rm -rf -- "$task_stage"' EXIT

xcodebuild -project "$task_root/apps/macos/CodexMicroMac.xcodeproj" -scheme CodexMicroMac \
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$task_root/apps/macos/.build/xcode-$task_arch" \
  "ARCHS=$task_xcode_archs" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
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
/usr/bin/codesign --force --sign - "$task_bridge"
/usr/bin/codesign --force --sign - "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
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
