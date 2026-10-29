#!/usr/bin/env python3
"""Generate the native app/system-extension project using the checked-in Swift package."""
from pathlib import Path
import hashlib
import plistlib
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--without-experimental-runtime", action="store_true",
                    help="Build universal stock-UVC distribution without the experimental ARM-only DepthAI runtime")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[1]
# CMIO validates this before launching the extension, even when frames use a sink.
with (ROOT/'Config/Extension-Info.plist').open('rb') as f:
    mach_service = plistlib.load(f)['CMIOExtension']['CMIOExtensionMachServiceName']
with (ROOT/'Config/Extension.entitlements').open('rb') as f:
    extension_groups = plistlib.load(f).get('com.apple.security.application-groups', [])
with (ROOT/'Config/App.entitlements').open('rb') as f:
    app_groups = plistlib.load(f).get('com.apple.security.application-groups', [])
assert any((mach_service == group or mach_service.startswith(group + '.')) and group in app_groups
           for group in extension_groups), 'CMIO Mach service must be prefixed by an App Group granted to both app and extension'
objects = {}

def oid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(object_name, isa, **values):
    key = oid(object_name)
    objects[key] = dict(isa=isa, **values)
    return key

def build_settings(target, debug):
    values = dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='14.0', SWIFT_VERSION='5.0',
        DEVELOPMENT_TEAM='G766RX9X84', CODE_SIGN_STYLE='Automatic', CODE_SIGN_IDENTITY='Apple Development',
        ENABLE_HARDENED_RUNTIME='YES', ONLY_ACTIVE_ARCH='YES' if debug else 'NO', CLANG_ENABLE_MODULES='YES', ENABLE_USER_SCRIPT_SANDBOXING='YES',
        SWIFT_OPTIMIZATION_LEVEL='-Onone' if debug else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if debug else 'dwarf-with-dsym',
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if debug else '',
        CURRENT_PROJECT_VERSION='16', MARKETING_VERSION='0.1.0')
    if target == 'app':
        values.update(PRODUCT_BUNDLE_IDENTIFIER='com.timothyricks.opal-app', PRODUCT_NAME='OpalStudio',
            INFOPLIST_FILE='Config/App-Info.plist', CODE_SIGN_ENTITLEMENTS='Config/App.entitlements',
            LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'],
            ENABLE_APP_SANDBOX='YES', ENABLE_RESOURCE_ACCESS_CAMERA='YES', ENABLE_USER_SELECTED_FILES='readwrite',
            GENERATE_INFOPLIST_FILE='NO', COMBINE_HIDPI_IMAGES='YES')
    elif target == 'camera-launch':
        values.update(PRODUCT_BUNDLE_IDENTIFIER='com.timothyricks.opal-app.camera-launch', PRODUCT_NAME='OpalCameraLaunchAgent',
            EXECUTABLE_NAME='OpalCameraLaunchAgent', SKIP_INSTALL='YES', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='Config/CameraLaunchAgent-Info.plist', CREATE_INFOPLIST_SECTION_IN_BINARY='YES',
            ENABLE_APP_SANDBOX='YES', CODE_SIGN_ENTITLEMENTS='Config/CameraLaunchAgent.entitlements', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'])
    else:
        values.update(PRODUCT_BUNDLE_IDENTIFIER='com.timothyricks.opal-app.camera', PRODUCT_NAME='com.timothyricks.opal-app.camera',
            EXECUTABLE_NAME='CameraExtension', INFOPLIST_FILE='Config/Extension-Info.plist',
            CODE_SIGN_ENTITLEMENTS='Config/Extension.entitlements', ENABLE_APP_SANDBOX='YES',
            SKIP_INSTALL='YES', GENERATE_INFOPLIST_FILE='NO', APPLICATION_EXTENSION_API_ONLY='YES',
            LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'],
            WRAPPER_EXTENSION='systemextension')
    return values

def configurations(name, target=None):
    configs = []
    for config in ['Debug','Release']:
        values = build_settings(target, config == 'Debug') if target else dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='14.0', SWIFT_VERSION='5.0')
        configs.append(add(name+config, 'XCBuildConfiguration', name=config, buildSettings=values))
    return add(name+'Configurations', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')

main_children = []
def source_group(name, relative_path):
    refs, builds = [], []
    for file in sorted((ROOT/relative_path).glob('*.swift')):
        ref = add(str(file.relative_to(ROOT)), 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=file.name, sourceTree='<group>')
        refs.append(ref)
        builds.append(add('build '+str(file.relative_to(ROOT)), 'PBXBuildFile', fileRef=ref))
    main_children.append(add(name+'Group', 'PBXGroup', name=name, path=relative_path, sourceTree='<group>', children=refs))
    return builds
app_sources = source_group('App', 'Sources/OpalApp')
ext_sources = source_group('Camera Extension', 'Sources/CameraExtension')
launch_sources = source_group('Camera Launch Agent', 'Sources/CameraLaunchAgent')
config_refs=[]
for path in ['App-Info.plist','Extension-Info.plist','App.entitlements','Extension.entitlements']:
    config_refs.append(add('config '+path, 'PBXFileReference', path=path, sourceTree='<group>', lastKnownFileType='text.plist.xml'))
main_children.append(add('ConfigGroup', 'PBXGroup', path='Config', sourceTree='<group>', children=config_refs))
app_product=add('AppProduct','PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path='OpalStudio.app', sourceTree='BUILT_PRODUCTS_DIR')
ext_product=add('ExtensionProduct','PBXFileReference', explicitFileType='wrapper.system-extension', includeInIndex='0', path='com.timothyricks.opal-app.camera.systemextension', sourceTree='BUILT_PRODUCTS_DIR')
launch_product=add('CameraLaunchProduct','PBXFileReference', explicitFileType='compiled.mach-o.executable', includeInIndex='0', path='OpalCameraLaunchAgent', sourceTree='BUILT_PRODUCTS_DIR')
products_group=add('ProductsGroup','PBXGroup', name='Products', sourceTree='<group>', children=[app_product,ext_product,launch_product])
main_children.append(products_group)
package=add('LocalPackage', 'XCLocalSwiftPackageReference', relativePath='.')
package_products=[]
package_links=[]
for product in ['OpalCore','CameraBridge','C1API']:
    dep=add('package product '+product,'XCSwiftPackageProductDependency', package=package, productName=product)
    package_products.append(dep)
    package_links.append(add('link '+product,'PBXBuildFile', productRef=dep))
c1_refs=[]
c1_builds=[]
for library in ['libC1Bridge.dylib','libdepthai-core.dylib','libusb-1.0.dylib']:
    ref=add('c1 '+library,'PBXFileReference', explicitFileType='compiled.mach-o.dylib', path='build/c1/'+library, sourceTree='SOURCE_ROOT')
    c1_refs.append(ref)
    c1_builds.append(add('embed c1 '+library,'PBXBuildFile', fileRef=ref, settings={'ATTRIBUTES':['CodeSignOnCopy']}))
main_children.append(add('C1Libraries','PBXGroup', name='C1 runtime libraries', sourceTree='<group>', children=c1_refs))
c1_phase=add('EmbedC1Libraries','PBXCopyFilesBuildPhase', name='Embed C1 Runtime', buildActionMask='2147483647', dstPath='C1Bridge', dstSubfolderSpec='10', files=c1_builds, runOnlyForDeploymentPostprocessing='0')
license_ref=add('C1Licenses','PBXFileReference', lastKnownFileType='folder', name='C1Licenses', path='build/c1/licenses', sourceTree='SOURCE_ROOT')
main_children.append(license_ref)
license_build=add('C1LicensesBuild','PBXBuildFile', fileRef=license_ref)
license_phase=add('EmbedC1Licenses','PBXCopyFilesBuildPhase', name='Embed C1 Licenses', buildActionMask='2147483647', dstPath='C1Licenses', dstSubfolderSpec='7', files=[license_build], runOnlyForDeploymentPostprocessing='0')
resource_builds=[]
resource_refs=[]
for file in sorted((ROOT/'Resources').glob('*')):
    ref=add('resource '+file.name,'PBXFileReference', path='Resources/'+file.name, sourceTree='SOURCE_ROOT', lastKnownFileType={'.icns':'image.icns','.mp4':'video.mpeg4','.mlmodelc':'folder'}.get(file.suffix,'image.png'))
    resource_refs.append(ref)
    resource_builds.append(add('copy resource '+file.name,'PBXBuildFile',fileRef=ref))
main_children.append(add('AppResourcesGroup','PBXGroup', name='Resources', sourceTree='<group>',children=resource_refs))
resource_phase=add('AppResources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=resource_builds,runOnlyForDeploymentPostprocessing='0')
app_src_phase=add('AppSources','PBXSourcesBuildPhase', buildActionMask='2147483647', files=app_sources, runOnlyForDeploymentPostprocessing='0')
ext_src_phase=add('ExtensionSources','PBXSourcesBuildPhase', buildActionMask='2147483647', files=ext_sources, runOnlyForDeploymentPostprocessing='0')
app_fw_phase=add('AppFrameworks','PBXFrameworksBuildPhase', buildActionMask='2147483647', files=package_links, runOnlyForDeploymentPostprocessing='0')
ext_fw_phase=add('ExtensionFrameworks','PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
embed_file=add('EmbedExtensionBuildFile','PBXBuildFile', fileRef=ext_product, settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
embed_phase=add('EmbedExtension','PBXCopyFilesBuildPhase', name='Embed Camera Extension', buildActionMask='2147483647', dstPath='$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions', dstSubfolderSpec='16', files=[embed_file], runOnlyForDeploymentPostprocessing='0')
proxy=add('ExtensionProxy','PBXContainerItemProxy', containerPortal=oid('Project'), proxyType='1', remoteGlobalIDString=oid('ExtensionTarget'), remoteInfo='OpalCameraExtension')
dependency=add('ExtensionDependency','PBXTargetDependency', target=oid('ExtensionTarget'), targetProxy=proxy)
launch_src_phase=add('CameraLaunchSources','PBXSourcesBuildPhase', buildActionMask='2147483647', files=launch_sources, runOnlyForDeploymentPostprocessing='0')
launch_fw_phase=add('CameraLaunchFrameworks','PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
launch_build=add('EmbedCameraLaunchBinary','PBXBuildFile', fileRef=launch_product)
launch_embed=add('EmbedCameraLaunch','PBXCopyFilesBuildPhase', name='Embed Camera Launch Agent', buildActionMask='2147483647', dstPath='', dstSubfolderSpec='6', files=[launch_build], runOnlyForDeploymentPostprocessing='0')
launch_plist_ref=add('CameraLaunchPlist','PBXFileReference', lastKnownFileType='text.plist.xml', path='Config/com.timothyricks.opal-app.camera-launch.plist', sourceTree='SOURCE_ROOT')
main_children.append(launch_plist_ref)
launch_plist_build=add('EmbedCameraLaunchPlist','PBXBuildFile', fileRef=launch_plist_ref)
launch_plist_embed=add('EmbedLaunchAgentPlist','PBXCopyFilesBuildPhase', name='Embed LaunchAgent Registration', buildActionMask='2147483647', dstPath='$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents', dstSubfolderSpec='16', files=[launch_plist_build], runOnlyForDeploymentPostprocessing='0')
launch_proxy=add('CameraLaunchProxy','PBXContainerItemProxy', containerPortal=oid('Project'), proxyType='1', remoteGlobalIDString=oid('CameraLaunchTarget'), remoteInfo='OpalCameraLaunchAgent')
launch_dependency=add('CameraLaunchDependency','PBXTargetDependency', target=oid('CameraLaunchTarget'), targetProxy=launch_proxy)
launch_target=add('CameraLaunchTarget','PBXNativeTarget', name='OpalCameraLaunchAgent', productName='OpalCameraLaunchAgent', productType='com.apple.product-type.tool', productReference=launch_product,
                 buildConfigurationList=configurations('CameraLaunch','camera-launch'), buildPhases=[launch_src_phase,launch_fw_phase], buildRules=[], dependencies=[])
app_target=add('AppTarget','PBXNativeTarget', name='OpalStudio', productName='OpalStudio', productType='com.apple.product-type.application', productReference=app_product,
               buildConfigurationList=configurations('App','app'), buildPhases=[app_src_phase,app_fw_phase,resource_phase]+([] if args.without_experimental_runtime else [c1_phase,license_phase])+[embed_phase,launch_embed,launch_plist_embed], buildRules=[], dependencies=[dependency,launch_dependency], packageProductDependencies=package_products)
ext_target=add('ExtensionTarget','PBXNativeTarget', name='OpalCameraExtension', productName='com.timothyricks.opal-app.camera', productType='com.apple.product-type.system-extension', productReference=ext_product,
               buildConfigurationList=configurations('Extension','extension'), buildPhases=[ext_src_phase,ext_fw_phase], buildRules=[], dependencies=[])
main_group=add('MainGroup','PBXGroup', sourceTree='<group>', children=main_children)
project=add('Project','PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600',
              'TargetAttributes':{app_target:{'CreatedOnToolsVersion':'26.0','DevelopmentTeam':'G766RX9X84','ProvisioningStyle':'Automatic','SystemCapabilities':{'com.apple.SystemExtension':{'enabled':1},'com.apple.Sandbox':{'enabled':1},'com.apple.ApplicationGroups':{'enabled':1}}}, ext_target:{'CreatedOnToolsVersion':'26.0','DevelopmentTeam':'G766RX9X84','ProvisioningStyle':'Automatic','SystemCapabilities':{'com.apple.Sandbox':{'enabled':1},'com.apple.ApplicationGroups':{'enabled':1}}}}},
            buildConfigurationList=configurations('Project'), compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en','Base'],
            mainGroup=main_group, productRefGroup=products_group, projectDirPath='', projectRoot='', targets=[app_target,ext_target,launch_target], packageReferences=[package])
project_dir=ROOT/'OpalStudio.xcodeproj'
project_dir.mkdir(exist_ok=True)
with (project_dir/'project.pbxproj').open('wb') as f:
    plistlib.dump({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project},f,sort_keys=False)
scheme_dir=project_dir/'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
(scheme_dir/'OpalStudioNative.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OpalStudio.app" BlueprintName="OpalStudio" ReferencedContainer="container:OpalStudio.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OpalStudio.app" BlueprintName="OpalStudio" ReferencedContainer="container:OpalStudio.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project_dir)
