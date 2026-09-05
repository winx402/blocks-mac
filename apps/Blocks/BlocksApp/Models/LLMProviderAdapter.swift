import Foundation

enum LLMProviderTask: String {
    case translationPreview = "translation_preview"
    case summaryPreview = "summary_preview"

    var localizedTitle: String {
        switch self {
        case .translationPreview:
            L10n.string("llmAdapter.task.translationPreview")
        case .summaryPreview:
            L10n.string("llmAdapter.task.summaryPreview")
        }
    }
}

enum LLMProviderOutputFormat: String {
    case structuredJSON = "structured_json"
    case plainText = "plain_text"
}

enum LLMProviderError: Error, Equatable {
    case notConfigured
    case requiresConfirmation
    case notImplemented
    case timeout
    case invalidResponse
}

struct OpenAICompatibleProfileBoundary: Equatable {
    let providerID: String
    let providerName: String
    let baseURLSummary: String
    let modelName: String
    let keychainAccountAlias: String
    let timeoutSeconds: Int

    static func make(
        provider: LLMProviderProfile,
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        timeoutSeconds: Int = 60
    ) -> OpenAICompatibleProfileBoundary {
        OpenAICompatibleProfileBoundary(
            providerID: provider.id,
            providerName: provider.localizedName,
            baseURLSummary: summarizeBaseURL(baseURL),
            modelName: sanitized(modelName, fallback: "model-placeholder"),
            keychainAccountAlias: sanitized(keychainAccountAlias, fallback: "account-alias-placeholder"),
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func summarizeBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else {
            return "base-url-placeholder"
        }
        if let scheme = url.scheme {
            return "\(scheme)://\(host)"
        }
        return host
    }

    private static func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct ProviderSecretInputPreview: Identifiable, Equatable {
    let id: String
    let providerName: String
    let keychainAccountAlias: String
    let characterCount: Int
    let confirmationLevel: String
    let auditID: String

    static func makeSecretInputPreview(
        provider: LLMProviderProfile,
        keychainAccountAlias: String,
        secretCharacterCount: Int
    ) -> ProviderSecretInputPreview {
        let id = UUID().uuidString
        return ProviderSecretInputPreview(
            id: id,
            providerName: provider.localizedName,
            keychainAccountAlias: sanitized(keychainAccountAlias, fallback: "account-alias-placeholder"),
            characterCount: max(0, secretCharacterCount),
            confirmationLevel: "preview",
            auditID: ProviderAuditID.make(
                prefix: "llm_secret",
                uuidString: id
            )
        )
    }

    private static func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct OpenAIConnectionPreviewDraft: Identifiable, Equatable {
    let id: String
    let providerName: String
    let baseURLSummary: String
    let modelName: String
    let keychainAccountAlias: String
    let endpointSummary: String
    let timeoutSeconds: Int
    let confirmationLevel: String
    let auditID: String

    static func makeConnectionPreview(boundary: OpenAICompatibleProfileBoundary) -> OpenAIConnectionPreviewDraft {
        let id = UUID().uuidString
        return OpenAIConnectionPreviewDraft(
            id: id,
            providerName: boundary.providerName,
            baseURLSummary: boundary.baseURLSummary,
            modelName: boundary.modelName,
            keychainAccountAlias: boundary.keychainAccountAlias,
            endpointSummary: "POST /v1/chat/completions",
            timeoutSeconds: boundary.timeoutSeconds,
            confirmationLevel: "external_transfer",
            auditID: ProviderAuditID.make(
                prefix: "llm_conn",
                uuidString: id
            )
        )
    }
}

struct LLMProviderRequest: Identifiable, Equatable {
    let id: String
    let task: LLMProviderTask
    let providerProfileID: String
    let providerName: String
    let sourceSummary: String
    let characterCount: Int
    let outputFormat: LLMProviderOutputFormat
    let confirmationLevel: String
    let baseURLSummary: String
    let modelName: String
    let keychainAccountAlias: String
}

struct LLMProviderResponse: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let providerSummary: String
    let sourceSummary: String
    let outputSummary: String
    let confirmationLevel: String
    let auditID: String
    let warnings: [String]
}

protocol LLMProviderAdapter {
    func makePreview(request: LLMProviderRequest) -> LLMProviderResponse
    func runMock(request: LLMProviderRequest) -> LLMProviderResponse
}

struct LLMProviderMockAdapter: LLMProviderAdapter {
    func makePreview(request: LLMProviderRequest) -> LLMProviderResponse {
        response(
            request: request,
            outputSummary: L10n.format(
                "providerAudit.result.llmAdapterPreview",
                request.providerName,
                request.modelName,
                request.sourceSummary,
                request.characterCount
            ),
            confirmationLevel: request.confirmationLevel,
            warnings: [L10n.string("providerAudit.warning.noProviderCall")]
        )
    }

    func runMock(request: LLMProviderRequest) -> LLMProviderResponse {
        response(
            request: request,
            outputSummary: L10n.string("providerAudit.result.llmMockRun"),
            confirmationLevel: "none_mock",
            warnings: [L10n.string("llmAdapter.warning.mockOnly")]
        )
    }

    private func response(
        request: LLMProviderRequest,
        outputSummary: String,
        confirmationLevel: String,
        warnings: [String]
    ) -> LLMProviderResponse {
        let id = UUID().uuidString
        return LLMProviderResponse(
            id: id,
            createdAt: Date(),
            providerSummary: "\(request.providerName) / \(request.outputFormat.rawValue)",
            sourceSummary: request.sourceSummary,
            outputSummary: outputSummary,
            confirmationLevel: confirmationLevel,
            auditID: ProviderAuditID.make(
                prefix: "llm_mock",
                uuidString: id
            ),
            warnings: warnings
        )
    }
}
