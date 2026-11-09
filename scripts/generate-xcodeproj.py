#!/usr/bin/env python3
"""Writes PlatenReader.xcodeproj.

The project is small and uses a file-system-synchronised group for
PlatenReader/Sources, so adding or removing Swift files needs no project edits.
This script exists so the project file can be regenerated from scratch if it
ever gets mangled; day to day, just open the project in Xcode.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "PlatenReader.xcodeproj")

# Fixed IDs keep the file stable across regenerations.
I = {k: f"A1B2C3D4E5F6{n:012X}" for n, k in enumerate("""
project mainGroup productsGroup appGroup sourcesSync webRef infoRef coreRef appProduct
target sourcesPhase frameworksPhase resourcesPhase webBuild coreBuild coreDep corePkg
projDebug projRelease projConfigList tgtDebug tgtRelease tgtConfigList
""".split(), start=1)}

common_target = """
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = PlatenReader/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = org.platenreader.PlatenReader;
				PRODUCT_MODULE_NAME = PlatenReader;
				PRODUCT_NAME = "Platen Reader";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;"""

common_project = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;"""

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{I['webBuild']} /* Web in Resources */ = {{isa = PBXBuildFile; fileRef = {I['webRef']} /* Web */; }};
		{I['coreBuild']} /* PlatenCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['coreDep']} /* PlatenCore */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{I['appProduct']} /* Platen Reader.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Platen Reader.app"; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['webRef']} /* Web */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = Web; sourceTree = "<group>"; }};
		{I['infoRef']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{I['coreRef']} /* PlatenCore */ = {{isa = PBXFileReference; lastKnownFileType = wrapper; path = PlatenCore; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['sourcesSync']} /* Sources */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{I['frameworksPhase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['coreBuild']} /* PlatenCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{I['coreRef']} /* PlatenCore */,
				{I['appGroup']} /* PlatenReader */,
				{I['productsGroup']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['productsGroup']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['appProduct']} /* Platen Reader.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{I['appGroup']} /* PlatenReader */ = {{
			isa = PBXGroup;
			children = (
				{I['sourcesSync']} /* Sources */,
				{I['webRef']} /* Web */,
				{I['infoRef']} /* Info.plist */,
			);
			path = PlatenReader;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['target']} /* PlatenReader */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['tgtConfigList']};
			buildPhases = (
				{I['sourcesPhase']} /* Sources */,
				{I['frameworksPhase']} /* Frameworks */,
				{I['resourcesPhase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['sourcesSync']} /* Sources */,
			);
			name = PlatenReader;
			packageProductDependencies = (
				{I['coreDep']} /* PlatenCore */,
			);
			productName = PlatenReader;
			productReference = {I['appProduct']} /* Platen Reader.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
			}};
			buildConfigurationList = {I['projConfigList']};
			developmentRegion = "en-GB";
			hasScannedForEncodings = 0;
			knownRegions = (
				"en-GB",
				en,
				Base,
			);
			mainGroup = {I['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{I['corePkg']} /* XCLocalSwiftPackageReference "PlatenCore" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['target']} /* PlatenReader */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{I['resourcesPhase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['webBuild']} /* Web in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{I['sourcesPhase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{I['projDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_project}
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{I['projRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_project}
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{I['tgtDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_target}
			}};
			name = Debug;
		}};
		{I['tgtRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_target}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{I['projConfigList']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['projDebug']} /* Debug */,
				{I['projRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['tgtConfigList']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['tgtDebug']} /* Debug */,
				{I['tgtRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{I['corePkg']} /* XCLocalSwiftPackageReference "PlatenCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = PlatenCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{I['coreDep']} /* PlatenCore */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = PlatenCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['target']}" BuildableName = "Platen Reader.app" BlueprintName = "PlatenReader" ReferencedContainer = "container:PlatenReader.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "PlatenCoreTests" BuildableName = "PlatenCoreTests" BlueprintName = "PlatenCoreTests" ReferencedContainer = "container:PlatenCore">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['target']}" BuildableName = "Platen Reader.app" BlueprintName = "PlatenReader" ReferencedContainer = "container:PlatenReader.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['target']}" BuildableName = "Platen Reader.app" BlueprintName = "PlatenReader" ReferencedContainer = "container:PlatenReader.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

os.makedirs(os.path.join(PROJ, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write(pbx)
with open(os.path.join(PROJ, "xcshareddata", "xcschemes", "PlatenReader.xcscheme"), "w") as f:
    f.write(scheme)
print("Wrote", PROJ)
