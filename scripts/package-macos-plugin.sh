#!/bin/bash
# Stage a macOS-only plugin from the product-owned portable source and built app.
# No installation, Codex changes, publishing, or Windows manifest replacement.
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_arch="${1:-universal}"
case "$task_arch" in arm64|x86_64|universal) ;; *) echo 'Usage: scripts/package-macos-plugin.sh [universal|arm64|x86_64] [candidate-tag]' >&2; exit 2;; esac
task_output="$task_root/dist/macos/$task_arch"
if [[ -n "${2:-}" ]]; then
  [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid candidate tag.' >&2; exit 2; }
  task_output="$task_root/dist/macos/$2/$task_arch"
fi
task_app="$task_output/Codex Micro Monitor.app"
[[ -d "$task_app" && ! -L "$task_app" ]] || { echo 'Build scripts/package-macos.sh first.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$task_app"
task_stage="$(mktemp -d "$task_output/.plugin.XXXXXX")"
trap 'rm -rf -- "$task_stage"' EXIT
task_bundle="$task_stage/package-root"
task_plugin="$task_bundle/plugins/codex-micro-keypad"
mkdir -p "$task_bundle/plugins" "$task_bundle/.agents/plugins"
/usr/bin/ditto "$task_root/plugins/codex-micro-keypad" "$task_plugin"
/usr/bin/ditto "$task_root/.agents/plugins/marketplace.json" "$task_bundle/.agents/plugins/marketplace.json"
mkdir -p "$task_plugin/bin"
/usr/bin/ditto "$task_app" "$task_plugin/bin/Codex Micro Monitor.app"
python3 - "$task_plugin" <<'PY'
import json, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
with (root/'bin/Codex Micro Monitor.app/Contents/Info.plist').open('rb') as f:
    version = plistlib.load(f)['CodexMicroReleaseVersion']
p = root/'plugin.json'
manifest = json.loads(p.read_text())
manifest['version'] = version
manifest['description'] = 'Native macOS Codex Micro preview: task activity, model controls and guarded composer actions, without a virtual HID driver.'
interface = manifest['extensions']['com.openai']['interface']
interface['longDescription'] = 'A macOS 14+ preview for Apple silicon and Intel Macs. Requires the local Codex desktop app. Native composer controls require Accessibility permission and an unambiguous target; blank-draft modes use observed native controls or configured shortcuts with readback. Some controls remain pending live acceptance. No Micro hardware, Windows runtime or virtual HID driver is required. Independent third-party project, not affiliated with or endorsed by OpenAI or Work Louder.'
# The product source screenshots show the released Windows build.
interface.pop('screenshots', None)
p.write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+'\n')
config = {'$schema':'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json', 'mcpServers': {'codex-micro-keypad': {
    'type':'stdio', 'command':'${PLUGIN_ROOT}/bin/Codex Micro Monitor.app/Contents/MacOS/CodexMicroMac', 'args':['--mcp'], 'cwd':'${PLUGIN_ROOT}'}}}
(root/'mcp.json').write_text(json.dumps(config, indent=2)+'\n')
assert len(interface['shortDescription']) <= 30
PY
/usr/bin/ditto -c -k --sequesterRsrc "$task_bundle" "$task_stage/codex-micro-keypad-macos.zip"
mv -f "$task_stage/codex-micro-keypad-macos.zip" "$task_output/codex-micro-keypad-macos.zip"
echo "Plugin ZIP: $task_output/codex-micro-keypad-macos.zip"
