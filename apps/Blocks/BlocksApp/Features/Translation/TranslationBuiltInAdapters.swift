import BlocksCore
import Foundation
import NaturalLanguage
import OSLog

#if canImport(Translation)
import Translation
#endif

enum AppleTranslationFailurePhase {
    case runtime
    case preparation
}

enum AppleTranslationFailureClassifier {
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "AppleTranslationFailure"
    )

    static func classify(
        _ error: Error,
        phase: AppleTranslationFailurePhase
    ) -> Error {
        if error is CancellationError
            || error is TranslationServiceAdapterError {
            return error
        }
        let nsError = error as NSError
        logger.error(
            "phase=\(String(describing: phase), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            if TranslationError.unsupportedSourceLanguage ~= error {
                return TranslationServiceAdapterError.unavailable(
                    code: "translation_source_language_unsupported",
                    message: L10n.string(
                        "translation.error.sourceLanguageUnsupported"
                    )
                )
            }
            if TranslationError.unsupportedTargetLanguage ~= error {
                return TranslationServiceAdapterError.unavailable(
                    code: "translation_target_language_unsupported",
                    message: L10n.string(
                        "translation.error.targetLanguageUnsupported"
                    )
                )
            }
            if TranslationError.unsupportedLanguagePairing ~= error {
                return TranslationServiceAdapterError.unavailable(
                    code: "apple_language_pair_unsupported",
                    message: L10n.string(
                        "translation.error.languagePairUnsupported"
                    )
                )
            }
            if TranslationError.unableToIdentifyLanguage ~= error {
                return TranslationServiceAdapterError.failed(
                    code: "source_language_undetermined",
                    message: L10n.string(
                        "translation.error.sourceLanguageUndetermined"
                    )
                )
            }
            if TranslationError.nothingToTranslate ~= error {
                return TranslationServiceAdapterError.failed(
                    code: "empty_source_text",
                    message: L10n.string(
                        "translation.error.emptySource"
                    )
                )
            }
            if TranslationError.internalError ~= error {
                return TranslationServiceAdapterError.failed(
                    code: "apple_translation_runtime_unavailable",
                    message: L10n.string(
                        "translation.error.appleRuntimeUnavailable"
                    )
                )
            }
            if #available(macOS 26.0, *) {
                if TranslationError.alreadyCancelled ~= error {
                    return CancellationError()
                }
                if TranslationError.notInstalled ~= error {
                    return TranslationServiceAdapterError.unavailable(
                        code: "apple_language_download_required",
                        message: L10n.string(
                            "translation.error.languageDownloadRequired"
                        )
                    )
                }
            }
        }
#endif
        switch phase {
        case .runtime:
            return TranslationServiceAdapterError.failed(
                code: "apple_translation_runtime_unavailable",
                message: L10n.string(
                    "translation.error.appleRuntimeUnavailable"
                )
            )
        case .preparation:
            return TranslationServiceAdapterError.failed(
                code: "apple_translation_preparation_failed",
                message: L10n.string(
                    "translation.error.applePreparationFailed"
                )
            )
        }
    }
}

enum AppleTranslationReadinessPolicy {
    static func failure(
        availability: AppleTranslationPairAvailability,
        sessionIsReady: Bool
    ) -> TranslationServiceAdapterError? {
        guard !sessionIsReady else { return nil }
        switch availability {
        case .installed:
            return .failed(
                code: "apple_language_not_ready",
                message: L10n.string(
                    "translation.error.appleLanguageNotReady"
                )
            )
        case .downloadable:
            return .unavailable(
                code: "apple_language_download_required",
                message: L10n.string(
                    "translation.error.languageDownloadRequired"
                )
            )
        case .unsupported:
            return .unavailable(
                code: "apple_language_pair_unsupported",
                message: L10n.string(
                    "translation.error.languagePairUnsupported"
                )
            )
        }
    }
}

struct OpenAITranslationServiceConfiguration: Equatable {
    let baseURL: String
    let modelName: String
    let keychainAccountAlias: String
    let credentialRevision: UInt64
    let externalTransferGrant: ProviderExternalTransferGrant?

    var externalTransferTarget: ProviderExternalTransferTarget? {
        ProviderExternalTransferTarget(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            credentialRevision: credentialRevision
        )
    }

    var isComplete: Bool {
        guard let target = externalTransferTarget else { return false }
        let baseGate = ProviderRuntimeGate.validateOpenAICompatible(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            externalTransferConfirmed: true
        )
        return baseGate.ready
            && externalTransferGrant?.target == target
    }

    static func current(defaults: UserDefaults = .standard) -> OpenAITranslationServiceConfiguration {
        OpenAITranslationServiceConfiguration(
            baseURL: ProviderSettingsPersistence.storedProviderBaseURL(
                defaults: defaults
            ),
            modelName: defaults.string(
                forKey: ProviderSettingsPersistence.modelNameKey
            ) ?? "",
            keychainAccountAlias: defaults.string(
                forKey: ProviderSettingsPersistence.accountAliasKey
            ) ?? "",
            credentialRevision: ProviderSettingsPersistence
                .credentialRevision(defaults: defaults),
            externalTransferGrant: ProviderSettingsPersistence
                .externalTransferGrant(defaults: defaults)
        )
    }
}

private final class OpenAITranslationDeferredAuditCapture:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var audit: OpenAITranslationDeferredAudit?

    func store(_ audit: OpenAITranslationDeferredAudit) {
        lock.lock()
        if self.audit == nil {
            self.audit = audit
        }
        lock.unlock()
    }

    func take() -> OpenAITranslationDeferredAudit? {
        lock.lock()
        defer { lock.unlock() }
        let audit = audit
        self.audit = nil
        return audit
    }
}

private struct OpenAITranslationExecutionOutcome: Sendable {
    let result: OpenAITranslationRuntimeResult
    let deferredAudit: OpenAITranslationDeferredAudit?
    let publicationTarget: ProviderExternalTransferTarget?
    let publicationGrant: ProviderExternalTransferGrant?
}

private final class OpenAITranslationDefaultsReference: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private actor OpenAITranslationExecutionWorker {
    private let runtimeService: OpenAITranslationRuntimeService
    private let readProviderSecret:
        (String) throws -> ProviderUserSecretMaterial
    private let authorizationValidator: @Sendable (
        ProviderExternalTransferTarget,
        ProviderExternalTransferGrant?
    ) -> Bool
    private let admissionValidator: @Sendable (
        ProviderExternalTransferTarget,
        ProviderExternalTransferGrant?,
        () -> Bool
    ) -> Bool

    init(
        runtimeService: OpenAITranslationRuntimeService,
        readProviderSecret:
            @escaping (String) throws -> ProviderUserSecretMaterial,
        authorizationValidator: @escaping @Sendable (
            ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?
        ) -> Bool,
        admissionValidator: @escaping @Sendable (
            ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?,
            () -> Bool
        ) -> Bool
    ) {
        self.runtimeService = runtimeService
        self.readProviderSecret = readProviderSecret
        self.authorizationValidator = authorizationValidator
        self.admissionValidator = admissionValidator
    }

    func translate(
        request: TranslationServiceRequest,
        configuration: OpenAITranslationServiceConfiguration
    ) async throws -> OpenAITranslationExecutionOutcome {
        try Task.checkCancellation()
        let text = request.input.text
        let profile = OpenAITranslationRuntimeProfile(
            providerName: L10n.string(
                "translation.service.openAICompatible"
            ),
            baseURL: configuration.baseURL,
            modelName: configuration.modelName,
            keychainAccountAlias: configuration.keychainAccountAlias,
            timeoutSeconds: 60
        )
        let sourceLanguageMode =
            request.direction.source?.rawValue ?? "auto"
        let authorizationTarget = configuration.externalTransferTarget
        let publicationTarget: ProviderExternalTransferTarget?
        let publicationGrant: ProviderExternalTransferGrant?
        if let authorizationTarget,
           let externalTransferGrant = configuration.externalTransferGrant,
           externalTransferGrant.target == authorizationTarget {
            publicationTarget = authorizationTarget
            publicationGrant = externalTransferGrant
        } else {
            publicationTarget = nil
            publicationGrant = nil
        }
        let capturesDeferredAudit = publicationTarget != nil
            && publicationGrant != nil
        func deferredPreflightOutcome(
            errorCode: ProviderErrorCode
        ) -> OpenAITranslationExecutionOutcome {
            let deferredAuditCapture =
                OpenAITranslationDeferredAuditCapture()
            let result = runtimeService.preflightBlockedResult(
                profile: profile,
                errorCode: errorCode,
                textCharacterCount: text.count,
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: request.direction.target.rawValue,
                auditTarget: publicationTarget,
                auditGrant: publicationGrant,
                deferredAuditHandler: { audit in
                    guard capturesDeferredAudit else { return }
                    deferredAuditCapture.store(audit)
                },
                captureAudit: capturesDeferredAudit
            )
            return OpenAITranslationExecutionOutcome(
                result: result,
                deferredAudit: deferredAuditCapture.take(),
                publicationTarget: publicationTarget,
                publicationGrant: publicationGrant
            )
        }
        let gate = ProviderRuntimeGate.validateOpenAICompatible(
            baseURL: configuration.baseURL,
            modelName: configuration.modelName,
            keychainAccountAlias: configuration.keychainAccountAlias,
            externalTransferConfirmed: configuration.isComplete
        )
        guard gate.ready else {
            return deferredPreflightOutcome(
                errorCode: gate.errorCode ?? .missingConfiguration
            )
        }
        if OpenAITranslationRuntimeService.inputExceedsLimit(text) {
            let deferredAuditCapture =
                OpenAITranslationDeferredAuditCapture()
            let result = runtimeService.inputLimitExceededResult(
                profile: profile,
                textCharacterCount: text.count,
                sourceLanguageMode: sourceLanguageMode,
                targetLanguage: request.direction.target.rawValue,
                auditTarget: publicationTarget,
                auditGrant: publicationGrant,
                deferredAuditHandler: { audit in
                    guard capturesDeferredAudit else { return }
                    deferredAuditCapture.store(audit)
                },
                captureAudit: capturesDeferredAudit
            )
            return OpenAITranslationExecutionOutcome(
                result: result,
                deferredAudit: deferredAuditCapture.take(),
                publicationTarget: publicationTarget,
                publicationGrant: publicationGrant
            )
        }

        guard let authorizationTarget else {
            return deferredPreflightOutcome(
                errorCode: .confirmationRequired
            )
        }
        guard authorizationValidator(
                  authorizationTarget,
                  configuration.externalTransferGrant
              ) else {
            return deferredPreflightOutcome(
                errorCode: .confirmationRequired
            )
        }

        let secret: ProviderUserSecretMaterial
        do {
            secret = try readProviderSecret(
                configuration.keychainAccountAlias
            )
        } catch {
            if error is CancellationError {
                throw error
            }
            return deferredPreflightOutcome(
                errorCode: .missingSecret
            )
        }
        try Task.checkCancellation()
        guard authorizationValidator(
            authorizationTarget,
            configuration.externalTransferGrant
        ) else {
            return deferredPreflightOutcome(
                errorCode: .confirmationRequired
            )
        }
        guard secret.credentialRevision
                == authorizationTarget.credentialRevision else {
            return deferredPreflightOutcome(
                errorCode: .missingSecret
            )
        }
        let deferredAuditCapture = OpenAITranslationDeferredAuditCapture()
        let result = await runtimeService.translate(
            text: text,
            sourceLanguageMode: sourceLanguageMode,
            targetLanguage: request.direction.target.rawValue,
            profile: profile,
            secretMaterial: secret,
            authorizationCheck: {
                authorizationValidator(
                    authorizationTarget,
                    configuration.externalTransferGrant
                )
            },
            admission: { start in
                self.admissionValidator(
                    authorizationTarget,
                    configuration.externalTransferGrant,
                    start
                )
            },
            auditTarget: publicationTarget,
            auditGrant: publicationGrant,
            deferredAuditHandler: { audit in
                deferredAuditCapture.store(audit)
            }
        )
        return OpenAITranslationExecutionOutcome(
            result: result,
            deferredAudit: deferredAuditCapture.take(),
            publicationTarget: publicationTarget,
            publicationGrant: publicationGrant
        )
    }
}

@MainActor
final class OpenAICompatibleTranslationServiceAdapter: TranslationServiceAdapter {
    private let worker: OpenAITranslationExecutionWorker
    private let configuration: () -> OpenAITranslationServiceConfiguration
    private let publicationValidator: @Sendable (
        ProviderExternalTransferTarget,
        ProviderExternalTransferGrant?,
        () -> Void
    ) -> Bool

    init(
        runtimeService: OpenAITranslationRuntimeService = OpenAITranslationRuntimeService(),
        providerKeychainService: ProviderKeychainService = ProviderKeychainService(),
        defaults: UserDefaults = .standard,
        configuration: (() -> OpenAITranslationServiceConfiguration)? = nil,
        readProviderSecret: ((String) throws -> ProviderUserSecretMaterial)? = nil,
        authorizationValidator: (@Sendable (
            ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?
        ) -> Bool)? = nil,
        admissionValidator: (@Sendable (
            ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?,
            () -> Bool
        ) -> Bool)? = nil,
        publicationValidator: (@Sendable (
            ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?,
            () -> Void
        ) -> Bool)? = nil
    ) {
        let defaultsReference = OpenAITranslationDefaultsReference(defaults)
        self.configuration = configuration ?? {
            .current(defaults: defaultsReference.value)
        }
        self.publicationValidator = publicationValidator ?? {
            target,
            grant,
            publication in
            ProviderSettingsPersistence.publishExternalTransfer(
                target: target,
                grant: grant,
                defaults: defaultsReference.value,
                publication: publication
            )
        }
        let secretReader = readProviderSecret ?? { alias in
            try providerKeychainService.readUserSecretForProviderCall(alias: alias)
        }
        let resolvedAuthorizationValidator = authorizationValidator ?? {
            target,
            grant in
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target,
                grant: grant,
                defaults: defaultsReference.value
            )
        }
        let resolvedAdmissionValidator = admissionValidator ?? {
            target,
            grant,
            start in
            ProviderSettingsPersistence.admitExternalTransfer(
                target: target,
                grant: grant,
                defaults: defaultsReference.value,
                start: start
            )
        }
        worker = OpenAITranslationExecutionWorker(
            runtimeService: runtimeService,
            readProviderSecret: secretReader,
            authorizationValidator: resolvedAuthorizationValidator,
            admissionValidator: resolvedAdmissionValidator
        )
    }

    var descriptor: TranslationServiceDescriptor {
        let configuration = configuration()
        return TranslationServiceDescriptor(
            id: "openai-compatible",
            displayName: L10n.string("translation.service.openAICompatible"),
            kind: .openAICompatible,
            availability: configuration.isComplete ? .available : .requiresConfiguration,
            supportsStreaming: false,
            supportedTargetLanguages: TranslationLanguagePreferences.commonOptions
        )
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [worker, configuration, publicationValidator] in
                do {
                    try Task.checkCancellation()
                    let current = configuration()
                    let execution = try await worker.translate(
                        request: request,
                        configuration: current
                    )
                    try Task.checkCancellation()
                    let result = execution.result
                    let diagnostics = result.translationDiagnostics
                    guard result.ok, let output = result.outputText else {
                        let isInputTooLarge = result.warnings.contains(
                            "translation_input_too_large"
                        )
                        let resultError = TranslationServiceAdapterError.failed(
                            code: isInputTooLarge
                                ? "translation_input_too_large"
                                : result.status.rawValue,
                            message: isInputTooLarge
                                ? TranslationLocalizedFormat.inputTooLarge(
                                    maximumCharacterCount:
                                        OpenAITranslationRuntimeService
                                            .maximumInputCharacterCount
                                )
                                : result.localizedErrorDetail
                        )
                        guard let target = execution.publicationTarget,
                              let grant = execution.publicationGrant else {
                            throw resultError
                        }
                        guard publicationValidator(
                            target,
                            grant,
                            {
                                continuation.yield(
                                    .diagnostics(
                                        diagnostics,
                                        warnings: result.warnings
                                    )
                                )
                                execution.deferredAudit?.publishOnce()
                            }
                        ) else {
                            throw TranslationServiceAdapterError
                                .publicationRejected
                        }
                        throw resultError
                    }
                    guard let target = execution.publicationTarget,
                          let grant = execution.publicationGrant else {
                        throw TranslationServiceAdapterError.failed(
                            code: ProviderErrorCode.confirmationRequired.rawValue,
                            message: result.localizedErrorDetail
                        )
                    }
                    guard publicationValidator(
                        target,
                        grant,
                        {
                            continuation.yield(
                                .completed(
                                    output,
                                    warnings: result.warnings,
                                    diagnostics: diagnostics
                                )
                            )
                            execution.deferredAudit?.publishOnce()
                        }
                    ) else {
                        throw TranslationServiceAdapterError
                            .publicationRejected
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

@MainActor
final class AppleLocalTranslationServiceAdapter: TranslationServiceAdapter {
    private let runtimeController: AppleTranslationRuntimeController
    private let availabilityCoordinator:
        AppleTranslationAvailabilityCoordinator

    init(
        runtimeController: AppleTranslationRuntimeController,
        availabilityCoordinator:
            AppleTranslationAvailabilityCoordinator? = nil
    ) {
        self.runtimeController = runtimeController
        self.availabilityCoordinator =
            availabilityCoordinator
            ?? AppleTranslationAvailabilityCoordinator.shared
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: "apple-local",
            displayName: L10n.string("translation.service.appleLocal"),
            kind: .appleLocal,
            availability: Self.runtimeAvailability,
            supportsStreaming: false
        )
    }

    var requiresExplicitSourceLanguage: Bool { true }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = request.input.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        throw TranslationServiceAdapterError.failed(
                            code: "empty_source_text",
                            message: L10n.string("translation.error.emptySource")
                        )
                    }
#if canImport(Translation)
                    guard #available(macOS 15.0, *) else {
                        throw Self.unsupportedOS
                    }
                    let sourceTag = try Self.resolvedSourceTag(
                        explicit: request.direction.source,
                        text: text
                    )
                    let status = await availabilityCoordinator.availability(
                        for: AppleTranslationLanguagePair(
                            source: sourceTag,
                            target: request.direction.target
                        )
                    )
                    switch status {
                    case .installed:
                        break
                    case .downloadable:
                        if #unavailable(macOS 26.0) {
                            throw TranslationServiceAdapterError.unavailable(
                                code: "apple_language_download_required",
                                message: L10n.string(
                                    "translation.error.languageDownloadRequired"
                                )
                            )
                        }
                    case .unsupported:
                        throw TranslationServiceAdapterError.unavailable(
                            code: "apple_language_pair_unsupported",
                            message: L10n.string("translation.error.languagePairUnsupported")
                        )
                    }
                    try Task.checkCancellation()
                    let translatedText = try await runtimeController.translate(
                        text: text,
                        source: sourceTag,
                        target: request.direction.target,
                        availability: status
                    )
                    try Task.checkCancellation()
                    continuation.yield(.completed(translatedText))
                    continuation.finish()
#else
                    throw Self.unsupportedOS
#endif
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(
                        throwing:
                            AppleTranslationFailureClassifier.classify(
                                error,
                                phase: .runtime
                            )
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func supportedLanguages() async -> [TranslationLanguageTag] {
#if canImport(Translation)
        guard #available(macOS 15.0, *) else { return fallbackLanguages }
        let languages = await LanguageAvailability().supportedLanguages
        let tags = languages.compactMap {
            TranslationLanguageTag($0.minimalIdentifier)
        }
        return tags.isEmpty ? fallbackLanguages : tags.sorted { $0.rawValue < $1.rawValue }
#else
        return fallbackLanguages
#endif
    }

    static let fallbackLanguages: [TranslationLanguageTag] = [
        "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
        "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ].compactMap { TranslationLanguageTag($0) }

    private static var runtimeAvailability: TranslationServiceAvailability {
        if #available(macOS 15.0, *) {
            return .available
        }
        return .unsupported
    }

    private static var unsupportedOS: TranslationServiceAdapterError {
        TranslationServiceAdapterError.unavailable(
            code: "apple_translation_requires_macos_15",
            message: L10n.string("translation.error.appleRequiresMacOS15")
        )
    }

    private static func resolvedSourceTag(
        explicit: TranslationLanguageTag?,
        text: String
    ) throws -> TranslationLanguageTag {
        if let explicit {
            return explicit
        }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text),
              let tag = TranslationLanguageTag(detected.rawValue) else {
            throw TranslationServiceAdapterError.failed(
                code: "source_language_undetermined",
                message: L10n.string("translation.error.sourceLanguageUndetermined")
            )
        }
        return tag
    }
}

extension Locale.Language {
    fileprivate var minimalIdentifier: String {
        var subtags: [String] = []
        if let languageCode {
            subtags.append(languageCode.identifier)
        }
        if let script {
            subtags.append(script.identifier)
        }
        if let region {
            subtags.append(region.identifier)
        }
        return subtags.joined(separator: "-")
    }
}
