import BlocksCore
import Foundation
import XCTest
@testable import Blocks

final class BlocksNativePluginPinnedNetworkTests: XCTestCase {
    func testDNSResultIsPinnedWithoutASecondResolution() async throws {
        let resolver = RotatingAddressResolver(
            first: [.ipv4("93.184.216.34")],
            later: [.ipv4("127.0.0.1")]
        )
        let transport = PinnedTransportRecorder(
            responses: [
                .init(
                    statusCode: 200,
                    headers: [:],
                    body: Data("ok".utf8)
                ),
            ]
        )
        let broker = makeBroker(
            resolver: { try await resolver.resolve($0) },
            transport: { try await transport.perform($0) }
        )

        let response = try await broker.perform(
            request: .init(
                url: "https://api.example.com/v1/translate",
                method: .post,
                body: Data("hello".utf8)
            ),
            manifest: makeManifest(
                domains: ["api.example.com"],
                methods: [.post]
            ),
            approvedDomains: ["api.example.com"],
            approvedMethods: [.post],
            approvedSecretIDs: []
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        let resolverCallCount = await resolver.callCount
        XCTAssertEqual(resolverCallCount, 1)
        let requests = await transport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].originalHost, "api.example.com")
        XCTAssertEqual(requests[0].addresses, [.ipv4("93.184.216.34")])
    }

    func testAnyPrivateAddressInDNSAnswerFailsClosed() async throws {
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { _ in
                [
                    .ipv4("93.184.216.34"),
                    .ipv4("127.0.0.1"),
                ]
            },
            transport: { try await transport.perform($0) }
        )

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
            XCTFail("Expected a private DNS answer to be rejected.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .resolvedAddressDenied("api.example.com") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let rejectedRequests = await transport.recordedRequests
        XCTAssertTrue(rejectedRequests.isEmpty)
    }

    func testReservedAddressesFailClosed() throws {
        let reservedAddresses: [BlocksNativePluginResolvedAddress] = [
            .ipv4("192.0.2.1"),
            .ipv4("198.18.0.1"),
            .ipv4("198.19.255.254"),
            .ipv4("198.51.100.1"),
            .ipv4("203.0.113.1"),
            .ipv6("2001:db8::1"),
        ]

        for address in reservedAddresses {
            XCTAssertThrowsError(
                try BlocksNativePluginResolvedAddressPolicy.validate(
                    [address],
                    host: "fixture.example.com"
                ),
                "Expected \(address) to be rejected."
            )
        }
    }

    func testIPv4AndIPv6RemainNumericWhileTLSUsesOriginalHostname() throws {
        let request = BlocksNativePluginPinnedHTTPRequest(
            request: .init(
                url: "https://api.example.com:8443/v1",
                method: .get
            ),
            url: try XCTUnwrap(URL(string: "https://api.example.com:8443/v1")),
            originalHost: "api.example.com",
            port: 8443,
            addresses: [
                .ipv4("93.184.216.34"),
                .ipv6("2606:2800:220:1:248:1893:25c8:1946"),
            ]
        )

        let ipv4 = BlocksNativePluginPinnedHTTPTransport.connectionDescriptor(
            for: request,
            address: request.addresses[0]
        )
        let ipv6 = BlocksNativePluginPinnedHTTPTransport.connectionDescriptor(
            for: request,
            address: request.addresses[1]
        )

        XCTAssertEqual(ipv4.address, .ipv4("93.184.216.34"))
        XCTAssertEqual(ipv6.address, .ipv6("2606:2800:220:1:248:1893:25c8:1946"))
        XCTAssertEqual(ipv4.serverName, "api.example.com")
        XCTAssertEqual(ipv6.serverName, "api.example.com")
        XCTAssertEqual(ipv4.port, 8443)
        XCTAssertEqual(ipv6.port, 8443)
        XCTAssertNoThrow(
            try BlocksNativePluginResolvedAddressPolicy.validate(
                request.addresses,
                host: request.originalHost
            )
        )
    }

    func testRedirectRevalidatesAndPinsEachHostname() async throws {
        let resolver = MappingAddressResolver(
            values: [
                "api.example.com": [.ipv4("93.184.216.34")],
                "edge.example.com": [
                    .ipv6("2606:2800:220:1:248:1893:25c8:1946"),
                ],
            ]
        )
        let transport = PinnedTransportRecorder(
            responses: [
                .init(
                    statusCode: 302,
                    headers: [
                        "Location": "https://edge.example.com/result",
                    ],
                    body: Data()
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"ok":true}"#.utf8)
                ),
            ]
        )
        let broker = makeBroker(
            resolver: { try await resolver.resolve($0) },
            transport: { try await transport.perform($0) }
        )

        let response = try await broker.perform(
            request: .init(
                url: "https://api.example.com/start",
                method: .get
            ),
            manifest: makeManifest(
                domains: ["api.example.com", "edge.example.com"],
                methods: [.get]
            ),
            approvedDomains: ["api.example.com", "edge.example.com"],
            approvedMethods: [.get],
            approvedSecretIDs: []
        )

        XCTAssertEqual(response.statusCode, 200)
        let requestedHosts = await resolver.requestedHosts
        XCTAssertEqual(requestedHosts, ["api.example.com", "edge.example.com"])
        let requests = await transport.recordedRequests
        XCTAssertEqual(requests.map(\.originalHost), [
            "api.example.com",
            "edge.example.com",
        ])
        XCTAssertEqual(
            requests[1].addresses,
            [.ipv6("2606:2800:220:1:248:1893:25c8:1946")]
        )
    }

    func testCrossOriginRedirectCannotForwardSecretBearingBody() async throws {
        let transport = PinnedTransportRecorder(
            responses: [
                .init(
                    statusCode: 307,
                    headers: ["Location": "https://edge.example.com/result"],
                    body: Data()
                ),
            ]
        )
        let broker = makeBroker(
            resolver: { _ in [.ipv4("93.184.216.34")] },
            transport: { try await transport.perform($0) },
            secretResolver: { _, _ in "sensitive-value" }
        )

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com/start",
                    method: .post,
                    body: Data(#"{"token":"{{secret:api_key}}"}"#.utf8)
                ),
                manifest: makeManifest(
                    domains: ["api.example.com", "edge.example.com"],
                    methods: [.post],
                    secretIDs: ["api_key"]
                ),
                approvedDomains: ["api.example.com", "edge.example.com"],
                approvedMethods: [.post],
                approvedSecretIDs: ["api_key"]
            )
            XCTFail("Expected cross-origin secret forwarding to be rejected.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .redirectDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let recordedRequestCount = await transport.recordedRequests.count
        XCTAssertEqual(recordedRequestCount, 1)
    }

    func testChunkedAndContentLengthResponsesAreParsed() throws {
        let chunked = Data(
            (
                "HTTP/1.1 200 OK\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "X-Fixture: chunked\r\n"
                    + "\r\n"
                    + "4\r\nWiki\r\n"
                    + "5\r\npedia\r\n"
                    + "0\r\n\r\n"
            ).utf8
        )
        let chunkedResponse = try XCTUnwrap(
            BlocksNativePluginHTTP1Parser.parse(
                chunked,
                endOfStream: true
            )
        )
        XCTAssertEqual(chunkedResponse.statusCode, 200)
        XCTAssertEqual(chunkedResponse.body, Data("Wikipedia".utf8))
        XCTAssertEqual(chunkedResponse.headers["X-Fixture"], "chunked")

        let complete = Data(
            "HTTP/1.1 201 Created\r\nContent-Length: 5\r\n\r\nhello".utf8
        )
        let partial = complete.dropLast(2)
        XCTAssertNil(
            try BlocksNativePluginHTTP1Parser.parse(
                Data(partial),
                endOfStream: false
            )
        )
        let completeResponse = try XCTUnwrap(
            BlocksNativePluginHTTP1Parser.parse(
                complete,
                endOfStream: false
            )
        )
        XCTAssertEqual(completeResponse.statusCode, 201)
        XCTAssertEqual(completeResponse.body, Data("hello".utf8))
    }

    func testIncrementalDecoderHandlesAdversariallyFragmentedChunkedResponse() throws {
        let response = Data(
            (
                "HTTP/1.1 100 Continue\r\n\r\n"
                    + "HTTP/1.1 200 OK\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "\r\n"
                    + "4;fixture=value\r\nWiki\r\n"
                    + "5\r\npedia\r\n"
                    + "0\r\nX-Trailer: accepted\r\n\r\n"
            ).utf8
        )
        let decoder = BlocksNativePluginHTTP1ResponseDecoder()
        var parsed: BlocksNativePluginPinnedHTTPResponse?

        for (offset, byte) in response.enumerated() {
            parsed = try decoder.append(
                Data([byte]),
                endOfStream: offset == response.count - 1
            )
        }

        XCTAssertEqual(parsed?.statusCode, 200)
        XCTAssertEqual(parsed?.body, Data("Wikipedia".utf8))
        XCTAssertEqual(decoder.metrics.parsedHeaderCount, 2)
        XCTAssertLessThanOrEqual(
            decoder.metrics.maximumBufferedInputBytes,
            64 * 1_024
        )
        XCTAssertEqual(decoder.metrics.receivedWireBytes, response.count)
    }

    func testIncrementalDecoderKeepsScratchBufferBoundedAtResponseLimit() throws {
        let limit = BlocksNativePluginNetworkPolicy.maximumResponseBytes
        let decoder = BlocksNativePluginHTTP1ResponseDecoder()
        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(limit)\r\n\r\n".utf8
        )
        XCTAssertNil(try decoder.append(header))

        let receiveChunkSize = 64 * 1_024
        var remaining = limit
        var parsed: BlocksNativePluginPinnedHTTPResponse?
        while remaining > 0 {
            let count = min(receiveChunkSize, remaining)
            remaining -= count
            parsed = try decoder.append(
                Data(repeating: 0x61, count: count),
                endOfStream: remaining == 0
            )
        }

        XCTAssertEqual(parsed?.body.count, limit)
        XCTAssertEqual(decoder.metrics.parsedHeaderCount, 1)
        XCTAssertLessThanOrEqual(
            decoder.metrics.maximumBufferedInputBytes,
            receiveChunkSize
        )
    }

    func testIncrementalDecoderRejectsOversizedChunkBeforeReceivingItsBody() throws {
        let limit = BlocksNativePluginNetworkPolicy.maximumResponseBytes
        let decoder = BlocksNativePluginHTTP1ResponseDecoder()
        XCTAssertNil(
            try decoder.append(
                Data(
                    (
                        "HTTP/1.1 200 OK\r\n"
                            + "Transfer-Encoding: chunked\r\n\r\n"
                    ).utf8
                )
            )
        )

        XCTAssertThrowsError(
            try decoder.append(Data("\(String(limit + 1, radix: 16))\r\n".utf8))
        ) { error in
            guard case BlocksNativePluginNetworkBrokerError.responseTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(decoder.metrics.parsedHeaderCount, 1)
    }

    func testIncrementalDecoderRejectsMaliciouslyLongChunkMetadata() throws {
        let decoder = BlocksNativePluginHTTP1ResponseDecoder()
        XCTAssertNil(
            try decoder.append(
                Data(
                    (
                        "HTTP/1.1 200 OK\r\n"
                            + "Transfer-Encoding: chunked\r\n\r\n"
                    ).utf8
                )
            )
        )

        for _ in 0..<BlocksNativePluginHTTP1Parser.maximumChunkLineBytes {
            XCTAssertNil(try decoder.append(Data([0x61])))
        }
        XCTAssertThrowsError(try decoder.append(Data([0x61]))) { error in
            guard case BlocksNativePluginNetworkBrokerError.invalidHTTPResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConflictingLengthAndChunkedResponseIsRejected() {
        let response = Data(
            (
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Length: 4\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "\r\n"
                    + "4\r\ntest\r\n"
                    + "0\r\n\r\n"
            ).utf8
        )
        XCTAssertThrowsError(
            try BlocksNativePluginHTTP1Parser.parse(
                response,
                endOfStream: true
            )
        )
    }

    func testResponseBodyLimitAcceptsBoundaryAndRejectsLargerLength() throws {
        let limit = BlocksNativePluginNetworkPolicy.maximumResponseBytes
        var boundary = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(limit)\r\n\r\n".utf8
        )
        boundary.append(Data(repeating: 0x61, count: limit))
        let parsed = try XCTUnwrap(
            BlocksNativePluginHTTP1Parser.parse(
                boundary,
                endOfStream: false
            )
        )
        XCTAssertEqual(parsed.body.count, limit)

        let oversized = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(limit + 1)\r\n\r\n".utf8
        )
        XCTAssertThrowsError(
            try BlocksNativePluginHTTP1Parser.parse(
                oversized,
                endOfStream: false
            )
        ) { error in
            guard case BlocksNativePluginNetworkBrokerError.responseTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancellationPropagatesToPinnedTransport() async throws {
        let probe = CancellationProbe()
        let transportStarted = expectation(
            description: "pinned transport starts before cancellation"
        )
        let transportCancelled = expectation(
            description: "pinned transport observes cancellation"
        )
        let broker = makeBroker(
            resolver: { _ in [.ipv4("93.184.216.34")] },
            transport: { request in
                await probe.markStarted(host: request.originalHost)
                transportStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .init(statusCode: 200, headers: [:], body: Data())
                } catch {
                    await probe.markCancelled()
                    transportCancelled.fulfill()
                    throw error
                }
            }
        )
        let task = Task {
            try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 60
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
        }
        await fulfillment(of: [transportStarted], timeout: 2)
        let didStart = await probe.started
        XCTAssertTrue(didStart)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [transportCancelled], timeout: 2)
        let didCancel = await probe.cancelled
        XCTAssertTrue(didCancel)
    }

    func testDNSLatencyIsDeductedFromTransportBudget() async throws {
        let budgetProbe = TransportBudgetProbe()
        let broker = makeBroker(
            resolver: { _ in
                try await Task.sleep(for: .milliseconds(150))
                return [.ipv4("93.184.216.34")]
            },
            transport: { request in
                await budgetProbe.record(
                    timeoutSeconds: request.request.timeoutSeconds
                )
                return .init(
                    statusCode: 200,
                    headers: [:],
                    body: Data("ok".utf8)
                )
            }
        )

        _ = try await broker.perform(
            request: .init(
                url: "https://api.example.com",
                method: .get,
                timeoutSeconds: 2
            ),
            manifest: makeManifest(
                domains: ["api.example.com"],
                methods: [.get]
            ),
            approvedDomains: ["api.example.com"],
            approvedMethods: [.get],
            approvedSecretIDs: []
        )

        let recordedBudget = await budgetProbe.timeoutSeconds
        let observedBudget = try XCTUnwrap(recordedBudget)
        XCTAssertLessThan(observedBudget, 1.95)
        XCTAssertGreaterThan(observedBudget, 1.5)
    }

    func testSecretResolutionIsPartOfTotalRequestDeadline() async throws {
        let secretProbe = CancellationProbe()
        let resolver = RotatingAddressResolver(
            first: [.ipv4("93.184.216.34")],
            later: [.ipv4("93.184.216.34")]
        )
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { try await resolver.resolve($0) },
            transport: { try await transport.perform($0) },
            secretResolver: { _, secretID in
                await secretProbe.markStarted(host: secretID)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return "secret"
                } catch {
                    await secretProbe.markCancelled()
                    throw error
                }
            }
        )

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    headers: [
                        "Authorization": "Bearer {{secret:api_key}}",
                    ],
                    timeoutSeconds: 1
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get],
                    secretIDs: ["api_key"]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: ["api_key"]
            )
            XCTFail("Expected secret resolution to time out.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }

        // The deadline race must release the caller even if a resolver ignores
        // cancellation. Cooperative resolvers observe Task cancellation on a
        // separate unstructured task, so allow that acknowledgement to arrive
        // instead of requiring it in the same executor turn as the timeout.
        for _ in 0..<50 {
            if await secretProbe.cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let secretWasCancelled = await secretProbe.cancelled
        let resolverCallCount = await resolver.callCount
        let recordedRequests = await transport.recordedRequests
        XCTAssertTrue(secretWasCancelled)
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testDNSResolutionCannotOutliveRequestDeadline() async throws {
        let resolverProbe = CancellationProbe()
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { host in
                await resolverProbe.markStarted(host: host)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return [.ipv4("93.184.216.34")]
                } catch {
                    await resolverProbe.markCancelled()
                    throw error
                }
            },
            transport: { try await transport.perform($0) }
        )
        let startedAt = ContinuousClock.now

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 1
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
            XCTFail("Expected DNS resolution to time out.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }

        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(2)
        )
        for _ in 0..<50 {
            if await resolverProbe.cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resolverWasCancelled = await resolverProbe.cancelled
        let recordedRequests = await transport.recordedRequests
        XCTAssertTrue(resolverWasCancelled)
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testDeadlineReturnsEvenWhenResolverIgnoresCancellation() async throws {
        let resolver = NonCooperativeAddressResolver()
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { host in
                await resolver.resolve(host: host)
            },
            transport: { try await transport.perform($0) }
        )
        let releaser = Task {
            try? await Task.sleep(for: .seconds(2))
            await resolver.release()
        }
        let startedAt = ContinuousClock.now

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 1
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
            XCTFail("Expected DNS resolution to time out.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                await releaser.value
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }

        let elapsed = startedAt.duration(to: .now)
        await releaser.value
        XCTAssertLessThan(elapsed, .seconds(1.5))
        let recordedRequests = await transport.recordedRequests
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testCancellationDuringDNSReturnsPromptlyAndSkipsTransport() async throws {
        let resolverProbe = CancellationProbe()
        let resolverCancelled = expectation(
            description: "cooperative resolver observes cancellation"
        )
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { host in
                await resolverProbe.markStarted(host: host)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return [.ipv4("93.184.216.34")]
                } catch {
                    await resolverProbe.markCancelled()
                    resolverCancelled.fulfill()
                    throw error
                }
            },
            transport: { try await transport.perform($0) }
        )
        let task = Task {
            try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 60
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
        }
        for _ in 0..<100 {
            if await resolverProbe.started {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resolverDidStart = await resolverProbe.started
        XCTAssertTrue(resolverDidStart)

        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(
            cancelledAt.duration(to: .now),
            .seconds(1)
        )
        await fulfillment(of: [resolverCancelled], timeout: 1)
        let resolverWasCancelled = await resolverProbe.cancelled
        let recordedRequests = await transport.recordedRequests
        XCTAssertTrue(resolverWasCancelled)
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testCancellationReturnsEvenWhenResolverIgnoresCancellation() async throws {
        let resolver = NonCooperativeAddressResolver()
        let transport = PinnedTransportRecorder(responses: [])
        let broker = makeBroker(
            resolver: { host in
                await resolver.resolve(host: host)
            },
            transport: { try await transport.perform($0) }
        )
        let requestTask = Task {
            try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 60
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
        }
        for _ in 0..<100 {
            if await resolver.started {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resolverDidStart = await resolver.started
        XCTAssertTrue(resolverDidStart)
        let releaser = Task {
            try? await Task.sleep(for: .seconds(1))
            await resolver.release()
        }
        let cancelledAt = ContinuousClock.now
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let elapsed = cancelledAt.duration(to: .now)
        await releaser.value
        XCTAssertLessThan(elapsed, .milliseconds(500))
        let recordedRequests = await transport.recordedRequests
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testTransportUsesOnlyBudgetRemainingAfterDNS() async throws {
        let transportProbe = CancellationProbe()
        let broker = makeBroker(
            resolver: { _ in
                try await Task.sleep(for: .milliseconds(300))
                return [.ipv4("93.184.216.34")]
            },
            transport: { request in
                await transportProbe.markStarted(host: request.originalHost)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .init(statusCode: 200, headers: [:], body: Data())
                } catch {
                    await transportProbe.markCancelled()
                    throw error
                }
            }
        )
        let startedAt = ContinuousClock.now

        do {
            _ = try await broker.perform(
                request: .init(
                    url: "https://api.example.com",
                    method: .get,
                    timeoutSeconds: 1
                ),
                manifest: makeManifest(
                    domains: ["api.example.com"],
                    methods: [.get]
                ),
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
            XCTFail("Expected the total request budget to expire.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }

        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(2)
        )
        let transportDidStart = await transportProbe.started
        let transportWasCancelled = await transportProbe.cancelled
        XCTAssertTrue(transportDidStart)
        XCTAssertTrue(transportWasCancelled)
    }

    func testPinnedTransportDeadlineDoesNotWaitForUnresponsiveExchange() async throws {
        try await assertPinnedExchangeTerminatesBoundedly()
    }

    func testSharedRequestDeadlineRejectsImmediateSuccessAfterAbsoluteDeadline()
        async
    {
        let deadline = BlocksNativePluginRequestDeadline(
            timeoutSeconds: 1,
            deadlineElapsedOverrideForTesting: true
        )
        let startedAt = ContinuousClock.now

        do {
            let _: Int = try await deadline.run { 200 }
            XCTFail("Expected immediate success to be rejected at the deadline.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let duration = startedAt.duration(to: .now)
        XCTAssertLessThan(duration, .seconds(0.75))
    }

    func testSharedDeadlineRaceRejectsImmediateSuccessAfterAbsoluteDeadline()
        async
    {
        let race = BlocksNativePluginDeadlineRace<Int>(
            deadline: ContinuousClock.now.advanced(by: .seconds(1)),
            deadlineElapsedOverrideForTesting: true
        )
        let startedAt = ContinuousClock.now

        do {
            let _: Int = try await withCheckedThrowingContinuation {
                continuation in
                race.start(
                    continuation: continuation,
                    remaining: .seconds(1),
                    operation: { 200 }
                )
            }
            XCTFail("Expected immediate success to be rejected at the deadline.")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let duration = startedAt.duration(to: .now)
        XCTAssertLessThan(duration, .seconds(0.75))
    }

    func testPinnedTransportCancellationDoesNotWaitForExchangeCallback() async throws {
        let exchange = HangingPinnedExchange()
        let completion = expectation(
            description: "caller cancellation returns without exchange callback"
        )
        let requestTask = Task {
            do {
                _ = try await BlocksNativePluginPinnedHTTPTransport.perform(
                    makePinnedTransportRequest(timeoutSeconds: 30),
                    exchangeFactory: { _, _, _ in exchange }
                )
                XCTFail("Expected cancellation.")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            completion.fulfill()
        }

        for _ in 0..<100 {
            if exchange.hasStarted {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(exchange.hasStarted)
        requestTask.cancel()
        await fulfillment(of: [completion], timeout: 1)
        XCTAssertEqual(exchange.cancelCount, 1)
        try await assertPinnedExchangeRunExited(exchange)
    }

    func testPinnedTransportExchangeFactorySupportsSuccessAndFailure() async throws {
        let expected = BlocksNativePluginPinnedHTTPResponse(
            statusCode: 200,
            headers: ["X-Fixture": "success"],
            body: Data("ok".utf8)
        )
        let successful = try await BlocksNativePluginPinnedHTTPTransport.perform(
            makePinnedTransportRequest(),
            exchangeFactory: { _, _, _ in
                ImmediatePinnedExchange(result: .success(expected))
            }
        )
        XCTAssertEqual(successful, expected)

        do {
            _ = try await BlocksNativePluginPinnedHTTPTransport.perform(
                makePinnedTransportRequest(),
                exchangeFactory: { _, _, _ in
                    ImmediatePinnedExchange(result: .failure(PinnedExchangeFixtureError.failed))
                }
            )
            XCTFail("Expected exchange failure.")
        } catch PinnedExchangeFixtureError.failed {
            // Expected.
        }
    }

    func testPinnedTLSIntegrationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "BLOCKS_RUN_PLUGIN_NETWORK_INTEGRATION"
        ] == "1" else {
            throw XCTSkip(
                "Set BLOCKS_RUN_PLUGIN_NETWORK_INTEGRATION=1 to run the public TLS fixture."
            )
        }
        // This is an opt-in external-egress smoke test. The fixed Cloudflare
        // endpoint verifies numeric-IP transport and the independent TLS
        // hostname without weakening the production fail-closed handling for
        // DNS proxies that synthesize 198.18.0.0/15 answers.
        let host = "one.one.one.one"
        let request = BlocksNativePluginNetworkRequest(
            url: "https://one.one.one.one/",
            method: .get,
            timeoutSeconds: 10
        )
        do {
            let response = try await BlocksNativePluginPinnedHTTPTransport.perform(
                BlocksNativePluginPinnedHTTPRequest(
                    request: request,
                    url: try XCTUnwrap(URL(string: request.url)),
                    originalHost: host,
                    port: 443,
                    addresses: [.ipv4("1.1.1.1")]
                )
            )
            XCTAssertTrue((200..<400).contains(response.statusCode))
            XCTAssertFalse(response.body.isEmpty)
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .transport = error else {
                throw error
            }
            throw XCTSkip("Public TLS fixture is unreachable in the current environment.")
        }
    }

    private func makeBroker(
        resolver: @escaping BlocksNativePluginNetworkBroker.AddressResolver,
        transport: @escaping BlocksNativePluginNetworkBroker.PinnedTransport,
        secretResolver: @escaping BlocksNativePluginNetworkBroker.SecretResolver = {
            _, _ in ""
        }
    ) -> BlocksNativePluginNetworkBroker {
        BlocksNativePluginNetworkBroker(
            secretResolver: secretResolver,
            addressResolver: resolver,
            pinnedTransport: transport
        )
    }

    private func assertPinnedExchangeTerminatesBoundedly() async throws {
        let exchange = HangingPinnedExchange()
        let completion = expectation(
            description: "unresponsive exchange deadline returns promptly"
        )
        let result = PinnedExchangeResultRecorder()
        let startedAt = ContinuousClock.now
        Task {
            do {
                _ = try await BlocksNativePluginPinnedHTTPTransport.perform(
                    makePinnedTransportRequest(timeoutSeconds: 0.05),
                    exchangeFactory: { _, _, _ in exchange }
                )
                await result.record("unexpected success")
            } catch let error as BlocksNativePluginNetworkBrokerError {
                guard case let .transport(message) = error else {
                    await result.record("unexpected broker error")
                    completion.fulfill()
                    return
                }
                await result.record(message)
            } catch {
                await result.record("unexpected error")
            }
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        let recordedResult = await result.value
        XCTAssertEqual(recordedResult, "The request timed out.")
        XCTAssertEqual(exchange.cancelCount, 1)
        try await assertPinnedExchangeRunExited(exchange)
    }

    private func assertPinnedExchangeRunExited(
        _ exchange: HangingPinnedExchange
    ) async throws {
        for _ in 0..<100 {
            if exchange.hasRunExited {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(exchange.hasRunExited)
    }

    private func makePinnedTransportRequest(
        timeoutSeconds: Double = 1
    ) -> BlocksNativePluginPinnedHTTPRequest {
        let request = BlocksNativePluginNetworkRequest(
            url: "https://api.example.com/fixture",
            method: .get,
            timeoutSeconds: timeoutSeconds
        )
        return BlocksNativePluginPinnedHTTPRequest(
            request: request,
            url: URL(string: request.url)!,
            originalHost: "api.example.com",
            port: 443,
            addresses: [.ipv4("93.184.216.34")]
        )
    }

    private func makeManifest(
        domains: [String],
        methods: [BlocksNativePluginHTTPMethod],
        secretIDs: [String] = []
    ) -> BlocksNativePluginManifest {
        BlocksNativePluginManifest(
            id: "com.example.pinned-network",
            displayName: "Pinned Network Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(domains: domains, methods: methods),
                secrets: secretIDs.map {
                    .init(id: $0, displayName: $0)
                }
            )
        )
    }
}

private actor RotatingAddressResolver {
    private let first: [BlocksNativePluginResolvedAddress]
    private let later: [BlocksNativePluginResolvedAddress]
    private(set) var callCount = 0

    init(
        first: [BlocksNativePluginResolvedAddress],
        later: [BlocksNativePluginResolvedAddress]
    ) {
        self.first = first
        self.later = later
    }

    func resolve(_ host: String) throws -> [BlocksNativePluginResolvedAddress] {
        callCount += 1
        return callCount == 1 ? first : later
    }
}

private actor MappingAddressResolver {
    private let values: [String: [BlocksNativePluginResolvedAddress]]
    private(set) var requestedHosts: [String] = []

    init(values: [String: [BlocksNativePluginResolvedAddress]]) {
        self.values = values
    }

    func resolve(_ host: String) throws -> [BlocksNativePluginResolvedAddress] {
        requestedHosts.append(host)
        guard let result = values[host] else {
            throw BlocksNativePluginNetworkBrokerError.transport(
                "Missing fixture address."
            )
        }
        return result
    }
}

private actor NonCooperativeAddressResolver {
    private var continuation:
        CheckedContinuation<[BlocksNativePluginResolvedAddress], Never>?
    private(set) var started = false

    func resolve(
        host _: String
    ) async -> [BlocksNativePluginResolvedAddress] {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: [.ipv4("93.184.216.34")])
        continuation = nil
    }
}

private actor PinnedTransportRecorder {
    private var responses: [BlocksNativePluginPinnedHTTPResponse]
    private(set) var recordedRequests: [BlocksNativePluginPinnedHTTPRequest] = []

    init(responses: [BlocksNativePluginPinnedHTTPResponse]) {
        self.responses = responses
    }

    func perform(
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) throws -> BlocksNativePluginPinnedHTTPResponse {
        recordedRequests.append(request)
        guard !responses.isEmpty else {
            throw BlocksNativePluginNetworkBrokerError.transport(
                "Missing fixture response."
            )
        }
        return responses.removeFirst()
    }
}

private actor CancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var host: String?

    func markStarted(host: String) {
        started = true
        self.host = host
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor TransportBudgetProbe {
    private(set) var timeoutSeconds: Double?

    func record(timeoutSeconds: Double) {
        self.timeoutSeconds = timeoutSeconds
    }
}

private enum PinnedExchangeFixtureError: Error {
    case failed
}

private final class ImmediatePinnedExchange:
    @unchecked Sendable, BlocksNativePluginPinnedConnectionExchanging
{
    private let result: Result<BlocksNativePluginPinnedHTTPResponse, Error>

    init(result: Result<BlocksNativePluginPinnedHTTPResponse, Error>) {
        self.result = result
    }

    func run() async throws -> BlocksNativePluginPinnedHTTPResponse {
        try result.get()
    }

    func cancel() {}
}

private final class HangingPinnedExchange:
    @unchecked Sendable, BlocksNativePluginPinnedConnectionExchanging
{
    private let lock = NSLock()
    private var started = false
    private var runExited = false
    private var cancellations = 0
    private var cancelled = false
    private var continuation: CheckedContinuation<
        BlocksNativePluginPinnedHTTPResponse,
        Error
    >?

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    var hasRunExited: Bool {
        lock.withLock { runExited }
    }

    func run() async throws -> BlocksNativePluginPinnedHTTPResponse {
        lock.withLock { started = true }
        defer {
            lock.withLock { runExited = true }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // This fixture deliberately models a Network.framework callback
            // that never arrives; cancel must still release the local task.
            let cancelledBeforeRunWait = lock.withLock { () -> Bool in
                if cancelled {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if cancelledBeforeRunWait {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<
            BlocksNativePluginPinnedHTTPResponse,
            Error
        >? in
            cancellations += 1
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private actor PinnedExchangeResultRecorder {
    private(set) var value = ""

    func record(_ value: String) {
        self.value = value
    }
}
