import BlocksCore
import Foundation
import OSLog

struct TranslationServiceRequest: Sendable {
    let invocation: TranslationSourceInvocation
    let attachments: [TranslationSourceAttachmentPayload]

    var sessionID: String { invocation.sessionID }
    var input: TranslationInput { invocation.input }
    var direction: TranslationLanguageDirection {
        invocation.direction
    }

    init(
        sessionID: String,
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        context: TranslationSourceContext? = nil,
        attachments: [TranslationSourceAttachmentPayload] = []
    ) {
        self.attachments = attachments
        invocation = TranslationSourceInvocation(
            sessionID: sessionID,
            input: input,
            direction: direction,
            context: context,
            attachments: attachments.map(\.descriptor)
        )
    }
}

/// Attachment bytes remain in memory only for the active translation session.
/// The Core invocation carries descriptors so snapshots and favorites never
/// retain image data.
struct TranslationSourceAttachmentPayload: Sendable {
    let descriptor: TranslationSourceAttachmentDescriptor
    let data: Data
    let base64EncodedData: String?

    init(
        descriptor: TranslationSourceAttachmentDescriptor,
        data: Data,
        base64EncodedData: String? = nil
    ) {
        self.descriptor = descriptor
        self.data = data
        self.base64EncodedData = base64EncodedData
    }
}

enum TranslationServiceEvent: Sendable {
    case partial(String)
    case source(TranslationSourceEvent)
    case diagnostics(
        TranslationResultDiagnostics,
        warnings: [String] = []
    )
    case completed(
        String,
        warnings: [String] = [],
        diagnostics: TranslationResultDiagnostics? = nil
    )
}

enum TranslationServiceAdapterError: LocalizedError, Equatable, Sendable {
    case unavailable(code: String, message: String)
    case invalidConfiguration(code: String, message: String)
    case failed(code: String, message: String)
    case publicationRejected

    var errorCode: String {
        switch self {
        case let .unavailable(code, _),
             let .invalidConfiguration(code, _),
             let .failed(code, _):
            code
        case .publicationRejected:
            "publication_rejected"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .unavailable(_, message),
             let .invalidConfiguration(_, message),
             let .failed(_, message):
            message
        case .publicationRejected:
            nil
        }
    }
}

enum TranslationErrorPresentation {
    static func message(
        code: String?,
        fallback: String?
    ) -> String {
        guard let code else {
            return fallback ?? L10n.string("translation.error.generic")
        }
        switch code {
        case "apple_language_download_required":
            return L10n.string(
                "translation.error.languageDownloadRequired"
            )
        case "apple_language_not_ready":
            return L10n.string(
                "translation.error.appleLanguageNotReady"
            )
        case "apple_language_pair_unsupported":
            return L10n.string(
                "translation.error.languagePairUnsupported"
            )
        case "apple_translation_runtime_unavailable":
            return L10n.string(
                "translation.error.appleRuntimeUnavailable"
            )
        case "apple_translation_preparation_failed":
            return L10n.string(
                "translation.error.applePreparationFailed"
            )
        case "translation_source_language_unsupported":
            return L10n.string(
                "translation.error.sourceLanguageUnsupported"
            )
        case "translation_target_language_unsupported":
            return L10n.string(
                "translation.error.targetLanguageUnsupported"
            )
        case "translation_language_pair_unsupported":
            return L10n.string(
                "translation.error.languagePairUnsupported"
            )
        case "translation_response_language_mismatch":
            return L10n.string(
                "translation.community.error.responseLanguageMismatch"
            )
        case "source_language_undetermined":
            return L10n.string(
                "translation.error.sourceLanguageUndetermined"
            )
        case "empty_source_text":
            return L10n.string("translation.error.emptySource")
        case "plugin_runner_unavailable":
            return L10n.string(
                "translation.error.pluginRunnerUnavailable"
            )
        case "plugin_not_approved":
            return L10n.string("translation.error.pluginNotApproved")
        case "plugin_disabled":
            return L10n.string("translation.error.pluginDisabled")
        case "plugin_package_changed", "package_hash_mismatch":
            return L10n.string("translation.error.pluginPackageChanged")
        case "plugin_capability_unavailable", "capability_unavailable":
            return L10n.string(
                "translation.error.pluginCapabilityUnavailable"
            )
        case "plugin_empty_output":
            return L10n.string("translation.error.pluginEmptyOutput")
        case "plugin_ocr_empty_output":
            return L10n.string("translation.screenshot.noText")
        case "plugin_ocr_image_too_large":
            return L10n.string(
                "translation.error.pluginOCRImageTooLarge"
            )
        case "plugin_ocr_image_encoding_failed":
            return L10n.string(
                "translation.error.pluginOCRImageEncodingFailed"
            )
        case "plugin_translation_image_invalid":
            return L10n.string(
                "translation.error.pluginOCRImageEncodingFailed"
            )
        case "network_policy_denied",
             "network_request_invalid",
             "network_request_failed",
             "network_budget_exceeded":
            return L10n.string("translation.error.pluginNetworkFailed")
        case "progress_budget_exceeded",
             "invalid_output",
             "async_result_not_supported",
             "script_exception":
            return L10n.string("translation.error.pluginStopped")
        default:
            if code.hasPrefix("plugin_") {
                return L10n.string("translation.error.pluginFailed")
            }
            return fallback ?? L10n.string("translation.error.generic")
        }
    }

    static func message(for error: Error) -> String {
        if let adapterError = error as? TranslationServiceAdapterError {
            return message(
                code: adapterError.errorCode,
                fallback: adapterError.errorDescription
            )
        }
        if let pluginError = error as? BlocksNativePluginExecutionError {
            return message(
                code: TranslationPluginServiceErrorMapper.code(
                    for: pluginError
                ),
                fallback: pluginError.errorDescription
            )
        }
        return L10n.string("translation.error.generic")
    }

    static func notificationTitle(for error: Error) -> String {
        let code = (error as? TranslationServiceAdapterError)?.errorCode
        switch code {
        case "apple_language_download_required":
            return L10n.string(
                "translation.notification.languageDownloadRequired"
            )
        case "apple_language_not_ready":
            return L10n.string(
                "translation.notification.languageNotReady"
            )
        case "apple_language_pair_unsupported",
             "translation_source_language_unsupported",
             "translation_target_language_unsupported":
            return L10n.string(
                "translation.notification.languageUnsupported"
            )
        default:
            return L10n.string(
                "translation.notification.appleTranslationFailed"
            )
        }
    }
}

@MainActor
protocol TranslationServiceAdapter: AnyObject {
    var descriptor: TranslationServiceDescriptor { get }
    var requiresExplicitSourceLanguage: Bool { get }
    var acceptedInputs: Set<TranslationSourceAcceptedInput> { get }

    /// Validates the requested *directed* language pair. A pair cannot be
    /// inferred safely from independent source/target lists for services whose
    /// routing is asymmetric (for example Tencent's web endpoint).
    func validateLanguageDirection(
        _ direction: TranslationLanguageDirection
    ) throws

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error>
}

extension TranslationServiceAdapter {
    var requiresExplicitSourceLanguage: Bool { false }
    var acceptedInputs: Set<TranslationSourceAcceptedInput> {
        [.text]
    }

    func validateLanguageDirection(
        _ direction: TranslationLanguageDirection
    ) throws {
        try TranslationServiceDirectionValidator.validate(
            direction: direction,
            service: descriptor
        )
    }
}

enum TranslationServiceDirectionValidator {
    static func validate(
        direction: TranslationLanguageDirection,
        service: TranslationServiceDescriptor
    ) throws {
        if service.availability == .unsupported
            || service.availability == .disabled {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_service_unavailable",
                message: L10n.string("translation.error.serviceUnavailable")
            )
        }
        if let source = direction.source,
           !service.supportedSourceLanguages.isEmpty,
           !service.supportedSourceLanguages.contains(source) {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_source_language_unsupported",
                message: L10n.string("translation.error.languagePairUnsupported")
            )
        }
        if !service.supportedTargetLanguages.isEmpty,
           !service.supportedTargetLanguages.contains(direction.target) {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_target_language_unsupported",
                message: L10n.string("translation.error.languagePairUnsupported")
            )
        }
    }
}

@MainActor
final class TranslationServiceRegistry: ObservableObject {
    @Published private(set) var descriptors: [TranslationServiceDescriptor] = []

    private var adaptersByID: [String: any TranslationServiceAdapter] = [:]

    func replaceAdapters(_ adapters: [any TranslationServiceAdapter]) {
        adaptersByID = Dictionary(
            uniqueKeysWithValues: adapters.map { ($0.descriptor.id, $0) }
        )
        descriptors = adapters.map(\.descriptor)
    }

    func register(_ adapter: any TranslationServiceAdapter) {
        adaptersByID[adapter.descriptor.id] = adapter
        if let index = descriptors.firstIndex(where: { $0.id == adapter.descriptor.id }) {
            descriptors[index] = adapter.descriptor
        } else {
            descriptors.append(adapter.descriptor)
        }
    }

    func unregister(serviceID: String) {
        adaptersByID.removeValue(forKey: serviceID)
        descriptors.removeAll { $0.id == serviceID }
    }

    func adapter(serviceID: String) -> (any TranslationServiceAdapter)? {
        adaptersByID[serviceID]
    }

    func orderedAdapters(serviceIDs: [String], maximumCount: Int = 4) -> [any TranslationServiceAdapter] {
        var seen: Set<String> = []
        return serviceIDs.compactMap { serviceID in
            guard seen.insert(serviceID).inserted else { return nil }
            return adaptersByID[serviceID]
        }
        .prefix(max(0, maximumCount))
        .map { $0 }
    }
}

enum TranslationLocalizedFormat {
    static func characterCount(_ count: Int) -> String {
        L10n.format(
            "translation.preview.characterCount",
            Int64(count)
        )
    }

    static func inputTooLarge(maximumCharacterCount: Int) -> String {
        L10n.format(
            "translation.error.inputTooLarge",
            Int64(maximumCharacterCount)
        )
    }

    static func ocrLines(_ lineCount: Int) -> String {
        L10n.format(
            "translation.screenshot.ocrLines",
            Int64(lineCount)
        )
    }

    static func duration(milliseconds: Int) -> String {
        L10n.format(
            "translation.panel.diagnostics.durationValue",
            Int64(milliseconds)
        )
    }

    static func httpStatus(_ status: Int) -> String {
        L10n.format(
            "translation.community.error.httpStatus",
            Int64(status)
        )
    }
}

@MainActor
final class TranslationRunCoordinator {
    typealias UpdateHandler = @MainActor (TranslationSessionSnapshot) -> Void

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationRun"
    )

    private var revision: UInt64 = 0
    private var serviceTasks: [String: Task<Void, Never>] = [:]
    private var serviceAttemptGenerations: [String: UInt64] = [:]
    private var session: TranslationSessionSnapshot?
    private var sessionAttachments:
        [TranslationSourceAttachmentPayload] = []
    private var deferredAttachmentServiceIDs: Set<String> = []
    private var allowedServiceIDs: Set<String> = []
    private var sessionSourceContext: TranslationSourceContext?
    private var adaptersByID: [String: any TranslationServiceAdapter] = [:]
    private var updateHandler: UpdateHandler?

    deinit {
        serviceTasks.values.forEach { $0.cancel() }
    }

    @discardableResult
    func start(
        sessionID: String = UUID().uuidString,
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        adapters: [any TranslationServiceAdapter],
        context: TranslationSourceContext? = nil,
        attachments: [TranslationSourceAttachmentPayload] = [],
        onUpdate: @escaping UpdateHandler
    ) -> TranslationSessionSnapshot {
        cancelTasks(incrementRevision: true)
        let currentRevision = revision
        serviceAttemptGenerations.removeAll()
        adaptersByID = Dictionary(uniqueKeysWithValues: adapters.map { ($0.descriptor.id, $0) })
        allowedServiceIDs = Set(adaptersByID.keys)
        sessionAttachments = attachments
        deferredAttachmentServiceIDs.removeAll()
        sessionSourceContext = context
        updateHandler = onUpdate

        let createdAt = Date()
        let initial = TranslationSessionSnapshot(
            id: sessionID,
            input: input,
            direction: direction,
            results: adapters.map {
                TranslationResultSnapshot(
                    service: $0.descriptor,
                    state: .waiting
                )
            },
            createdAt: createdAt,
            updatedAt: createdAt
        )
        session = initial
        onUpdate(initial)
        Self.logger.info(
            "session=\(initial.id, privacy: .public) revision=\(currentRevision, privacy: .public) phase=start source=\(direction.source?.rawValue ?? "auto", privacy: .public) target=\(direction.target.rawValue, privacy: .public) characters=\(input.text.count, privacy: .public) services=\(adapters.count, privacy: .public)"
        )

        for adapter in adapters {
            let serviceID = adapter.descriptor.id
            if Self.requiresScreenshotAttachment(adapter),
               !Self.hasScreenshotAttachment(attachments) {
                deferredAttachmentServiceIDs.insert(serviceID)
                continue
            }
            let attemptGeneration = nextAttemptGeneration(
                for: serviceID
            )
            launch(
                adapter: adapter,
                session: initial,
                context: context,
                attachments: attachments,
                revision: currentRevision,
                attemptGeneration: attemptGeneration
            )
        }
        return initial
    }

    func installAttachments(
        _ attachments: [TranslationSourceAttachmentPayload]
    ) {
        guard let session,
              Self.hasScreenshotAttachment(attachments),
              !deferredAttachmentServiceIDs.isEmpty else {
            return
        }
        sessionAttachments = attachments
        let serviceIDs = deferredAttachmentServiceIDs
        deferredAttachmentServiceIDs.removeAll()
        let currentRevision = revision
        for serviceID in serviceIDs {
            guard allowedServiceIDs.contains(serviceID),
                  let adapter = adaptersByID[serviceID] else {
                continue
            }
            let attemptGeneration = nextAttemptGeneration(
                for: serviceID
            )
            launch(
                adapter: adapter,
                session: session,
                context: sessionSourceContext,
                attachments: attachments,
                revision: currentRevision,
                attemptGeneration: attemptGeneration
            )
        }
    }

    func failPendingScreenshotAttachment(
        code: String,
        message: String
    ) {
        guard !deferredAttachmentServiceIDs.isEmpty else {
            return
        }
        let serviceIDs = deferredAttachmentServiceIDs
        deferredAttachmentServiceIDs.removeAll()
        let currentRevision = revision
        for serviceID in serviceIDs {
            let attemptGeneration = nextAttemptGeneration(
                for: serviceID
            )
            replaceResult(
                serviceID: serviceID,
                state: .failed,
                translatedText: "",
                errorCode: code,
                errorMessage: message,
                isRetryable: false,
                warnings: [],
                startedAt: nil,
                completedAt: Date(),
                diagnostics: Self.defaultDiagnostics(
                    serviceID: serviceID,
                    status: code,
                    startedAt: Date()
                ),
                revision: currentRevision,
                attemptGeneration: attemptGeneration
            )
        }
    }

    func retry(serviceID: String) {
        guard allowedServiceIDs.contains(serviceID),
              let session,
              let adapter = adaptersByID[serviceID] else {
            return
        }
        guard !Self.requiresScreenshotAttachment(adapter)
                || Self.hasScreenshotAttachment(sessionAttachments) else {
            return
        }
        let attemptGeneration = nextAttemptGeneration(for: serviceID)
        serviceTasks[serviceID]?.cancel()
        let currentRevision = revision
        let attachments = sessionAttachments
        let context = sessionSourceContext
        replaceResult(
            serviceID: serviceID,
            state: .waiting,
            translatedText: "",
            errorCode: nil,
            errorMessage: nil,
            warnings: [],
            startedAt: nil,
            completedAt: nil,
            diagnostics: nil,
            revision: currentRevision,
            attemptGeneration: attemptGeneration
        )
        launch(
            adapter: adapter,
            session: session,
            context: context,
            attachments: attachments,
            revision: currentRevision,
            attemptGeneration: attemptGeneration
        )
        Self.logger.info(
            "session=\(session.id, privacy: .public) revision=\(currentRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=retry"
        )
    }

    func reorderServices(_ orderedServiceIDs: [String]) {
        guard let current = session else { return }
        let rank = Dictionary(
            uniqueKeysWithValues: orderedServiceIDs.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let originalRank = Dictionary(
            uniqueKeysWithValues: current.results.enumerated().map {
                ($0.element.service.id, $0.offset)
            }
        )
        let reordered = current.results.sorted { lhs, rhs in
            let lhsRank =
                rank[lhs.service.id]
                ?? (orderedServiceIDs.count
                    + (originalRank[lhs.service.id] ?? 0))
            let rhsRank =
                rank[rhs.service.id]
                ?? (orderedServiceIDs.count
                    + (originalRank[rhs.service.id] ?? 0))
            return lhsRank < rhsRank
        }
        guard reordered.map(\.service.id)
                != current.results.map(\.service.id) else {
            return
        }
        submit(
            TranslationSessionSnapshot(
                id: current.id,
                input: current.input,
                direction: current.direction,
                results: reordered,
                isFavorite: current.isFavorite,
                createdAt: current.createdAt,
                updatedAt: Date()
            ),
            revision: revision
        )
        Self.logger.info(
            "session=\(current.id, privacy: .public) revision=\(self.revision, privacy: .public) phase=reorder services=\(orderedServiceIDs.count, privacy: .public)"
        )
    }

    func updateAllowedServiceIDs(_ serviceIDs: [String]) {
        allowedServiceIDs = Set(serviceIDs)
    }

    func cancel(serviceID: String) {
        deferredAttachmentServiceIDs.remove(serviceID)
        guard let current = session,
              let result = current.results.first(where: {
                  $0.service.id == serviceID
              }),
              result.state == .waiting
                  || result.state == .running
                  || result.state == .streaming else {
            return
        }
        let attemptGeneration = nextAttemptGeneration(for: serviceID)
        serviceTasks.removeValue(forKey: serviceID)?.cancel()
        replaceResult(
            serviceID: serviceID,
            state: .cancelled,
            translatedText: result.translatedText,
            errorCode: "cancelled",
            errorMessage: nil,
            warnings: result.warnings,
            startedAt: result.startedAt,
            completedAt: Date(),
            diagnostics: result.diagnostics,
            revision: revision,
            attemptGeneration: attemptGeneration
        )
    }

    func markSessionFavorite(sessionID: String) {
        guard let current = session,
              current.id == sessionID,
              !current.isFavorite else {
            return
        }
        submit(
            TranslationSessionSnapshot(
                id: current.id,
                input: current.input,
                direction: current.direction,
                results: current.results,
                isFavorite: true,
                createdAt: current.createdAt,
                updatedAt: Date()
            ),
            revision: revision
        )
    }

    func cancelCurrent() {
        let currentRevision = revision
        serviceTasks.values.forEach { $0.cancel() }
        serviceTasks.removeAll()
        sessionAttachments.removeAll()
        deferredAttachmentServiceIDs.removeAll()
        allowedServiceIDs.removeAll()
        sessionSourceContext = nil
        guard let current = session else { return }
        let results = current.results.map { result in
            guard result.state == .waiting
                    || result.state == .running
                    || result.state == .streaming else {
                return result
            }
            return TranslationResultSnapshot(
                id: result.id,
                service: result.service,
                state: .cancelled,
                translatedText: result.translatedText,
                errorCode: "cancelled",
                errorMessage: nil,
                warnings: result.warnings,
                startedAt: result.startedAt,
                completedAt: Date(),
                diagnostics: result.diagnostics
            )
        }
        submit(
            TranslationSessionSnapshot(
                id: current.id,
                input: current.input,
                direction: current.direction,
                results: results,
                isFavorite: current.isFavorite,
                createdAt: current.createdAt,
                updatedAt: Date()
            ),
            revision: currentRevision
        )
        revision &+= 1
    }

    private func run(
        adapter: any TranslationServiceAdapter,
        request: TranslationServiceRequest,
        revision requestRevision: UInt64,
        attemptGeneration: UInt64
    ) async {
        let serviceID = adapter.descriptor.id
        defer {
            if isCurrentAttempt(
                serviceID: serviceID,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            ) {
                serviceTasks.removeValue(forKey: serviceID)
            }
        }
        let startedAt = Date()
        Self.logger.debug(
            "session=\(request.sessionID, privacy: .public) revision=\(requestRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=running"
        )
        replaceResult(
            serviceID: serviceID,
            state: .running,
            translatedText: "",
            errorCode: nil,
            errorMessage: nil,
            warnings: [],
            startedAt: startedAt,
            completedAt: nil,
            diagnostics: nil,
            revision: requestRevision,
            attemptGeneration: attemptGeneration
        )

        var sourceFailureRetryable: Bool?
        do {
            if request.direction.source == nil,
               adapter.requiresExplicitSourceLanguage {
                throw TranslationServiceAdapterError.failed(
                    code: "source_language_undetermined",
                    message: L10n.string(
                        "translation.error.sourceLanguageUndetermined"
                    )
                )
            }
            try adapter.validateLanguageDirection(request.direction)
            var latestText = ""
            var completionWarnings: [String] = []
            var runtimeDiagnostics: TranslationResultDiagnostics?
            var sourceStatus: TranslationSourceStatus?
            var detectedSourceLanguage: TranslationLanguageTag?
            var sourceMetadata: [String: JSONValue] = [:]
            var didReceiveCompletion = false
            for try await event in adapter.translate(request) {
                try Task.checkCancellation()
                guard isCurrentAttempt(
                    serviceID: serviceID,
                    revision: requestRevision,
                    attemptGeneration: attemptGeneration
                ) else {
                    return
                }
                switch event {
                case let .partial(text):
                    latestText = text
                    replaceResult(
                        serviceID: serviceID,
                        state: .streaming,
                        translatedText: text,
                        errorCode: nil,
                        errorMessage: nil,
                        warnings: [],
                        startedAt: startedAt,
                        completedAt: nil,
                        diagnostics: runtimeDiagnostics,
                        sourceStatus: sourceStatus,
                        revision: requestRevision,
                        attemptGeneration: attemptGeneration
                    )
                case let .source(sourceEvent):
                    switch sourceEvent {
                    case let .status(status):
                        sourceStatus = status
                        replaceResult(
                            serviceID: serviceID,
                            state: latestText.isEmpty
                                ? .running
                                : .streaming,
                            translatedText: latestText,
                            errorCode: nil,
                            errorMessage: nil,
                            warnings: completionWarnings,
                            startedAt: startedAt,
                            completedAt: nil,
                            diagnostics: runtimeDiagnostics,
                            sourceStatus: status,
                            revision: requestRevision,
                            attemptGeneration: attemptGeneration
                        )
                    case let .diagnostics(diagnostics):
                        runtimeDiagnostics =
                            TranslationResultDiagnostics(
                                auditID: UUID().uuidString,
                                durationMS:
                                    Self.durationMilliseconds(
                                        since: startedAt
                                    ),
                                route: serviceID,
                                status: diagnostics.code
                            )
                        if let message = diagnostics.message,
                           !message.isEmpty {
                            completionWarnings = [message]
                        }
                        replaceResult(
                            serviceID: serviceID,
                            state: latestText.isEmpty
                                ? .running
                                : .streaming,
                            translatedText: latestText,
                            errorCode: nil,
                            errorMessage: nil,
                            warnings: completionWarnings,
                            startedAt: startedAt,
                            completedAt: nil,
                            diagnostics: runtimeDiagnostics,
                            sourceStatus: sourceStatus,
                            revision: requestRevision,
                            attemptGeneration: attemptGeneration
                        )
                    case let .completed(output):
                        latestText = output.text
                        completionWarnings = output.warnings
                        detectedSourceLanguage =
                            output.detectedSourceLanguage
                        sourceMetadata = output.metadata
                        didReceiveCompletion = true
                    case let .failed(failure):
                        sourceFailureRetryable = failure.isRetryable
                        throw TranslationServiceAdapterError.failed(
                            code: failure.code,
                            message: failure.message
                        )
                    }
                case let .diagnostics(diagnostics, warnings):
                    runtimeDiagnostics = diagnostics
                    completionWarnings = warnings
                    replaceResult(
                        serviceID: serviceID,
                        state: latestText.isEmpty ? .running : .streaming,
                        translatedText: latestText,
                        errorCode: nil,
                        errorMessage: nil,
                        warnings: completionWarnings,
                        startedAt: startedAt,
                        completedAt: nil,
                        diagnostics: diagnostics,
                        sourceStatus: sourceStatus,
                        revision: requestRevision,
                        attemptGeneration: attemptGeneration
                    )
                case let .completed(text, warnings, diagnostics):
                    latestText = text
                    runtimeDiagnostics = diagnostics ?? runtimeDiagnostics
                    completionWarnings = warnings
                    didReceiveCompletion = true
                }
            }
            try Task.checkCancellation()
            guard isCurrentAttempt(
                serviceID: serviceID,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            ) else {
                return
            }
            let normalized = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard didReceiveCompletion, !normalized.isEmpty else {
                throw TranslationServiceAdapterError.failed(
                    code: "empty_translation_result",
                    message: L10n.string("translation.error.emptyResult")
                )
            }
            replaceResult(
                serviceID: serviceID,
                state: .succeeded,
                translatedText: normalized,
                errorCode: nil,
                errorMessage: nil,
                warnings: completionWarnings,
                startedAt: startedAt,
                completedAt: Date(),
                diagnostics:
                    runtimeDiagnostics
                    ?? Self.defaultDiagnostics(
                        serviceID: serviceID,
                        status: "succeeded",
                        startedAt: startedAt
                    ),
                sourceStatus: nil,
                detectedSourceLanguage: detectedSourceLanguage,
                sourceMetadata: sourceMetadata,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            )
            Self.logger.info(
                "session=\(request.sessionID, privacy: .public) revision=\(requestRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=succeeded duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
        } catch TranslationServiceAdapterError.publicationRejected {
            guard isCurrentAttempt(
                serviceID: serviceID,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            ) else {
                return
            }
            replaceResult(
                serviceID: serviceID,
                state: .cancelled,
                translatedText: "",
                errorCode:
                    TranslationServiceAdapterError
                        .publicationRejected.errorCode,
                errorMessage: nil,
                warnings: [],
                startedAt: startedAt,
                completedAt: Date(),
                diagnostics: nil,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            )
            Self.logger.debug(
                "session=\(request.sessionID, privacy: .public) revision=\(requestRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=publication-rejected"
            )
        } catch is CancellationError {
            guard isCurrentAttempt(
                serviceID: serviceID,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            ) else {
                return
            }
            replaceResult(
                serviceID: serviceID,
                state: .cancelled,
                translatedText: "",
                errorCode: "cancelled",
                errorMessage: nil,
                warnings: [],
                startedAt: startedAt,
                completedAt: Date(),
                diagnostics: nil,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            )
            Self.logger.debug(
                "session=\(request.sessionID, privacy: .public) revision=\(requestRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=cancelled"
            )
        } catch {
            guard isCurrentAttempt(
                serviceID: serviceID,
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            ) else {
                return
            }
            let adapterError = error as? TranslationServiceAdapterError
            let currentResult = session?.results.first {
                $0.service.id == serviceID
            }
            replaceResult(
                serviceID: serviceID,
                state: .failed,
                translatedText: "",
                errorCode: adapterError?.errorCode ?? "translation_failed",
                errorMessage: TranslationErrorPresentation.message(for: error),
                isRetryable: sourceFailureRetryable,
                warnings: currentResult?.warnings ?? [],
                startedAt: startedAt,
                completedAt: Date(),
                diagnostics:
                    currentResult?.diagnostics
                    ?? Self.defaultDiagnostics(
                        serviceID: serviceID,
                        status:
                            adapterError?.errorCode
                            ?? "translation_failed",
                        startedAt: startedAt
                    ),
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            )
            Self.logger.error(
                "session=\(request.sessionID, privacy: .public) revision=\(requestRevision, privacy: .public) service=\(serviceID, privacy: .public) attempt=\(attemptGeneration, privacy: .public) phase=failed code=\(adapterError?.errorCode ?? "translation_failed", privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
        }
    }

    private func launch(
        adapter: any TranslationServiceAdapter,
        session: TranslationSessionSnapshot,
        context: TranslationSourceContext?,
        attachments: [TranslationSourceAttachmentPayload],
        revision requestRevision: UInt64,
        attemptGeneration: UInt64
    ) {
        let serviceID = adapter.descriptor.id
        guard allowedServiceIDs.contains(serviceID) else {
            return
        }
        serviceTasks[serviceID] = Task { [weak self] in
            await self?.run(
                adapter: adapter,
                request: TranslationServiceRequest(
                    sessionID: session.id,
                    input: session.input,
                    direction: session.direction,
                    context: context,
                    attachments: attachments
                ),
                revision: requestRevision,
                attemptGeneration: attemptGeneration
            )
        }
    }

    private static func requiresScreenshotAttachment(
        _ adapter: any TranslationServiceAdapter
    ) -> Bool {
        adapter.acceptedInputs.contains(.screenshotImage)
    }

    private static func hasScreenshotAttachment(
        _ attachments: [TranslationSourceAttachmentPayload]
    ) -> Bool {
        attachments.contains {
            $0.descriptor.kind == .screenshotImage
        }
    }

    private static func defaultDiagnostics(
        serviceID: String,
        status: String,
        startedAt: Date
    ) -> TranslationResultDiagnostics {
        TranslationResultDiagnostics(
            auditID: UUID().uuidString,
            durationMS: durationMilliseconds(since: startedAt),
            route: serviceID,
            status: status
        )
    }

    private static func durationMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private func replaceResult(
        serviceID: String,
        state: TranslationResultState,
        translatedText: String,
        errorCode: String?,
        errorMessage: String?,
        isRetryable: Bool? = nil,
        warnings: [String],
        startedAt: Date?,
        completedAt: Date?,
        diagnostics: TranslationResultDiagnostics?,
        sourceStatus: TranslationSourceStatus? = nil,
        detectedSourceLanguage: TranslationLanguageTag? = nil,
        sourceMetadata: [String: JSONValue] = [:],
        revision requestRevision: UInt64,
        attemptGeneration: UInt64
    ) {
        guard isCurrentAttempt(
            serviceID: serviceID,
            revision: requestRevision,
            attemptGeneration: attemptGeneration
        ),
        let current = session else {
            return
        }
        let results = current.results.map { result in
            guard result.service.id == serviceID else { return result }
            return TranslationResultSnapshot(
                id: result.id,
                service: result.service,
                state: state,
                translatedText: translatedText,
                errorCode: errorCode,
                errorMessage: errorMessage,
                isRetryable: isRetryable,
                warnings: warnings,
                startedAt: startedAt,
                completedAt: completedAt,
                diagnostics: diagnostics,
                sourceStatus: sourceStatus,
                detectedSourceLanguage: detectedSourceLanguage,
                sourceMetadata: sourceMetadata
            )
        }
        submit(
            TranslationSessionSnapshot(
                id: current.id,
                input: current.input,
                direction: current.direction,
                results: results,
                isFavorite: current.isFavorite,
                createdAt: current.createdAt,
                updatedAt: Date()
            ),
            revision: requestRevision
        )
    }

    private func submit(
        _ snapshot: TranslationSessionSnapshot,
        revision requestRevision: UInt64
    ) {
        guard revision == requestRevision else { return }
        session = snapshot
        updateHandler?(snapshot)
    }

    private func cancelTasks(incrementRevision: Bool) {
        serviceTasks.values.forEach { $0.cancel() }
        serviceTasks.removeAll()
        sessionAttachments.removeAll()
        allowedServiceIDs.removeAll()
        if incrementRevision {
            revision &+= 1
        }
    }

    private func nextAttemptGeneration(for serviceID: String) -> UInt64 {
        let next = (serviceAttemptGenerations[serviceID] ?? 0) &+ 1
        serviceAttemptGenerations[serviceID] = next
        return next
    }

    private func isCurrentAttempt(
        serviceID: String,
        revision requestRevision: UInt64,
        attemptGeneration: UInt64
    ) -> Bool {
        revision == requestRevision
            && serviceAttemptGenerations[serviceID] == attemptGeneration
    }

}
