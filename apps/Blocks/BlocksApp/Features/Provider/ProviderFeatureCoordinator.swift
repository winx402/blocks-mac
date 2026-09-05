import Foundation
import BlocksCore

enum ProviderRouteStatusFormatter {
    static func status(for resolution: ProviderRouteResolution) -> AppStatus {
        AppStatus(
            kind: resolution.ok ? .ready : .placeholder,
            title: L10n.string("status.providerRouteResolution.title"),
            detail: L10n.format(
                "status.providerRouteResolution.detail",
                resolution.errorCode?.rawValue ?? "ready",
                ProviderAuditID.display(resolution.auditID)
            )
        )
    }
}

@MainActor
final class ProviderFeatureCoordinator {
    private let providerStore: ProviderStore
    private var statusRecorder: (AppStatus) -> Void = { _ in }
    private var selectedProviderSummary: () -> String = { "" }
    private var selectedProviderRequiresExternalTransfer: () -> Bool = { false }
    private var publishRouteResolution: (ProviderRouteResolution) -> Void = { _ in }
    private var dispatchPluginEvent: @MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }

    init(providerStore: ProviderStore) {
        self.providerStore = providerStore
    }

    func configure(
        statusRecorder: @escaping (AppStatus) -> Void,
        selectedProviderSummary: @escaping () -> String,
        selectedProviderRequiresExternalTransfer: @escaping () -> Bool,
        publishRouteResolution: @escaping (ProviderRouteResolution) -> Void,
        dispatchPluginEvent: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }
    ) {
        self.statusRecorder = statusRecorder
        self.selectedProviderSummary = selectedProviderSummary
        self.selectedProviderRequiresExternalTransfer = selectedProviderRequiresExternalTransfer
        self.publishRouteResolution = publishRouteResolution
        self.dispatchPluginEvent = dispatchPluginEvent
    }

    @discardableResult
    func resolveProviderSettingsRoute(
        apiKeychainAccountAlias: String,
        externalTransferConfirmed: Bool
    ) -> ProviderRouteResolution {
        let resolution = providerStore.resolveProviderSettingsRoute(
            apiKeychainAccountAlias: apiKeychainAccountAlias,
            externalTransferConfirmed: externalTransferConfirmed
        )
        publishRouteResolution(resolution)
        statusRecorder(ProviderRouteStatusFormatter.status(for: resolution))
        Task { @MainActor [dispatchPluginEvent] in
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .providerRouteResolved,
                    payload: [
                        "ok": .bool(resolution.ok),
                        "audit_id": .string(resolution.auditID),
                        "error_code": resolution.errorCode.map {
                            .string($0.rawValue)
                        } ?? .null,
                    ]
                )
            )
        }
        return resolution
    }

    func previewProviderSettingsConfirmation() {
        _ = providerStore.previewProviderSettingsConfirmation(
            providerSummary: selectedProviderSummary(),
            requiresExternalTransfer: selectedProviderRequiresExternalTransfer()
        )
        recordStatus(
            .placeholder,
            title: "status.providerSettingsPreview.title",
            detail: L10n.string("status.providerSettingsPreview.detail")
        )
    }

    func previewProviderSecretLifecycle(step: String, state: String, auditID: String) {
        providerStore.previewProviderSecretLifecycle(
            step: step,
            state: state,
            auditID: auditID,
            providerSummary: selectedProviderSummary()
        )
        recordStatus(
            .placeholder,
            title: "status.providerSecretLifecycle.title",
            detail: L10n.format(
                "status.providerSecretLifecycle.detail",
                step,
                state,
                ProviderAuditID.display(auditID)
            )
        )
    }

    func performProviderKeychainGate(
        action: ProviderKeychainGateAction,
        accountAlias: String
    ) async -> ProviderKeychainGateUIOutcome {
        let outcome = await providerStore.performProviderKeychainGate(
            action: action,
            accountAlias: accountAlias,
            providerSummary: selectedProviderSummary()
        )
        if let result = providerStore.providerKeychainLastResult {
            recordStatus(
                result.ok ? .ready : .failed,
                title: "status.providerKeychainGate.title",
                detail: L10n.format(
                    "status.providerKeychainGate.detail",
                    result.step,
                    result.account,
                    ProviderAuditID.display(outcome.auditID)
                )
            )
        } else {
            recordStatus(
                .failed,
                title: "status.providerKeychainGate.title",
                detail: L10n.string("settings.providerSecretNoValue")
            )
        }
        return outcome
    }

    func performProviderUserSecretGate(
        action: ProviderUserSecretAction,
        accountAlias: String,
        secretCandidate: String? = nil,
        replacingAccountAlias: String? = nil,
        authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil
    ) async -> ProviderKeychainGateUIOutcome {
        let outcome = await providerStore.performProviderUserSecretGate(
            action: action,
            accountAlias: accountAlias,
            secretCandidate: secretCandidate,
            replacingAccountAlias: replacingAccountAlias,
            authorizationIntent: authorizationIntent
        )
        if let result = providerStore.providerUserSecretLastResult {
            recordStatus(
                result.ok ? .ready : .failed,
                title: "status.providerUserSecretGate.title",
                detail: L10n.format(
                    "status.providerUserSecretGate.detail",
                    result.step,
                    result.account,
                    ProviderAuditID.display(outcome.auditID)
                )
            )
        } else {
            recordStatus(
                .failed,
                title: "status.providerUserSecretGate.title",
                detail: L10n.string("settings.providerSecretNoValue")
            )
        }
        return outcome
    }

    func validateProviderConnectionGate(summary: String, ready: Bool) {
        _ = providerStore.validateProviderConnectionGate(summary: summary, ready: ready)
        recordStatus(
            ready ? .ready : .placeholder,
            title: "status.providerConnectionValidated.title",
            detail: ready
                ? L10n.string("status.providerConnectionValidated.readyDetail")
                : L10n.format("status.providerConnectionValidated.blockedDetail", summary)
        )
    }

    func previewProviderConnectionTest(summary: String, ready: Bool) {
        providerStore.previewProviderConnectionTest(
            summary: summary,
            ready: ready,
            providerSummary: selectedProviderSummary(),
            requiresExternalTransfer: selectedProviderRequiresExternalTransfer()
        )
        recordStatus(
            ready ? .ready : .placeholder,
            title: "status.providerConnectionPreview.title",
            detail: L10n.string(
                ready
                    ? "status.providerConnectionPreview.readyDetail"
                    : "status.providerConnectionPreview.blockedDetail"
            )
        )
    }

    func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String) {
        let auditID = providerStore.previewLLMAdapterBoundary(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
        recordStatus(
            .placeholder,
            title: "status.llmAdapterPreview.title",
            detail: L10n.format(
                "status.llmAdapterPreview.detail",
                ProviderAuditID.display(auditID)
            )
        )
    }

    func runLLMMockAdapter() {
        let auditID = providerStore.runLLMMockAdapter()
        recordStatus(
            .ready,
            title: "status.llmMockRun.title",
            detail: L10n.format(
                "status.llmMockRun.detail",
                ProviderAuditID.display(auditID)
            )
        )
    }

    func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String) {
        let auditID = providerStore.previewProviderSecretInput(
            secretCharacterCount: secretCharacterCount,
            keychainAccountAlias: keychainAccountAlias
        )
        recordStatus(
            .placeholder,
            title: "status.providerSecretInputPreview.title",
            detail: L10n.format(
                "status.providerSecretInputPreview.detail",
                ProviderAuditID.display(auditID)
            )
        )
    }

    @discardableResult
    func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String {
        let auditID = providerStore.previewOpenAIConnection(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
        recordStatus(
            .placeholder,
            title: "status.openAIConnectionPreview.title",
            detail: L10n.format(
                "status.openAIConnectionPreview.detail",
                ProviderAuditID.display(auditID)
            )
        )
        return auditID
    }

    func runOpenAIConnectionTest(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        configurationFingerprint: ProviderConnectionConfigurationFingerprint
    ) async {
        let causationID = UUID()
        let willResult = await dispatchPluginEvent(
            BlocksPluginEventEnvelope(
                name: .providerWillSendRequest,
                causationID: causationID,
                authorization: .init(userInitiated: true),
                payload: [
                    "provider": .string("openai-compatible"),
                    "model": .string(modelName),
                    "base_url_host": .string(
                        URL(string: baseURL)?.host ?? ""
                    ),
                    "operation": .string("connection_test"),
                ]
            )
        )
        guard willResult.allowed else {
            recordStatus(
                .failed,
                title: "status.openAIConnectionTest.title",
                detail: willResult.reason ?? "Blocked by plugin."
            )
            return
        }
        let resolvedModel = willResult.envelope.payload.string("model")
            ?? modelName
        let resolvedConfigurationFingerprint =
            ProviderConnectionConfigurationFingerprint(
                baseURL: baseURL,
                modelName: resolvedModel,
                keychainAccountAlias: keychainAccountAlias,
                credentialRevision: configurationFingerprint.credentialRevision
            )
        guard !Task.isCancelled else {
            return
        }
        let execution = await providerStore.runOpenAIConnectionTestExecution(
            baseURL: baseURL,
            modelName: resolvedModel,
            keychainAccountAlias: keychainAccountAlias,
            configurationFingerprint: resolvedConfigurationFingerprint
        )
        guard case let .published(result) = execution else { return }
        // Publish only if the exact post-hook configuration remains current.
        guard !Task.isCancelled,
              providerStore.isActiveOpenAIConnectionConfiguration(
                resolvedConfigurationFingerprint
              ) else {
            return
        }
        recordStatus(
            result.ok ? .ready : .failed,
            title: "status.openAIConnectionTest.title",
            detail: L10n.format(
                "status.openAIConnectionTest.detail",
                result.status.rawValue,
                ProviderAuditID.display(result.auditID)
            )
        )
        _ = await dispatchPluginEvent(
            BlocksPluginEventEnvelope(
                name: result.ok
                    ? .providerRequestCompleted
                    : .providerRequestFailed,
                causationID: causationID,
                payload: [
                    "provider": .string("openai-compatible"),
                    "model": .string(resolvedModel),
                    "operation": .string("connection_test"),
                    "status": .string(result.status.rawValue),
                    "audit_id": .string(result.auditID),
                ]
            )
        )
    }

    func clearProviderAuditEvents() {
        providerStore.clearProviderAuditEvents()
        recordStatus(
            .ready,
            title: "status.providerAuditCleared.title",
            detail: L10n.string("status.providerAuditCleared.detail")
        )
    }

    private func recordStatus(_ kind: AppStatusKind, title: String, detail: String) {
        statusRecorder(AppStatus(kind: kind, title: L10n.string(title), detail: detail))
    }
}

struct ProviderKeychainGateUIOutcome {
    let lifecycleRawValue: String
    let auditID: String
    let operationSucceeded: Bool

    init(
        lifecycleRawValue: String,
        auditID: String,
        operationSucceeded: Bool = true
    ) {
        self.lifecycleRawValue = lifecycleRawValue
        self.auditID = auditID
        self.operationSucceeded = operationSucceeded
    }
}
