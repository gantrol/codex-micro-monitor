#!/usr/bin/env python3
"""Create an isolated copy of Micro with a test-only desktop bundle."""
import argparse
import os
from pathlib import Path
import plistlib
import platform
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--app',type=Path,required=True)
parser.add_argument('--launch',action='store_true')
parser.add_argument('--native-composer',action='store_true',help='Observe a confirmed native composer with no chat ID')
parser.add_argument('--workspace-actions',action='store_true',help='Allow OAI and FOLD to use the production macOS opener; folder is disposable')
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
folder=Path(tempfile.mkdtemp(prefix='micro-ui-e2e-',dir='/tmp')).resolve()
app=folder/'Micro Isolated E2E.app'
subprocess.run(['/usr/bin/ditto',str(args.app.resolve()),str(app)],check=True)
info=app/'Contents/Info.plist'
with info.open('rb') as f: data=plistlib.load(f)
bundle_id='com.gantrol.micro.isolated-e2e.'+folder.name.replace('_','-')
data['CFBundleIdentifier']=bundle_id
(folder/'bundle-id').write_text(bundle_id)
data['CFBundleName']='Micro Isolated E2E'
data.pop('CFBundleURLTypes',None)
with info.open('wb') as f: plistlib.dump(data,f)
bridge=app/'Contents/PlugIns/MicroDesktop.bundle'
subprocess.run(['xcrun','swiftc','-emit-library','-module-name','FixtureDesktop','-target',platform.machine()+'-apple-macos14.0',str(root/'apps/macos/Sources/MicroShared/DesktopServices.swift'),str(root/'apps/macos/Sources/MicroDesktop/WorkspaceActions.swift'),str(root/'tests/macos/FixtureDesktopBridge.swift'),'-o',str(bridge/'Contents/MacOS/MicroDesktop')],check=True)
for bundle in [bridge,app]: subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(bundle)],check=True)
log=folder/'actions.jsonl'; log.touch()
(folder/'home').mkdir()
project=folder/('Micro Workspace E2E '+folder.name)
project.mkdir()
(project/'MICRO-E2E-ONLY.txt').write_text('Disposable project fixture for the Micro FOLD key.\n')
(folder/'workspace-folder').write_text(str(project))
# A dedicated bundle identifier isolates UserDefaults; delete only that fixture domain.
subprocess.run(['/usr/bin/defaults','delete',bundle_id],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if args.launch:
    env=dict(os.environ,MICRO_E2E_LOG=str(log),CODEX_HOME=str(folder/'home'),MICRO_E2E_NATIVE_ONLY='1' if args.native_composer else '0',MICRO_E2E_WORKSPACE_ACTIONS='1' if args.workspace_actions else '0',MICRO_E2E_FOLDER=str(project))
    stderr=(folder/'stderr.log').open('w')
    process=subprocess.Popen([str(app/'Contents/MacOS/CodexMicroMac')],env=env,stdout=stderr,stderr=stderr,start_new_session=True)
    (folder/'pid').write_text(str(process.pid))
print(folder)
