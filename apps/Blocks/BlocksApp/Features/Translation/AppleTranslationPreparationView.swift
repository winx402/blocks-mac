import BlocksCore
import Foundation
import NaturalLanguage
import OSLog
import SwiftUI

#if canImport(Translation)
import Translation
#endif

@MainActor
final class AppleTranslationSystemInteractionGuard:
    ObservableObject
{
    static let shared = AppleTranslationSystemInteractionGuard()

    @Published private(set) var isActive = false
    private var activeRequestIDs: Set<UUID> = []

    private init() {}

    func begin(_ requestID: UUID) {
        activeRequestIDs.insert(requestID)
        isActive = !activeRequestIDs.isEmpty
    }

    func end(_ requestID: UUID) {
        activeRequestIDs.remove(requestID)
        isActive = !activeRequestIDs.isEmpty
    }
}

@MainActor
final class AppleTranslationPreparationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case awaitingSystemConfirmation
        case installing
        case verifying
        case failed(String)
    }

    struct Request: Identifiable {
        let id = UUID()
        let source: TranslationLanguageTag
        let target: TranslationLanguageTag
        let completion: @MainActor (Result<Void, Error>) -> Void
    }

    @Published fileprivate var request: Request?
    @Published private(set) var phase: Phase = .idle

    var isPreparing: Bool {
        request != nil
    }

    func prepare(
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard #available(macOS 15.0, *) else {
            completion(.failure(
                TranslationServiceAdapterError.unavailable(
                    code: "apple_translation_requires_macos_15",
                    message: L10n.string("translation.error.appleRequiresMacOS15")
                )
            ))
            return
        }
        let source: TranslationLanguageTag?
        if let explicit = direction.source {
            source = explicit
        } else if let detected = NLLanguageRecognizer.dominantLanguage(for: input.text) {
            source = TranslationLanguageTag(detected.rawValue)
        } else {
            source = nil
        }
        guard let source else {
            completion(.failure(
                TranslationServiceAdapterError.failed(
                    code: "source_language_undetermined",
                    message: L10n.string("translation.error.sourceLanguageUndetermined")
                )
            ))
            return
        }
        prepare(
            source: source,
            target: direction.target,
            completion: completion
        )
    }

    func prepare(
        source: TranslationLanguageTag,
        target: TranslationLanguageTag,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        cancel()
        guard #available(macOS 15.0, *) else {
            completion(.failure(
                TranslationServiceAdapterError.unavailable(
                    code: "apple_translation_requires_macos_15",
                    message: L10n.string(
                        "translation.error.appleRequiresMacOS15"
                    )
                )
            ))
            return
        }
        let pending = Request(
            source: source,
            target: target,
            completion: completion
        )
        phase = .awaitingSystemConfirmation
        request = pending
        AppleTranslationSystemInteractionGuard.shared.begin(pending.id)
    }

    func cancel() {
        guard let pending = request else { return }
        request = nil
        phase = .idle
        AppleTranslationSystemInteractionGuard.shared.end(pending.id)
        pending.completion(.failure(CancellationError()))
    }

    fileprivate func markInstalling(requestID: UUID) {
        guard request?.id == requestID else { return }
        phase = .installing
    }

    fileprivate func markVerifying(requestID: UUID) {
        guard request?.id == requestID else { return }
        phase = .verifying
    }

    fileprivate func finish(
        requestID: UUID,
        result: Result<Void, Error>
    ) {
        guard let pending = request, pending.id == requestID else {
            return
        }
        request = nil
        AppleTranslationSystemInteractionGuard.shared.end(requestID)
        switch result {
        case .success:
            phase = .idle
        case let .failure(error):
            phase = .failed(
                TranslationErrorPresentation.message(for: error)
            )
        }
        pending.completion(result)
    }
}

struct AppleTranslationLanguagePair:
    Identifiable,
    Hashable
{
    let source: TranslationLanguageTag
    let target: TranslationLanguageTag

    var id: String {
        "\(source.rawValue)→\(target.rawValue)"
    }
}

enum AppleTranslationLanguagePairResolver {
    static func directedPairs(
        for preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> [AppleTranslationLanguagePair] {
        preferences.focusLanguages.flatMap { focusLanguage in
            [
                AppleTranslationLanguagePair(
                    source: preferences.nativeLanguage,
                    target: focusLanguage
                ),
                AppleTranslationLanguagePair(
                    source: focusLanguage,
                    target: preferences.nativeLanguage
                ),
            ]
        }
    }
}

enum AppleTranslationPairAvailability: Equatable {
    case installed
    case downloadable
    case unsupported
}

/// The shared source of truth for directed Apple Translation language-pair
/// availability. The framework can transiently report `.supported` during a
/// cold start even when a pair is already installed, so callers receive a
/// bounded recheck before a download is offered.
@MainActor
final class AppleTranslationAvailabilityCoordinator {
    static let shared = AppleTranslationAvailabilityCoordinator()

    typealias AvailabilityQuery = @MainActor @Sendable (
        AppleTranslationLanguagePair,
        Bool
    ) async -> AppleTranslationPairAvailability

    private struct PendingQuery {
        let id: UUID
        let task: Task<AppleTranslationPairAvailability, Never>
    }

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "AppleTranslationAvailability"
    )

    private var installedPairs: Set<AppleTranslationLanguagePair> = []
    private var pendingQueries:
        [AppleTranslationLanguagePair: PendingQuery] = [:]
    private let availabilityQuery: AvailabilityQuery

    init(availabilityQuery: AvailabilityQuery? = nil) {
        self.availabilityQuery = availabilityQuery ?? { pair, recheck in
            guard #available(macOS 15.0, *) else {
                return .unsupported
            }
            return await Self.queryAvailability(
                pair: pair,
                coldStartRecheck: recheck
            )
        }
    }

    func availability(
        for pair: AppleTranslationLanguagePair,
        coldStartRecheck: Bool = true
    ) async -> AppleTranslationPairAvailability {
        guard #available(macOS 15.0, *) else {
            return .unsupported
        }
        if installedPairs.contains(pair) {
            return .installed
        }
        if let pending = pendingQueries[pair] {
            return await pending.task.value
        }

        let queryID = UUID()
        let startedAt = ContinuousClock.now
        let availabilityQuery = availabilityQuery
        let task = Task {
            await availabilityQuery(pair, coldStartRecheck)
        }
        pendingQueries[pair] = PendingQuery(id: queryID, task: task)
        let result = await task.value
        if pendingQueries[pair]?.id == queryID {
            pendingQueries[pair] = nil
        }
        if result == .installed {
            installedPairs.insert(pair)
        }
        Self.logger.info(
            "event=resolved pair=\(pair.id, privacy: .public) result=\(String(describing: result), privacy: .public) coldRecheck=\(coldStartRecheck, privacy: .public) durationMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
        return result
    }

    func invalidate(_ pair: AppleTranslationLanguagePair) {
        installedPairs.remove(pair)
        pendingQueries[pair]?.task.cancel()
        pendingQueries[pair] = nil
    }

    func markInstalled(_ pair: AppleTranslationLanguagePair) {
        pendingQueries[pair]?.task.cancel()
        pendingQueries[pair] = nil
        installedPairs.insert(pair)
    }

    @available(macOS 15.0, *)
    private static func queryAvailability(
        pair: AppleTranslationLanguagePair,
        coldStartRecheck: Bool
    ) async -> AppleTranslationPairAvailability {
        #if canImport(Translation)
        let source = Locale.Language(identifier: pair.source.rawValue)
        let target = Locale.Language(identifier: pair.target.rawValue)
        let availability = LanguageAvailability()
        let initial = await availability.status(from: source, to: target)
        switch initial {
        case .installed:
            return .installed
        case .unsupported:
            return .unsupported
        case .supported:
            guard coldStartRecheck else {
                return .downloadable
            }
        @unknown default:
            return .unsupported
        }

        for delay in [Duration.milliseconds(220), .milliseconds(520)] {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return .downloadable
            }
            let rechecked = await availability.status(
                from: source,
                to: target
            )
            switch rechecked {
            case .installed:
                return .installed
            case .unsupported:
                return .unsupported
            case .supported:
                continue
            @unknown default:
                return .unsupported
            }
        }
        return .downloadable
        #else
        return .unsupported
        #endif
    }

    private static func elapsedMilliseconds(
        since startedAt: ContinuousClock.Instant
    ) -> Int {
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        return max(
            0,
            Int(
                Double(components.seconds) * 1_000
                    + Double(components.attoseconds)
                        / 1_000_000_000_000_000
            )
        )
    }
}

enum AppleTranslationLanguagePackState: Equatable {
    case checking
    case installed
    case downloadable
    case unsupported
    case awaitingSystemConfirmation
    case installing
    case verifying
    case failed(String)
}

@MainActor
final class AppleTranslationLanguagePackController:
    ObservableObject
{
    static let shared = AppleTranslationLanguagePackController()

    @Published private(set) var states:
        [AppleTranslationLanguagePair: AppleTranslationLanguagePackState] = [:]
    @Published private(set) var activePair: AppleTranslationLanguagePair?

    let preparationController = AppleTranslationPreparationController()
    private let availabilityCoordinator:
        AppleTranslationAvailabilityCoordinator
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    init(
        availabilityCoordinator:
            AppleTranslationAvailabilityCoordinator? = nil
    ) {
        self.availabilityCoordinator =
            availabilityCoordinator
            ?? AppleTranslationAvailabilityCoordinator.shared
    }

    func refresh(
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) {
        let pairs = AppleTranslationLanguagePairResolver.directedPairs(
            for: preferences
        )
        refreshGeneration &+= 1
        let generation = refreshGeneration
        states = Dictionary(
            uniqueKeysWithValues: pairs.map { ($0, .checking) }
        )
        guard #available(macOS 15.0, *) else {
            states = Dictionary(
                uniqueKeysWithValues: pairs.map { ($0, .unsupported) }
            )
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var resolved:
                [AppleTranslationLanguagePair: AppleTranslationLanguagePackState] = [:]
            for pair in pairs {
                guard !Task.isCancelled else { return }
                let status = await availabilityCoordinator.availability(
                    for: pair
                )
                switch status {
                case .installed:
                    resolved[pair] = .installed
                case .downloadable:
                    resolved[pair] = .downloadable
                case .unsupported:
                    resolved[pair] = .unsupported
                }
            }
            guard generation == refreshGeneration else {
                return
            }
            states = resolved
        }
    }

    func prepare(
        _ pair: AppleTranslationLanguagePair,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) {
        guard activePair == nil else { return }
        activePair = pair
        states[pair] = .awaitingSystemConfirmation
        preparationController.prepare(
            source: pair.source,
            target: pair.target
        ) { [weak self] result in
            guard let self, activePair == pair else { return }
            activePair = nil
            switch result {
            case .success:
                availabilityCoordinator.markInstalled(pair)
                states[pair] = .installed
                refresh(preferences: preferences)
            case let .failure(error) where error is CancellationError:
                refresh(preferences: preferences)
            case let .failure(error):
                states[pair] = .failed(
                    TranslationErrorPresentation.message(for: error)
                )
            }
        }
    }

    func synchronizePreparationPhase() {
        guard let activePair else { return }
        switch preparationController.phase {
        case .idle:
            break
        case .awaitingSystemConfirmation:
            states[activePair] = .awaitingSystemConfirmation
        case .installing:
            states[activePair] = .installing
        case .verifying:
            states[activePair] = .verifying
        case let .failed(message):
            states[activePair] = .failed(message)
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        preparationController.cancel()
        activePair = nil
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

/// Bridges the view-scoped Translation framework API on macOS 15–25 into the
/// service adapter without creating a second translation runtime.
@MainActor
final class AppleTranslationRuntimeController: ObservableObject {
    fileprivate struct Request: Identifiable {
        let id: UUID
        let text: String
        let source: TranslationLanguageTag
        let target: TranslationLanguageTag
        let availability: AppleTranslationPairAvailability
        let continuation: CheckedContinuation<String, Error>
    }

    @Published fileprivate var currentRequest: Request?
    private var queuedRequests: [Request] = []

    func translate(
        text: String,
        source: TranslationLanguageTag,
        target: TranslationLanguageTag,
        availability: AppleTranslationPairAvailability = .installed
    ) async throws -> String {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = Request(
                    id: requestID,
                    text: text,
                    source: source,
                    target: target,
                    availability: availability,
                    continuation: continuation
                )
                if currentRequest == nil {
                    currentRequest = request
                } else {
                    queuedRequests.append(request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    fileprivate func finish(
        requestID: UUID,
        result: Result<String, Error>
    ) {
        guard let request = currentRequest, request.id == requestID else { return }
        currentRequest = nil
        request.continuation.resume(with: result)
        if !queuedRequests.isEmpty {
            currentRequest = queuedRequests.removeFirst()
        }
    }

    func cancel(requestID: UUID) {
        if let request = currentRequest, request.id == requestID {
            currentRequest = nil
            request.continuation.resume(throwing: CancellationError())
            if !queuedRequests.isEmpty {
                currentRequest = queuedRequests.removeFirst()
            }
            return
        }
        guard let index = queuedRequests.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let request = queuedRequests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }

    func cancelAll() {
        let requests = [currentRequest].compactMap { $0 } + queuedRequests
        currentRequest = nil
        queuedRequests.removeAll()
        requests.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }
}

struct AppleTranslationPreparationHost: View {
    @ObservedObject var controller: AppleTranslationPreparationController

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                AppleTranslationPreparationTaskHost(controller: controller)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct AppleTranslationRuntimeHost: View {
    @ObservedObject var controller: AppleTranslationRuntimeController

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                AppleTranslationRuntimeTaskHost(controller: controller)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTranslationPreparationTaskHost: View {
    @ObservedObject var controller: AppleTranslationPreparationController
    @State private var configuration: TranslationSession.Configuration?
    @State private var activeRequestID: UUID?

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                guard let request = controller.request,
                      request.id == activeRequestID else {
                    return
                }
                do {
                    await MainActor.run {
                        controller.markInstalling(
                            requestID: request.id
                        )
                    }
                    try await session.prepareTranslation()
                    await MainActor.run {
                        controller.markVerifying(
                            requestID: request.id
                        )
                    }
                    if #available(macOS 26.0, *) {
                        guard await session.isReady else {
                            throw TranslationServiceAdapterError.failed(
                                code: "apple_language_not_ready",
                                message: L10n.string(
                                    "translation.error.appleLanguageNotReady"
                                )
                            )
                        }
                    }
                    await MainActor.run {
                        controller.finish(
                            requestID: request.id,
                            result: .success(())
                        )
                    }
                } catch {
                    await MainActor.run {
                        controller.finish(
                            requestID: request.id,
                            result: .failure(
                                AppleTranslationFailureClassifier.classify(
                                    error,
                                    phase: .preparation
                                )
                            )
                        )
                    }
                }
            }
            .onChange(of: controller.request?.id) { _, requestID in
                guard let request = controller.request, requestID == request.id else {
                    activeRequestID = nil
                    configuration = nil
                    return
                }
                activeRequestID = request.id
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: request.source.rawValue),
                    target: Locale.Language(identifier: request.target.rawValue)
                )
            }
            .onDisappear {
                controller.cancel()
                activeRequestID = nil
                configuration = nil
            }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationRuntimeTaskHost: View {
    @ObservedObject var controller: AppleTranslationRuntimeController
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .id(controller.currentRequest?.id)
            .translationTask(configuration) { session in
                guard let request = controller.currentRequest else { return }
                do {
                    if #available(macOS 26.0, *),
                       let readinessFailure =
                        AppleTranslationReadinessPolicy.failure(
                            availability: request.availability,
                            sessionIsReady: await session.isReady
                        ) {
                        throw readinessFailure
                    }
                    let response = try await session.translate(request.text)
                    await MainActor.run {
                        controller.finish(
                            requestID: request.id,
                            result: .success(response.targetText)
                        )
                    }
                } catch {
                    await MainActor.run {
                        controller.finish(
                            requestID: request.id,
                            result: .failure(error)
                        )
                    }
                }
            }
            .onChange(of: controller.currentRequest?.id, initial: true) { _, _ in
                guard let request = controller.currentRequest else {
                    configuration = nil
                    return
                }
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: request.source.rawValue),
                    target: Locale.Language(identifier: request.target.rawValue)
                )
            }
    }
}
#endif
