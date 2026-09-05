import BlocksCore
import Darwin
import Foundation
import Network
import Security

enum BlocksNativePluginNetworkBrokerError: Error, LocalizedError {
    case domainWasNotApproved(String)
    case secretWasNotApproved(String)
    case secretMissing(String)
    case secretValueInvalid(String)
    case invalidHTTPResponse
    case responseTooLarge
    case redirectDenied(String)
    case tooManyRedirects
    case resolvedAddressDenied(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .domainWasNotApproved(domain):
            return "Network access to \(domain) was not approved."
        case let .secretWasNotApproved(secretID):
            return "Access to plugin secret \(secretID) was not approved."
        case let .secretMissing(secretID):
            return "The required plugin secret is missing: \(secretID)."
        case let .secretValueInvalid(secretID):
            return "The plugin secret contains characters that are unsafe for this request: \(secretID)."
        case .invalidHTTPResponse:
            return "The plugin host received an invalid HTTP response."
        case .responseTooLarge:
            return "The plugin host stopped a response that exceeded the size limit."
        case let .redirectDenied(url):
            return "The plugin host denied a redirect to \(url)."
        case .tooManyRedirects:
            return "The plugin host stopped a request that exceeded the redirect limit."
        case let .resolvedAddressDenied(host):
            return "The plugin host denied a private or local address resolved by \(host)."
        case let .transport(message):
            return "The plugin network request failed: \(message)"
        }
    }
}

enum BlocksNativePluginResolvedAddress: Hashable, Sendable {
    case ipv4(String)
    case ipv6(String)

    fileprivate var endpointHost: NWEndpoint.Host? {
        switch self {
        case let .ipv4(value):
            return IPv4Address(value).map(NWEndpoint.Host.ipv4)
        case let .ipv6(value):
            return IPv6Address(value).map(NWEndpoint.Host.ipv6)
        }
    }
}

struct BlocksNativePluginPinnedHTTPRequest: Sendable {
    let request: BlocksNativePluginNetworkRequest
    let url: URL
    let originalHost: String
    let port: UInt16
    let addresses: [BlocksNativePluginResolvedAddress]
    let deadline: BlocksNativePluginRequestDeadline?

    init(
        request: BlocksNativePluginNetworkRequest,
        url: URL,
        originalHost: String,
        port: UInt16,
        addresses: [BlocksNativePluginResolvedAddress],
        deadline: BlocksNativePluginRequestDeadline? = nil
    ) {
        self.request = request
        self.url = url
        self.originalHost = originalHost
        self.port = port
        self.addresses = addresses
        self.deadline = deadline
    }
}

struct BlocksNativePluginPinnedHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct BlocksNativePluginPinnedConnectionDescriptor: Equatable, Sendable {
    let address: BlocksNativePluginResolvedAddress
    let serverName: String
    let port: UInt16
}

actor BlocksNativePluginNetworkBroker {
    typealias SecretResolver = @Sendable (
        _ pluginID: String,
        _ secretID: String
    ) async throws -> String
    typealias AddressResolver = @Sendable (
        _ host: String
    ) async throws -> [BlocksNativePluginResolvedAddress]
    typealias PinnedTransport = @Sendable (
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse

    private static let maximumRedirects = 5
    private static let timeoutMessage = "The request timed out."

    private let policy: BlocksNativePluginNetworkPolicy
    private let secretResolver: SecretResolver
    private let addressResolver: AddressResolver
    private let pinnedTransport: PinnedTransport

    init(
        policy: BlocksNativePluginNetworkPolicy = .init(),
        secretResolver: @escaping SecretResolver,
        addressResolver: @escaping AddressResolver = {
            try await BlocksNativePluginResolvedAddressPolicy.resolve(host: $0)
        },
        pinnedTransport: @escaping PinnedTransport = {
            try await BlocksNativePluginPinnedHTTPTransport.perform($0)
        }
    ) {
        self.policy = policy
        self.secretResolver = secretResolver
        self.addressResolver = addressResolver
        self.pinnedTransport = pinnedTransport
    }

    func perform(
        request: BlocksNativePluginNetworkRequest,
        manifest: BlocksNativePluginManifest,
        approvedDomains: Set<String>,
        approvedMethods: Set<BlocksNativePluginHTTPMethod>,
        approvedSecretIDs: Set<String>
    ) async throws -> BlocksNativePluginNetworkResponse {
        let initialValidation = try policy.validate(request, manifest: manifest)
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: request.timeoutSeconds
        )
        if let unapprovedSecret = initialValidation.referencedSecretIDs
            .subtracting(approvedSecretIDs)
            .sorted()
            .first {
            throw BlocksNativePluginNetworkBrokerError.secretWasNotApproved(
                unapprovedSecret
            )
        }
        let secretBearingHeaders = Set(
            try request.headers.compactMap { name, value in
                try BlocksNativePluginSecretReferenceParser.references(in: value)
                    .isEmpty ? nil : name.lowercased()
            }
        )
        let bodyContainsSecret: Bool
        if let body = request.body,
           let bodyText = String(data: body, encoding: .utf8) {
            bodyContainsSecret = try !BlocksNativePluginSecretReferenceParser
                .references(in: bodyText)
                .isEmpty
        } else {
            bodyContainsSecret = false
        }

        var currentRequest = try await deadline.run(
            operation: { [secretResolver] in
                try await Self.resolveSecrets(
                    in: request,
                    manifest: manifest,
                    secretResolver: secretResolver
                )
            }
        )
        var redirectCount = 0

        while true {
            try Task.checkCancellation()
            let validated = try policy.validate(currentRequest, manifest: manifest)
            guard approvedMethods.contains(currentRequest.method) else {
                throw BlocksNativePluginNetworkPolicyError.methodNotAllowed(
                    currentRequest.method.rawValue
                )
            }
            guard let host = validated.url.host?.lowercased(),
                  Self.isApproved(host: host, domains: approvedDomains) else {
                throw BlocksNativePluginNetworkBrokerError.domainWasNotApproved(
                    validated.url.host ?? "unknown"
                )
            }
            let port = validated.url.port ?? 443
            guard (1...65_535).contains(port) else {
                throw BlocksNativePluginNetworkPolicyError.invalidURL
            }
            let resolvedAddresses = try await deadline.run(
                operation: { [addressResolver] in
                    try await addressResolver(host)
                }
            )
            try BlocksNativePluginResolvedAddressPolicy.validate(
                resolvedAddresses,
                host: host
            )
            let remaining = try deadline.remainingSeconds()
            let boundedRequest = BlocksNativePluginNetworkRequest(
                requestID: currentRequest.requestID,
                url: currentRequest.url,
                method: currentRequest.method,
                headers: currentRequest.headers,
                body: currentRequest.body,
                timeoutSeconds: min(currentRequest.timeoutSeconds, remaining)
            )
            let response: BlocksNativePluginPinnedHTTPResponse
            do {
                let pinnedRequest = BlocksNativePluginPinnedHTTPRequest(
                    request: boundedRequest,
                    url: validated.url,
                    originalHost: host,
                    port: UInt16(port),
                    addresses: resolvedAddresses,
                    deadline: deadline
                )
                response = try await deadline.run(
                    operation: { [pinnedTransport] in
                        try await pinnedTransport(pinnedRequest)
                    }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BlocksNativePluginNetworkBrokerError {
                throw error
            } catch {
                throw BlocksNativePluginNetworkBrokerError.transport(
                    String(error.localizedDescription.prefix(512))
                )
            }
            try policy.validateResponseSize(response.body.count)

            guard Self.isRedirectStatus(response.statusCode) else {
                return BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: response.statusCode,
                    headers: Self.boundedResponseHeaders(response.headers),
                    body: response.body
                )
            }
            guard redirectCount < Self.maximumRedirects,
                  let location = Self.headerValue(
                      named: "location",
                      in: response.headers
                  ),
                  let redirectURL = URL(
                      string: location,
                      relativeTo: validated.url
                  )?.absoluteURL else {
                if redirectCount >= Self.maximumRedirects {
                    throw BlocksNativePluginNetworkBrokerError.tooManyRedirects
                }
                throw BlocksNativePluginNetworkBrokerError.redirectDenied(
                    Self.headerValue(named: "location", in: response.headers)
                        ?? "missing"
                )
            }
            redirectCount += 1
            currentRequest = try makeRedirectRequest(
                from: currentRequest,
                sourceURL: validated.url,
                redirectURL: redirectURL,
                statusCode: response.statusCode,
                secretBearingHeaders: secretBearingHeaders,
                bodyContainsSecret: bodyContainsSecret,
                manifest: manifest,
                approvedDomains: approvedDomains,
                approvedMethods: approvedMethods
            )
        }
    }

    private func makeRedirectRequest(
        from request: BlocksNativePluginNetworkRequest,
        sourceURL: URL,
        redirectURL: URL,
        statusCode: Int,
        secretBearingHeaders: Set<String>,
        bodyContainsSecret: Bool,
        manifest: BlocksNativePluginManifest,
        approvedDomains: Set<String>,
        approvedMethods: Set<BlocksNativePluginHTTPMethod>
    ) throws -> BlocksNativePluginNetworkRequest {
        var method = request.method
        var body = request.body
        if statusCode == 303 || ((statusCode == 301 || statusCode == 302) && method == .post) {
            method = .get
            body = nil
        }
        try policy.validateRedirect(
            from: request,
            to: redirectURL,
            method: method,
            manifest: manifest
        )
        guard let redirectedHost = redirectURL.host?.lowercased(),
              Self.isApproved(host: redirectedHost, domains: approvedDomains),
              approvedMethods.contains(method) else {
            throw BlocksNativePluginNetworkBrokerError.redirectDenied(
                redirectURL.absoluteString
            )
        }

        let crossesOrigin = !Self.sameOrigin(sourceURL, redirectURL)
        if crossesOrigin, bodyContainsSecret, body != nil {
            throw BlocksNativePluginNetworkBrokerError.redirectDenied(
                redirectURL.absoluteString
            )
        }
        var headers = request.headers
        if crossesOrigin {
            headers = headers.filter { name, _ in
                let normalizedName = name.lowercased()
                return normalizedName != "authorization"
                    && normalizedName != "cookie"
                    && !secretBearingHeaders.contains(normalizedName)
            }
        }
        if body == nil {
            headers = headers.filter { name, _ in
                let normalizedName = name.lowercased()
                return normalizedName != "content-type"
                    && normalizedName != "content-encoding"
            }
        }
        return BlocksNativePluginNetworkRequest(
            requestID: request.requestID,
            url: redirectURL.absoluteString,
            method: method,
            headers: headers,
            body: body,
            timeoutSeconds: request.timeoutSeconds
        )
    }

    private static func resolveSecrets(
        in request: BlocksNativePluginNetworkRequest,
        manifest: BlocksNativePluginManifest,
        secretResolver: SecretResolver
    ) async throws -> BlocksNativePluginNetworkRequest {
        var allReferences = Set<String>()
        for value in request.headers.values {
            allReferences.formUnion(
                try BlocksNativePluginSecretReferenceParser.references(in: value)
            )
        }
        if let body = request.body,
           let bodyText = String(data: body, encoding: .utf8) {
            allReferences.formUnion(
                try BlocksNativePluginSecretReferenceParser.references(in: bodyText)
            )
        }

        var resolvedSecrets: [String: String] = [:]
        for secretID in allReferences.sorted() {
            let secret: String
            do {
                secret = try await secretResolver(manifest.id, secretID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BlocksNativePluginNetworkBrokerError.secretMissing(secretID)
            }
            guard !secret.contains("\r"), !secret.contains("\n") else {
                throw BlocksNativePluginNetworkBrokerError.secretValueInvalid(secretID)
            }
            resolvedSecrets[secretID] = secret
        }

        let headers = try request.headers.mapValues {
            try Self.substituteSecrets(in: $0, values: resolvedSecrets)
        }
        let body: Data?
        if let originalBody = request.body,
           let text = String(data: originalBody, encoding: .utf8) {
            body = Data(try Self.substituteSecrets(in: text, values: resolvedSecrets).utf8)
        } else {
            body = request.body
        }
        return BlocksNativePluginNetworkRequest(
            requestID: request.requestID,
            url: request.url,
            method: request.method,
            headers: headers,
            body: body,
            timeoutSeconds: request.timeoutSeconds
        )
    }

    private static func substituteSecrets(
        in value: String,
        values: [String: String]
    ) throws -> String {
        var result = value
        let references = try BlocksNativePluginSecretReferenceParser.references(in: value)
        for secretID in references {
            guard let secret = values[secretID] else {
                throw BlocksNativePluginNetworkBrokerError.secretMissing(secretID)
            }
            result = result.replacingOccurrences(
                of: "{{secret:\(secretID)}}",
                with: secret
            )
        }
        return result
    }

    private static func isApproved(
        host: String,
        domains: Set<String>
    ) -> Bool {
        domains.map { $0.lowercased() }.contains {
            matches(host: host, approvedDomain: $0)
        }
    }

    private static func matches(host: String, approvedDomain: String) -> Bool {
        if approvedDomain.hasPrefix("*.") {
            let suffix = String(approvedDomain.dropFirst(2))
            return host.hasSuffix("." + suffix) && host != suffix
        }
        return host == approvedDomain
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private static func isRedirectStatus(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    private static func headerValue(
        named name: String,
        in headers: [String: String]
    ) -> String? {
        headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static func boundedResponseHeaders(
        _ source: [String: String]
    ) -> [String: String] {
        var headers: [String: String] = [:]
        var totalBytes = 0
        for (name, value) in source.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            guard headers.count < 64 else { break }
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                continue
            }
            let boundedValue = String(value.prefix(4_096))
            let nextSize = name.utf8.count + boundedValue.utf8.count
            guard totalBytes + nextSize <= 64 * 1_024 else { break }
            headers[name] = boundedValue
            totalBytes += nextSize
        }
        return headers
    }

}

/// Shared absolute deadline semantics for request stages that must remain
/// bounded even when a dependency ignores cooperative cancellation.
struct BlocksNativePluginRequestDeadline: Sendable {
    private static let timeoutMessage = "The request timed out."

    private let deadline: ContinuousClock.Instant
    private let deadlineElapsedOverrideForTesting: Bool?

    init(
        timeoutSeconds: Double,
        deadlineElapsedOverrideForTesting: Bool? = nil
    ) {
        deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        self.deadlineElapsedOverrideForTesting = deadlineElapsedOverrideForTesting
    }

    func run<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = try remaining()
        let race = BlocksNativePluginDeadlineRace<Value>(
            deadline: deadline,
            deadlineElapsedOverrideForTesting: deadlineElapsedOverrideForTesting
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    remaining: remaining,
                    operation: operation
                )
            }
        } onCancel: {
            race.cancel()
        }
    }

    func remainingSeconds() throws -> Double {
        let components = try remaining().components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var instant: ContinuousClock.Instant { deadline }

    func remaining() throws -> Duration {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else {
            throw BlocksNativePluginNetworkBrokerError.transport(
                Self.timeoutMessage
            )
        }
        return remaining
    }
}

/// A deadline must release its caller even when an injected resolver or
/// transport ignores cooperative task cancellation. A structured task group
/// cannot provide that guarantee because leaving its scope waits for every
/// child. This race owns unstructured child tasks, resumes exactly once, and
/// still cancels the losing operation so cooperative implementations stop.
final class BlocksNativePluginDeadlineRace<Value: Sendable>:
    @unchecked Sendable
{
    typealias Continuation = CheckedContinuation<Value, Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: Result<Value, Error>?
    private let deadline: ContinuousClock.Instant
    private let deadlineElapsedOverrideForTesting: Bool?
    private let directCancellation: (@Sendable () -> Void)?

    init(
        deadline: ContinuousClock.Instant,
        deadlineElapsedOverrideForTesting: Bool? = nil,
        directCancellation: (@Sendable () -> Void)? = nil
    ) {
        self.deadline = deadline
        self.deadlineElapsedOverrideForTesting = deadlineElapsedOverrideForTesting
        self.directCancellation = directCancellation
    }

    func start(
        continuation: Continuation,
        remaining: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task { [weak self] in
            do {
                let value = try await operation()
                self?.finish(.success(value), cancelOperation: false)
            } catch {
                self?.finish(.failure(error), cancelOperation: false)
            }
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: remaining)
            } catch {
                return
            }
            self?.finish(
                .failure(
                    BlocksNativePluginNetworkBrokerError.transport(
                        "The request timed out."
                    )
                ),
                cancelOperation: true
            )
        }
        installTasks(operation: operationTask, timeout: timeoutTask)
    }

    func cancel() {
        finish(.failure(CancellationError()), cancelOperation: true)
    }

    private func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        lock.lock()
        if terminalResult == nil {
            operationTask = operation
            timeoutTask = timeout
            lock.unlock()
            return
        }
        lock.unlock()
        operation.cancel()
        timeout.cancel()
    }

    private func finish(
        _ result: Result<Value, Error>,
        cancelOperation: Bool
    ) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        let finalResult: Result<Value, Error>
        let shouldCancelOperation: Bool
        if case .success = result,
           deadlineElapsedOverrideForTesting ?? (ContinuousClock.now >= deadline) {
            finalResult = .failure(
                BlocksNativePluginNetworkBrokerError.transport(
                    "The request timed out."
                )
            )
            shouldCancelOperation = true
        } else {
            finalResult = result
            shouldCancelOperation = cancelOperation
        }
        terminalResult = finalResult
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        self.operationTask = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        if shouldCancelOperation {
            if let directCancellation {
                directCancellation()
            } else {
                operationTask?.cancel()
            }
        }
        timeoutTask?.cancel()
        continuation?.resume(with: finalResult)
    }
}

enum BlocksNativePluginResolvedAddressPolicy {
    private static let resolverQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.blocks.plugin-dns-resolver"
        queue.qualityOfService = .userInitiated
        // getaddrinfo does not expose a cancellation API. Keep any calls that
        // outlive their request bounded instead of creating one blocked thread
        // for every plugin request.
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func resolve(
        host: String
    ) async throws -> [BlocksNativePluginResolvedAddress] {
        let resolution = BlocksNativePluginDNSResolution(host: host)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.start(
                    on: resolverQueue,
                    continuation: continuation
                )
            }
        } onCancel: {
            resolution.cancel()
        }
    }

    static func validate(
        _ addresses: [BlocksNativePluginResolvedAddress],
        host: String
    ) throws {
        guard !addresses.isEmpty, addresses.count <= 32 else {
            throw BlocksNativePluginNetworkBrokerError.resolvedAddressDenied(host)
        }
        for address in addresses {
            switch address {
            case let .ipv4(value):
                var parsed = in_addr()
                guard inet_pton(AF_INET, value, &parsed) == 1 else {
                    throw BlocksNativePluginNetworkBrokerError.resolvedAddressDenied(host)
                }
                let integer = UInt32(bigEndian: parsed.s_addr)
                guard isPublicIPv4(integer) else {
                    throw BlocksNativePluginNetworkBrokerError.resolvedAddressDenied(host)
                }
            case let .ipv6(value):
                var parsed = in6_addr()
                guard inet_pton(AF_INET6, value, &parsed) == 1,
                      isPublicIPv6(parsed) else {
                    throw BlocksNativePluginNetworkBrokerError.resolvedAddressDenied(host)
                }
            }
        }
    }

    fileprivate static func resolveSynchronously(
        host: String
    ) throws -> [BlocksNativePluginResolvedAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let result else {
            throw BlocksNativePluginNetworkBrokerError.transport(
                "DNS resolution failed."
            )
        }
        defer { freeaddrinfo(result) }

        var addresses: [BlocksNativePluginResolvedAddress] = []
        var seen = Set<BlocksNativePluginResolvedAddress>()
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor?.pointee {
            let address: BlocksNativePluginResolvedAddress?
            if info.ai_family == AF_INET, let socketAddress = info.ai_addr {
                var value = socketAddress.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                address = inet_ntop(
                    AF_INET,
                    &value,
                    &buffer,
                    socklen_t(INET_ADDRSTRLEN)
                ).map { _ in .ipv4(String(cString: buffer)) }
            } else if info.ai_family == AF_INET6, let socketAddress = info.ai_addr {
                var value = socketAddress.withMemoryRebound(
                    to: sockaddr_in6.self,
                    capacity: 1
                ) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                address = inet_ntop(
                    AF_INET6,
                    &value,
                    &buffer,
                    socklen_t(INET6_ADDRSTRLEN)
                ).map { _ in .ipv6(String(cString: buffer)) }
            } else {
                address = nil
            }
            if let address, seen.insert(address).inserted {
                addresses.append(address)
            }
            guard addresses.count <= 32 else {
                throw BlocksNativePluginNetworkBrokerError.resolvedAddressDenied(host)
            }
            cursor = info.ai_next
        }
        try validate(addresses, host: host)
        return addresses
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        let third = UInt8((value >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 {
            return false
        }
        if first == 100, (64...127).contains(second) {
            return false
        }
        if first == 169, second == 254 {
            return false
        }
        if first == 172, (16...31).contains(second) {
            return false
        }
        if first == 192, second == 0 || second == 168 {
            return false
        }
        if first == 192, second == 88, third == 99 {
            return false
        }
        if first == 198, second == 18 || second == 19 {
            return false
        }
        if first == 198, second == 51, third == 100 {
            return false
        }
        if first == 203, second == 0, third == 113 {
            return false
        }
        return true
    }

    private static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }
        // Only globally routable unicast addresses are allowed. This excludes
        // unspecified, loopback, link-local, ULA, multicast and NAT64 ranges.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        // 6to4 and Teredo can tunnel embedded private IPv4 addresses; neither
        // is needed by the plugin transport.
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x01,
           bytes[2] == 0x00, bytes[3] == 0x00 {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x01,
           bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }
        return true
    }
}

private final class BlocksNativePluginDNSResolution: @unchecked Sendable {
    typealias Output = [BlocksNativePluginResolvedAddress]

    private let host: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var operation: BlockOperation?
    private var isFinished = false

    init(host: String) {
        self.host = host
    }

    func start(
        on queue: OperationQueue,
        continuation: CheckedContinuation<Output, Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, operation?.isCancelled == false else { return }
            let result = Result {
                try BlocksNativePluginResolvedAddressPolicy
                    .resolveSynchronously(host: self.host)
            }
            self.finish(result)
        }
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    func cancel() {
        lock.lock()
        let operation = operation
        lock.unlock()
        operation?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Output, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum BlocksNativePluginPinnedHTTPTransport {
    typealias ExchangeFactory = @Sendable (
        _ descriptor: BlocksNativePluginPinnedConnectionDescriptor,
        _ requestData: Data,
        _ maximumWireBytes: Int
    ) -> any BlocksNativePluginPinnedConnectionExchanging

    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumWireBytes =
        BlocksNativePluginNetworkPolicy.maximumResponseBytes + maximumHeaderBytes

    static func perform(
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        try await perform(
            request,
            exchangeFactory: { descriptor, requestData, maximumWireBytes in
                makeExchange(
                    descriptor: descriptor,
                    requestData: requestData,
                    maximumWireBytes: maximumWireBytes
                )
            }
        )
    }

    static func perform(
        _ request: BlocksNativePluginPinnedHTTPRequest,
        exchangeFactory: @escaping ExchangeFactory
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        let requestData = try makeRequestData(request)
        let deadline = request.deadline ?? BlocksNativePluginRequestDeadline(
            timeoutSeconds: request.request.timeoutSeconds
        )
        var lastPreflightError: Error?
        for address in request.addresses {
            try Task.checkCancellation()
            let descriptor = connectionDescriptor(
                for: request,
                address: address
            )
            guard descriptor.address.endpointHost != nil,
                  NWEndpoint.Port(rawValue: descriptor.port) != nil else {
                continue
            }
            let remaining = try deadline.remaining()
            let exchange = exchangeFactory(
                descriptor,
                requestData,
                maximumWireBytes
            )
            do {
                let response = try await awaitExchange(
                    exchange,
                    deadline: deadline,
                    remaining: remaining
                )
                return response
            } catch let error as BlocksNativePluginPinnedConnectionError
                where error.isSafeToRetry {
                lastPreflightError = error
                continue
            } catch is CancellationError {
                throw CancellationError()
            }
        }
        if let lastPreflightError {
            throw BlocksNativePluginNetworkBrokerError.transport(
                String(lastPreflightError.localizedDescription.prefix(512))
            )
        }
        throw BlocksNativePluginNetworkBrokerError.transport(
            "No validated address could be connected."
        )
    }

    static func connectionDescriptor(
        for request: BlocksNativePluginPinnedHTTPRequest,
        address: BlocksNativePluginResolvedAddress
    ) -> BlocksNativePluginPinnedConnectionDescriptor {
        BlocksNativePluginPinnedConnectionDescriptor(
            address: address,
            serverName: request.originalHost,
            port: request.port
        )
    }

    private static func awaitExchange(
        _ exchange: any BlocksNativePluginPinnedConnectionExchanging,
        deadline: BlocksNativePluginRequestDeadline,
        remaining: Duration
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        let race = BlocksNativePluginDeadlineRace<
            BlocksNativePluginPinnedHTTPResponse
        >(
            deadline: deadline.instant,
            directCancellation: { exchange.cancel() }
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    remaining: remaining,
                    operation: {
                        try await exchange.run()
                    }
                )
            }
        } onCancel: {
            race.cancel()
        }
    }

    private static func makeExchange(
        descriptor: BlocksNativePluginPinnedConnectionDescriptor,
        requestData: Data,
        maximumWireBytes: Int
    ) -> any BlocksNativePluginPinnedConnectionExchanging {
        let tlsOptions = NWProtocolTLS.Options()
        descriptor.serverName.withCString {
            sec_protocol_options_set_tls_server_name(
                tlsOptions.securityProtocolOptions,
                $0
            )
        }
        "http/1.1".withCString {
            sec_protocol_options_add_tls_application_protocol(
                tlsOptions.securityProtocolOptions,
                $0
            )
        }
        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(
            host: descriptor.address.endpointHost!,
            port: NWEndpoint.Port(rawValue: descriptor.port)!,
            using: parameters
        )
        return BlocksNativePluginPinnedConnectionExchange(
            connection: connection,
            requestData: requestData,
            maximumWireBytes: maximumWireBytes
        )
    }

    private static func makeRequestData(
        _ pinned: BlocksNativePluginPinnedHTTPRequest
    ) throws -> Data {
        guard let components = URLComponents(
            url: pinned.url,
            resolvingAgainstBaseURL: false
        ) else {
            throw BlocksNativePluginNetworkPolicyError.invalidURL
        }
        var target = components.percentEncodedPath
        if target.isEmpty {
            target = "/"
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }
        guard !target.contains("\r"), !target.contains("\n") else {
            throw BlocksNativePluginNetworkPolicyError.invalidURL
        }

        var headers = pinned.request.headers.filter { name, _ in
            let normalized = name.lowercased()
            return normalized != "host"
                && normalized != "connection"
                && normalized != "content-length"
                && normalized != "accept-encoding"
                && normalized != "expect"
        }
        let hostHeader = pinned.port == 443
            ? pinned.originalHost
            : "\(pinned.originalHost):\(pinned.port)"
        headers["Host"] = hostHeader
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        if let body = pinned.request.body {
            headers["Content-Length"] = String(body.count)
        }

        var head = "\(pinned.request.method.rawValue) \(target) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
            }
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        guard var data = head.data(using: .isoLatin1) else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        if let body = pinned.request.body {
            data.append(body)
        }
        return data
    }
}

private enum BlocksNativePluginPinnedConnectionError: Error, LocalizedError {
    case failedBeforeRequest(String)
    case failedAfterRequest(String)

    var isSafeToRetry: Bool {
        if case .failedBeforeRequest = self {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .failedBeforeRequest(message), let .failedAfterRequest(message):
            return message
        }
    }
}

protocol BlocksNativePluginPinnedConnectionExchanging: AnyObject, Sendable {
    func run() async throws -> BlocksNativePluginPinnedHTTPResponse
    func cancel()
}

private final class BlocksNativePluginPinnedConnectionExchange:
    @unchecked Sendable, BlocksNativePluginPinnedConnectionExchanging
{
    private let connection: NWConnection
    private let requestData: Data
    private let queue = DispatchQueue(
        label: "app.blocks.translation.plugin-network",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        BlocksNativePluginPinnedHTTPResponse,
        Error
    >?
    private var decoder: BlocksNativePluginHTTP1ResponseDecoder
    private var completed = false
    private var started = false
    private var requestWasSent = false

    init(
        connection: NWConnection,
        requestData: Data,
        maximumWireBytes: Int
    ) {
        self.connection = connection
        self.requestData = requestData
        decoder = BlocksNativePluginHTTP1ResponseDecoder(
            maximumWireBytes: maximumWireBytes
        )
    }

    func run() async throws -> BlocksNativePluginPinnedHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !completed, !started else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                started = true
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: queue)
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.lock()
            guard !completed, !requestWasSent else {
                lock.unlock()
                return
            }
            requestWasSent = true
            lock.unlock()
            connection.send(
                content: requestData,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.finish(
                            .failure(
                                BlocksNativePluginPinnedConnectionError
                                    .failedAfterRequest(error.localizedDescription)
                            )
                        )
                    } else {
                        self.receiveIfActive()
                    }
                }
            )
        case let .failed(error):
            lock.lock()
            let wasSent = requestWasSent
            lock.unlock()
            finish(
                .failure(
                    wasSent
                        ? BlocksNativePluginPinnedConnectionError
                            .failedAfterRequest(error.localizedDescription)
                        : BlocksNativePluginPinnedConnectionError
                            .failedBeforeRequest(error.localizedDescription)
                )
            )
        case .cancelled:
            finish(.failure(CancellationError()))
        case let .waiting(error):
            finish(
                .failure(
                    BlocksNativePluginPinnedConnectionError
                        .failedBeforeRequest(error.localizedDescription)
                )
            )
        case .setup, .preparing:
            break
        @unknown default:
            finish(
                .failure(
                    BlocksNativePluginPinnedConnectionError.failedAfterRequest(
                        "The network connection entered an unknown state."
                    )
                )
            )
        }
    }

    private func receive() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        lock.unlock()
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let receivedData = data ?? Data()
            let parserReachedEnd = isComplete && error == nil
            self.lock.lock()
            guard !self.completed else {
                self.lock.unlock()
                return
            }
            let parseResult: Result<
                BlocksNativePluginPinnedHTTPResponse?,
                Error
            >
            do {
                parseResult = .success(
                    try self.decoder.append(
                        receivedData,
                        endOfStream: parserReachedEnd
                    )
                )
            } catch {
                parseResult = .failure(error)
            }
            self.lock.unlock()

            switch parseResult {
            case let .success(response?):
                self.finish(.success(response))
                return
            case .success(nil):
                break
            case let .failure(parseError):
                self.finish(.failure(parseError))
                return
            }
            if let error {
                self.finish(
                    .failure(
                        BlocksNativePluginPinnedConnectionError
                            .failedAfterRequest(error.localizedDescription)
                    )
                )
            } else if isComplete {
                self.finish(
                    .failure(
                        BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                    )
                )
            } else {
                self.receiveIfActive()
            }
        }
    }

    private func receiveIfActive() {
        lock.lock()
        let shouldReceive = !completed
        lock.unlock()
        guard shouldReceive else { return }
        receive()
    }

    private func finish(
        _ result: Result<BlocksNativePluginPinnedHTTPResponse, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
    }
}

struct BlocksNativePluginHTTP1DecoderMetrics: Equatable {
    fileprivate(set) var receivedWireBytes = 0
    fileprivate(set) var maximumBufferedInputBytes = 0
    fileprivate(set) var parsedHeaderCount = 0
}

final class BlocksNativePluginHTTP1ResponseDecoder {
    private enum State {
        case responseHead
        case contentLength(remaining: Int)
        case untilEndOfStream
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataTerminator
        case chunkTrailers
        case complete
    }

    private let maximumWireBytes: Int
    private var state: State = .responseHead
    private var pending = Data()
    private var pendingOffset = 0
    private var body = Data()
    private var finalHead: BlocksNativePluginHTTP1Parser.ParsedHead?
    private var completedResponse: BlocksNativePluginPinnedHTTPResponse?
    private(set) var metrics = BlocksNativePluginHTTP1DecoderMetrics()

    init(
        maximumWireBytes: Int =
            BlocksNativePluginNetworkPolicy.maximumResponseBytes
                + BlocksNativePluginHTTP1Parser.maximumHeaderBytes
    ) {
        self.maximumWireBytes = maximumWireBytes
    }

    func append(
        _ data: Data,
        endOfStream: Bool = false
    ) throws -> BlocksNativePluginPinnedHTTPResponse? {
        if let completedResponse {
            return completedResponse
        }
        guard data.count <= maximumWireBytes - metrics.receivedWireBytes else {
            throw BlocksNativePluginNetworkBrokerError.responseTooLarge
        }
        metrics.receivedWireBytes += data.count
        if !data.isEmpty {
            compactPending()
            pending.append(data)
            metrics.maximumBufferedInputBytes = max(
                metrics.maximumBufferedInputBytes,
                pending.count - pendingOffset
            )
        }
        return try process(endOfStream: endOfStream)
    }

    private func process(
        endOfStream: Bool
    ) throws -> BlocksNativePluginPinnedHTTPResponse? {
        while true {
            switch state {
            case .responseHead:
                guard let headerRange = pending.range(
                    of: BlocksNativePluginHTTP1Parser.headerTerminator,
                    in: pendingOffset..<pending.count
                ) else {
                    if availableInputCount
                        > BlocksNativePluginHTTP1Parser.maximumHeaderBytes
                        || endOfStream {
                        throw BlocksNativePluginNetworkBrokerError
                            .invalidHTTPResponse
                    }
                    return nil
                }
                guard headerRange.upperBound - pendingOffset
                    <= BlocksNativePluginHTTP1Parser.maximumHeaderBytes else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                let parsedHead = try BlocksNativePluginHTTP1Parser.parseHead(
                    Data(pending[pendingOffset..<headerRange.lowerBound])
                )
                metrics.parsedHeaderCount += 1
                consumeInput(through: headerRange.upperBound)
                if (100..<200).contains(parsedHead.statusCode),
                   parsedHead.statusCode != 101 {
                    continue
                }
                finalHead = parsedHead
                if parsedHead.statusCode == 204 || parsedHead.statusCode == 304 {
                    return try complete()
                }
                if parsedHead.transferEncodingIsChunked {
                    state = .chunkSize
                    continue
                }
                if let contentLength = parsedHead.contentLength {
                    guard contentLength
                        <= BlocksNativePluginNetworkPolicy.maximumResponseBytes else {
                        throw BlocksNativePluginNetworkBrokerError.responseTooLarge
                    }
                    if contentLength == 0 {
                        return try complete()
                    }
                    body.reserveCapacity(contentLength)
                    state = .contentLength(remaining: contentLength)
                    continue
                }
                state = .untilEndOfStream

            case let .contentLength(remaining):
                let consumed = min(remaining, availableInputCount)
                if consumed > 0 {
                    body.append(
                        pending[pendingOffset..<(pendingOffset + consumed)]
                    )
                    consumeInput(count: consumed)
                }
                let nextRemaining = remaining - consumed
                if nextRemaining == 0 {
                    return try complete()
                }
                guard !endOfStream else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                state = .contentLength(remaining: nextRemaining)
                return nil

            case .untilEndOfStream:
                try appendPendingBody()
                guard endOfStream else { return nil }
                return try complete()

            case .chunkSize:
                guard let lineRange = pending.range(
                    of: BlocksNativePluginHTTP1Parser.lineTerminator,
                    in: pendingOffset..<pending.count
                ) else {
                    if availableInputCount
                        > BlocksNativePluginHTTP1Parser.maximumChunkLineBytes
                        || endOfStream {
                        throw BlocksNativePluginNetworkBrokerError
                            .invalidHTTPResponse
                    }
                    return nil
                }
                guard lineRange.lowerBound - pendingOffset
                    <= BlocksNativePluginHTTP1Parser.maximumChunkLineBytes else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                let lineData = Data(
                    pending[pendingOffset..<lineRange.lowerBound]
                )
                consumeInput(through: lineRange.upperBound)
                let size = try BlocksNativePluginHTTP1Parser.parseChunkSize(
                    lineData
                )
                if size == 0 {
                    state = .chunkTrailers
                } else {
                    guard size
                        <= BlocksNativePluginNetworkPolicy.maximumResponseBytes
                            - body.count else {
                        throw BlocksNativePluginNetworkBrokerError.responseTooLarge
                    }
                    state = .chunkData(remaining: size)
                }

            case let .chunkData(remaining):
                let consumed = min(remaining, availableInputCount)
                if consumed > 0 {
                    body.append(
                        pending[pendingOffset..<(pendingOffset + consumed)]
                    )
                    consumeInput(count: consumed)
                }
                let nextRemaining = remaining - consumed
                if nextRemaining == 0 {
                    state = .chunkDataTerminator
                    continue
                }
                guard !endOfStream else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                state = .chunkData(remaining: nextRemaining)
                return nil

            case .chunkDataTerminator:
                guard availableInputCount >= 2 else {
                    if endOfStream {
                        throw BlocksNativePluginNetworkBrokerError
                            .invalidHTTPResponse
                    }
                    return nil
                }
                guard pending[pendingOffset] == 13,
                      pending[pendingOffset + 1] == 10 else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                consumeInput(count: 2)
                state = .chunkSize

            case .chunkTrailers:
                if availableInputCount >= 2,
                   pending[pendingOffset] == 13,
                   pending[pendingOffset + 1] == 10 {
                    consumeInput(count: 2)
                    return try complete()
                }
                guard let trailerRange = pending.range(
                    of: BlocksNativePluginHTTP1Parser.headerTerminator,
                    in: pendingOffset..<pending.count
                ) else {
                    if availableInputCount
                        > BlocksNativePluginHTTP1Parser.maximumHeaderBytes
                        || endOfStream {
                        throw BlocksNativePluginNetworkBrokerError
                            .invalidHTTPResponse
                    }
                    return nil
                }
                guard trailerRange.upperBound - pendingOffset
                    <= BlocksNativePluginHTTP1Parser.maximumHeaderBytes else {
                    throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
                }
                consumeInput(through: trailerRange.upperBound)
                return try complete()

            case .complete:
                return completedResponse
            }
        }
    }

    private var availableInputCount: Int {
        pending.count - pendingOffset
    }

    private func consumeInput(count: Int) {
        pendingOffset += count
    }

    private func consumeInput(through endIndex: Int) {
        pendingOffset = endIndex
    }

    private func compactPending() {
        guard pendingOffset > 0 else { return }
        if pendingOffset == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending.removeSubrange(..<pendingOffset)
        }
        pendingOffset = 0
    }

    private func appendPendingBody() throws {
        guard availableInputCount
            <= BlocksNativePluginNetworkPolicy.maximumResponseBytes - body.count else {
            throw BlocksNativePluginNetworkBrokerError.responseTooLarge
        }
        body.append(pending[pendingOffset...])
        consumeInput(through: pending.count)
    }

    private func complete() throws -> BlocksNativePluginPinnedHTTPResponse {
        guard let head = finalHead else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        let response = BlocksNativePluginPinnedHTTPResponse(
            statusCode: head.statusCode,
            headers: head.headers,
            body: body
        )
        completedResponse = response
        state = .complete
        return response
    }
}

enum BlocksNativePluginHTTP1Parser {
    static let maximumHeaderBytes = 64 * 1_024
    static let maximumChunkLineBytes = 1_024
    static let headerTerminator = Data([13, 10, 13, 10])
    static let lineTerminator = Data([13, 10])

    static func parse(
        _ data: Data,
        endOfStream: Bool
    ) throws -> BlocksNativePluginPinnedHTTPResponse? {
        let decoder = BlocksNativePluginHTTP1ResponseDecoder()
        let receiveChunkSize = 64 * 1_024
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + receiveChunkSize)
            let response = try decoder.append(
                Data(data[offset..<end]),
                endOfStream: endOfStream && end == data.count
            )
            if let response {
                return response
            }
            offset = end
        }
        return try decoder.append(Data(), endOfStream: endOfStream)
    }

    fileprivate static func parseHead(_ data: Data) throws -> ParsedHead {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        let statusComponents = statusLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard statusComponents.count >= 2,
              statusComponents[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusComponents[1]),
              (100...599).contains(statusCode) else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }

        var headers: [String: String] = [:]
        var contentLengths: [Int] = []
        var transferEncodingTokens: [String] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ",
                  line.first != "\t",
                  let separator = line.firstIndex(of: ":") else {
                throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
            }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
            }
            if name.caseInsensitiveCompare("content-length") == .orderedSame {
                for component in value.split(separator: ",") {
                    guard let parsed = Int(
                        component.trimmingCharacters(in: .whitespaces)
                    ), parsed >= 0 else {
                        throw BlocksNativePluginNetworkBrokerError
                            .invalidHTTPResponse
                    }
                    contentLengths.append(parsed)
                }
            }
            if name.caseInsensitiveCompare("transfer-encoding") == .orderedSame {
                transferEncodingTokens.append(
                    contentsOf: value.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased()
                    }
                )
            }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        if let firstLength = contentLengths.first,
           contentLengths.contains(where: { $0 != firstLength }) {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        let transferEncodingIsChunked: Bool
        if transferEncodingTokens.isEmpty {
            transferEncodingIsChunked = false
        } else {
            guard transferEncodingTokens == ["chunked"] else {
                throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
            }
            transferEncodingIsChunked = true
        }
        guard !(transferEncodingIsChunked && !contentLengths.isEmpty) else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        return ParsedHead(
            statusCode: statusCode,
            headers: headers,
            contentLength: contentLengths.first,
            transferEncodingIsChunked: transferEncodingIsChunked
        )
    }

    fileprivate static func parseChunkSize(_ data: Data) throws -> Int {
        guard let line = String(data: data, encoding: .ascii) else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        let sizeText = line.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        guard !sizeText.isEmpty,
              sizeText.count <= 16,
              let size = Int(sizeText, radix: 16),
              size >= 0 else {
            throw BlocksNativePluginNetworkBrokerError.invalidHTTPResponse
        }
        return size
    }

    fileprivate struct ParsedHead {
        let statusCode: Int
        let headers: [String: String]
        let contentLength: Int?
        let transferEncodingIsChunked: Bool
    }
}
