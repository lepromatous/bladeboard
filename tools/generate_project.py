#!/usr/bin/env python3
"""Writes Bladeboard.xcodeproj.

The project uses Xcode's folder-synchronized groups (Xcode 16 and later):
App/, Core/ and Tests/ are referenced as folders, so adding or removing a
Swift file needs no project change at all. Run this only to change targets
or build settings, and note that it resets the signing team you picked in
Xcode:

    python3 tools/generate_project.py

Two targets:

  Bladeboard        iOS app. App/ + Core/.
  BladeboardTests   macOS unit tests. Core/ + Tests/. Core is Foundation-only,
                     so the protocol, catalog and library code tests on the Mac
                     in seconds with no simulator.
"""

import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Bladeboard.xcodeproj"

APP = "Bladeboard"
TESTS = "BladeboardTests"
BUNDLE_ID = "com.lepromatous.Bladeboard"
IOS_TARGET = "18.0"
MACOS_TARGET = "14.0"


def uid(*parts):
    return hashlib.md5("::".join(parts).encode()).hexdigest()[:24].upper()


def settings(values, indent="\t\t\t\t"):
    lines = []
    for key in sorted(values):
        value = values[key]
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            lines.extend(f'{indent}\t"{v}",' for v in value)
            lines.append(f"{indent});")
        else:
            text = str(value)
            if not text or any(c in text for c in ' $()"=,;@+-') and not text.startswith('"'):
                text = '"' + text.replace('"', '\\"') + '"'
            lines.append(f"{indent}{key} = {text};")
    return "\n".join(lines)


COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "IPHONEOS_DEPLOYMENT_TARGET": IOS_TARGET,
    "MACOSX_DEPLOYMENT_TARGET": MACOS_TARGET,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
DEBUG = {
    **COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
RELEASE = {
    **COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}
APP_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": "",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Bladeboard",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.music",
    "INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription":
        "Bladeboard uses Bluetooth to reach your Katana through the AIRSTEP Kat.",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":
        "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown "
        "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
        "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "TARGETED_DEVICE_FAMILY": "1,2",
}
TEST_SETTINGS = {
    "CODE_SIGN_STYLE": "Automatic",
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".Tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "macosx",
    "SUPPORTED_PLATFORMS": "macosx",
}


def main():
    app_product, test_product = f"{APP}.app", f"{TESTS}.xctest"
    ids = {name: uid(name) for name in (
        "project", "main", "products", "config", "plist", "app.product", "test.product",
        "group.App", "group.Core", "group.Tests", "exc.app", "exc.test",
        "app.target", "test.target", "app.sources", "app.frameworks", "app.resources",
        "test.sources", "test.frameworks", "test.resources",
        "cfg.project", "cfg.app", "cfg.test",
        "cfg.project.Debug", "cfg.project.Release", "cfg.app.Debug", "cfg.app.Release",
        "cfg.test.Debug", "cfg.test.Release",
    )}
    I = ids

    def phase(kind, key):
        return (f"\t\t{I[key]} /* {kind} */ = {{\n\t\t\tisa = PBX{kind}BuildPhase;\n"
                f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
                f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")

    def config(key, name, values):
        return (f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
                f"\t\t\tbuildSettings = {{\n{settings(values)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")

    def config_list(key, prefix, comment):
        return (f"\t\t{I[key]} /* Build configuration list for {comment} */ = {{\n"
                f"\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{I[prefix + '.Debug']} /* Debug */,\n\t\t\t\t{I[prefix + '.Release']} /* Release */,\n"
                f"\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")

    def target(key, name, product_key, product, product_type, groups, prefix):
        group_list = "".join(f"\t\t\t\t{I['group.' + g]} /* {g} */,\n" for g in groups)
        return (f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
                f"\t\t\tbuildConfigurationList = {I['cfg.' + prefix]} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
                f"\t\t\tbuildPhases = (\n\t\t\t\t{I[prefix + '.sources']} /* Sources */,\n"
                f"\t\t\t\t{I[prefix + '.frameworks']} /* Frameworks */,\n\t\t\t\t{I[prefix + '.resources']} /* Resources */,\n\t\t\t);\n"
                f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
                f"\t\t\tfileSystemSynchronizedGroups = (\n{group_list}\t\t\t);\n"
                f"\t\t\tname = {name};\n\t\t\tpackageProductDependencies = (\n\t\t\t);\n"
                f"\t\t\tproductName = {name};\n\t\t\tproductReference = {I[product_key]} /* {product} */;\n"
                f"\t\t\tproductType = \"{product_type}\";\n\t\t}};")

    def sync_group(name, exceptions=()):
        exc = ""
        if exceptions:
            exc = "exceptions = (" + "".join(f"{I[e]} /* exceptions */, " for e in exceptions) + "); "
        return (f"\t\t{I['group.' + name]} /* {name} */ = {{isa = PBXFileSystemSynchronizedRootGroup; "
                f"{exc}path = {name}; sourceTree = \"<group>\"; }};")

    def exception(key, target_key, name):
        # catalog.json is the generator's output; the app reads the copy
        # embedded in CatalogData.swift, so keep the file out of bundles.
        return (f"\t\t{I[key]} /* Exceptions for \"Core\" folder in \"{name}\" target */ = {{\n"
                f"\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
                f"\t\t\tmembershipExceptions = (\n\t\t\t\tGenerated/catalog.json,\n\t\t\t);\n"
                f"\t\t\ttarget = {I[target_key]} /* {name} */;\n\t\t}};")

    text = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXFileReference section */
		{I['app.product']} /* {app_product} */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {app_product}; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['test.product']} /* {test_product} */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {test_product}; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['plist']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
{exception('exc.app', 'app.target', APP)}
{exception('exc.test', 'test.target', TESTS)}
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
{sync_group('App')}
{sync_group('Core', ('exc.app', 'exc.test'))}
{sync_group('Tests')}
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
{phase('Frameworks', 'app.frameworks')}
{phase('Frameworks', 'test.frameworks')}
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['main']} = {{
			isa = PBXGroup;
			children = (
				{I['group.App']} /* App */,
				{I['group.Core']} /* Core */,
				{I['group.Tests']} /* Tests */,
				{I['config']} /* Config */,
				{I['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['config']} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{I['plist']} /* Info.plist */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{I['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['app.product']} /* {app_product} */,
				{I['test.product']} /* {test_product} */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{target('app.target', APP, 'app.product', app_product, 'com.apple.product-type.application', ('App', 'Core'), 'app')}
{target('test.target', TESTS, 'test.product', test_product, 'com.apple.product-type.bundle.unit-test', ('Core', 'Tests'), 'test')}
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {{
					{I['app.target']} = {{
						CreatedOnToolsVersion = 26.0;
					}};
					{I['test.target']} = {{
						CreatedOnToolsVersion = 26.0;
					}};
				}};
			}};
			buildConfigurationList = {I['cfg.project']} /* Build configuration list for PBXProject "{APP}" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {I['main']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['app.target']} /* {APP} */,
				{I['test.target']} /* {TESTS} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{phase('Resources', 'app.resources')}
{phase('Resources', 'test.resources')}
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{phase('Sources', 'app.sources')}
{phase('Sources', 'test.sources')}
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{config('cfg.project.Debug', 'Debug', DEBUG)}
{config('cfg.project.Release', 'Release', RELEASE)}
{config('cfg.app.Debug', 'Debug', APP_SETTINGS)}
{config('cfg.app.Release', 'Release', APP_SETTINGS)}
{config('cfg.test.Debug', 'Debug', TEST_SETTINGS)}
{config('cfg.test.Release', 'Release', TEST_SETTINGS)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{config_list('cfg.project', 'cfg.project', f'PBXProject "{APP}"')}
{config_list('cfg.app', 'cfg.app', f'PBXNativeTarget "{APP}"')}
{config_list('cfg.test', 'cfg.test', f'PBXNativeTarget "{TESTS}"')}
/* End XCConfigurationList section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(text)
    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
        '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')

    schemes = PROJECT / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    app_ref = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{I["app.target"]}" '
               f'BuildableName="{app_product}" BlueprintName="{APP}" ReferencedContainer="container:{APP}.xcodeproj"></BuildableReference>')
    test_ref = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{I["test.target"]}" '
                f'BuildableName="{test_product}" BlueprintName="{TESTS}" ReferencedContainer="container:{APP}.xcodeproj"></BuildableReference>')
    debugger = 'selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"'
    (schemes / f"{APP}.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" {debugger} shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" {debugger} launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")
    (schemes / f"{TESTS}.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {test_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" {debugger} shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {test_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" {debugger} launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES"></LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"></ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")
    print(f"Wrote {PROJECT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
