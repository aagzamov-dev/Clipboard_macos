#!/usr/bin/env python3
"""Reproduce the dependency-free Xcode project from its native source files."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = root / 'Clipboard.xcodeproj'
(project / 'xcshareddata/xcschemes').mkdir(parents=True, exist_ok=True)
objects = []
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(name, value):
    objects.append(f'{uid(name)} = {{ {value} }};')
    return uid(name)
def quoted(value): return '"' + value.replace('"', '\\"') + '"'
def array(values): return '(' + ', '.join(values) + (',' if values else '') + ')'
app_sources = sorted((root / 'ClipboardApp').glob('*.swift'))
ui_sources = sorted((root / 'Tests').glob('*UITests.swift'))
for path in app_sources + ui_sources:
    obj(str(path.relative_to(root)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(str(path.relative_to(root)))}; sourceTree = SOURCE_ROOT;')
    obj('build:' + path.name, f'isa = PBXBuildFile; fileRef = {uid(str(path.relative_to(root)))};')
obj('appProduct', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Clipboard.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('testProduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ClipboardUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; name = Products; children = {array([uid("appProduct"), uid("testProduct")])}; sourceTree = "<group>";')
obj('mainGroup', f'isa = PBXGroup; children = {array([uid(str(p.relative_to(root))) for p in app_sources + ui_sources] + [uid("products")])}; sourceTree = "<group>";')
obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = Packages/ClipboardCore;')
obj('coreProduct', f'isa = XCSwiftPackageProductDependency; package = {uid("package")}; productName = ClipboardCore;')
obj('coreFramework', f'isa = PBXBuildFile; productRef = {uid("coreProduct")};')
for name, sources in [('app',app_sources),('test',ui_sources)]:
    obj(name+'Sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array([uid("build:" + p.name) for p in sources])}; runOnlyForDeploymentPostprocessing = 0;')
    obj(name+'Frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {array([uid("coreFramework")] if name == "app" else [])}; runOnlyForDeploymentPostprocessing = 0;')
    obj(name+'Resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('testProxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("appTarget")}; remoteInfo = Clipboard;')
obj('testDependency', f'isa = PBXTargetDependency; target = {uid("appTarget")}; targetProxy = {uid("testProxy")};')
for name in ['project','app','test']:
    configs = []
    for config in ['Debug','Release']:
        settings = {'MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','SWIFT_VERSION':'6.0','CLANG_ENABLE_MODULES':'YES','SWIFT_STRICT_CONCURRENCY':'complete','CODE_SIGN_STYLE':'Automatic','ENABLE_HARDENED_RUNTIME':'YES','ENABLE_APP_SANDBOX':'NO'}
        if config == 'Debug': settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG','ENABLE_TESTABILITY':'YES','ONLY_ACTIVE_ARCH':'YES'})
        else: settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','SWIFT_COMPILATION_MODE':'wholemodule','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym'})
        if name == 'app': settings.update({'PRODUCT_NAME':'Clipboard','PRODUCT_BUNDLE_IDENTIFIER':'local.clipboard.Clipboard','INFOPLIST_FILE':'ClipboardApp/Info.plist','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
        if name == 'test': settings.update({'ENABLE_HARDENED_RUNTIME':'NO','PRODUCT_NAME':'ClipboardUITests','PRODUCT_BUNDLE_IDENTIFIER':'local.clipboard.ClipboardUITests','GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'Clipboard'})
        configs.append(obj(name+config, 'isa = XCBuildConfiguration; name = '+config+'; buildSettings = {'+' '.join(k+' = '+quoted(v)+';' for k,v in settings.items())+'};'))
    obj(name+'Configs', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('appTarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("appConfigs")}; buildPhases = {array([uid("appSources"),uid("appFrameworks"),uid("appResources")])}; buildRules = (); dependencies = (); name = Clipboard; packageProductDependencies = {array([uid("coreProduct")])}; productName = Clipboard; productReference = {uid("appProduct")}; productType = "com.apple.product-type.application";')
obj('testTarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("testConfigs")}; buildPhases = {array([uid("testSources"),uid("testFrameworks"),uid("testResources")])}; buildRules = (); dependencies = {array([uid("testDependency")])}; name = ClipboardUITests; productName = ClipboardUITests; productReference = {uid("testProduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {uid("mainGroup")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; packageReferences = {array([uid("package")])}; targets = {array([uid("appTarget"),uid("testTarget")])};')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
def ref(target, product, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Clipboard.xcodeproj"/>'
appref=ref('appTarget','Clipboard.app','Clipboard')
testref=ref('testTarget','ClipboardUITests.xctest','ClipboardUITests')
(project/'xcshareddata/xcschemes/Clipboard.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{testref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Created Clipboard.xcodeproj')
