import BlocksCore

extension AppModel {
    @discardableResult
    func previewClipboardCleanupPolicy(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) -> Bool {
        clipboardCoordinator.previewCleanupPolicy(cleanupMode: cleanupMode, retentionPolicy: retentionPolicy, maxItems: maxItems, preserveFavorite: preserveFavorite, completion: completion)
    }

    func cancelClipboardCleanupPolicyPreview() { clipboardCoordinator.cancelCleanupPolicyPreview() }

    func confirmClipboardCleanupPolicy(
        token: ClipboardPolicyConfirmationToken,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) {
        clipboardCoordinator.confirmCleanupPolicy(token: token, completion: completion)
    }

    @discardableResult
    func resolveProviderSettingsRoute(
        apiKeychainAccountAlias: String,
        externalTransferConfirmed: Bool
    ) -> ProviderRouteResolution {
        providerCoordinator.resolveProviderSettingsRoute(
            apiKeychainAccountAlias: apiKeychainAccountAlias,
            externalTransferConfirmed: externalTransferConfirmed
        )
    }

    func previewProviderSettingsConfirmation() { providerCoordinator.previewProviderSettingsConfirmation() }

    func previewProviderSecretLifecycle(step: String, state: String, auditID: String) {
        providerCoordinator.previewProviderSecretLifecycle(step: step, state: state, auditID: auditID)
    }

    func performProviderKeychainGate(
        action: ProviderKeychainGateAction,
        accountAlias: String
    ) async -> ProviderKeychainGateUIOutcome {
        await providerCoordinator.performProviderKeychainGate(action: action, accountAlias: accountAlias)
    }

    func performProviderUserSecretGate(
        action: ProviderUserSecretAction,
        accountAlias: String,
        secretCandidate: String? = nil,
        replacingAccountAlias: String? = nil,
        authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil
    ) async -> ProviderKeychainGateUIOutcome {
        await providerCoordinator.performProviderUserSecretGate(
            action: action,
            accountAlias: accountAlias,
            secretCandidate: secretCandidate,
            replacingAccountAlias: replacingAccountAlias,
            authorizationIntent: authorizationIntent
        )
    }

    func validateProviderConnectionGate(summary: String, ready: Bool) {
        providerCoordinator.validateProviderConnectionGate(summary: summary, ready: ready)
    }

    func previewProviderConnectionTest(summary: String, ready: Bool) {
        providerCoordinator.previewProviderConnectionTest(summary: summary, ready: ready)
    }

    func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String) {
        providerCoordinator.previewLLMAdapterBoundary(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
    }

    func runLLMMockAdapter() { providerCoordinator.runLLMMockAdapter() }

    func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String) {
        providerCoordinator.previewProviderSecretInput(
            secretCharacterCount: secretCharacterCount,
            keychainAccountAlias: keychainAccountAlias
        )
    }

    @discardableResult
    func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String {
        providerCoordinator.previewOpenAIConnection(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
    }

    func runOpenAIConnectionTest(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        configurationFingerprint: ProviderConnectionConfigurationFingerprint
    ) async {
        await providerCoordinator.runOpenAIConnectionTest(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            configurationFingerprint: configurationFingerprint
        )
    }

    func clearProviderAuditEvents() { providerCoordinator.clearProviderAuditEvents() }
    func startSmartScreenshot() async {
        translationCoordinator.closeUnpinnedPanels()
        await screenshotCoordinator.startSmartScreenshot()
    }

    func registerDefaultShortcuts(force: Bool = false) {
        guard !BlocksRuntimeEnvironment.isUnitTestHost else { return }
        shortcutCoordinator.registerDefaultShortcuts(force: force)
    }

    func refreshShortcutRegistrations() {
        guard !BlocksRuntimeEnvironment.isUnitTestHost else { return }
        shortcutCoordinator.refreshShortcutRegistrations()
    }

    func refreshPermissionState() {
        permissionCoordinator.refreshPermissionState()
        clipboardCoordinator.pastePermissionStateDidRefresh()
    }

    func openScreenRecordingSettings() { permissionCoordinator.openScreenRecordingSettings() }
    func revealCurrentAppInFinder() { permissionCoordinator.revealCurrentAppInFinder() }
    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    ) {
        permissionCoordinator.restartForPermissionRefresh(completion: completion)
    }
    func requestScreenRecordingPermissionAssist() { permissionCoordinator.requestScreenRecordingPermissionAssist() }
    func requestAccessibilityPermissionAssist() { permissionCoordinator.requestAccessibilityPermissionAssist() }
}
