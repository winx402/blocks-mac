import Foundation

enum ProviderAuditEventKind: String {
    case translationMockResult = "translation_mock_result"
    case providerSettingsPreview = "provider_settings_preview"
    case keychainLifecyclePreview = "keychain_lifecycle_preview"
    case providerConnectionPreview = "provider_connection_preview"
    case llmAdapterPreview = "llm_adapter_preview"
    case llmMockRun = "llm_mock_run"
    case secretInputPreview = "secret_input_preview"
    case openAIConnectionPreview = "openai_connection_preview"
    case userSecretKeychainGate = "user_secret_keychain_gate"
    case openAIConnectionTest = "openai_connection_test"
    case providerRouteResolution = "provider_route_resolution"
    case translationRuntime = "translation_runtime"

    var localizedTitle: String {
        switch self {
        case .translationMockResult:
            L10n.string("providerAudit.kind.translationMockResult")
        case .providerSettingsPreview:
            L10n.string("providerAudit.kind.providerSettingsPreview")
        case .keychainLifecyclePreview:
            L10n.string("providerAudit.kind.keychainLifecyclePreview")
        case .providerConnectionPreview:
            L10n.string("providerAudit.kind.providerConnectionPreview")
        case .llmAdapterPreview:
            L10n.string("providerAudit.kind.llmAdapterPreview")
        case .llmMockRun:
            L10n.string("providerAudit.kind.llmMockRun")
        case .secretInputPreview:
            L10n.string("providerAudit.kind.secretInputPreview")
        case .openAIConnectionPreview:
            L10n.string("providerAudit.kind.openAIConnectionPreview")
        case .userSecretKeychainGate:
            L10n.string("providerAudit.kind.userSecretKeychainGate")
        case .openAIConnectionTest:
            L10n.string("providerAudit.kind.openAIConnectionTest")
        case .providerRouteResolution:
            L10n.string("providerAudit.kind.providerRouteResolution")
        case .translationRuntime:
            L10n.string("providerAudit.kind.translationRuntime")
        }
    }

    var systemImage: String {
        switch self {
        case .translationMockResult, .llmMockRun:
            "sparkles"
        case .providerSettingsPreview:
            "eye"
        case .keychainLifecyclePreview:
            "key"
        case .providerConnectionPreview:
            "checkmark.shield"
        case .llmAdapterPreview:
            "arrow.triangle.branch"
        case .secretInputPreview:
            "lock.badge.clock"
        case .openAIConnectionPreview:
            "network.badge.shield.half.filled"
        case .userSecretKeychainGate:
            "key.horizontal"
        case .openAIConnectionTest:
            "network"
        case .providerRouteResolution:
            "point.3.connected.trianglepath.dotted"
        case .translationRuntime:
            "character.book.closed.fill"
        }
    }
}

enum ProviderAuditAction: String {
    case settingsPreview = "settings_preview"
    case keychainLifecycle = "keychain_lifecycle"
    case keychainGate = "keychain_gate"
    case userSecretGate = "user_secret_gate"
    case connectionPreview = "connection_preview"
    case adapterPreview = "adapter_preview"
    case mockRun = "mock_run"
    case secretInputPreview = "secret_input_preview"
    case openAIConnectionPreview = "openai_connection_preview"
    case connectionTest = "connection_test"
    case routeResolution = "route_resolution"
    case translationRuntime = "translation_runtime"
}

enum ProviderAuditOutcome: String {
    case previewed
    case ready
    case completed
    case blocked
    case failed
}

enum ProviderAuditConfirmationLevel: String {
    case noneMock = "none_mock"
    case preview
    case externalTransfer = "external_transfer"
}

struct ProviderAuditEvent: Identifiable {
    let id: String
    let createdAt: Date
    let kind: ProviderAuditEventKind
    let action: ProviderAuditAction
    let outcome: ProviderAuditOutcome
    let confirmationLevel: ProviderAuditConfirmationLevel
    let count: Int?
    let errorCode: ProviderErrorCode?
    let auditID: String
    let warningCount: Int

    init(
        id: String,
        createdAt: Date,
        kind: ProviderAuditEventKind,
        action: ProviderAuditAction,
        outcome: ProviderAuditOutcome,
        confirmationLevel: ProviderAuditConfirmationLevel,
        count: Int? = nil,
        errorCode: ProviderErrorCode? = nil,
        auditID: String,
        warningCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.action = action
        self.outcome = outcome
        self.confirmationLevel = confirmationLevel
        self.count = count
        self.errorCode = errorCode
        self.auditID = auditID
        self.warningCount = warningCount
    }

    /// Compatibility boundary for older callers. All free-form input is
    /// deliberately discarded before the audit event enters memory.
    init(
        id: String,
        createdAt: Date,
        kind: ProviderAuditEventKind,
        providerSummary _: String,
        confirmationLevel _: String,
        sourceSummary _: String,
        resultSummary _: String,
        auditID: String,
        warnings: [String]
    ) {
        self.init(
            id: id,
            createdAt: createdAt,
            kind: kind,
            action: kind.auditAction,
            outcome: .previewed,
            confirmationLevel: .preview,
            auditID: auditID,
            warningCount: warnings.count
        )
    }

    var providerSummary: String { kind.localizedTitle }

    var sourceSummary: String { action.rawValue }

    var resultSummary: String {
        if let errorCode {
            return errorCode.localizedDetail
        }
        switch outcome {
        case .previewed:
            return L10n.string("providerAudit.result.settingsPreview")
        case .ready, .completed:
            return L10n.string("providerAudit.result.connectionReady")
        case .blocked:
            return L10n.string("providerAudit.result.connectionBlocked")
        case .failed:
            return ProviderErrorCode.invalidResponse.localizedDetail
        }
    }

    var warnings: [String] {
        guard warningCount > 0 else { return [] }
        let warning = errorCode?.localizedTitle
            ?? L10n.string("providerAudit.warning.noProviderCall")
        return Array(repeating: warning, count: warningCount)
    }
}

struct ProviderAuditPresentation: Equatable {
    let title: String
    let detail: String
    let technicalDetail: String
    let warnings: [String]

    init(event: ProviderAuditEvent) {
        title = event.kind.localizedTitle
        detail = event.resultSummary
        technicalDetail = event.errorCode?.rawValue
            ?? event.confirmationLevel.rawValue
        warnings = event.warningCount > 0
            ? [
                event.errorCode?.localizedTitle
                    ?? L10n.string("providerAudit.warning.noProviderCall"),
            ]
            : []
    }
}

private extension ProviderAuditEventKind {
    var auditAction: ProviderAuditAction {
        switch self {
        case .translationMockResult:
            .mockRun
        case .providerSettingsPreview:
            .settingsPreview
        case .keychainLifecyclePreview:
            .keychainLifecycle
        case .providerConnectionPreview:
            .connectionPreview
        case .llmAdapterPreview:
            .adapterPreview
        case .llmMockRun:
            .mockRun
        case .secretInputPreview:
            .secretInputPreview
        case .openAIConnectionPreview:
            .openAIConnectionPreview
        case .userSecretKeychainGate:
            .userSecretGate
        case .openAIConnectionTest:
            .connectionTest
        case .providerRouteResolution:
            .routeResolution
        case .translationRuntime:
            .translationRuntime
        }
    }
}
