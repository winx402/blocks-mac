import BlocksCore
import Foundation

enum TranslationCommunityWebSource:
    String,
    CaseIterable,
    Sendable
{
    case myMemory = "community:mymemory"
    case googleWeb = "community:google-web"
    case deepLWeb = "community:deepl-web"
    case tencentWeb = "community:tencent-web"

    /// Only sources that pass a real low-sensitive request in the current
    /// release are exposed in production settings. DeepL's community web
    /// protocol remains implemented for regression tests, but a six-request
    /// release probe produced one HTTP 429, so it is not exposed as reliable.
    static let productionAvailable: [Self] = [
        .myMemory,
        .googleWeb,
        .tencentWeb,
    ]

    var displayName: String {
        L10n.string(
            "translation.service.\(rawValue.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "-", with: "."))"
        )
    }

    var allowedHosts: Set<String> {
        switch self {
        case .myMemory:
            ["api.mymemory.translated.net"]
        case .googleWeb:
            ["translate.googleapis.com"]
        case .deepLWeb:
            ["www2.deepl.com"]
        case .tencentWeb:
            ["wxapp.translator.qq.com"]
        }
    }
}

protocol TranslationCommunityWebHTTPTransport: Sendable {
    func data(
        for request: URLRequest,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTranslationCommunityWebHTTPTransport:
    TranslationCommunityWebHTTPTransport
{
    private static let maximumResponseBytes = 1_048_576

    func data(
        for request: URLRequest,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.user == nil,
              url.password == nil else {
            throw TranslationCommunityWebError.invalidRequest
        }
        guard request.value(
            forHTTPHeaderField: "Cookie"
        ) == nil else {
            throw TranslationCommunityWebError.invalidRequest
        }
        var boundedRequest = request
        boundedRequest.timeoutInterval = min(
            max(request.timeoutInterval, 1),
            15
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return try await TranslationBoundedURLSessionClient(
            maximumResponseBytes: Self.maximumResponseBytes,
            sessionConfiguration: configuration
        ).data(for: boundedRequest)
    }
}

enum TranslationCommunityWebError: Error, LocalizedError {
    case invalidRequest
    case inputTooLarge
    case sourceLanguageUndetermined
    case unsupportedLanguage
    case httpStatus(Int)
    case invalidResponse
    case emptyResponse
    case responseLanguageMismatch

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            L10n.string("translation.community.error.invalidRequest")
        case .inputTooLarge:
            L10n.string("translation.community.error.inputTooLarge")
        case .sourceLanguageUndetermined:
            L10n.string(
                "translation.error.sourceLanguageUndetermined"
            )
        case .unsupportedLanguage:
            L10n.string(
                "translation.error.languagePairUnsupported"
            )
        case let .httpStatus(status):
            TranslationLocalizedFormat.httpStatus(status)
        case .invalidResponse:
            L10n.string("translation.community.error.invalidResponse")
        case .emptyResponse:
            L10n.string("translation.community.error.emptyResponse")
        case .responseLanguageMismatch:
            L10n.string(
                "translation.community.error.responseLanguageMismatch"
            )
        }
    }

    var adapterErrorCode: String {
        switch self {
        case .invalidRequest:
            "network_request_invalid"
        case .inputTooLarge:
            "translation_input_too_large"
        case .sourceLanguageUndetermined:
            "source_language_undetermined"
        case .unsupportedLanguage:
            "translation_target_language_unsupported"
        case let .httpStatus(status) where status == 408:
            "network_timed_out"
        case let .httpStatus(status) where status == 429:
            "network_rate_limited"
        case let .httpStatus(status) where status >= 500:
            "network_unavailable"
        case .httpStatus:
            "network_http_client_error"
        case .invalidResponse:
            "remote_invalid_response"
        case .emptyResponse:
            "empty_translation_result"
        case .responseLanguageMismatch:
            "translation_response_language_mismatch"
        }
    }
}

private actor TranslationCommunityWebWorker {
    private let source: TranslationCommunityWebSource
    private let transport: any TranslationCommunityWebHTTPTransport

    init(
        source: TranslationCommunityWebSource,
        transport: any TranslationCommunityWebHTTPTransport
    ) {
        self.source = source
        self.transport = transport
    }

    func translate(
        _ request: TranslationServiceRequest
    ) async throws -> String {
        let text = request.input.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else {
            throw TranslationCommunityWebError.emptyResponse
        }
        switch source {
        case .myMemory:
            return try await translateWithMyMemory(
                text,
                direction: request.direction
            )
        case .googleWeb:
            return try await translateWithGoogle(
                text,
                direction: request.direction
            )
        case .deepLWeb:
            return try await translateWithDeepL(
                text,
                direction: request.direction
            )
        case .tencentWeb:
            return try await translateWithTencent(
                text,
                direction: request.direction
            )
        }
    }

    private func translateWithMyMemory(
        _ text: String,
        direction: TranslationLanguageDirection
    ) async throws -> String {
        let sourceTag = try resolvedSourceTag(
            explicit: direction.source,
            text: text
        )
        let chunks = Self.utf8Chunks(text, maximumBytes: 500)
        var translated: [String] = []
        translated.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            var components = URLComponents(
                string: "https://api.mymemory.translated.net/get"
            )
            components?.queryItems = [
                URLQueryItem(name: "q", value: chunk),
                URLQueryItem(
                    name: "langpair",
                    value:
                        "\(Self.myMemoryLanguage(sourceTag))|\(Self.myMemoryLanguage(direction.target))"
                ),
            ]
            guard let url = components?.url else {
                throw TranslationCommunityWebError.invalidRequest
            }
            let (data, response) = try await transport.data(
                for: URLRequest(url: url),
                allowedHosts: source.allowedHosts
            )
            try Self.validate(response)
            guard let object = try JSONSerialization
                .jsonObject(with: data) as? [String: Any],
                  let responseStatus = object["responseStatus"]
                    as? Int,
                  responseStatus == 200,
                  let responseData = object["responseData"]
                    as? [String: Any],
                  let value = responseData["translatedText"]
                    as? String,
                  !value.isEmpty else {
                throw TranslationCommunityWebError.invalidResponse
            }
            translated.append(value)
        }
        return translated.joined()
    }

    private func translateWithGoogle(
        _ text: String,
        direction: TranslationLanguageDirection
    ) async throws -> String {
        guard text.count <= 5_000 else {
            throw TranslationCommunityWebError.inputTooLarge
        }
        var components = URLComponents(
            string:
                "https://translate.googleapis.com/translate_a/single"
        )
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(
                name: "sl",
                value: direction.source.map(Self.googleLanguage)
                    ?? "auto"
            ),
            URLQueryItem(
                name: "tl",
                value: Self.googleLanguage(direction.target)
            ),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components?.url else {
            throw TranslationCommunityWebError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await transport.data(
            for: request,
            allowedHosts: source.allowedHosts
        )
        try Self.validate(response)
        guard let root = try JSONSerialization
            .jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw TranslationCommunityWebError.invalidResponse
        }
        let output = segments.compactMap { segment -> String? in
            (segment as? [Any])?.first as? String
        }
        .joined()
        guard !output.isEmpty else {
            throw TranslationCommunityWebError.emptyResponse
        }
        return output
    }

    private func translateWithDeepL(
        _ text: String,
        direction: TranslationLanguageDirection
    ) async throws -> String {
        guard text.count <= 5_000 else {
            throw TranslationCommunityWebError.inputTooLarge
        }
        let sourceLanguage = direction.source.map(
            Self.deepLLanguage
        ) ?? "auto"
        let targetLanguage = Self.deepLLanguage(direction.target)
        guard targetLanguage != "auto" else {
            throw TranslationCommunityWebError.unsupportedLanguage
        }
        let requestID = Int.random(
            in: 100_000_000...999_999_000
        )
        let timestamp = Self.deepLTimestamp(for: text)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "LMT_handle_texts",
            "id": requestID,
            "params": [
                "texts": [[
                    "text": text,
                    "requestAlternatives": 0,
                ]],
                "splitting": "newlines",
                "lang": [
                    "source_lang_user_selected": sourceLanguage,
                    "target_lang": targetLanguage,
                ],
                "timestamp": timestamp,
            ],
        ]
        var request = URLRequest(
            url: URL(string: "https://www2.deepl.com/jsonrpc")!
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await transport.data(
            for: request,
            allowedHosts: source.allowedHosts
        )
        try Self.validate(response)
        guard let root = try JSONSerialization
            .jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let texts = result["texts"] as? [[String: Any]],
              let output = texts.first?["text"] as? String,
              !output.isEmpty else {
            throw TranslationCommunityWebError.invalidResponse
        }
        return output
    }

    private func translateWithTencent(
        _ text: String,
        direction: TranslationLanguageDirection
    ) async throws -> String {
        guard text.utf8.count <= 1_800 else {
            throw TranslationCommunityWebError.inputTooLarge
        }
        let sourceLanguage = direction.source.map(
            Self.tencentLanguage
        ) ?? "auto"
        let targetLanguage = Self.tencentLanguage(direction.target)
        var components = URLComponents(
            string:
                "https://wxapp.translator.qq.com/api/translate"
        )
        components?.queryItems = [
            URLQueryItem(name: "source", value: "auto"),
            URLQueryItem(name: "target", value: "auto"),
            URLQueryItem(name: "sourceText", value: text),
            URLQueryItem(name: "platform", value: "WeChat_APP"),
            URLQueryItem(
                name: "candidateLangs",
                value: "\(sourceLanguage)|\(targetLanguage)"
            ),
            URLQueryItem(
                name: "guid",
                value: "oqdgX0SIwhvM0TmqzTHghWBvfk22"
            ),
        ]
        guard let url = components?.url else {
            throw TranslationCommunityWebError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3_1 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.32",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "https://servicewechat.com/wxb1070eabc6f9107e/117/page-frame.html",
            forHTTPHeaderField: "Referer"
        )
        let (data, response) = try await transport.data(
            for: request,
            allowedHosts: source.allowedHosts
        )
        try Self.validate(response)
        guard let root = try JSONSerialization
            .jsonObject(with: data) as? [String: Any],
              let errorCode = root["errCode"] as? Int,
              errorCode == 0,
              let returnedSource = root["source"] as? String,
              !returnedSource.isEmpty,
              let returnedTarget = root["target"] as? String,
              let output = root["targetText"] as? String,
              !output.isEmpty else {
            throw TranslationCommunityWebError.invalidResponse
        }
        guard Self.tencentLanguage(
            returnedTarget,
            matches: direction.target
        ) else {
            throw TranslationCommunityWebError.responseLanguageMismatch
        }
        return output
    }

    private func resolvedSourceTag(
        explicit: TranslationLanguageTag?,
        text: String
    ) throws -> TranslationLanguageTag {
        if let explicit {
            return explicit
        }
        guard let detected =
            TranslationTargetResolver.reliablyDetectedLanguage(
                in: text
            ) else {
            throw TranslationCommunityWebError
                .sourceLanguageUndetermined
        }
        return detected
    }

    private static func validate(
        _ response: HTTPURLResponse
    ) throws {
        guard (200...299).contains(response.statusCode) else {
            throw TranslationCommunityWebError.httpStatus(
                response.statusCode
            )
        }
    }

    private static func utf8Chunks(
        _ text: String,
        maximumBytes: Int
    ) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let string = String(character)
            let bytes = string.utf8.count
            if currentBytes + bytes > maximumBytes,
               !current.isEmpty {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func primaryCode(
        _ tag: TranslationLanguageTag
    ) -> String {
        tag.rawValue
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased() ?? tag.rawValue.lowercased()
    }

    private static func googleLanguage(
        _ tag: TranslationLanguageTag
    ) -> String {
        switch tag.rawValue {
        case "zh-Hans":
            "zh-CN"
        case "zh-Hant":
            "zh-TW"
        default:
            tag.rawValue
        }
    }

    private static func myMemoryLanguage(
        _ tag: TranslationLanguageTag
    ) -> String {
        googleLanguage(tag)
    }

    private static func deepLLanguage(
        _ tag: TranslationLanguageTag
    ) -> String {
        switch tag.rawValue {
        case "zh-Hans", "zh-Hant":
            "ZH"
        case "pt-BR":
            "PT-BR"
        case "pt-PT":
            "PT-PT"
        default:
            primaryCode(tag).uppercased()
        }
    }

    private static func tencentLanguage(
        _ tag: TranslationLanguageTag
    ) -> String {
        switch tag.rawValue {
        case "zh-Hans":
            "zh"
        case "zh-Hant":
            "zh-TW"
        default:
            primaryCode(tag)
        }
    }

    private static func tencentLanguage(
        _ returnedValue: String,
        matches requested: TranslationLanguageTag
    ) -> Bool {
        let normalizedReturned = returnedValue
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let expected = tencentLanguage(requested)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalizedReturned == expected {
            return true
        }
        if requested.rawValue == "zh-Hans" {
            return normalizedReturned == "zh-cn"
                || normalizedReturned == "zh-hans"
        }
        if requested.rawValue == "zh-Hant" {
            return normalizedReturned == "zh-tw"
                || normalizedReturned == "zh-hant"
        }
        return false
    }

    private static func deepLTimestamp(for text: String) -> Int64 {
        let count = text.reduce(into: 0) {
            if $1 == "i" {
                $0 += 1
            }
        }
        let base = Int64(Date().timeIntervalSince1970 * 1_000)
        guard count > 0 else { return base }
        let divisor = Int64(count + 1)
        return base - (base % divisor) + divisor
    }
}

@MainActor
final class TranslationCommunityWebServiceAdapter:
    TranslationServiceAdapter
{
    private let source: TranslationCommunityWebSource
    private let worker: TranslationCommunityWebWorker
    private let disclosureStore: TranslationCommunityWebDisclosureStore

    init(
        source: TranslationCommunityWebSource,
        transport: any TranslationCommunityWebHTTPTransport =
            URLSessionTranslationCommunityWebHTTPTransport(),
        disclosureStore: TranslationCommunityWebDisclosureStore =
            TranslationCommunityWebDisclosureStore()
    ) {
        self.source = source
        self.disclosureStore = disclosureStore
        worker = TranslationCommunityWebWorker(
            source: source,
            transport: transport
        )
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: source.rawValue,
            displayName: source.displayName,
            kind: .communityWeb,
            availability: .available,
            supportsStreaming: false,
            supportedSourceLanguages:
                TranslationLanguagePreferences.commonOptions,
            supportedTargetLanguages:
                TranslationLanguagePreferences.commonOptions
        )
    }

    var requiresExplicitSourceLanguage: Bool {
        source == .myMemory
    }

    func validateLanguageDirection(
        _ direction: TranslationLanguageDirection
    ) throws {
        try TranslationServiceDirectionValidator.validate(
            direction: direction,
            service: descriptor
        )
        guard source == .tencentWeb,
              let sourceLanguage = direction.source else {
            return
        }
        let sourceIsChinese = Self.isChinese(sourceLanguage)
        let targetIsSimplifiedChinese =
            direction.target.rawValue == "zh-Hans"
        let supported = sourceIsChinese
            ? Self.tencentTargetsFromChinese.contains(
                Self.primaryLanguage(direction.target)
            )
            : targetIsSimplifiedChinese
        guard supported else {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_language_pair_unsupported",
                message: L10n.string(
                    "translation.error.languagePairUnsupported"
                )
            )
        }
    }

    private static let tencentTargetsFromChinese: Set<String> = [
        "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja",
        "ko", "ms", "pt", "ru", "th", "tr", "vi",
    ]

    private static func isChinese(
        _ language: TranslationLanguageTag
    ) -> Bool {
        primaryLanguage(language) == "zh"
    }

    private static func primaryLanguage(
        _ language: TranslationLanguageTag
    ) -> String {
        language.rawValue.lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? language.rawValue.lowercased()
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        guard disclosureStore.isAcknowledged(source: source) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: TranslationServiceAdapterError.unavailable(
                        code: "confirmation_required",
                        message: L10n.string(
                            "translation.community.confirmation.title"
                        )
                    )
                )
            }
        }
        return AsyncThrowingStream<TranslationServiceEvent, Error> {
            continuation in
            let task = Task { [worker, source] in
                let startedAt = Date()
                do {
                    let output = try await worker.translate(request)
                    try Task.checkCancellation()
                    continuation.yield(
                        .completed(
                            output,
                            diagnostics:
                                TranslationResultDiagnostics(
                                    auditID: UUID().uuidString,
                                    durationMS: max(
                                        0,
                                        Int(
                                            Date().timeIntervalSince(
                                                startedAt
                                            ) * 1_000
                                        )
                                    ),
                                    route: source.rawValue,
                                    status: "succeeded"
                                )
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: CancellationError()
                    )
                } catch let error as TranslationCommunityWebError {
                    let errorCode = error.adapterErrorCode
                    continuation.yield(
                        .diagnostics(
                            TranslationResultDiagnostics(
                                auditID: UUID().uuidString,
                                durationMS: max(
                                    0,
                                    Int(
                                        Date().timeIntervalSince(
                                            startedAt
                                        ) * 1_000
                                    )
                                ),
                                route: source.rawValue,
                                status: errorCode
                            )
                        )
                    )
                    continuation.finish(
                        throwing:
                            TranslationServiceAdapterError.failed(
                                code: errorCode,
                                message:
                                    error.errorDescription
                                        ?? L10n.string(
                                            "translation.error.generic"
                                        )
                            )
                    )
                } catch let urlError as URLError {
                    let errorCode: String
                    switch urlError.code {
                    case .cancelled:
                        continuation.finish(
                            throwing: CancellationError()
                        )
                        return
                    case .timedOut:
                        errorCode = "network_timed_out"
                    case .networkConnectionLost:
                        errorCode = "network_connection_lost"
                    case .cannotFindHost,
                         .cannotConnectToHost,
                         .dnsLookupFailed,
                         .notConnectedToInternet:
                        errorCode = "network_unavailable"
                    default:
                        errorCode = "network_request_failed"
                    }
                    continuation.yield(
                        .diagnostics(
                            TranslationResultDiagnostics(
                                auditID: UUID().uuidString,
                                durationMS: max(
                                    0,
                                    Int(
                                        Date().timeIntervalSince(
                                            startedAt
                                        ) * 1_000
                                    )
                                ),
                                route: source.rawValue,
                                status: errorCode
                            )
                        )
                    )
                    continuation.finish(
                        throwing:
                            TranslationServiceAdapterError.failed(
                                code: errorCode,
                                message: L10n.string(
                                    "translation.community.error.network"
                                )
                            )
                    )
                } catch {
                    let errorCode = "network_request_failed"
                    continuation.yield(
                        .diagnostics(
                            TranslationResultDiagnostics(
                                auditID: UUID().uuidString,
                                durationMS: max(
                                    0,
                                    Int(
                                        Date().timeIntervalSince(
                                            startedAt
                                        ) * 1_000
                                    )
                                ),
                                route: source.rawValue,
                                status: errorCode
                            )
                        )
                    )
                    continuation.finish(
                        throwing:
                            TranslationServiceAdapterError.failed(
                                code: errorCode,
                                message:
                                    L10n.string(
                                        "translation.community.error.network"
                                    )
                            )
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

struct TranslationCommunityWebDisclosure: Codable, Hashable {
    static let currentVersion = 1

    let sourceID: String
    let disclosureVersion: Int
    let destinationHosts: [String]

    init(
        sourceID: String,
        disclosureVersion: Int = Self.currentVersion,
        destinationHosts: some Sequence<String>
    ) {
        self.sourceID = sourceID
        self.disclosureVersion = disclosureVersion
        self.destinationHosts = Array(
            Set(destinationHosts.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            })
        ).sorted()
    }

    init(source: TranslationCommunityWebSource) {
        self.init(
            sourceID: source.rawValue,
            destinationHosts: source.allowedHosts
        )
    }
}

struct TranslationCommunityWebDisclosureStore {
    private static let key = "translation.communityWeb.disclosures.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAcknowledged(
        source: TranslationCommunityWebSource
    ) -> Bool {
        isAcknowledged(disclosure: .init(source: source))
    }

    func isAcknowledged(
        disclosure: TranslationCommunityWebDisclosure
    ) -> Bool {
        disclosures.contains(disclosure)
    }

    func acknowledge(source: TranslationCommunityWebSource) {
        acknowledge(disclosure: .init(source: source))
    }

    func acknowledge(disclosure: TranslationCommunityWebDisclosure) {
        var values = disclosures
        values.insert(disclosure)
        guard let data = try? JSONEncoder().encode(values.sorted {
            $0.sourceID == $1.sourceID
                ? $0.disclosureVersion < $1.disclosureVersion
                : $0.sourceID < $1.sourceID
        }) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    private var disclosures: Set<TranslationCommunityWebDisclosure> {
        guard let data = defaults.data(forKey: Self.key),
              let values = try? JSONDecoder().decode(
                  [TranslationCommunityWebDisclosure].self,
                  from: data
              ) else {
            // The prior ID-only acknowledgement key cannot establish consent
            // for a destination or disclosure-version-bound contract.
            return []
        }
        return Set(values)
    }
}
