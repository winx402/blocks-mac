import BlocksCore
import Foundation

struct OpenAITranslationRuntimeProfile: Equatable {
    let providerName: String
    let baseURL: String
    let modelName: String
    let keychainAccountAlias: String
    let timeoutSeconds: Int
}

struct OpenAITranslationRuntimeResult: Codable, Equatable, Identifiable,
    @unchecked Sendable
{
    let id: String
    let ok: Bool
    let status: OpenAIConnectionStatus
    let providerName: String
    let baseURLSummary: String
    let modelName: String
    let keychainAccountAlias: String
    let sourceLanguageMode: String
    let targetLanguage: String
    let textCharacterCount: Int
    let outputText: String?
    let httpStatusCode: Int?
    let durationMS: Int
    let requestID: String?
    let secretLength: Int?
    let auditID: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case ok
        case status
        case providerName = "provider_name"
        case baseURLSummary = "base_url_summary"
        case modelName = "model_name"
        case keychainAccountAlias = "keychain_account_alias"
        case sourceLanguageMode = "source_language_mode"
        case targetLanguage = "target_language"
        case textCharacterCount = "text_character_count"
        case outputText = "output_text"
        case httpStatusCode = "http_status_code"
        case durationMS = "duration_ms"
        case requestID = "request_id"
        case secretLength = "secret_length"
        case auditID = "audit_id"
        case warnings
    }
}

/// A one-shot audit publication staged alongside an external result. The
/// adapter commits it only from the same final authorization boundary that
/// publishes the corresponding diagnostics or translated text.
struct OpenAITranslationDeferredAudit: Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        init(action: @escaping @Sendable () -> Void) {
            self.action = action
        }

        func publishOnce() {
            lock.lock()
            let action = action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private let state: State

    init(action: @escaping @Sendable () -> Void) {
        state = State(action: action)
    }

    func publishOnce() {
        state.publishOnce()
    }
}

extension OpenAITranslationRuntimeResult {
    var routeSummary: String {
        "\(baseURLSummary) · POST /v1/chat/completions"
    }

    var translationDiagnostics: TranslationResultDiagnostics {
        TranslationResultDiagnostics(
            auditID: auditID,
            durationMS: durationMS,
            route: routeSummary,
            status: status.rawValue
        )
    }

    var localizedErrorTitle: String {
        if ok {
            return L10n.string("translation.runtimeResult.title")
        }
        return status.providerErrorCode?.localizedTitle ?? L10n.string("translation.runtimeResult.errorTitle")
    }

    var localizedErrorDetail: String {
        if ok {
            return L10n.string("translation.errorUX.shortDetail")
        }
        return status.providerErrorCode?.localizedDetail ?? L10n.string("translation.errorUX.shortDetail")
    }
}

struct OpenAITranslationRuntimeService {
    static let maximumInputCharacterCount = 100_000
    static let maximumInputUTF8ByteCount = 400_000

    private let transport: OpenAIConnectionTransport
    private let auditHandler:
        (@Sendable (OpenAITranslationRuntimeResult) -> Void)?
    private let auditTokenSource: ProviderAuditTokenSource?
    private let auditHandlerWithToken:
        (@Sendable (
            OpenAITranslationRuntimeResult,
            ProviderAuditToken,
            ProviderExternalTransferTarget?,
            ProviderExternalTransferGrant?
        ) -> Void)?

    init(
        transport: OpenAIConnectionTransport =
            URLSessionOpenAIConnectionTransport(),
        auditHandler:
            (@Sendable (OpenAITranslationRuntimeResult) -> Void)? = nil
    ) {
        self.transport = transport
        self.auditHandler = auditHandler
        auditTokenSource = nil
        auditHandlerWithToken = nil
    }

    init(
        transport: OpenAIConnectionTransport =
            URLSessionOpenAIConnectionTransport(),
        auditTokenSource: @escaping ProviderAuditTokenSource,
        auditHandlerWithToken: @escaping @Sendable (
            OpenAITranslationRuntimeResult,
            ProviderAuditToken,
            ProviderExternalTransferTarget?,
            ProviderExternalTransferGrant?
        ) -> Void
    ) {
        self.transport = transport
        auditHandler = nil
        self.auditTokenSource = auditTokenSource
        self.auditHandlerWithToken = auditHandlerWithToken
    }

    func translate(
        text: String,
        sourceLanguageMode: String,
        targetLanguage: String,
        profile: OpenAITranslationRuntimeProfile,
        secretMaterial: ProviderUserSecretMaterial,
        authorizationCheck: @Sendable () -> Bool = { true },
        admission: (@Sendable (() -> Bool) -> Bool)? = nil,
        auditTarget: ProviderExternalTransferTarget? = nil,
        auditGrant: ProviderExternalTransferGrant? = nil,
        deferredAuditHandler:
            (@Sendable (OpenAITranslationDeferredAudit) -> Void)? = nil
    ) async -> OpenAITranslationRuntimeResult {
        let auditToken = auditTokenSource?()
        let auditHandler = auditHandler
        let auditHandlerWithToken = auditHandlerWithToken
        let startedAt = Date()
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func publishRuntime(
            _ runtimeResult: OpenAITranslationRuntimeResult
        ) -> OpenAITranslationRuntimeResult {
            let deferredAudit = OpenAITranslationDeferredAudit {
                if let auditToken, let auditHandlerWithToken {
                    auditHandlerWithToken(
                        runtimeResult,
                        auditToken,
                        auditTarget,
                        auditGrant
                    )
                } else {
                    auditHandler?(runtimeResult)
                }
            }
            if let deferredAuditHandler {
                deferredAuditHandler(deferredAudit)
            } else {
                deferredAudit.publishOnce()
            }
            return runtimeResult
        }
        guard let endpointURL = endpointURL(from: profile.baseURL) else {
            return publishRuntime(result(
                profile: profile,
                ok: false,
                status: .invalidBaseURL,
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: targetLanguage,
                textCharacterCount: normalizedText.count,
                outputText: nil,
                httpStatusCode: nil,
                durationMS: elapsedMS(since: startedAt),
                requestID: nil,
                secretLength: secretMaterial.secretLength,
                warnings: ["invalid_base_url"]
            ))
        }

        guard authorizationCheck() else {
            return publishRuntime(
                Self.externalTransferDisabledResult(
                    profile: profile,
                    textCharacterCount: normalizedText.count,
                    targetLanguage: targetLanguage
                )
            )
        }

        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            secretMaterial.withSecret { secret in
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try requestBody(
                text: normalizedText,
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: targetLanguage,
                modelName: profile.modelName
            )

            let operation = transport.makeOperation(
                request,
                timeoutSeconds: profile.timeoutSeconds
            )
            let response: OpenAIConnectionTransportResponse? = try await withTaskCancellationHandler {
                let started = if let admission {
                    admission { operation.start() }
                } else {
                    authorizationCheck() && operation.start()
                }
                guard started else { return nil }
                return try await operation.response()
            } onCancel: {
                operation.cancel()
            }
            guard let response else {
                return publishRuntime(
                    Self.externalTransferDisabledResult(
                        profile: profile,
                        textCharacterCount: normalizedText.count,
                        targetLanguage: targetLanguage
                    )
                )
            }

            let statusCode = response.httpResponse.statusCode
            let requestID = headerValue("x-request-id", in: response.httpResponse)

            guard authorizationCheck() else {
                return publishRuntime(result(
                    profile: profile,
                    ok: false,
                    status: .confirmationRequired,
                    sourceLanguageMode: sourceLanguageMode,
                    targetLanguage: targetLanguage,
                    textCharacterCount: normalizedText.count,
                    outputText: nil,
                    httpStatusCode: statusCode,
                    durationMS: elapsedMS(since: startedAt),
                    requestID: requestID,
                    secretLength: nil,
                    warnings: [
                        "external_transfer_disabled",
                        "authorization_revoked_after_transport",
                        "provider_response_redacted",
                    ]
                ))
            }

            if (200..<300).contains(statusCode) {
                guard let output = parsedOutputText(from: response.data), !output.isEmpty else {
                    return publishRuntime(result(
                        profile: profile,
                        ok: false,
                        status: .invalidResponse,
                        sourceLanguageMode: sourceLanguageMode,
                        targetLanguage: targetLanguage,
                        textCharacterCount: normalizedText.count,
                        outputText: nil,
                        httpStatusCode: statusCode,
                        durationMS: elapsedMS(since: startedAt),
                        requestID: requestID,
                        secretLength: secretMaterial.secretLength,
                        warnings: ["provider_response_redacted", "invalid_response_shape"]
                    ))
                }

                return publishRuntime(result(
                    profile: profile,
                    ok: true,
                    status: .success,
                    sourceLanguageMode: sourceLanguageMode,
                    targetLanguage: targetLanguage,
                    textCharacterCount: normalizedText.count,
                    outputText: output,
                    httpStatusCode: statusCode,
                    durationMS: elapsedMS(since: startedAt),
                    requestID: requestID,
                    secretLength: secretMaterial.secretLength,
                    warnings: ["provider_response_redacted"]
                ))
            }

            return publishRuntime(result(
                profile: profile,
                ok: false,
                status: normalizedStatus(httpStatusCode: statusCode),
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: targetLanguage,
                textCharacterCount: normalizedText.count,
                outputText: nil,
                httpStatusCode: statusCode,
                durationMS: elapsedMS(since: startedAt),
                requestID: requestID,
                secretLength: secretMaterial.secretLength,
                warnings: responseWarnings(httpStatusCode: statusCode)
            ))
        } catch {
            return publishRuntime(result(
                profile: profile,
                ok: false,
                status: normalizedStatus(error: error),
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: targetLanguage,
                textCharacterCount: normalizedText.count,
                outputText: nil,
                httpStatusCode: nil,
                durationMS: elapsedMS(since: startedAt),
                requestID: nil,
                secretLength: secretMaterial.secretLength,
                warnings: ["provider_response_redacted", "transport_error_redacted"]
            ))
        }
    }

    func inputLimitExceededResult(
        profile: OpenAITranslationRuntimeProfile,
        textCharacterCount: Int,
        sourceLanguageMode: String,
        targetLanguage: String,
        auditTarget: ProviderExternalTransferTarget? = nil,
        auditGrant: ProviderExternalTransferGrant? = nil,
        deferredAuditHandler:
            (@Sendable (OpenAITranslationDeferredAudit) -> Void)? = nil,
        captureAudit: Bool = true
    ) -> OpenAITranslationRuntimeResult {
        let result = Self.makeStaticResult(
            profile: profile,
            status: .invalidResponse,
            textCharacterCount: textCharacterCount,
            sourceLanguageMode: sourceLanguageMode,
            targetLanguage: targetLanguage,
            warning: "translation_input_too_large"
        )
        guard captureAudit else { return result }
        let auditToken = auditTokenSource?()
        let deferredAudit = OpenAITranslationDeferredAudit {
            if let auditToken, let auditHandlerWithToken {
                auditHandlerWithToken(
                    result,
                    auditToken,
                    auditTarget,
                    auditGrant
                )
            } else {
                auditHandler?(result)
            }
        }
        if let deferredAuditHandler {
            deferredAuditHandler(deferredAudit)
        } else {
            deferredAudit.publishOnce()
        }
        return result
    }

    func preflightBlockedResult(
        profile: OpenAITranslationRuntimeProfile,
        errorCode: ProviderErrorCode,
        textCharacterCount: Int,
        sourceLanguageMode: String,
        targetLanguage: String,
        auditTarget: ProviderExternalTransferTarget? = nil,
        auditGrant: ProviderExternalTransferGrant? = nil,
        deferredAuditHandler:
            (@Sendable (OpenAITranslationDeferredAudit) -> Void)? = nil,
        captureAudit: Bool = true
    ) -> OpenAITranslationRuntimeResult {
        let result = Self.makeStaticResult(
            profile: profile,
            status: Self.connectionStatus(for: errorCode),
            textCharacterCount: textCharacterCount,
            sourceLanguageMode: sourceLanguageMode,
            targetLanguage: targetLanguage,
            warning: errorCode.rawValue
        )
        guard captureAudit else { return result }
        let auditToken = auditTokenSource?()
        let deferredAudit = OpenAITranslationDeferredAudit {
            if let auditToken, let auditHandlerWithToken {
                auditHandlerWithToken(
                    result,
                    auditToken,
                    auditTarget,
                    auditGrant
                )
            } else {
                auditHandler?(result)
            }
        }
        if let deferredAuditHandler {
            deferredAuditHandler(deferredAudit)
        } else {
            deferredAudit.publishOnce()
        }
        return result
    }

    static func inputExceedsLimit(_ text: String) -> Bool {
        guard text.count <= maximumInputCharacterCount else {
            return true
        }
        return text.utf8.count > maximumInputUTF8ByteCount
    }

    static func externalTransferDisabledResult(
        profile: OpenAITranslationRuntimeProfile,
        textCharacterCount: Int,
        targetLanguage: String
    ) -> OpenAITranslationRuntimeResult {
        makeStaticResult(
            profile: profile,
            status: .confirmationRequired,
            textCharacterCount: textCharacterCount,
            targetLanguage: targetLanguage,
            warning: "external_transfer_disabled"
        )
    }

    static func blockedResult(
        profile: OpenAITranslationRuntimeProfile,
        status: OpenAIConnectionStatus,
        textCharacterCount: Int,
        targetLanguage: String,
        warning: String
    ) -> OpenAITranslationRuntimeResult {
        makeStaticResult(
            profile: profile,
            status: status,
            textCharacterCount: textCharacterCount,
            targetLanguage: targetLanguage,
            warning: warning
        )
    }

    static func missingSecretResult(
        profile: OpenAITranslationRuntimeProfile,
        textCharacterCount: Int,
        targetLanguage: String,
        message: String
    ) -> OpenAITranslationRuntimeResult {
        makeStaticResult(
            profile: profile,
            status: .missingSecret,
            textCharacterCount: textCharacterCount,
            targetLanguage: targetLanguage,
            warning: message
        )
    }

    private static func makeStaticResult(
        profile: OpenAITranslationRuntimeProfile,
        status: OpenAIConnectionStatus,
        textCharacterCount: Int,
        sourceLanguageMode: String = "auto",
        targetLanguage: String,
        warning: String
    ) -> OpenAITranslationRuntimeResult {
        let id = UUID().uuidString
        return OpenAITranslationRuntimeResult(
            id: id,
            ok: false,
            status: status,
            providerName: sanitized(profile.providerName, fallback: "OpenAI-compatible"),
            baseURLSummary: summarizeBaseURL(profile.baseURL),
            modelName: sanitized(profile.modelName, fallback: "model-placeholder"),
            keychainAccountAlias: sanitized(profile.keychainAccountAlias, fallback: "account-alias-placeholder"),
            sourceLanguageMode: sourceLanguageMode,
            targetLanguage: targetLanguage,
            textCharacterCount: textCharacterCount,
            outputText: nil,
            httpStatusCode: nil,
            durationMS: 0,
            requestID: nil,
            secretLength: nil,
            auditID: ProviderAuditID.make(
                prefix: "tr_runtime",
                uuidString: id
            ),
            warnings: [warning, "provider_call_not_executed"]
        )
    }

    private func endpointURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderRuntimeGate.isAllowedProviderBaseURL(trimmed) else {
            return nil
        }
        guard let base = URL(string: trimmed), let scheme = base.scheme, base.host != nil else {
            return nil
        }
        guard scheme == "https" || scheme == "http" else {
            return nil
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let currentPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if currentPath == "v1/chat/completions" {
            components?.path = "/v1/chat/completions"
        } else if currentPath.hasSuffix("v1") {
            components?.path = "/" + currentPath + "/chat/completions"
        } else if currentPath.isEmpty {
            components?.path = "/v1/chat/completions"
        } else {
            components?.path = "/" + currentPath + "/v1/chat/completions"
        }
        return components?.url
    }

    private func requestBody(text: String, sourceLanguageMode: String, targetLanguage: String, modelName: String) throws -> Data {
        let body: [String: Any] = [
            "model": Self.sanitized(modelName, fallback: "model-placeholder"),
            "messages": [
                [
                    "role": "system",
                    "content": "Translate the provided text. Return only the translated text."
                ],
                [
                    "role": "user",
                    "content": "Source language: \(sourceLanguageMode)\nTarget language: \(targetLanguage)\nText:\n\(text)"
                ]
            ],
            "temperature": 0,
            "stream": false
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func parsedOutputText(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            return nil
        }

        if
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let text = first["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func normalizedStatus(httpStatusCode: Int) -> OpenAIConnectionStatus {
        switch httpStatusCode {
        case 401:
            .unauthorized
        case 403:
            .forbidden
        case 429:
            .rateLimited
        case 500...599:
            .serverError
        default:
            .httpError
        }
    }

    private func normalizedStatus(error: Error) -> OpenAIConnectionStatus {
        if let brokerError = error as? BlocksNativePluginNetworkBrokerError,
           case let .transport(message) = brokerError,
           message == "The request timed out." {
            return .timeout
        }
        guard let urlError = error as? URLError else {
            return .networkError
        }
        return urlError.code == .timedOut ? .timeout : .networkError
    }

    private func responseWarnings(httpStatusCode: Int) -> [String] {
        if Self.redirectStatusCodes.contains(httpStatusCode) {
            return [
                "provider_response_redacted",
                "redirect_denied",
                "http_error_body_not_recorded",
            ]
        }
        return [
            "provider_response_redacted",
            "http_error_body_not_recorded",
        ]
    }

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }

    private func result(
        profile: OpenAITranslationRuntimeProfile,
        ok: Bool,
        status: OpenAIConnectionStatus,
        sourceLanguageMode: String,
        targetLanguage: String,
        textCharacterCount: Int,
        outputText: String?,
        httpStatusCode: Int?,
        durationMS: Int,
        requestID: String?,
        secretLength: Int?,
        warnings: [String]
    ) -> OpenAITranslationRuntimeResult {
        let id = UUID().uuidString
        return OpenAITranslationRuntimeResult(
            id: id,
            ok: ok,
            status: status,
            providerName: Self.sanitized(profile.providerName, fallback: "OpenAI-compatible"),
            baseURLSummary: Self.summarizeBaseURL(profile.baseURL),
            modelName: Self.sanitized(profile.modelName, fallback: "model-placeholder"),
            keychainAccountAlias: Self.sanitized(profile.keychainAccountAlias, fallback: "account-alias-placeholder"),
            sourceLanguageMode: sourceLanguageMode,
            targetLanguage: targetLanguage,
            textCharacterCount: textCharacterCount,
            outputText: outputText,
            httpStatusCode: httpStatusCode,
            durationMS: durationMS,
            requestID: requestID,
            secretLength: secretLength,
            auditID: ProviderAuditID.make(
                prefix: "tr_runtime",
                uuidString: id
            ),
            warnings: warnings
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

    private func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }

    private static func connectionStatus(
        for errorCode: ProviderErrorCode
    ) -> OpenAIConnectionStatus {
        switch errorCode {
        case .missingConfiguration:
            .missingConfiguration
        case .invalidBaseURL:
            .invalidBaseURL
        case .confirmationRequired:
            .confirmationRequired
        case .missingSecret:
            .missingSecret
        case .unsupportedCapability:
            .unsupportedCapability
        case .unauthorized:
            .unauthorized
        case .forbidden:
            .forbidden
        case .rateLimited:
            .rateLimited
        case .timeout:
            .timeout
        case .networkError:
            .networkError
        case .invalidResponse:
            .invalidResponse
        case .providerUnavailable:
            .serverError
        }
    }

    private func publish(
        _ result: OpenAITranslationRuntimeResult,
        auditToken: ProviderAuditToken? = nil,
        auditTarget: ProviderExternalTransferTarget? = nil,
        auditGrant: ProviderExternalTransferGrant? = nil
    ) -> OpenAITranslationRuntimeResult {
        if let auditToken, let auditHandlerWithToken {
            auditHandlerWithToken(result, auditToken, auditTarget, auditGrant)
        } else {
            auditHandler?(result)
        }
        return result
    }
}
