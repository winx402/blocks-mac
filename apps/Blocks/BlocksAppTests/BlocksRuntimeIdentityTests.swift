import XCTest
@testable import Blocks
import BlocksCore

final class BlocksRuntimeIdentityTests: XCTestCase {
    func testRuntimeIdentityUsesTheSelectedCompileTimeNamespace() {
#if BLOCKS_LOCAL_DEVELOPMENT
        XCTAssertTrue(BlocksRuntimeIdentity.isLocalDevelopment)
        XCTAssertEqual(BlocksRuntimeIdentity.applicationBundleIdentifier, "app.blocks.dev")
        XCTAssertEqual(BlocksRuntimeIdentity.identifierPrefix, "app.blocks.dev")
        XCTAssertEqual(BlocksRuntimeIdentity.mainExecutableName, "Blocks")
        XCTAssertEqual(BlocksRuntimeIdentity.applicationSupportDirectoryName, "Blocks Dev")
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerLaunchAgentLabel,
            "app.blocks.dev.action-broker"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerMachServiceName,
            "app.blocks.dev.action-broker.xpc"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerLaunchAgentPlistName,
            "app.blocks.dev.action-broker.plist"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.nativePluginRunnerServiceName,
            "app.blocks.dev.plugin-runner"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperBundleIdentifier,
            "app.blocks.dev.selection-helper"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperURLScheme,
            "blocks-dev-selection-helper"
        )
        XCTAssertEqual(BlocksRuntimeIdentity.selectionHelperLoopbackPort, 49_318)
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperLegacyKeychainService,
            "app.blocks.dev.selection-helper.shared-key"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperKeychainService,
            "app.blocks.dev.selection-helper.shared-active-key.v4"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperBootstrapKeychainService,
            "app.blocks.dev.selection-helper.shared-bootstrap-key"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperSharedKeychainAccessGroupSuffix,
            ".app.blocks.dev.selection-helper.shared"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.clipboardRecorderApplicationGroupIdentifier,
            "group.app.blocks.dev"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.providerKeychainService,
            "app.blocks.dev.provider.dev"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.translationServiceCredentialKeychainService,
            "app.blocks.dev.translation-service-credential"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.nativePluginSecretKeychainService,
            "app.blocks.dev.translation-plugin-secret"
        )
#else
        XCTAssertFalse(BlocksRuntimeIdentity.isLocalDevelopment)
        XCTAssertEqual(BlocksRuntimeIdentity.applicationBundleIdentifier, "app.blocks.app")
        XCTAssertEqual(BlocksRuntimeIdentity.identifierPrefix, "app.blocks")
        XCTAssertEqual(BlocksRuntimeIdentity.mainExecutableName, "Blocks")
        XCTAssertEqual(BlocksRuntimeIdentity.applicationSupportDirectoryName, "Blocks")
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerLaunchAgentLabel,
            "app.blocks.action-broker"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerMachServiceName,
            "app.blocks.action-broker.xpc"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.actionBrokerLaunchAgentPlistName,
            "app.blocks.action-broker.plist"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.nativePluginRunnerServiceName,
            "app.blocks.plugin-runner"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperBundleIdentifier,
            "app.blocks.selection-helper"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperURLScheme,
            "blocks-selection-helper"
        )
        XCTAssertEqual(BlocksRuntimeIdentity.selectionHelperLoopbackPort, 49_317)
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperLegacyKeychainService,
            "app.blocks.selection-helper.shared-key"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperKeychainService,
            "app.blocks.selection-helper.shared-active-key.v4"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperBootstrapKeychainService,
            "app.blocks.selection-helper.shared-bootstrap-key"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.selectionHelperSharedKeychainAccessGroupSuffix,
            ".app.blocks.selection-helper.shared"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.clipboardRecorderApplicationGroupIdentifier,
            "group.app.blocks.app"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.providerKeychainService, "app.blocks.provider.dev")
        XCTAssertEqual(
            BlocksRuntimeIdentity.translationServiceCredentialKeychainService,
            "app.blocks.translation-service-credential"
        )
        XCTAssertEqual(
            BlocksRuntimeIdentity.nativePluginSecretKeychainService,
            "app.blocks.translation-plugin-secret"
        )
#endif
    }

    func testRuntimeConsumersUseTheCentralNamespace() {
        XCTAssertEqual(
            BlocksActionBrokerXPC.appBundleIdentifier,
            BlocksRuntimeIdentity.applicationBundleIdentifier
        )
        XCTAssertEqual(
            BlocksActionBrokerXPC.launchAgentLabel,
            BlocksRuntimeIdentity.actionBrokerLaunchAgentLabel
        )
        XCTAssertEqual(
            BlocksActionBrokerXPC.machServiceName,
            BlocksRuntimeIdentity.actionBrokerMachServiceName
        )
        XCTAssertEqual(
            BlocksActionBrokerXPC.launchAgentPlistName,
            BlocksRuntimeIdentity.actionBrokerLaunchAgentPlistName
        )
        XCTAssertEqual(
            BlocksNativePluginXPC.hostAppBundleIdentifier,
            BlocksRuntimeIdentity.applicationBundleIdentifier
        )
        XCTAssertEqual(
            BlocksNativePluginXPC.serviceName,
            BlocksRuntimeIdentity.nativePluginRunnerServiceName
        )
        XCTAssertEqual(
            BlocksSelectionCaptureProtocol.appBundleIdentifier,
            BlocksRuntimeIdentity.applicationBundleIdentifier
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.bundleIdentifier,
            BlocksRuntimeIdentity.selectionHelperBundleIdentifier
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.urlScheme,
            BlocksRuntimeIdentity.selectionHelperURLScheme
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.loopbackPort,
            BlocksRuntimeIdentity.selectionHelperLoopbackPort
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.legacyKeychainService,
            BlocksRuntimeIdentity.selectionHelperLegacyKeychainService
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.keychainService,
            BlocksRuntimeIdentity.selectionHelperKeychainService
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.bootstrapKeychainService,
            BlocksRuntimeIdentity.selectionHelperBootstrapKeychainService
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.sharedKeychainAccessGroupSuffix,
            BlocksRuntimeIdentity.selectionHelperSharedKeychainAccessGroupSuffix
        )
        XCTAssertEqual(
            ClipboardRecorderStore.applicationGroupIdentifier,
            BlocksRuntimeIdentity.clipboardRecorderApplicationGroupIdentifier
        )
        XCTAssertEqual(
            ProviderKeychainService.defaultService,
            BlocksRuntimeIdentity.providerKeychainService
        )
    }
}
