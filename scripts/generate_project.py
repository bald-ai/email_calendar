#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project after adding Swift sources. No XcodeGen needed."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


files = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "EmailCalendar").rglob("*.swift"))
objects = []


def obj(key, body):
    objects.append(f"\t\t{identifier(key)} = {{ {body} }};")


for path in files:
    obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(path)}; sourceTree = SOURCE_ROOT;")
    obj("build:" + path, f"isa = PBXBuildFile; fileRef = {identifier('file:' + path)};")

obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = EmailCalendar.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("sqlite", 'isa = PBXFileReference; lastKnownFileType = "sourcecode.text-based-dylib-definition"; path = usr/lib/libsqlite3.tbd; sourceTree = SDKROOT;')
obj("sqliteBuild", f"isa = PBXBuildFile; fileRef = {identifier('sqlite')};")
obj("keyboardBuild", f"isa = PBXBuildFile; productRef = {identifier('keyboardProduct')};")
obj("configFile", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/App.xcconfig; sourceTree = SOURCE_ROOT;')
obj("exampleFile", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Secrets.example.xcconfig; sourceTree = SOURCE_ROOT;')
obj("infoFile", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = EmailCalendar/Resources/Info.plist; sourceTree = SOURCE_ROOT;')
obj("entitlements", 'isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = EmailCalendar/Resources/EmailCalendar.entitlements; sourceTree = SOURCE_ROOT;')
obj("sourcesGroup", f"isa = PBXGroup; name = Sources; children = ({','.join(identifier('file:' + p) for p in files)}); sourceTree = \"<group>\";")
obj("productsGroup", f"isa = PBXGroup; name = Products; children = ({identifier('app')}); sourceTree = \"<group>\";")
obj("mainGroup", f"isa = PBXGroup; children = ({','.join(identifier(s) for s in ['sourcesGroup','configFile','exampleFile','infoFile','entitlements','sqlite','productsGroup'])}); sourceTree = \"<group>\";")
obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(identifier('build:' + p) for p in files)}); runOnlyForDeploymentPostprocessing = 0;")
obj("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({identifier('sqliteBuild')},{identifier('keyboardBuild')}); runOnlyForDeploymentPostprocessing = 0;")
obj("resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("keyboardPackage", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sindresorhus/KeyboardShortcuts"; requirement = { kind = upToNextMajorVersion; minimumVersion = 2.3.0; };')
obj("keyboardProduct", f"isa = XCSwiftPackageProductDependency; package = {identifier('keyboardPackage')}; productName = KeyboardShortcuts;")
for scope in ["project", "target"]:
    for config in ["Debug", "Release"]:
        settings = {
            "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "CLANG_ENABLE_MODULES": "YES",
            "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete"
        }
        if scope == "target":
            settings.update({"CODE_SIGN_STYLE": "Automatic", "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks"})
        if config == "Debug":
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "DEBUG_INFORMATION_FORMAT": "dwarf"})
        else:
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"})
        base = f"baseConfigurationReference = {identifier('configFile')};" if scope == "target" else ""
        obj(scope + config, f"isa = XCBuildConfiguration; {base} buildSettings = {{ {' '.join(f'{k} = {quoted(v)};' for k,v in settings.items())} }}; name = {config};")
    obj(scope + "Config", f"isa = XCConfigurationList; buildConfigurations = ({identifier(scope+'Debug')},{identifier(scope+'Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {identifier('targetConfig')}; buildPhases = ({identifier('sources')},{identifier('frameworks')},{identifier('resources')}); buildRules = (); dependencies = (); name = EmailCalendar; packageProductDependencies = ({identifier('keyboardProduct')}); productName = EmailCalendar; productReference = {identifier('app')}; productType = \"com.apple.product-type.application\";")
obj("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; TargetAttributes = {{ {identifier('target')} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {identifier('projectConfig')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {identifier('mainGroup')}; packageReferences = ({identifier('keyboardPackage')}); productRefGroup = {identifier('productsGroup')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({identifier('target')});")
project = ROOT / "EmailCalendar.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {identifier('project')};\n}}\n")
schemes = project / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier("target")}" BuildableName="EmailCalendar.app" BlueprintName="EmailCalendar" ReferencedContainer="container:EmailCalendar.xcodeproj"/>'
(schemes / "EmailCalendar.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated Xcode project with {len(files)} Swift sources.")
