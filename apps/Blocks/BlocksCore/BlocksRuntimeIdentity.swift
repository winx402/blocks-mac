import Foundation

/// Compile-time runtime identities for the production and local-development
/// applications. Keep values that select an OS namespace here so the two
/// installations cannot accidentally share persistent state or IPC endpoints.
public enum BlocksRuntimeIdentity {
#if BLOCKS_LOCAL_DEVELOPMENT
    public static let isLocalDevelopment = true
    public static let applicationBundleIdentifier = "app.blocks.dev"
    public static let identifierPrefix = "app.blocks.dev"
    public static let mainExecutableName = "Blocks Dev"
    public static let applicationSupportDirectoryName = "Blocks Dev"
    public static let actionBrokerLaunchAgentLabel =
        "app.blocks.dev.action-broker"
    public static let actionBrokerMachServiceName =
        "app.blocks.dev.action-broker.xpc"
    public static let actionBrokerLaunchAgentPlistName =
        "app.blocks.dev.action-broker.plist"
    public static let nativePluginRunnerServiceName =
        "app.blocks.dev.plugin-runner"
    public static let selectionHelperBundleIdentifier =
        "app.blocks.dev.selection-helper"
    public static let selectionHelperURLScheme = "blocks-dev-selection-helper"
    public static let selectionHelperLoopbackPort: UInt16 = 49_318
    public static let selectionHelperLegacyKeychainService =
        "app.blocks.dev.selection-helper.shared-key"
    public static let selectionHelperKeychainService =
        "app.blocks.dev.selection-helper.shared-active-key.v4"
    public static let selectionHelperBootstrapKeychainService =
        "app.blocks.dev.selection-helper.shared-bootstrap-key"
    public static let selectionHelperSharedKeychainAccessGroupSuffix =
        ".app.blocks.dev.selection-helper.shared"
    public static let clipboardRecorderApplicationGroupIdentifier =
        "group.app.blocks.dev"
    public static let providerKeychainService = "app.blocks.dev.provider.dev"
    public static let translationServiceCredentialKeychainService =
        "app.blocks.dev.translation-service-credential"
    public static let nativePluginSecretKeychainService =
        "app.blocks.dev.translation-plugin-secret"
#else
    public static let isLocalDevelopment = false
    public static let applicationBundleIdentifier = "app.blocks.app"
    public static let identifierPrefix = "app.blocks"
    public static let mainExecutableName = "Blocks"
    public static let applicationSupportDirectoryName = "Blocks"
    public static let actionBrokerLaunchAgentLabel = "app.blocks.action-broker"
    public static let actionBrokerMachServiceName = "app.blocks.action-broker.xpc"
    public static let actionBrokerLaunchAgentPlistName =
        "app.blocks.action-broker.plist"
    public static let nativePluginRunnerServiceName = "app.blocks.plugin-runner"
    public static let selectionHelperBundleIdentifier =
        "app.blocks.selection-helper"
    public static let selectionHelperURLScheme = "blocks-selection-helper"
    public static let selectionHelperLoopbackPort: UInt16 = 49_317
    public static let selectionHelperLegacyKeychainService =
        "app.blocks.selection-helper.shared-key"
    public static let selectionHelperKeychainService =
        "app.blocks.selection-helper.shared-active-key.v4"
    public static let selectionHelperBootstrapKeychainService =
        "app.blocks.selection-helper.shared-bootstrap-key"
    public static let selectionHelperSharedKeychainAccessGroupSuffix =
        ".app.blocks.selection-helper.shared"
    public static let clipboardRecorderApplicationGroupIdentifier =
        "group.app.blocks.app"
    public static let providerKeychainService = "app.blocks.provider.dev"
    public static let translationServiceCredentialKeychainService =
        "app.blocks.translation-service-credential"
    public static let nativePluginSecretKeychainService =
        "app.blocks.translation-plugin-secret"
#endif
}
