import BlocksCore
import CryptoKit
import Foundation

struct TranslationServiceTemplateDescriptor: Identifiable, Equatable {
    enum CostKind: String {
        case localFree
        case freeTier
        case selfHosted
        case mayBill
    }

    struct Field: Identifiable, Equatable {
        enum Kind: Equatable {
            case text
            case url
            case secret
            case choice([String])
        }

        let id: String
        let kind: Kind
        let required: Bool
        let defaultValue: String?
    }

    let id: TranslationServiceTemplateID
    let displayNameLocalizationKey: String
    let costKinds: [CostKind]
    let dataRecipientLocalizationKey: String
    let documentationURL: URL
    let verifiedOn: String
    let fields: [Field]

    var displayName: String {
        L10n.string(displayNameLocalizationKey)
    }

    var transmitsDataTo: String {
        L10n.string(dataRecipientLocalizationKey)
    }
}

enum TranslationServiceTemplateCatalog {
    static let externalTemplates: [TranslationServiceTemplateDescriptor] = [
        .init(
            id: .deepLFree,
            displayNameLocalizationKey:
                "translation.services.template.deepl",
            costKinds: [.freeTier],
            dataRecipientLocalizationKey:
                "translation.services.recipient.deepl",
            documentationURL: URL(
                string: "https://developers.deepl.com/docs/getting-started/auth"
            )!,
            verifiedOn: "2026-07-27",
            fields: [
                .init(
                    id: "auth_key",
                    kind: .secret,
                    required: true,
                    defaultValue: nil
                ),
            ]
        ),
        .init(
            id: .microsoftTranslator,
            displayNameLocalizationKey:
                "translation.services.template.microsoft",
            costKinds: [.freeTier, .mayBill],
            dataRecipientLocalizationKey:
                "translation.services.recipient.microsoft",
            documentationURL: URL(
                string:
                    "https://learn.microsoft.com/en-us/azure/ai-services/translator/text-translation/reference/authentication"
            )!,
            verifiedOn: "2026-07-27",
            fields: [
                .init(
                    id: "subscription_key",
                    kind: .secret,
                    required: true,
                    defaultValue: nil
                ),
                .init(
                    id: "region",
                    kind: .text,
                    required: false,
                    defaultValue: nil
                ),
            ]
        ),
        .init(
            id: .googleCloudBasic,
            displayNameLocalizationKey:
                "translation.services.template.google",
            costKinds: [.freeTier, .mayBill],
            dataRecipientLocalizationKey:
                "translation.services.recipient.google",
            documentationURL: URL(
                string:
                    "https://cloud.google.com/translate/docs/authentication"
            )!,
            verifiedOn: "2026-07-27",
            fields: [
                .init(
                    id: "api_key",
                    kind: .secret,
                    required: true,
                    defaultValue: nil
                ),
            ]
        ),
        .init(
            id: .alibabaMachineTranslation,
            displayNameLocalizationKey:
                "translation.services.template.alibaba",
            costKinds: [.freeTier, .mayBill],
            dataRecipientLocalizationKey:
                "translation.services.recipient.alibaba",
            documentationURL: URL(
                string:
                    "https://help.aliyun.com/zh/machine-translation/product-overview/billing-overview"
            )!,
            verifiedOn: "2026-07-27",
            fields: [
                .init(
                    id: "access_key_id",
                    kind: .secret,
                    required: true,
                    defaultValue: nil
                ),
                .init(
                    id: "access_key_secret",
                    kind: .secret,
                    required: true,
                    defaultValue: nil
                ),
                .init(
                    id: "region",
                    kind: .choice(
                        AlibabaMachineTranslationRegion.allCases.map(
                            \.rawValue
                        )
                    ),
                    required: true,
                    defaultValue: "cn-hangzhou"
                ),
            ]
        ),
        .init(
            id: .libreTranslate,
            displayNameLocalizationKey:
                "translation.services.template.libre",
            costKinds: [.selfHosted],
            dataRecipientLocalizationKey:
                "translation.services.recipient.libre",
            documentationURL: URL(
                string: "https://docs.libretranslate.com/guides/api_usage/"
            )!,
            verifiedOn: "2026-07-27",
            fields: [
                .init(
                    id: "base_url",
                    kind: .url,
                    required: true,
                    defaultValue: "https://libretranslate.com"
                ),
                .init(
                    id: "api_key",
                    kind: .secret,
                    required: false,
                    defaultValue: nil
                ),
            ]
        ),
    ]

    static func descriptor(
        for templateID: TranslationServiceTemplateID
    ) -> TranslationServiceTemplateDescriptor? {
        externalTemplates.first { $0.id == templateID }
    }

    static func credentialFieldIDs(
        for templateID: TranslationServiceTemplateID,
        requiredOnly: Bool = false
    ) -> [String] {
        descriptor(for: templateID)?.fields.compactMap {
            if case .secret = $0.kind,
               !requiredOnly || $0.required {
                return $0.id
            }
            return nil
        } ?? []
    }

    static func supportedLanguages(
        for templateID: TranslationServiceTemplateID
    ) -> [TranslationLanguageTag] {
        let supportedPrimaryCodes: Set<String>?
        switch templateID {
        case .deepLFree:
            supportedPrimaryCodes = [
                "ar", "bg", "cs", "da", "de", "el", "en", "es", "et",
                "fi", "fr", "he", "hu", "id", "it", "ja", "ko", "lt",
                "lv", "nb", "nl", "no", "pl", "pt", "ro", "ru", "sk",
                "sl", "sv", "th", "tr", "uk", "vi", "zh",
            ]
        case .alibabaMachineTranslation:
            supportedPrimaryCodes = [
                "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja",
                "ko", "pt", "ru", "th", "tr", "vi", "zh",
            ]
        case .microsoftTranslator,
             .googleCloudBasic:
            supportedPrimaryCodes = nil
        case .libreTranslate:
            // Each self-hosted instance can install a different model set.
            // Connection validation discovers `/languages` and supplies an
            // instance-specific capability override.
            return []
        case .appleLocal, .openAICompatible:
            return []
        }
        guard let supportedPrimaryCodes else {
            return TranslationLanguagePreferences.commonOptions
        }
        return TranslationLanguagePreferences.commonOptions.filter {
            let primary = $0.rawValue.lowercased()
                .split(separator: "-")
                .first
                .map(String.init) ?? ""
            return supportedPrimaryCodes.contains(primary)
        }
    }
}

protocol TranslationOfficialHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTranslationOfficialHTTPTransport:
    TranslationOfficialHTTPTransport
{
    typealias AddressResolver = @Sendable (
        _ host: String
    ) async throws -> [BlocksNativePluginResolvedAddress]
    typealias PinnedTransport = @Sendable (
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse

    private static let maximumResponseBytes = 2 * 1_048_576
    private let addressResolver: AddressResolver
    private let pinnedTransport: PinnedTransport

    init(
        addressResolver: @escaping AddressResolver = {
            try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0)
        },
        pinnedTransport: @escaping PinnedTransport = {
            try await BlocksNativePluginPinnedHTTPTransport.perform($0)
        }
    ) {
        self.addressResolver = addressResolver
        self.pinnedTransport = pinnedTransport
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              let host = url.host?.lowercased() else {
            throw TranslationOfficialAdapterError.invalidBaseURL
        }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw TranslationOfficialAdapterError.insecureBaseURL
        }
        let explicitPort: Int?
        do {
            explicitPort = try LibreTranslateBaseURLPolicy
                .validatedExplicitPort(in: url)
        } catch {
            throw TranslationOfficialAdapterError.invalidBaseURL
        }
        let port = explicitPort ?? (scheme == "http" ? 80 : 443)
        if scheme == "http" {
            guard host == "127.0.0.1" || host == "::1" else {
                throw TranslationOfficialAdapterError.insecureBaseURL
            }
            return try await TranslationBoundedURLSessionClient(
                maximumResponseBytes: Self.maximumResponseBytes
            ).data(for: request)
        }
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: request.timeoutInterval
        )
        let addresses = try await deadline.run { [addressResolver] in
            try await addressResolver(host)
        }
        try BlocksNativePluginResolvedAddressPolicy.validate(
            addresses,
            host: host
        )
        let method = BlocksNativePluginHTTPMethod(
            rawValue: request.httpMethod ?? "GET"
        ) ?? .get
        let pluginRequest = BlocksNativePluginNetworkRequest(
            url: url.absoluteString,
            method: method,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeoutSeconds: min(
                request.timeoutInterval,
                try deadline.remainingSeconds()
            )
        )
        let pinnedRequest = BlocksNativePluginPinnedHTTPRequest(
            request: pluginRequest,
            url: url,
            originalHost: host,
            port: UInt16(port),
            addresses: addresses,
            deadline: deadline
        )
        let pinned = try await deadline.run { [pinnedTransport] in
            try await pinnedTransport(pinnedRequest)
        }
        guard pinned.body.count <= Self.maximumResponseBytes else {
            throw TranslationOfficialAdapterError.responseTooLarge
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: pinned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: pinned.headers
        ) else {
            throw TranslationOfficialAdapterError.invalidResponse
        }
        return (pinned.body, response)
    }
}

final class TranslationBoundedURLSessionClient:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    typealias WatchdogSleeper = @Sendable (Duration) async throws -> Void
    typealias DeadlineHasElapsed = @Sendable (
        ContinuousClock.Instant
    ) -> Bool
    typealias RedirectDeniedObserver = @Sendable () -> Void

    private let maximumResponseBytes: Int
    private let sessionConfiguration: URLSessionConfiguration
    private let watchdogSleeper: WatchdogSleeper
    private let deadlineHasElapsed: DeadlineHasElapsed
    private let redirectDeniedObserver: RedirectDeniedObserver
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var watchdogTask: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var isFinished = false

    init(
        maximumResponseBytes: Int,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        watchdogSleeper: @escaping WatchdogSleeper = {
            try await Task.sleep(for: $0)
        },
        deadlineHasElapsed: @escaping DeadlineHasElapsed = {
            ContinuousClock.now >= $0
        },
        redirectDeniedObserver: @escaping RedirectDeniedObserver = {}
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.sessionConfiguration = sessionConfiguration
        self.watchdogSleeper = watchdogSleeper
        self.deadlineHasElapsed = deadlineHasElapsed
        self.redirectDeniedObserver = redirectDeniedObserver
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let timeoutInterval = request.timeoutInterval
        guard timeoutInterval.isFinite, timeoutInterval > 0 else {
            throw BlocksNativePluginNetworkBrokerError.transport(
                "The request timeout configuration is invalid."
            )
        }
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(timeoutInterval)
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    (Data, HTTPURLResponse),
                    Error
                >) in
                lock.lock()
                guard !isFinished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.deadline = deadline
                let configuration = sessionConfiguration
                configuration.requestCachePolicy =
                    .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = request.timeoutInterval
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let dataTask = session.dataTask(with: request)
                self.session = session
                self.dataTask = dataTask
                let watchdogSleeper = watchdogSleeper
                self.watchdogTask = Task { [weak self, watchdogSleeper] in
                    do {
                        try await watchdogSleeper(.seconds(timeoutInterval))
                    } catch {
                        return
                    }
                    self?.finish(
                        .failure(
                            BlocksNativePluginNetworkBrokerError.transport(
                                "The request timed out."
                            )
                        )
                    )
                }
                lock.unlock()
                if Task.isCancelled {
                    cancel()
                } else {
                    dataTask.resume()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        redirectDeniedObserver()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(.failure(TranslationOfficialAdapterError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength
            > Int64(maximumResponseBytes) {
            finish(
                .failure(TranslationOfficialAdapterError.responseTooLarge)
            )
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = httpResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        guard chunk.count <= maximumResponseBytes - data.count else {
            lock.unlock()
            finish(
                .failure(TranslationOfficialAdapterError.responseTooLarge)
            )
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as? URLError)?.code == .timedOut {
                finish(
                    .failure(
                        BlocksNativePluginNetworkBrokerError.transport(
                            "The request timed out."
                        )
                    )
                )
                return
            }
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = response
        let data = data
        lock.unlock()
        guard let response else {
            finish(.failure(TranslationOfficialAdapterError.invalidResponse))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(
        _ result: Result<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let finalResult: Result<(Data, HTTPURLResponse), Error>
        if case .success = result,
           let deadline,
           deadlineHasElapsed(deadline) {
            finalResult = .failure(
                BlocksNativePluginNetworkBrokerError.transport(
                    "The request timed out."
                )
            )
        } else {
            finalResult = result
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        let dataTask = dataTask
        self.dataTask = nil
        let watchdogTask = watchdogTask
        self.watchdogTask = nil
        self.deadline = nil
        lock.unlock()
        watchdogTask?.cancel()
        dataTask?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: finalResult)
    }

    private func cancel() {
        lock.lock()
        let dataTask = dataTask
        lock.unlock()
        dataTask?.cancel()
        finish(.failure(CancellationError()))
    }
}

enum TranslationOfficialAdapterError: Error, LocalizedError, Equatable {
    case unsupportedTemplate
    case missingConfiguration(String)
    case invalidConfiguration(String)
    case invalidBaseURL
    case insecureBaseURL
    case privateNetworkDenied
    case inputTooLarge
    case unsupportedLanguage(String)
    case noSupportedLanguagePair
    case httpStatus(Int)
    case invalidResponse
    case responseLanguageMismatch
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedTemplate:
            "This translation service template is not supported."
        case let .missingConfiguration(field):
            "Translation service configuration is missing: \(field)."
        case let .invalidConfiguration(field):
            "Translation service configuration is invalid: \(field)."
        case .invalidBaseURL:
            "The translation service URL is invalid."
        case .insecureBaseURL:
            "The translation service URL must use HTTPS."
        case .privateNetworkDenied:
            "Only HTTPS public servers or an explicit loopback LibreTranslate server are allowed."
        case .inputTooLarge:
            "The source text exceeds this translation service limit."
        case let .unsupportedLanguage(language):
            "The translation service does not support this language identifier: \(language)."
        case .noSupportedLanguagePair:
            "The LibreTranslate instance did not report a usable language pair."
        case let .httpStatus(status):
            "The translation service returned HTTP \(status)."
        case .invalidResponse:
            "The translation service returned an invalid response."
        case .responseLanguageMismatch:
            L10n.string(
                "translation.community.error.responseLanguageMismatch"
            )
        case .responseTooLarge:
            "The translation service response exceeds the allowed size."
        }
    }
}

struct LibreTranslateCapabilitySnapshot:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion = 1
    static let maximumLanguageCount = 256
    static let maximumEdgeCount = 16_384
    static let maximumEncodedBytes = 512 * 1_024

    struct Language: Codable, Equatable, Hashable, Sendable {
        let rawCode: String
        let tag: TranslationLanguageTag
    }

    struct Entry: Codable, Equatable, Sendable {
        let source: Language
        let targets: [Language]
    }

    struct ValidationProbe: Equatable, Sendable {
        let source: Language
        let target: Language
        let text: String

        var direction: TranslationLanguageDirection {
            TranslationLanguageDirection(
                source: source.tag,
                target: target.tag
            )
        }
    }

    let schemaVersion: Int
    let profileID: String
    let profileRevision: Double
    let fetchedAt: Date
    let entries: [Entry]

    var supportedSourceLanguages: [TranslationLanguageTag] {
        TranslationLanguagePreferences.sortedOptions(
            entries.map(\.source.tag)
        )
    }

    var supportedTargetLanguages: [TranslationLanguageTag] {
        TranslationLanguagePreferences.sortedOptions(
            entries.flatMap { $0.targets.map(\.tag) }
        )
    }

    func validated(
        for profile: TranslationServiceProfile
    ) throws -> LibreTranslateCapabilitySnapshot {
        guard schemaVersion == Self.currentSchemaVersion,
              profile.templateID == .libreTranslate,
              profileID == profile.id,
              abs(
                  profileRevision
                    - profile.updatedAt.timeIntervalSince1970
              ) < 0.000_001,
              !entries.isEmpty,
              entries.count <= Self.maximumLanguageCount else {
            throw TranslationOfficialAdapterError.invalidResponse
        }
        var edgeCount = 0
        var sourceCodes: Set<String> = []
        for entry in entries {
            guard Self.isValidRawCode(entry.source.rawCode),
                  sourceCodes.insert(entry.source.rawCode).inserted,
                  !entry.targets.isEmpty else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            var targetCodes: Set<String> = []
            for target in entry.targets {
                guard Self.isValidRawCode(target.rawCode),
                      targetCodes.insert(target.rawCode).inserted else {
                    throw TranslationOfficialAdapterError.invalidResponse
                }
                edgeCount += 1
                guard edgeCount <= Self.maximumEdgeCount else {
                    throw TranslationOfficialAdapterError.responseTooLarge
                }
            }
        }
        return self
    }

    func serverCodes(
        for direction: TranslationLanguageDirection
    ) throws -> (source: String?, target: String) {
        if let sourceTag = direction.source {
            for entry in entries.sorted(by: {
                $0.source.rawCode < $1.source.rawCode
            }) where Self.matches(sourceTag, language: entry.source) {
                if let target = entry.targets
                    .filter({
                        Self.matches(direction.target, language: $0)
                    })
                    .sorted(by: { $0.rawCode < $1.rawCode })
                    .first {
                    return (
                        source: entry.source.rawCode,
                        target: target.rawCode
                    )
                }
            }
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                "\(sourceTag.rawValue)→\(direction.target.rawValue)"
            )
        }
        guard let target = entries
            .flatMap(\.targets)
            .filter({
                Self.matches(direction.target, language: $0)
            })
            .sorted(by: { $0.rawCode < $1.rawCode })
            .first else {
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                direction.target.rawValue
            )
        }
        return (source: nil, target: target.rawCode)
    }

    func validationProbe() throws -> ValidationProbe {
        let sourcePriority = [
            "en", "zh", "zt", "es", "fr", "de", "ja", "ko",
        ]
        let priorityByCode = Dictionary(
            uniqueKeysWithValues: sourcePriority.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let candidates = entries.flatMap { entry in
            entry.targets.compactMap { target -> ValidationProbe? in
                guard target.rawCode != entry.source.rawCode else {
                    return nil
                }
                return ValidationProbe(
                    source: entry.source,
                    target: target,
                    text: Self.validationText(
                        sourceCode: entry.source.rawCode
                    )
                )
            }
        }
        guard let probe = candidates.sorted(by: { lhs, rhs in
            let lhsExact = lhs.source.rawCode == "en"
                && lhs.target.rawCode == "es"
            let rhsExact = rhs.source.rawCode == "en"
                && rhs.target.rawCode == "es"
            if lhsExact != rhsExact { return lhsExact }
            let lhsPriority =
                priorityByCode[lhs.source.rawCode] ?? Int.max
            let rhsPriority =
                priorityByCode[rhs.source.rawCode] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.source.rawCode != rhs.source.rawCode {
                return lhs.source.rawCode < rhs.source.rawCode
            }
            return lhs.target.rawCode < rhs.target.rawCode
        }).first else {
            throw TranslationOfficialAdapterError.noSupportedLanguagePair
        }
        return probe
    }

    static func language(rawCode: String) -> Language? {
        let normalized = rawCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard isValidRawCode(normalized) else { return nil }
        let tag: TranslationLanguageTag?
        switch normalized {
        case "zh":
            tag = TranslationLanguageTag("zh-Hans")
        case "zt":
            tag = TranslationLanguageTag("zh-Hant")
        default:
            tag = TranslationLanguageTag(normalized)
        }
        return tag.map {
            Language(rawCode: normalized, tag: $0)
        }
    }

    private static func isValidRawCode(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 32
            && value.range(
                of: #"^[a-z0-9][a-z0-9-]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func validationText(sourceCode: String) -> String {
        switch sourceCode {
        case "en": "Hello."
        case "zh", "zt": "你好。"
        case "es": "Hola."
        case "fr": "Bonjour."
        case "de": "Hallo."
        case "ja": "こんにちは。"
        case "ko": "안녕하세요."
        default: "Test."
        }
    }

    private static func matches(
        _ requested: TranslationLanguageTag,
        language: Language
    ) -> Bool {
        if requested == language.tag { return true }
        let requestedPrimary = requested.rawValue.lowercased()
            .split(separator: "-").first.map(String.init)
        let supportedPrimary = language.tag.rawValue.lowercased()
            .split(separator: "-").first.map(String.init)
        return requestedPrimary == supportedPrimary
            && requestedPrimary != "zh"
    }
}

/// Process-local admission and publication boundary for one official-service
/// profile revision. It deliberately has no persistence or logging because it
/// only protects in-process execution while credentials are being replaced or
/// removed.
final class TranslationOfficialServiceExecutionGate: @unchecked Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let profileID: String
        fileprivate let generation: UInt64
    }

    final class Lease: @unchecked Sendable {
        fileprivate let identifier: UUID
        fileprivate let token: Token

        private let lock = NSLock()
        private var operationCancellation: (@Sendable () -> Void)?
        private var publicationCancellation: (@Sendable () -> Void)?
        private var termination: (@Sendable () -> Void)?
        private var isInvalidated = false
        #if DEBUG
        private var didFinishPublication = false
        #endif

        fileprivate init(identifier: UUID, token: Token) {
            self.identifier = identifier
            self.token = token
        }

        fileprivate func registerOperationCancellation(
            _ cancellation: @escaping @Sendable () -> Void
        ) {
            lock.lock()
            if isInvalidated {
                lock.unlock()
                cancellation()
                return
            }
            operationCancellation = cancellation
            lock.unlock()
        }

        fileprivate func registerPublicationCancellation(
            _ cancellation: @escaping @Sendable () -> Void
        ) {
            lock.lock()
            if isInvalidated {
                lock.unlock()
                cancellation()
                return
            }
            publicationCancellation = cancellation
            lock.unlock()
        }

        @discardableResult
        fileprivate func registerTermination(
            _ termination: @escaping @Sendable () -> Void
        ) -> Bool {
            lock.lock()
            if isInvalidated {
                lock.unlock()
                termination()
                return false
            }
            self.termination = termination
            lock.unlock()
            return true
        }

        @discardableResult
        fileprivate func revoke(
            deliveringTermination: Bool
        ) -> Bool {
            lock.lock()
            guard !isInvalidated else {
                lock.unlock()
                return false
            }
            isInvalidated = true
            let termination = deliveringTermination ? termination : nil
            self.termination = nil
            let operationCancellation = operationCancellation
            self.operationCancellation = nil
            let publicationCancellation = publicationCancellation
            self.publicationCancellation = nil
            lock.unlock()
            termination?()
            operationCancellation?()
            publicationCancellation?()
            return true
        }

        fileprivate func disarmTermination() {
            lock.lock()
            termination = nil
            lock.unlock()
        }

        fileprivate func permitsPublication() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !isInvalidated
        }

        #if DEBUG
        fileprivate func markPublicationFinished() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinishPublication else { return false }
            didFinishPublication = true
            return true
        }
        #endif
    }

    private let lock = NSLock()
    private var profileGenerations: [String: UInt64] = [:]
    private var disabledProfileIDs: Set<String> = []
    private var exhaustedProfileIDs: Set<String> = []
    private var activeLeases: [UUID: Lease] = [:]
    #if DEBUG
    private let onLeaseReleased: (@Sendable (String) -> Void)?
    private let onPublicationFinished: (@Sendable (String) -> Void)?
    #endif

    init() {
        #if DEBUG
        onLeaseReleased = nil
        onPublicationFinished = nil
        #endif
    }

    #if DEBUG
    init(testInitialGenerations: [String: UInt64]) {
        profileGenerations = testInitialGenerations
        onLeaseReleased = nil
        onPublicationFinished = nil
    }

    init(
        testInitialGenerations: [String: UInt64],
        onLeaseReleased: @escaping @Sendable (String) -> Void,
        onPublicationFinished: @escaping @Sendable (String) -> Void
    ) {
        profileGenerations = testInitialGenerations
        self.onLeaseReleased = onLeaseReleased
        self.onPublicationFinished = onPublicationFinished
    }

    func activeLeaseCount(profileID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeases.values.count {
            $0.token.profileID == profileID
        }
    }
    #endif

    func token(for profileID: String) -> Token {
        lock.lock()
        let token = Token(
            profileID: profileID,
            generation: profileGenerations[profileID, default: 0]
        )
        lock.unlock()
        return token
    }

    /// Invalidates every prior token for this profile before cancelling the
    /// admitted work. Cancellation happens outside the lock because a
    /// transport may synchronously observe it.
    func invalidate(profileID: String) {
        lock.lock()
        let invalidatedLeases = invalidateLocked(profileID: profileID)
        lock.unlock()
        revokeInvalidatedLeases(invalidatedLeases)
    }

    /// Closes admission for a display-only profile without advancing an
    /// already closed generation on every registry refresh. The first
    /// open-to-closed transition still revokes any old token and lease.
    func deactivate(profileID: String) {
        lock.lock()
        guard !disabledProfileIDs.contains(profileID) else {
            lock.unlock()
            return
        }
        let invalidatedLeases = invalidateLocked(profileID: profileID)
        lock.unlock()
        revokeInvalidatedLeases(invalidatedLeases)
    }

    private func invalidateLocked(profileID: String) -> [Lease] {
        let generation = profileGenerations[profileID, default: 0]
        if generation == UInt64.max {
            exhaustedProfileIDs.insert(profileID)
        } else {
            profileGenerations[profileID] = generation + 1
        }
        disabledProfileIDs.insert(profileID)
        let invalidatedLeases = activeLeases.values.filter {
            $0.token.profileID == profileID
        }
        for lease in invalidatedLeases {
            activeLeases[lease.identifier] = nil
        }
        return invalidatedLeases
    }

    private func revokeInvalidatedLeases(_ invalidatedLeases: [Lease]) {
        for lease in invalidatedLeases {
            lease.revoke(deliveringTermination: true)
            notifyLeaseReleased(lease)
        }
    }

    func admit(_ token: Token) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard profileGenerations[token.profileID, default: 0]
            == token.generation,
            !disabledProfileIDs.contains(token.profileID),
            !exhaustedProfileIDs.contains(token.profileID) else {
            return nil
        }
        let lease = Lease(identifier: UUID(), token: token)
        activeLeases[lease.identifier] = lease
        return lease
    }

    /// Reopens admission only when the Store is ready to construct a fresh
    /// enabled adapter for the current generation.
    @discardableResult
    func activate(profileID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exhaustedProfileIDs.contains(profileID) else {
            return false
        }
        let generation = profileGenerations[profileID, default: 0]
        guard generation != UInt64.max else {
            exhaustedProfileIDs.insert(profileID)
            disabledProfileIDs.insert(profileID)
            return false
        }
        guard disabledProfileIDs.contains(profileID) else {
            return true
        }
        // A profile may have received a display-only adapter while disabled.
        // Advancing here makes that token stale before a newly enabled adapter
        // is constructed, so a retained adapter cannot regain admission.
        profileGenerations[profileID] = generation + 1
        disabledProfileIDs.remove(profileID)
        return true
    }

    func register<Result, Failure>(
        _ task: Task<Result, Failure>,
        for lease: Lease
    ) where Failure: Error {
        lease.registerOperationCancellation {
            task.cancel()
        }
    }

    func registerPublication<Result, Failure>(
        _ task: Task<Result, Failure>,
        for lease: Lease
    ) where Failure: Error {
        lease.registerPublicationCancellation {
            task.cancel()
        }
    }

    @discardableResult
    func registerStreamTermination(
        for lease: Lease,
        _ termination: @escaping @Sendable () -> Void
    ) -> Bool {
        lease.registerTermination(termination)
    }

    func terminateStream(for lease: Lease) {
        lease.revoke(deliveringTermination: true)
    }

    func disarmStreamTermination(for lease: Lease) {
        lease.disarmTermination()
    }

    /// This only takes the lease-local lock. The caller must schedule `finish`
    /// separately so termination never takes the gate lock in reverse order.
    @discardableResult
    func revokeStreamTermination(for lease: Lease) -> Bool {
        lease.revoke(deliveringTermination: false)
    }

    /// Runs publication while holding the same lock as invalidation, so a
    /// completion or failure is either published before invalidation or not at
    /// all. The body must remain synchronous and non-reentrant.
    @discardableResult
    func publish(
        for lease: Lease,
        _ body: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(lease) else {
            return false
        }
        body()
        return true
    }

    func isCurrent(_ lease: Lease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(lease)
    }

    private func isCurrentLocked(_ lease: Lease) -> Bool {
        profileGenerations[lease.token.profileID, default: 0]
            == lease.token.generation
            && activeLeases[lease.identifier] === lease
            && lease.permitsPublication()
    }

    func finish(_ lease: Lease) {
        lock.lock()
        let didRelease: Bool
        if activeLeases[lease.identifier] === lease {
            activeLeases[lease.identifier] = nil
            didRelease = true
        } else {
            didRelease = false
        }
        lock.unlock()
        if didRelease {
            notifyLeaseReleased(lease)
        }
    }

    func finishPublication(_ lease: Lease) {
        finish(lease)
        #if DEBUG
        guard lease.markPublicationFinished() else { return }
        onPublicationFinished?(lease.token.profileID)
        #endif
    }

    private func notifyLeaseReleased(_ lease: Lease) {
        #if DEBUG
        onLeaseReleased?(lease.token.profileID)
        #endif
    }
}

actor TranslationOfficialServiceWorker {
    typealias CredentialReader = @Sendable (
        _ profileID: String,
        _ fieldID: String
    ) throws -> String
    typealias OptionalCredentialReader = @Sendable (
        _ profileID: String,
        _ fieldID: String
    ) throws -> String?

    private let profile: TranslationServiceProfile
    private let transport: any TranslationOfficialHTTPTransport
    private let credentialReader: CredentialReader
    private let optionalCredentialReader: OptionalCredentialReader
    private var libreCapabilities: LibreTranslateCapabilitySnapshot?
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String

    init(
        profile: TranslationServiceProfile,
        transport: any TranslationOfficialHTTPTransport,
        credentialReader: @escaping CredentialReader,
        optionalCredentialReader:
            @escaping OptionalCredentialReader,
        libreCapabilities: LibreTranslateCapabilitySnapshot? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        nonce: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.profile = profile
        self.transport = transport
        self.credentialReader = credentialReader
        self.optionalCredentialReader = optionalCredentialReader
        self.libreCapabilities = libreCapabilities
        self.now = now
        self.nonce = nonce
    }

    func translate(
        request: TranslationServiceRequest
    ) async throws -> String {
        let text = request.input.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else {
            throw TranslationServiceAdapterError.failed(
                code: "empty_source_text",
                message: L10n.string("translation.error.emptySource")
            )
        }
        if profile.templateID == .libreTranslate,
           libreCapabilities == nil {
            libreCapabilities = try await discoverLibreCapabilities()
        }
        let urlRequest = try makeRequest(
            text: text,
            direction: request.direction
        )
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: urlRequest)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationOfficialAdapterError.httpStatus(
                response.statusCode
            )
        }
        return try Self.parseResponse(
            data,
            templateID: profile.templateID,
            requestedTarget: request.direction.target
        )
    }

    func discoverLibreCapabilities()
        async throws -> LibreTranslateCapabilitySnapshot
    {
        guard profile.templateID == .libreTranslate else {
            throw TranslationOfficialAdapterError.unsupportedTemplate
        }
        guard let baseURL = configurationString("base_url") else {
            throw TranslationOfficialAdapterError
                .missingConfiguration("base_url")
        }
        var request = URLRequest(
            url: try LibreTranslateEndpointPolicy.languagesEndpoint(
                baseURL
            )
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationOfficialAdapterError.httpStatus(
                response.statusCode
            )
        }
        guard data.count
                <= LibreTranslateCapabilitySnapshot.maximumEncodedBytes,
              let rows = try JSONSerialization.jsonObject(with: data)
                as? [[String: Any]],
              rows.count
                <= LibreTranslateCapabilitySnapshot.maximumLanguageCount else {
            throw TranslationOfficialAdapterError.responseTooLarge
        }
        var entries: [LibreTranslateCapabilitySnapshot.Entry] = []
        var seenSources: Set<String> = []
        var edgeCount = 0
        for row in rows {
            guard let rawCode = row["code"] as? String,
                  let source =
                    LibreTranslateCapabilitySnapshot.language(
                        rawCode: rawCode
                    ),
                  let rawTargets = row["targets"] as? [String] else {
                continue
            }
            var seenTargets: Set<String> = []
            let targets = rawTargets.compactMap {
                LibreTranslateCapabilitySnapshot.language(rawCode: $0)
            }.filter {
                seenTargets.insert($0.rawCode).inserted
            }
            guard !targets.isEmpty,
                  seenSources.insert(source.rawCode).inserted else {
                continue
            }
            edgeCount += targets.count
            guard edgeCount
                    <= LibreTranslateCapabilitySnapshot.maximumEdgeCount else {
                throw TranslationOfficialAdapterError.responseTooLarge
            }
            entries.append(
                LibreTranslateCapabilitySnapshot.Entry(
                    source: source,
                    targets: targets
                )
            )
        }
        guard !entries.isEmpty else {
            throw TranslationOfficialAdapterError.noSupportedLanguagePair
        }
        return try LibreTranslateCapabilitySnapshot(
            schemaVersion:
                LibreTranslateCapabilitySnapshot.currentSchemaVersion,
            profileID: profile.id,
            profileRevision: profile.updatedAt.timeIntervalSince1970,
            fetchedAt: now(),
            entries: entries
        ).validated(for: profile)
    }

    func validateLibreCapabilities(
        _ snapshot: LibreTranslateCapabilitySnapshot
    ) async throws -> String {
        let validated = try snapshot.validated(for: profile)
        let probe = try validated.validationProbe()
        let request = try makeLibreRequest(
            text: probe.text,
            sourceCode: probe.source.rawCode,
            targetCode: probe.target.rawCode
        )
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationOfficialAdapterError.httpStatus(
                response.statusCode
            )
        }
        return try Self.parseResponse(
            data,
            templateID: .libreTranslate,
            requestedTarget: nil
        )
    }

    private func makeRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        switch profile.templateID {
        case .deepLFree:
            return try makeDeepLRequest(text: text, direction: direction)
        case .microsoftTranslator:
            return try makeMicrosoftRequest(text: text, direction: direction)
        case .googleCloudBasic:
            return try makeGoogleRequest(text: text, direction: direction)
        case .alibabaMachineTranslation:
            return try makeAlibabaRequest(text: text, direction: direction)
        case .libreTranslate:
            return try makeLibreRequest(text: text, direction: direction)
        case .appleLocal, .openAICompatible:
            throw TranslationOfficialAdapterError.unsupportedTemplate
        }
    }

    private func makeDeepLRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        guard text.utf8.count <= 128 * 1_024 else {
            throw TranslationOfficialAdapterError.inputTooLarge
        }
        var request = URLRequest(
            url: URL(string: "https://api-free.deepl.com/v2/translate")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "DeepL-Auth-Key \(try credential("auth_key"))",
            forHTTPHeaderField: "Authorization"
        )
        var body: [String: Any] = [
            "text": [text],
            "target_lang": try Self.deepLLanguage(
                direction.target,
                isTarget: true
            ),
        ]
        if let source = direction.source {
            body["source_lang"] = try Self.deepLLanguage(
                source,
                isTarget: false
            )
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeMicrosoftRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        guard text.count <= 50_000 else {
            throw TranslationOfficialAdapterError.inputTooLarge
        }
        var components = URLComponents(
            string:
                "https://api.cognitive.microsofttranslator.com/translate"
        )!
        var query = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: direction.target.rawValue),
        ]
        if let source = direction.source {
            query.append(
                URLQueryItem(name: "from", value: source.rawValue)
            )
        }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            try credential("subscription_key"),
            forHTTPHeaderField: "Ocp-Apim-Subscription-Key"
        )
        if let region = configurationString("region"), !region.isEmpty {
            guard Self.validMicrosoftRegion(region) else {
                throw TranslationOfficialAdapterError
                    .invalidConfiguration("region")
            }
            request.setValue(
                region,
                forHTTPHeaderField: "Ocp-Apim-Subscription-Region"
            )
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [["Text": text]]
        )
        return request
    }

    private func makeGoogleRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        guard text.utf8.count <= 100_000 else {
            throw TranslationOfficialAdapterError.inputTooLarge
        }
        var request = URLRequest(
            url: URL(
                string:
                    "https://translation.googleapis.com/language/translate/v2"
            )!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        // Google Cloud API keys are accepted through this official header and
        // therefore never appear in a URL or diagnostic.
        request.setValue(
            try credential("api_key"),
            forHTTPHeaderField: "X-Goog-Api-Key"
        )
        var body: [String: Any] = [
            "q": text,
            "target": try Self.googleLanguage(direction.target),
            "format": "text",
        ]
        if let source = direction.source {
            body["source"] = try Self.googleLanguage(source)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeAlibabaRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        guard text.count <= 5_000 else {
            throw TranslationOfficialAdapterError.inputTooLarge
        }
        let rawRegion = configurationString("region") ?? "cn-hangzhou"
        guard let region = AlibabaMachineTranslationRegion(
            rawValue: rawRegion
        ),
        let url = URL(
            string: "https://\(region.publicEndpointHost)/"
        ) else {
            throw TranslationOfficialAdapterError.invalidBaseURL
        }
        let body = AlibabaCloudACS3Signer.formEncodedBody(
            [
                "FormatType": "text",
                "SourceLanguage":
                    try direction.source.map(Self.alibabaLanguage) ?? "auto",
                "SourceText": text,
                "TargetLanguage": try Self.alibabaLanguage(
                    direction.target
                ),
                "Scene": "general",
            ]
        )
        return AlibabaCloudACS3Signer.makeSignedRequest(
            url: url,
            action: "TranslateGeneral",
            version: "2018-10-12",
            body: body,
            accessKeyID: try credential("access_key_id"),
            accessKeySecret: try credential("access_key_secret"),
            date: now(),
            nonce: nonce()
        )
    }

    private func makeLibreRequest(
        text: String,
        direction: TranslationLanguageDirection
    ) throws -> URLRequest {
        guard text.utf8.count <= 100_000 else {
            throw TranslationOfficialAdapterError.inputTooLarge
        }
        guard let libreCapabilities else {
            throw TranslationOfficialAdapterError
                .missingConfiguration("supported_languages")
        }
        let languageCodes = try libreCapabilities.serverCodes(
            for: direction
        )
        return try makeLibreRequest(
            text: text,
            sourceCode: languageCodes.source ?? "auto",
            targetCode: languageCodes.target
        )
    }

    private func makeLibreRequest(
        text: String,
        sourceCode: String,
        targetCode: String
    ) throws -> URLRequest {
        guard let baseURL = configurationString("base_url") else {
            throw TranslationOfficialAdapterError
                .missingConfiguration("base_url")
        }
        let endpoint = try LibreTranslateEndpointPolicy.translateEndpoint(
            baseURL
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "q": text,
            "source": sourceCode,
            "target": targetCode,
            "format": "text",
        ]
        if let apiKey = try optionalCredentialReader(
            profile.id,
            "api_key"
        ),
           !apiKey.isEmpty {
            body["api_key"] = apiKey
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func credential(_ fieldID: String) throws -> String {
        do {
            let value = try credentialReader(profile.id, fieldID)
            try TranslationServiceCredentialPolicy.validateStored(value)
            return value
        } catch TranslationServiceCredentialStoreError
            .missingCredential(_) {
            throw TranslationOfficialAdapterError
                .missingConfiguration(fieldID)
        } catch {
            throw error
        }
    }

    private func configurationString(_ fieldID: String) -> String? {
        guard case let .string(value)? = profile.configuration[fieldID] else {
            return nil
        }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private static func parseResponse(
        _ data: Data,
        templateID: TranslationServiceTemplateID,
        requestedTarget: TranslationLanguageTag?
    ) throws -> String {
        let text: String?
        switch templateID {
        case .deepLFree:
            guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            text = ((root["translations"] as? [[String: Any]])?.first)?[
                "text"
            ] as? String
        case .microsoftTranslator:
            let array = try JSONSerialization.jsonObject(with: data)
                as? [[String: Any]]
            let translation = ((array?.first)?["translations"]
                as? [[String: Any]])?.first
            if let returnedTarget = translation?["to"] as? String,
               let requestedTarget,
               !Self.sameLanguage(
                    returnedTarget,
                    requested: requestedTarget
               ) {
                throw TranslationOfficialAdapterError
                    .responseLanguageMismatch
            }
            text = translation?["text"] as? String
        case .googleCloudBasic:
            guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            text = ((((root["data"] as? [String: Any])?["translations"]
                as? [[String: Any]])?.first)?["translatedText"]) as? String
        case .alibabaMachineTranslation:
            guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            text = ((root["Data"] as? [String: Any])?["Translated"]
                as? String)
                ?? ((root["Data"] as? [String: Any])?["TranslatedText"]
                    as? String)
        case .libreTranslate:
            guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            text = root["translatedText"] as? String
        case .appleLocal, .openAICompatible:
            text = nil
        }
        let normalized = text?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalized, !normalized.isEmpty else {
            throw TranslationOfficialAdapterError.invalidResponse
        }
        return normalized
    }

    private static func sameLanguage(
        _ returnedValue: String,
        requested: TranslationLanguageTag
    ) -> Bool {
        guard let returned = TranslationLanguageTag(
            returnedValue.replacingOccurrences(of: "_", with: "-")
        ) else {
            return false
        }
        return TranslationTargetResolver.isSameLanguage(
            returned,
            requested
        )
    }

    static func deepLLanguage(
        _ language: TranslationLanguageTag,
        isTarget: Bool
    ) throws -> String {
        let normalized = language.rawValue.lowercased()
        let variants: [String: String] = isTarget
            ? [
                "en-us": "EN-US",
                "en-gb": "EN-GB",
                "pt-br": "PT-BR",
                "pt-pt": "PT-PT",
                "zh-hans": "ZH-HANS",
                "zh-hant": "ZH-HANT",
                "no": "NB",
            ]
            : [
                "en-us": "EN",
                "en-gb": "EN",
                "pt-br": "PT",
                "pt-pt": "PT",
                "zh-hans": "ZH",
                "zh-hant": "ZH",
                "no": "NB",
            ]
        if let variant = variants[normalized] { return variant }
        let primary = normalized.split(separator: "-").first.map(String.init)
            ?? normalized
        let supported = Set([
            "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi",
            "fr", "he", "hu", "id", "it", "ja", "ko", "lt", "lv", "nb",
            "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr",
            "uk", "vi", "zh",
        ])
        guard supported.contains(primary) else {
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                language.rawValue
            )
        }
        return primary.uppercased()
    }

    static func googleLanguage(
        _ language: TranslationLanguageTag
    ) throws -> String {
        let normalized = language.rawValue.lowercased()
        if normalized == "zh-hans" { return "zh-CN" }
        if normalized == "zh-hant" { return "zh-TW" }
        let primary = normalized.split(separator: "-").first.map(String.init)
            ?? normalized
        guard primary.count >= 2, primary.count <= 3 else {
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                language.rawValue
            )
        }
        return primary
    }

    static func alibabaLanguage(
        _ language: TranslationLanguageTag
    ) throws -> String {
        let raw = language.rawValue.lowercased()
        if raw.hasPrefix("zh") { return "zh" }
        let primary = raw.split(separator: "-").first.map(String.init) ?? raw
        let supported = Set([
            "en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it", "ar",
            "th", "tr", "vi", "id", "hi",
        ])
        guard supported.contains(primary) else {
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                language.rawValue
            )
        }
        return primary
    }

    static func libreLanguage(
        _ language: TranslationLanguageTag
    ) throws -> String {
        let primary = language.rawValue.lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        guard primary.count >= 2, primary.count <= 3 else {
            throw TranslationOfficialAdapterError.unsupportedLanguage(
                language.rawValue
            )
        }
        return primary
    }

    private static func validMicrosoftRegion(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(
                of: #"^[A-Za-z0-9-]+$"#,
                options: .regularExpression
            ) != nil
    }
}

enum TranslationOfficialCredentialState: Equatable, Sendable {
    case configured
    case missing
    case inaccessible(message: String)

    var isConfigured: Bool {
        self == .configured
    }

    var errorMessage: String? {
        guard case let .inaccessible(message) = self else {
            return nil
        }
        return message
    }
}

struct TranslationOfficialServiceProfilePreparation: Sendable {
    let profile: TranslationServiceProfile
    let credentialState: TranslationOfficialCredentialState
}

struct TranslationOfficialServiceProfileBatch: Sendable {
    let profiles: [TranslationServiceProfile]
    let preparations: [TranslationOfficialServiceProfilePreparation]
    let loadIssues: [TranslationServiceProfileLoadIssue]
}

enum TranslationOfficialServiceProfilePreparer {
    static func prepare(
        profiles: [TranslationServiceProfile],
        credentialStore: any TranslationServiceCredentialStoring
    ) -> [TranslationOfficialServiceProfilePreparation] {
        profiles.compactMap { profile in
            guard TranslationServiceTemplateCatalog.descriptor(
                for: profile.templateID
            ) != nil else {
                return nil
            }
            return TranslationOfficialServiceProfilePreparation(
                profile: profile,
                credentialState: credentialState(
                    for: profile,
                    credentialStore: credentialStore
                )
            )
        }
    }

    static func credentialState(
        for profile: TranslationServiceProfile,
        credentialStore: any TranslationServiceCredentialStoring
    ) -> TranslationOfficialCredentialState {
        do {
            for fieldID in TranslationServiceTemplateCatalog
                .credentialFieldIDs(
                    for: profile.templateID,
                    requiredOnly: true
                )
            {
                guard try credentialStore.contains(
                    profileID: profile.id,
                    fieldID: fieldID
                ) else {
                    return .missing
                }
            }
            return .configured
        } catch {
            return .inaccessible(
                message: String(
                    error.localizedDescription.prefix(512)
                )
            )
        }
    }
}

@MainActor
final class TranslationOfficialServiceAdapter: TranslationServiceAdapter {
    private let profile: TranslationServiceProfile
    private let worker: TranslationOfficialServiceWorker
    private let credentialState: TranslationOfficialCredentialState
    private let libreCapabilities: LibreTranslateCapabilitySnapshot?
    private let executionGate: TranslationOfficialServiceExecutionGate
    private let executionToken: TranslationOfficialServiceExecutionGate.Token

    init(
        profile: TranslationServiceProfile,
        credentialState: TranslationOfficialCredentialState,
        credentialStore: any TranslationServiceCredentialStoring =
            TranslationServiceCredentialStore(),
        transport: any TranslationOfficialHTTPTransport =
            URLSessionTranslationOfficialHTTPTransport(),
        libreCapabilities: LibreTranslateCapabilitySnapshot? = nil,
        executionGate: TranslationOfficialServiceExecutionGate =
            TranslationOfficialServiceExecutionGate(),
        executionToken: TranslationOfficialServiceExecutionGate.Token? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        nonce: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.profile = profile
        self.credentialState = credentialState
        self.libreCapabilities = libreCapabilities
        self.executionGate = executionGate
        self.executionToken = executionToken
            ?? executionGate.token(for: profile.id)
        worker = TranslationOfficialServiceWorker(
            profile: profile,
            transport: transport,
            credentialReader: { profileID, fieldID in
                try credentialStore.read(
                    profileID: profileID,
                    fieldID: fieldID
                )
            },
            optionalCredentialReader: { profileID, fieldID in
                try credentialStore.value(
                    profileID: profileID,
                    fieldID: fieldID
                )
            },
            libreCapabilities: libreCapabilities,
            now: now,
            nonce: nonce
        )
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: profile.serviceID,
            displayName: profile.displayName,
            kind: .officialExternal,
            availability: Self.isRunnable(
                profile: profile,
                credentialState: credentialState
            )
                ? .available
                : .requiresConfiguration,
            supportsStreaming: false,
            supportedSourceLanguages:
                libreCapabilities?.supportedSourceLanguages
                ?? TranslationServiceTemplateCatalog.supportedLanguages(
                    for: profile.templateID
                ),
            supportedTargetLanguages:
                libreCapabilities?.supportedTargetLanguages
                ?? TranslationServiceTemplateCatalog.supportedLanguages(
                    for: profile.templateID
                )
        )
    }

    func validateLanguageDirection(
        _ direction: TranslationLanguageDirection
    ) throws {
        try TranslationServiceDirectionValidator.validate(
            direction: direction,
            service: descriptor
        )
        guard profile.templateID == .libreTranslate,
              let libreCapabilities else {
            return
        }
        do {
            _ = try libreCapabilities.serverCodes(for: direction)
        } catch TranslationOfficialAdapterError.unsupportedLanguage {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_language_pair_unsupported",
                message: L10n.string(
                    "translation.error.languagePairUnsupported"
                )
            )
        }
    }

    func discoverLibreCapabilities()
        async throws -> LibreTranslateCapabilitySnapshot
    {
        try await executeGatedOperation { [worker] in
            try await worker.discoverLibreCapabilities()
        }
    }

    func validateLibreCapabilities(
        _ snapshot: LibreTranslateCapabilitySnapshot
    ) async throws -> String {
        try await executeGatedOperation { [worker] in
            try await worker.validateLibreCapabilities(snapshot)
        }
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        switch credentialState {
        case .configured:
            break
        case .missing:
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: TranslationServiceAdapterError.invalidConfiguration(
                        code: "official_service_requires_configuration",
                        message: TranslationOfficialAdapterError
                            .missingConfiguration("credential")
                            .localizedDescription
                    )
                )
            }
        case let .inaccessible(message):
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: TranslationServiceAdapterError.unavailable(
                        code: "official_credential_unavailable",
                        message: message
                    )
                )
            }
        }
        return AsyncThrowingStream { continuation in
            guard let lease = executionGate.admit(executionToken) else {
                continuation.finish(throwing: CancellationError())
                return
            }
            guard executionGate.registerStreamTermination(for: lease, {
                continuation.finish(throwing: CancellationError())
            }) else {
                return
            }
            let operation = Task<String, Error> { [worker] in
                try await worker.translate(request: request)
            }
            executionGate.register(operation, for: lease)
            let publication = Task { [executionGate] in
                defer { executionGate.finishPublication(lease) }
                do {
                    let text = try await operation.value
                    let wasPublished = executionGate.publish(for: lease) {
                        executionGate.disarmStreamTermination(for: lease)
                        continuation.yield(.completed(text))
                        continuation.finish()
                    }
                    if !wasPublished {
                        executionGate.terminateStream(for: lease)
                    }
                } catch is CancellationError {
                    let wasPublished = executionGate.publish(for: lease) {
                        executionGate.disarmStreamTermination(for: lease)
                        continuation.finish(throwing: CancellationError())
                    }
                    if !wasPublished {
                        executionGate.terminateStream(for: lease)
                    }
                } catch let error as TranslationOfficialAdapterError
                    where error == .responseLanguageMismatch {
                    let wasPublished = executionGate.publish(for: lease) {
                        executionGate.disarmStreamTermination(for: lease)
                        continuation.finish(
                            throwing: TranslationServiceAdapterError.failed(
                                code: "translation_response_language_mismatch",
                                message: error.localizedDescription
                            )
                        )
                    }
                    if !wasPublished {
                        executionGate.terminateStream(for: lease)
                    }
                } catch {
                    let wasPublished = executionGate.publish(for: lease) {
                        executionGate.disarmStreamTermination(for: lease)
                        continuation.finish(
                            throwing: TranslationServiceAdapterError.failed(
                                code: "official_service_failed",
                                message: String(
                                    error.localizedDescription.prefix(512)
                                )
                            )
                        )
                    }
                    if !wasPublished {
                        executionGate.terminateStream(for: lease)
                    }
                }
            }
            executionGate.registerPublication(publication, for: lease)
            continuation.onTermination = { [executionGate] _ in
                guard executionGate.revokeStreamTermination(
                    for: lease
                ) else {
                    return
                }
                Task { [executionGate] in
                    executionGate.finish(lease)
                }
            }
        }
    }

    private func executeGatedOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let lease = executionGate.admit(executionToken) else {
            throw CancellationError()
        }
        let task = Task<Result, Error> {
            try await operation()
        }
        executionGate.register(task, for: lease)
        defer { executionGate.finish(lease) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            guard executionGate.isCurrent(lease) else {
                throw CancellationError()
            }
            return result
        }, onCancel: {
            task.cancel()
        })
    }

    static func isRunnable(
        profile: TranslationServiceProfile,
        credentialState: TranslationOfficialCredentialState
    ) -> Bool {
        configurationIsComplete(profile) && credentialState.isConfigured
    }

    private static func configurationIsComplete(
        _ profile: TranslationServiceProfile
    ) -> Bool {
        switch profile.templateID {
        case .libreTranslate:
            guard case let .string(value)? =
                    profile.configuration["base_url"] else {
                return false
            }
            return (try? LibreTranslateEndpointPolicy.translateEndpoint(
                value
            )) != nil
        case .alibabaMachineTranslation:
            guard case let .string(value)? =
                    profile.configuration["region"] else {
                return false
            }
            return AlibabaMachineTranslationRegion(
                rawValue: value
            ) != nil
        case .deepLFree,
             .microsoftTranslator,
             .googleCloudBasic:
            return true
        case .appleLocal, .openAICompatible:
            return false
        }
    }
}

enum LibreTranslateEndpointPolicy {
    static func translateEndpoint(_ baseURL: String) throws -> URL {
        try endpoint(baseURL, operation: "translate")
    }

    static func languagesEndpoint(_ baseURL: String) throws -> URL {
        try endpoint(baseURL, operation: "languages")
    }

    private static func endpoint(
        _ baseURL: String,
        operation: String
    ) throws -> URL {
        do {
            return try LibreTranslateBaseURLPolicy.operationEndpoint(
                baseURL: baseURL,
                operation: operation
            )
        } catch let error as LibreTranslateBaseURLValidationError {
            switch error {
            case .invalidURL:
                throw TranslationOfficialAdapterError.invalidBaseURL
            case .insecureURL:
                throw TranslationOfficialAdapterError.insecureBaseURL
            case .privateNetworkDenied:
                throw TranslationOfficialAdapterError
                    .privateNetworkDenied
            }
        } catch {
            throw TranslationOfficialAdapterError.invalidBaseURL
        }
    }
}

enum AlibabaCloudACS3Signer {
    static func formEncodedBody(
        _ parameters: [String: String]
    ) -> Data {
        let body = parameters.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(parameters[key] ?? ""))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func makeSignedRequest(
        url: URL,
        action: String,
        version: String,
        body: Data,
        accessKeyID: String,
        accessKeySecret: String,
        date: Date,
        nonce: String
    ) -> URLRequest {
        let dateString = timestampString(date)
        let payloadHash = sha256Hex(body)
        let host = url.host ?? ""
        let canonicalHeaders = [
            "content-type:application/x-www-form-urlencoded",
            "host:\(host)",
            "x-acs-action:\(action)",
            "x-acs-content-sha256:\(payloadHash)",
            "x-acs-date:\(dateString)",
            "x-acs-signature-nonce:\(nonce)",
            "x-acs-version:\(version)",
        ].joined(separator: "\n") + "\n"
        let signedHeaders = [
            "content-type",
            "host",
            "x-acs-action",
            "x-acs-content-sha256",
            "x-acs-date",
            "x-acs-signature-nonce",
            "x-acs-version",
        ].joined(separator: ";")
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let stringToSign = [
            "ACS3-HMAC-SHA256",
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let signature = hmacSHA256Hex(
            key: accessKeySecret,
            value: stringToSign
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(action, forHTTPHeaderField: "x-acs-action")
        request.setValue(version, forHTTPHeaderField: "x-acs-version")
        request.setValue(dateString, forHTTPHeaderField: "x-acs-date")
        request.setValue(
            nonce,
            forHTTPHeaderField: "x-acs-signature-nonce"
        )
        request.setValue(
            payloadHash,
            forHTTPHeaderField: "x-acs-content-sha256"
        )
        request.setValue(
            "ACS3-HMAC-SHA256 Credential=\(accessKeyID),"
                + "SignedHeaders=\(signedHeaders),Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func hmacSHA256Hex(
        key: String,
        value: String
    ) -> String {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return authentication.map {
            String(format: "%02x", $0)
        }.joined()
    }
}
