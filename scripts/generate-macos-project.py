#!/usr/bin/env python3
"""Generate the small Mac Catalyst Xcode project from the native source list."""
from pathlib import Path
import hashlib
import json
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'apps/macos'
objects={}
def item(label,**value):
    key=hashlib.sha256(label.encode()).hexdigest()[:24].upper()
    objects[key]=value
    return key
sources=sorted((BASE/'Sources/CodexMicroMac').glob('*.swift'))+sorted((BASE/'Sources/MicroShared').glob('*.swift'))+[BASE/'Sources/MicroCore/MacPreviewCapabilities.swift']
refs=[]; builds=[]
for path in sources:
    rel=str(path.relative_to(BASE))
    ref=item(rel,isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path=rel,sourceTree='<group>')
    refs.append(ref); builds.append(item(rel+'build',isa='PBXBuildFile',fileRef=ref))
locale=[]
for language in ['en','zh-Hans']:
    locale.append(item(language,isa='PBXFileReference',lastKnownFileType='text.plist.strings',name=language,path=f'Sources/CodexMicroMac/Resources/{language}.lproj/Localizable.strings',sourceTree='<group>'))
strings=item('strings',isa='PBXVariantGroup',children=locale,name='Localizable.strings',sourceTree='<group>')
resources=[item('stringsbuild',isa='PBXBuildFile',fileRef=strings)]
product=item('product',isa='PBXFileReference',explicitFileType='wrapper.application',path='Codex Micro Monitor.app',sourceTree='BUILT_PRODUCTS_DIR')
signing=item('signing',isa='PBXFileReference',lastKnownFileType='text.xcconfig',path='Packaging/Signing.xcconfig',sourceTree='<group>')
group=item('main',isa='PBXGroup',children=refs+[strings,signing,product],sourceTree='<group>')
# WidgetKit runs a native macOS extension alongside the Catalyst application.
widgetrefs=[]; widgetbuilds=[]
for path in [BASE/'Sources/MicroShared/MicroWidgetSnapshot.swift',BASE/'Sources/MicroMonitorWidget/MicroMonitorWidget.swift']:
    rel=str(path.relative_to(BASE))
    ref=item('widget'+rel,isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path=rel,sourceTree='<group>')
    widgetrefs.append(ref); widgetbuilds.append(item('widget'+rel+'build',isa='PBXBuildFile',fileRef=ref))
widgetresources=[item('widgetstringsbuild',isa='PBXBuildFile',fileRef=strings)]
for path in sorted((BASE/'Sources/MicroMonitorWidget/Resources').glob('*.png')):
    rel=str(path.relative_to(BASE))
    ref=item(rel,isa='PBXFileReference',lastKnownFileType='image.png',path=rel,sourceTree='<group>')
    widgetrefs.append(ref); widgetresources.append(item(rel+'build',isa='PBXBuildFile',fileRef=ref))
widgetproduct=item('widgetproduct',isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='MicroMonitorWidget.appex',sourceTree='BUILT_PRODUCTS_DIR')
objects[group]['children']+=widgetrefs+[widgetproduct]
widgetphases=[item('widgetsources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=widgetbuilds,runOnlyForDeploymentPostprocessing=0),item('widgetresources',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=widgetresources,runOnlyForDeploymentPostprocessing=0),item('widgetframeworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
widgetconfigs=[]
for name in ['Debug','Release']:
    widgetconfigs.append(item('widgetconfig'+name,isa='XCBuildConfiguration',name=name,baseConfigurationReference=signing,buildSettings={
        'SDKROOT':'macosx','SDK_VARIANT':'macos','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0',
        'SUPPORTED_PLATFORMS':'macosx','SUPPORTS_MACCATALYST':'NO','PRODUCT_NAME':'MicroMonitorWidget',
        'PRODUCT_BUNDLE_IDENTIFIER':'com.gantrol.codex-micro-monitor.widget','INFOPLIST_FILE':'Packaging/WidgetInfo.plist',
        'GENERATE_INFOPLIST_FILE':'NO','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES',
        'CODE_SIGN_ENTITLEMENTS':'Packaging/MicroWidget.entitlements','ENABLE_APP_SANDBOX':'YES',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks',
        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','CLANG_ENABLE_MODULES':'YES'}))
widgetconfiglist=item('widgetconfigs',isa='XCConfigurationList',buildConfigurations=widgetconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
widgettarget=item('widgettarget',isa='PBXNativeTarget',name='MicroMonitorWidget',productName='MicroMonitorWidget',productReference=widgetproduct,productType='com.apple.product-type.app-extension',buildConfigurationList=widgetconfiglist,buildPhases=widgetphases,buildRules=[],dependencies=[])
widgetdependency=item('widgetdependency',isa='PBXTargetDependency',target=widgettarget)
phases=[item('sources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0),item('resources',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0),item('frameworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
widgetembed=item('widgetembed',isa='PBXBuildFile',fileRef=widgetproduct,settings={'ATTRIBUTES':['RemoveHeadersOnCopy','CodeSignOnCopy']})
phases.append(item('embedwidgets',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[widgetembed],name='Embed Widget Extension',runOnlyForDeploymentPostprocessing=0))
phases.append(item('desktopbridge',isa='PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=[],outputPaths=[],alwaysOutOfDate=1,runOnlyForDeploymentPostprocessing=0,shellPath='/bin/bash',shellScript='"$SRCROOT/../../scripts/build-macos-desktop-bridge.sh"\n'))
configs=[]
for name in ['Debug','Release']:
    configs.append(item('config'+name,isa='XCBuildConfiguration',name=name,baseConfigurationReference=signing,buildSettings={
        'SDKROOT':'macosx','SDK_VARIANT':'iosmac','IPHONEOS_DEPLOYMENT_TARGET':'17.0','MACOSX_DEPLOYMENT_TARGET':'14.0',
        'SWIFT_VERSION':'5.0','SUPPORTS_MACCATALYST':'YES','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO',
        'DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER':'NO','TARGETED_DEVICE_FAMILY':'2,6',
        'PRODUCT_NAME':'Codex Micro Monitor','EXECUTABLE_NAME':'CodexMicroMac','PRODUCT_MODULE_NAME':'CodexMicroMac',
        'PRODUCT_BUNDLE_IDENTIFIER':'com.gantrol.codex-micro-monitor','INFOPLIST_FILE':'Packaging/Info.plist',
        'GENERATE_INFOPLIST_FILE':'NO',
        'CODE_SIGN_ENTITLEMENTS':'Packaging/MicroApp.entitlements',
        'ENABLE_APP_SANDBOX':'NO','ENABLE_HARDENED_RUNTIME':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'NO',
        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','SWIFT_COMPILATION_MODE':'wholemodule' if name=='Release' else 'incremental',
        'CLANG_ENABLE_MODULES':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks',
        'SUPPORTED_PLATFORMS':'macosx','SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD':'NO'}))
configlist=item('configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
# Project and target cannot share XCBuildConfiguration objects in Xcode.
pc=[]
for name in ['Debug','Release']:
    pc.append(item('projectconfig'+name,isa='XCBuildConfiguration',name=name,buildSettings={'SDKROOT':'macosx','SDK_VARIANT':'iosmac','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES'}))
pclist=item('projectconfigs',isa='XCConfigurationList',buildConfigurations=pc,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=item('target',isa='PBXNativeTarget',name='CodexMicroMac',productName='Codex Micro Monitor',productReference=product,productType='com.apple.product-type.application',buildConfigurationList=configlist,buildPhases=phases,buildRules=[],dependencies=[widgetdependency])
project=item('project',isa='PBXProject',attributes={'LastUpgradeCheck':'1630','BuildIndependentTargetsInParallel':'YES'},buildConfigurationList=pclist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','zh-Hans','Base'],mainGroup=group,projectDirPath='',projectRoot='',targets=[target,widgettarget])
def encode(value,depth=0):
    if isinstance(value,dict):return '{\n'+''.join('  '*(depth+1)+json.dumps(k)+' = '+encode(v,depth+1)+';\n' for k,v in value.items())+'  '*depth+'}'
    if isinstance(value,list):return '('+', '.join(encode(v,depth+1) for v in value)+')'
    return json.dumps(value,ensure_ascii=False)
p=BASE/'CodexMicroMac.xcodeproj/project.pbxproj';p.parent.mkdir(exist_ok=True)
p.write_text('// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
print(p)
