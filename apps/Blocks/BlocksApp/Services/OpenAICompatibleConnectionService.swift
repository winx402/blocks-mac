import BlocksCore
import Foundation

enum OpenAIConnectionStatus: String, Codable, CaseIterable {
    case success
    case missingConfiguration = "missing_configuration"
    case confirmationRequired = "confirmation_required"
    case missingSecret = "missing_secret"
    case invalidBaseURL = "invalid_base_url"
    case unauthorized
    case forbidden
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case timeout
    case networkError = "network_error"
    case invalidResponse = "invalid_response"
    case httpError = "http_error"
    case unsupportedCapability = "unsupported_capability"
}

struct OpenAIConnectionTestProfile: Equatable {
    let providerName: String
    let baseURL: String
    let modelName: String
    let keychainAccountAlias: String
    let timeoutSeconds: Int
}

struct OpenAIConnectionTestResult: Codable, Equatable {
    let ok: Bool
    let status: OpenAIConnectionStatus
    let providerName: String
    let baseURLSummary: String
    let modelName: String
    let keychainAccountAlias: String
    let endpointSummary: String
    let httpStatusCode: Int?
    let durationMS: Int
    let requestID: String?
    let responseTextCharacterCount: Int?
    let secretLength: Int?
    let auditID: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case providerName = "provider_name"
        case baseURLSummary = "base_url_summary"
        case modelName = "model_name"
        case keychainAccountAlias = "keychain_account_alias"
        case endpointSummary = "endpoint_summary"
        case httpStatusCode = "http_status_code"
        case durationMS = "duration_ms"
        case requestID = "request_id"
        case responseTextCharacterCount = "response_text_character_count"
        case secretLength = "secret_length"
        case auditID = "audit_id"
        case warnings
    }
}

struct OpenAIConnectionTransportResponse: @unchecked Sendable {
    let httpResponse: HTTPURLResponse
    let data: Data
}

protocol OpenAIConnectionTransport {
    func perform(_ request: URLRequest, timeoutSeconds: Int) async throws -> OpenAIConnectionTransportResponse
    func makeOperation(_ request: URLRequest, timeoutSeconds: Int) -> any OpenAIConnectionTransportOperation
}

protocol OpenAIConnectionTransportOperation: AnyObject, Sendable {
    @discardableResult func start() -> Bool
    func response() async throws -> OpenAIConnectionTransportResponse
    func cancel()
}

extension OpenAIConnectionTransport {
    func makeOperation(_ request: URLRequest, timeoutSeconds: Int) -> any OpenAIConnectionTransportOperation {
        DeferredOpenAIConnectionTransportOperation { [self] in
            try await perform(request, timeoutSeconds: timeoutSeconds)
        }
    }
}

protocol OpenAIURLSessionLoading: Sendable {
    func data(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse)
}

extension URLSession: OpenAIURLSessionLoading {}

struct URLSessionOpenAIConnectionTransport: OpenAIConnectionTransport {
    typealias AddressResolver = @Sendable (String) async throws
        -> [BlocksNativePluginResolvedAddress]
    typealias PinnedTransport = @Sendable (BlocksNativePluginPinnedHTTPRequest)
        async throws -> BlocksNativePluginPinnedHTTPResponse

    #if DEBUG
    private let session: (any OpenAIURLSessionLoading)?
    private let addressResolver: AddressResolver
    private let pinnedTransport: PinnedTransport

    init() {
        session = nil
        addressResolver = { try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0) }
        pinnedTransport = { try await BlocksNativePluginPinnedHTTPTransport.perform($0) }
    }

    init(session: URLSession) {
        self.session = session
        addressResolver = { try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0) }
        pinnedTransport = { try await BlocksNativePluginPinnedHTTPTransport.perform($0) }
    }

    init(session: any OpenAIURLSessionLoading) {
        self.session = session
        addressResolver = { try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0) }
        pinnedTransport = { try await BlocksNativePluginPinnedHTTPTransport.perform($0) }
    }

    init(
        addressResolver: @escaping AddressResolver,
        pinnedTransport: @escaping PinnedTransport
    ) {
        session = nil
        self.addressResolver = addressResolver
        self.pinnedTransport = pinnedTransport
    }
    #else
    init() {}
    #endif

    func perform(_ request: URLRequest, timeoutSeconds: Int) async throws -> OpenAIConnectionTransportResponse {
        let operation = makeOperation(request, timeoutSeconds: timeoutSeconds)
        _ = operation.start()
        return try await operation.response()
    }

    func makeOperation(_ request: URLRequest, timeoutSeconds: Int) -> any OpenAIConnectionTransportOperation {
        DeferredOpenAIConnectionTransportOperation {
            #if DEBUG
            if let session = self.session {
                return try await Self.performFoundationRequest(
                    request,
                    timeoutSeconds: timeoutSeconds,
                    session: session,
                    requireLiteralLoopback: false
                )
            }
            if request.url?.scheme?.lowercased() == "http" {
                return try await Self.performProductionRequest(
                    request,
                    timeoutSeconds: timeoutSeconds
                )
            }
            return try await Self.performPinnedHTTPSRequest(
                request,
                timeoutSeconds: timeoutSeconds,
                addressResolver: self.addressResolver,
                pinnedTransport: self.pinnedTransport
            )
            #else
            return try await Self.performProductionRequest(
                request,
                timeoutSeconds: timeoutSeconds
            )
            #endif
        }
    }

    private static func performProductionRequest(
        _ request: URLRequest,
        timeoutSeconds: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        guard request.url?.scheme?.lowercased() == "http" else {
            return try await performPinnedHTTPSRequest(
                request,
                timeoutSeconds: timeoutSeconds,
                addressResolver: {
                    try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0)
                },
                pinnedTransport: { try await BlocksNativePluginPinnedHTTPTransport.perform($0) }
            )
        }
        guard let host = request.url?.host, isLiteralLoopback(host) else {
            throw URLError(.unsupportedURL)
        }
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: URLSession.shared.configuration,
            request: request,
            timeoutSeconds: timeoutSeconds
        )
        guard operation.start() else {
            return try await operation.response()
        }
        return try await operation.response()
    }

    private static func performFoundationRequest(
        _ request: URLRequest,
        timeoutSeconds: Int,
        session: any OpenAIURLSessionLoading,
        requireLiteralLoopback: Bool
    ) async throws -> OpenAIConnectionTransportResponse {
        guard let host = request.url?.host,
              !requireLiteralLoopback || isLiteralLoopback(host) else {
            throw URLError(.unsupportedURL)
        }
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: Double(timeoutSeconds)
        )
        var requestWithDeadline = request
        requestWithDeadline.timeoutInterval = try deadline.remainingSeconds()
        let boundedRequest = requestWithDeadline
        return try await deadline.run {
            let redirectDelegate = OpenAIRedirectDenyTaskDelegate()
            let (data, response) = try await session.data(
                for: boundedRequest,
                delegate: redirectDelegate
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard let boundedResponse = HTTPURLResponse(
                url: httpResponse.url ?? request.url!,
                statusCode: httpResponse.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: boundedHeaders(httpResponse.allHeaderFields.reduce(into: [:]) {
                    $0[String(describing: $1.key)] = String(describing: $1.value)
                })
            ) else { throw URLError(.badServerResponse) }
            return OpenAIConnectionTransportResponse(
                httpResponse: boundedResponse,
                data: try boundedResponseData(data)
            )
        }
    }

    private static func performPinnedHTTPSRequest(
        _ request: URLRequest,
        timeoutSeconds: Int,
        addressResolver: @escaping AddressResolver,
        pinnedTransport: @escaping PinnedTransport
    ) async throws -> OpenAIConnectionTransportResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw URLError(.unsupportedURL)
        }
        // The configuration gate normally rejects invalid explicit ports
        // before a secret read or transport creation. Recheck at the HTTPS
        // boundary so direct callers cannot resolve or pin an URL whose port
        // parsed away to nil.
        guard ProviderRuntimeGate.isAllowedProviderBaseURL(url.absoluteString)
        else {
            throw URLError(.badURL)
        }
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: Double(timeoutSeconds)
        )
        let addresses = try await deadline.run {
            try await addressResolver(host)
        }
        try BlocksNativePluginResolvedAddressPolicy.validate(addresses, host: host)
        let port = url.port ?? 443
        guard (1...65_535).contains(port) else { throw URLError(.badURL) }
        let boundedRequest = BlocksNativePluginNetworkRequest(
            url: url.absoluteString,
            method: .post,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeoutSeconds: min(Double(timeoutSeconds), try deadline.remainingSeconds())
        )
        let response = try await deadline.run {
            try await pinnedTransport(
                BlocksNativePluginPinnedHTTPRequest(
                    request: boundedRequest,
                    url: url,
                    originalHost: host,
                    port: UInt16(port),
                    addresses: addresses,
                    deadline: deadline
                )
            )
        }
        let headerFields = boundedHeaders(response.headers)
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else { throw URLError(.badServerResponse) }
        return OpenAIConnectionTransportResponse(
            httpResponse: httpResponse,
            data: try boundedResponseData(response.body)
        )
    }

    private static func isLiteralLoopback(_ host: String) -> Bool {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == "127.0.0.1"
            || host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == "::1"
    }

    private static func boundedResponseData(_ data: Data) throws -> Data {
        guard data.count <= BlocksNativePluginNetworkPolicy.maximumResponseBytes else {
            throw BlocksNativePluginNetworkBrokerError.responseTooLarge
        }
        return data
    }

    private static func boundedHeaders(_ headers: [String: String]) -> [String: String] {
        var bounded: [String: String] = [:]
        var totalBytes = 0
        for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard bounded.count < 64, name.caseInsensitiveCompare("Set-Cookie") != .orderedSame else { continue }
            let value = String(value.prefix(4_096))
            guard totalBytes + name.utf8.count + value.utf8.count <= 64 * 1_024 else { break }
            bounded[name] = value
            totalBytes += name.utf8.count + value.utf8.count
        }
        return bounded
    }
}

private final class DeferredOpenAIConnectionTransportOperation: OpenAIConnectionTransportOperation, @unchecked Sendable {
    private enum State { case prepared, started, cancelled, completed(Result<OpenAIConnectionTransportResponse, Error>) }
    private let lock = NSLock()
    private let perform: () async throws -> OpenAIConnectionTransportResponse
    private var state: State = .prepared
    private var waiter: CheckedContinuation<OpenAIConnectionTransportResponse, Error>?
    private var task: Task<Void, Never>?

    init(perform: @escaping () async throws -> OpenAIConnectionTransportResponse) { self.perform = perform }
    @discardableResult func start() -> Bool {
        lock.lock(); guard case .prepared = state else { lock.unlock(); return false }
        state = .started
        task = Task { [weak self] in
            guard let self else { return }
            do { self.finish(.success(try await self.perform())) } catch { self.finish(.failure(error)) }
        }
        lock.unlock(); return true
    }
    func response() async throws -> OpenAIConnectionTransportResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                switch state {
                case let .completed(result): lock.unlock(); continuation.resume(with: result)
                case .cancelled: lock.unlock(); continuation.resume(throwing: CancellationError())
                case .prepared, .started:
                    guard waiter == nil else {
                        lock.unlock()
                        continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                        return
                    }
                    waiter = continuation
                    lock.unlock()
                }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() {
        lock.lock()
        let canCancel: Bool
        switch state { case .prepared, .started: canCancel = true; default: canCancel = false }
        guard canCancel else { lock.unlock(); return }
        state = .cancelled; let waiter = self.waiter; self.waiter = nil; let task = self.task
        lock.unlock(); task?.cancel(); waiter?.resume(throwing: CancellationError())
    }
    private func finish(_ result: Result<OpenAIConnectionTransportResponse, Error>) {
        lock.lock(); guard case .started = state else { lock.unlock(); return }
        state = .completed(result); let waiter = self.waiter; self.waiter = nil
        lock.unlock(); waiter?.resume(with: result)
    }
}

final class NativeURLSessionOpenAIOperation: NSObject, OpenAIConnectionTransportOperation, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let maximumTimeoutSeconds = 86_400
    private enum State { case prepared, started, cancelled, completed(Result<OpenAIConnectionTransportResponse, Error>) }
    private let lock = NSLock()
    private let sessionConfiguration: URLSessionConfiguration
    private let request: URLRequest
    private let timeoutSeconds: Int
    private let deadlineElapsedOverrideForTesting: Bool?
    private var state: State = .prepared
    private var data = Data()
    private var httpResponse: HTTPURLResponse?
    // The operation owns this short-lived session so its delegate can reject redirects.
    // It is released after cancellation or completion to break the session/delegate cycle.
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadlineTask: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var waiter: CheckedContinuation<OpenAIConnectionTransportResponse, Error>?
    #if DEBUG
    private var waiterInstalledObserver: (@Sendable () -> Void)?
    #endif

    init(
        sessionConfiguration: URLSessionConfiguration,
        request: URLRequest,
        timeoutSeconds: Int,
        deadlineElapsedOverrideForTesting: Bool? = nil
    ) {
        self.sessionConfiguration = sessionConfiguration.copy() as! URLSessionConfiguration
        self.request = request
        self.timeoutSeconds = timeoutSeconds
        self.deadlineElapsedOverrideForTesting = deadlineElapsedOverrideForTesting
    }

    @discardableResult func start() -> Bool {
        let boundedTimeoutSeconds = Self.boundedTimeoutSeconds(timeoutSeconds)
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: Double(boundedTimeoutSeconds)
        )
        let timeout: Double
        do {
            timeout = try deadline.remainingSeconds()
        } catch {
            completeBeforeStart(.failure(error))
            return false
        }
        var boundedRequest = request
        boundedRequest.timeoutInterval = timeout
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: boundedRequest)

        lock.lock()
        guard case .prepared = state else {
            lock.unlock()
            session.invalidateAndCancel()
            return false
        }
        self.session = session
        self.task = task
        self.deadline = deadline.instant
        state = .started
        let deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            self?.complete(
                .failure(
                    BlocksNativePluginNetworkBrokerError.transport(
                        "The request timed out."
                    )
                ),
                cancelUnderlying: true
            )
        }
        self.deadlineTask = deadlineTask
        lock.unlock()
        task.resume()
        return true
    }

    static func boundedTimeoutSeconds(_ timeoutSeconds: Int) -> Int {
        min(max(timeoutSeconds, 0), maximumTimeoutSeconds)
    }
    func response() async throws -> OpenAIConnectionTransportResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                switch state {
                case let .completed(result): lock.unlock(); continuation.resume(with: result)
                case .cancelled: lock.unlock(); continuation.resume(throwing: CancellationError())
                case .prepared, .started:
                    guard waiter == nil else {
                        lock.unlock()
                        continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                        return
                    }
                    waiter = continuation
                    #if DEBUG
                    let observer = waiterInstalledObserver
                    #endif
                    lock.unlock()
                    #if DEBUG
                    observer?()
                    #endif
                }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() {
        lock.lock()
        let isCancellable: Bool
        switch state {
        case .prepared, .started:
            isCancellable = true
        case .cancelled, .completed:
            isCancellable = false
        }
        guard isCancellable else {
            lock.unlock()
            return
        }
        state = .cancelled
        let waiter = self.waiter
        self.waiter = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        let deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        self.deadline = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        deadlineTask?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        waiter?.resume(throwing: CancellationError())
    }
    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard case .started = state else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength
            > Int64(BlocksNativePluginNetworkPolicy.maximumResponseBytes) {
            lock.unlock()
            complete(
                .failure(BlocksNativePluginNetworkBrokerError.responseTooLarge),
                cancelUnderlying: true
            )
            completionHandler(.cancel)
            return
        }
        if let response = response as? HTTPURLResponse {
            httpResponse = Self.boundedHTTPResponse(response)
        }
        lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard case .started = state else {
            lock.unlock()
            return
        }
        guard self.data.count <= BlocksNativePluginNetworkPolicy.maximumResponseBytes - data.count else {
            lock.unlock()
            complete(
                .failure(BlocksNativePluginNetworkBrokerError.responseTooLarge),
                cancelUnderlying: true
            )
            return
        }
        self.data.append(data)
        lock.unlock()
    }
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<OpenAIConnectionTransportResponse, Error>
        if let error { result = .failure(error) }
        else {
            lock.lock()
            let response = httpResponse
            let data = self.data
            lock.unlock()
            if let response {
                result = .success(
                    OpenAIConnectionTransportResponse(
                        httpResponse: response,
                        data: data
                    )
                )
            } else {
                result = .failure(URLError(.badServerResponse))
            }
        }
        complete(result, cancelUnderlying: false)
    }

    private func complete(
        _ result: Result<OpenAIConnectionTransportResponse, Error>,
        cancelUnderlying: Bool
    ) {
        lock.lock()
        guard case .started = state else {
            lock.unlock()
            return
        }
        let finalResult: Result<OpenAIConnectionTransportResponse, Error>
        let shouldCancelUnderlying: Bool
        if case .success = result,
           let deadline,
           deadlineElapsedOverrideForTesting ?? (ContinuousClock.now >= deadline) {
            finalResult = .failure(
                BlocksNativePluginNetworkBrokerError.transport(
                    "The request timed out."
                )
            )
            shouldCancelUnderlying = true
        } else {
            finalResult = result
            shouldCancelUnderlying = cancelUnderlying
        }
        state = .completed(finalResult)
        let waiter = self.waiter
        self.waiter = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        let deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        self.deadline = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        deadlineTask?.cancel()
        if shouldCancelUnderlying {
            task?.cancel()
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        waiter?.resume(with: finalResult)
    }

    private func completeBeforeStart(
        _ result: Result<OpenAIConnectionTransportResponse, Error>
    ) {
        lock.lock()
        guard case .prepared = state else {
            lock.unlock()
            return
        }
        state = .completed(result)
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private static func boundedHTTPResponse(
        _ response: HTTPURLResponse
    ) -> HTTPURLResponse? {
        var headers: [String: String] = [:]
        var totalBytes = 0
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            guard name.caseInsensitiveCompare("Set-Cookie") != .orderedSame,
                  headers.count < 64 else { continue }
            let value = String(describing: value).prefix(4_096)
            guard totalBytes + name.utf8.count + value.utf8.count <= 64 * 1_024 else { break }
            headers[name] = String(value)
            totalBytes += name.utf8.count + value.utf8.count
        }
        return HTTPURLResponse(
            url: response.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    #if DEBUG
    func setWaiterInstalledObserverForTesting(
        _ observer: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        waiterInstalledObserver = observer
        lock.unlock()
    }
    #endif
}

private final class OpenAIRedirectDenyTaskDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct OpenAICompatibleConnectionService {
    private let transport: OpenAIConnectionTransport
    private let endpointSummary = "POST /v1/chat/completions"

    init(transport: OpenAIConnectionTransport = URLSessionOpenAIConnectionTransport()) {
        self.transport = transport
    }

    func testConnection(
        profile: OpenAIConnectionTestProfile,
        secretMaterial: ProviderUserSecretMaterial,
        authorizationCheck: @MainActor @Sendable () -> Bool = { true },
        admission: (@MainActor @Sendable (() -> Bool) -> Bool)? = nil
    ) async -> OpenAIConnectionTestResult {
        let startedAt = Date()
        guard let endpointURL = endpointURL(from: profile.baseURL) else {
            return result(
                profile: profile,
                ok: false,
                status: .invalidBaseURL,
                httpStatusCode: nil,
                durationMS: elapsedMS(since: startedAt),
                requestID: nil,
                responseTextCharacterCount: nil,
                secretLength: secretMaterial.secretLength,
                warnings: ["invalid_base_url"]
            )
        }

        guard await authorizationCheck() else {
            return result(
                profile: profile,
                ok: false,
                status: .confirmationRequired,
                httpStatusCode: nil,
                durationMS: elapsedMS(since: startedAt),
                requestID: nil,
                responseTextCharacterCount: nil,
                secretLength: nil,
                warnings: [
                    "confirmation_required",
                    "provider_call_not_executed",
                ]
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
            request.httpBody = try requestBody(modelName: profile.modelName)

            let operation = transport.makeOperation(
                request,
                timeoutSeconds: profile.timeoutSeconds
            )
            let response: OpenAIConnectionTransportResponse? = try await withTaskCancellationHandler {
                let started = if let admission {
                    await admission { operation.start() }
                } else {
                    await authorizationCheck() && operation.start()
                }
                guard started else { return nil }
                return try await operation.response()
            } onCancel: {
                // Cancellation and start linearize through the operation's
                // own lock. If cancellation wins, start() returns false and
                // no URLSession task is resumed; if start wins, the task is
                // cancelled immediately afterward.
                operation.cancel()
            }
            guard let response else {
                return result(
                    profile: profile,
                    ok: false,
                    status: .confirmationRequired,
                    httpStatusCode: nil,
                    durationMS: elapsedMS(since: startedAt),
                    requestID: nil,
                    responseTextCharacterCount: nil,
                    secretLength: nil,
                    warnings: [
                        "confirmation_required",
                        "provider_call_not_executed",
                    ]
                )
            }

            let statusCode = response.httpResponse.statusCode
            let requestID = headerValue("x-request-id", in: response.httpResponse)

            guard await authorizationCheck() else {
                return result(
                    profile: profile,
                    ok: false,
                    status: .confirmationRequired,
                    httpStatusCode: statusCode,
                    durationMS: elapsedMS(since: startedAt),
                    requestID: requestID,
                    responseTextCharacterCount: nil,
                    secretLength: nil,
                    warnings: [
                        "external_transfer_disabled",
                        "authorization_revoked_after_transport",
                        "provider_response_redacted",
                    ]
                )
            }

            if (200..<300).contains(statusCode) {
                guard let responseCharacterCount = parsedTextCharacterCount(from: response.data) else {
                    return result(
                        profile: profile,
                        ok: false,
                        status: .invalidResponse,
                        httpStatusCode: statusCode,
                        durationMS: elapsedMS(since: startedAt),
                        requestID: requestID,
                        responseTextCharacterCount: nil,
                        secretLength: secretMaterial.secretLength,
                        warnings: ["provider_response_redacted", "invalid_response_shape"]
                    )
                }
                return result(
                    profile: profile,
                    ok: true,
                    status: .success,
                    httpStatusCode: statusCode,
                    durationMS: elapsedMS(since: startedAt),
                    requestID: requestID,
                    responseTextCharacterCount: responseCharacterCount,
                    secretLength: secretMaterial.secretLength,
                    warnings: ["provider_response_redacted"]
                )
            }

            return result(
                profile: profile,
                ok: false,
                status: normalizedStatus(httpStatusCode: statusCode),
                httpStatusCode: statusCode,
                durationMS: elapsedMS(since: startedAt),
                requestID: requestID,
                responseTextCharacterCount: nil,
                secretLength: secretMaterial.secretLength,
                warnings: responseWarnings(httpStatusCode: statusCode)
            )
        } catch {
            return result(
                profile: profile,
                ok: false,
                status: normalizedStatus(error: error),
                httpStatusCode: nil,
                durationMS: elapsedMS(since: startedAt),
                requestID: nil,
                responseTextCharacterCount: nil,
                secretLength: secretMaterial.secretLength,
                warnings: ["provider_response_redacted", "transport_error_redacted"]
            )
        }
    }

    func missingSecretResult(profile: OpenAIConnectionTestProfile, message: String) -> OpenAIConnectionTestResult {
        result(
            profile: profile,
            ok: false,
            status: .missingSecret,
            httpStatusCode: nil,
            durationMS: 0,
            requestID: nil,
            responseTextCharacterCount: nil,
            secretLength: nil,
            warnings: ["missing_keychain_secret", message]
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

    private func requestBody(modelName: String) throws -> Data {
        let sanitizedModel = sanitized(modelName, fallback: "model-placeholder")
        let body: [String: Any] = [
            "model": sanitizedModel,
            "messages": [
                [
                    "role": "user",
                    "content": "ping"
                ]
            ],
            "max_tokens": 8,
            "stream": false
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func parsedTextCharacterCount(from data: Data) -> Int? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            return nil
        }

        if
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.isEmpty
        {
            return content.count
        }

        if let text = first["text"] as? String, !text.isEmpty {
            return text.count
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
        profile: OpenAIConnectionTestProfile,
        ok: Bool,
        status: OpenAIConnectionStatus,
        httpStatusCode: Int?,
        durationMS: Int,
        requestID: String?,
        responseTextCharacterCount: Int?,
        secretLength: Int?,
        warnings: [String]
    ) -> OpenAIConnectionTestResult {
        let id = UUID().uuidString
        return OpenAIConnectionTestResult(
            ok: ok,
            status: status,
            providerName: sanitized(profile.providerName, fallback: "OpenAI-compatible"),
            baseURLSummary: summarizeBaseURL(profile.baseURL),
            modelName: sanitized(profile.modelName, fallback: "model-placeholder"),
            keychainAccountAlias: sanitized(profile.keychainAccountAlias, fallback: "account-alias-placeholder"),
            endpointSummary: endpointSummary,
            httpStatusCode: httpStatusCode,
            durationMS: durationMS,
            requestID: requestID,
            responseTextCharacterCount: responseTextCharacterCount,
            secretLength: secretLength,
            auditID: ProviderAuditID.make(
                prefix: "llm_test",
                uuidString: id
            ),
            warnings: warnings
        )
    }

    private func summarizeBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else {
            return "base-url-placeholder"
        }
        if let scheme = url.scheme {
            return "\(scheme)://\(host)"
        }
        return host
    }

    private func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }
}
