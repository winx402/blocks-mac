import AppKit
@testable import BlocksCore
import BlocksScreenshotCore
import CryptoKit
import Network
import SwiftUI
import XCTest
@testable import Blocks

private struct SelectionHelperBundleIdentityVerifierStub:
    SelectionHelperBundleIdentityVerifying
{
    let identity: SelectionHelperBundleIdentity?

    init(
        teamID: String?,
        signingIdentifier: String =
            BlocksSelectionHelperProtocol.bundleIdentifier
    ) {
        identity = teamID.map {
            SelectionHelperBundleIdentity(
                teamID: $0,
                signingIdentifier: signingIdentifier
            )
        }
    }

    func verifiedIdentity(
        for applicationURL: URL
    ) -> SelectionHelperBundleIdentity? {
        identity
    }
}

private final class SelectionHelperKeychainOperationRecorder {
    let copyStatus: OSStatus
    let copyData: Data?
    let updateStatus: OSStatus
    let addStatus: OSStatus
    let deleteStatus: OSStatus
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    init(
        copyStatus: OSStatus = errSecItemNotFound,
        copyData: Data? = nil,
        updateStatus: OSStatus = errSecSuccess,
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.copyStatus = copyStatus
        self.copyData = copyData
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    func itemCopyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        copyQueries.append(query as? [String: Any] ?? [:])
        if copyStatus == errSecSuccess, let copyData {
            result?.pointee = copyData as CFData
        }
        return copyStatus
    }

    func itemUpdate(
        _ query: CFDictionary,
        _: CFDictionary
    ) -> OSStatus {
        updateQueries.append(query as? [String: Any] ?? [:])
        return updateStatus
    }

    func itemAdd(
        _ query: CFDictionary,
        _: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        addQueries.append(query as? [String: Any] ?? [:])
        return addStatus
    }

    func itemDelete(_ query: CFDictionary) -> OSStatus {
        deleteQueries.append(query as? [String: Any] ?? [:])
        return deleteStatus
    }
}

private final class SelectionHelperRequestFrameReceiverTestDelivery:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedValues: [Data] = []

    var count: Int {
        lock.withLock { storedValues.count }
    }

    var values: [Data] {
        lock.withLock { storedValues }
    }

    func append(_ value: Data) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}

private final class SelectionHelperRequestFrameReceiverTestServer:
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "app.blocks.tests.selection-helper-frame-server"
    )
    private let timeout: TimeInterval
    private let receivedPayload: (Data) -> Void
    private var listener: NWListener?
    private var receiver: SelectionHelperRequestFrameReceiver?

    init(
        timeout: TimeInterval,
        receivedPayload: @escaping (Data) -> Void
    ) throws {
        self.timeout = timeout
        self.receivedPayload = receivedPayload
    }

    func start() throws -> NWEndpoint.Port {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let ready = XCTestExpectation(
            description: "temporary loopback listener is ready"
        )
        let failed = SelectionHelperRequestFrameReceiverTestDelivery()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.fulfill()
            case .failed:
                failed.append(Data([0x01]))
                ready.fulfill()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let receiver = SelectionHelperRequestFrameReceiver(
                connection: connection,
                queue: queue,
                timeout: timeout,
                receivedPayload: receivedPayload
            )
            self.receiver = receiver
            receiver.start()
        }
        self.listener = listener
        listener.start(queue: queue)

        guard XCTWaiter().wait(for: [ready], timeout: 1) == .completed,
              failed.count == 0,
              let port = listener.port else {
            listener.cancel()
            self.listener = nil
            throw SelectionHelperRequestFrameReceiverTestError.listenerFailed
        }
        return port
    }

    func stop() {
        // Test callers invoke stop from the test thread, never this queue.
        // Keeping teardown serialized with newConnectionHandler prevents it
        // from publishing a receiver after the listener has been cleared.
        queue.sync {
            listener?.cancel()
            listener = nil
            receiver = nil
        }
    }
}

private final class SelectionHelperRequestFrameReceiverTestClient:
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "app.blocks.tests.selection-helper-frame-client"
    )
    private let ready = XCTestExpectation(
        description: "temporary loopback client is ready"
    )
    private let terminated: XCTestExpectation?
    private let terminalStateLock = NSLock()
    private var hasSignalledTerminalState = false
    private let connection: NWConnection

    init(
        port: NWEndpoint.Port,
        terminated: XCTestExpectation? = nil
    ) {
        self.terminated = terminated
        connection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready.fulfill()
                observeRemoteTermination()
            case .failed, .cancelled:
                signalTerminalState()
            default:
                break
            }
        }
    }

    func start() -> Bool {
        connection.start(queue: queue)
        return XCTWaiter().wait(for: [ready], timeout: 1) == .completed
    }

    func send(
        _ data: Data,
        closeWrite: Bool,
        completion: XCTestExpectation? = nil
    ) {
        connection.send(
            content: data,
            contentContext: closeWrite ? .finalMessage : .defaultMessage,
            isComplete: closeWrite,
            completion: .contentProcessed { _ in
                completion?.fulfill()
            }
        )
    }

    func cancel() {
        connection.cancel()
    }

    private func observeRemoteTermination() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1
        ) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                signalTerminalState()
            } else {
                observeRemoteTermination()
            }
        }
    }

    private func signalTerminalState() {
        let shouldSignal = terminalStateLock.withLock {
            guard !hasSignalledTerminalState else { return false }
            hasSignalledTerminalState = true
            return true
        }
        if shouldSignal {
            terminated?.fulfill()
        }
    }
}

private enum SelectionHelperRequestFrameReceiverTestError: Error {
    case listenerFailed
}

private final class SelectionHelperNetworkTestExpectation: @unchecked Sendable {
    private let storedExpectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        storedExpectation = expectation
    }

    func fulfill() {
        storedExpectation.fulfill()
    }
}

private final class SelectionHelperResponseFrameSenderTestRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let didFinish: @Sendable () -> Void
    private var storedFinishCount = 0

    init(didFinish: @escaping @Sendable () -> Void = {}) {
        self.didFinish = didFinish
    }

    var finishCount: Int {
        lock.withLock { storedFinishCount }
    }

    func recordFinish() {
        lock.withLock {
            storedFinishCount += 1
        }
        didFinish()
    }
}

private final class SelectionHelperProductionLoopbackTestServer:
    @unchecked Sendable
{
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var receiver: SelectionHelperRequestFrameReceiver?
    private let responseSenderTimeout: TimeInterval
    private let responseSenderFinishRecorder:
        SelectionHelperResponseFrameSenderTestRecorder
    // Accessed only from queue, including the sender completion callback.
    private var responseSenders: [UUID: SelectionHelperResponseFrameSender] = [:]

    init(
        responseSenderTimeout: TimeInterval =
            BlocksSelectionHelperProtocol.requestFrameTimeout,
        didFinish: @escaping @Sendable () -> Void = {}
    ) {
        queue = DispatchQueue(
            label: "app.blocks.tests.selection-helper-production-loopback"
        )
        self.responseSenderTimeout = responseSenderTimeout
        responseSenderFinishRecorder =
            SelectionHelperResponseFrameSenderTestRecorder(
                didFinish: didFinish
            )
        queue.setSpecific(key: queueKey, value: ())
    }

    var responseSenderFinishCount: Int {
        responseSenderFinishRecorder.finishCount
    }

    func start() throws -> NWEndpoint.Port {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let ready = XCTestExpectation(
            description: "production loopback listener is ready"
        )
        let failed = SelectionHelperRequestFrameReceiverTestDelivery()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.fulfill()
            case .failed:
                failed.append(Data([0x01]))
                ready.fulfill()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let receiver = SelectionHelperRequestFrameReceiver(
                connection: connection,
                queue: queue,
                timeout: 1
            ) { [weak self] payload in
                guard let self else {
                    connection.cancel()
                    return
                }
                let responseID = UUID()
                let sender = SelectionHelperResponseFrameSender(
                    connection: connection,
                    queue: queue,
                    timeout: responseSenderTimeout
                ) { [weak self] in
                    guard let self else { return }
                    self.responseSenders.removeValue(forKey: responseID)
                    self.responseSenderFinishRecorder.recordFinish()
                }
                responseSenders[responseID] = sender
                sender.send(payload)
            }
            self.receiver = receiver
            receiver.start()
        }
        synchronouslyOnQueue {
            self.listener = listener
        }
        listener.start(queue: queue)

        let waitResult = XCTWaiter().wait(for: [ready], timeout: 1)
        let port = synchronouslyOnQueue { self.listener?.port }
        guard waitResult == .completed,
              failed.count == 0,
              let port else {
            synchronouslyOnQueue {
                listener.cancel()
                self.listener = nil
                self.receiver = nil
            }
            throw SelectionHelperRequestFrameReceiverTestError.listenerFailed
        }
        return port
    }

    func stop() {
        synchronouslyOnQueue {
            responseSenders.values.forEach { $0.cancel() }
            responseSenders.removeAll()
            listener?.cancel()
            listener = nil
            receiver = nil
        }
    }

    private func synchronouslyOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}

private final class SelectionHelperLoopbackResponseTestServer:
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "app.blocks.tests.selection-helper-delayed-response"
    )
    private let requestReceived: SelectionHelperNetworkTestExpectation
    private var listener: NWListener?
    // Accessed only from queue.
    private var connection: NWConnection?

    init(requestReceived: SelectionHelperNetworkTestExpectation) {
        self.requestReceived = requestReceived
    }

    func start() throws -> NWEndpoint.Port {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let ready = XCTestExpectation(
            description: "delayed response loopback listener is ready"
        )
        let failed = SelectionHelperRequestFrameReceiverTestDelivery()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.fulfill()
            case .failed:
                failed.append(Data([0x01]))
                ready.fulfill()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receiveRequest(from: connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        guard XCTWaiter().wait(for: [ready], timeout: 1) == .completed,
              failed.count == 0,
              let port = listener.port else {
            listener.cancel()
            self.listener = nil
            throw SelectionHelperRequestFrameReceiverTestError.listenerFailed
        }
        return port
    }

    func send(
        _ data: Data?,
        closeWrite: Bool,
        completion: SelectionHelperNetworkTestExpectation,
        onCompletion: @escaping @Sendable (NWError?) -> Void = { _ in }
    ) {
        queue.async { [weak self] in
            guard let connection = self?.connection else { return }
            connection.send(
                content: data,
                contentContext: closeWrite ? .finalMessage : .defaultMessage,
                isComplete: closeWrite,
                completion: .contentProcessed { error in
                    onCompletion(error)
                    completion.fulfill()
                }
            )
        }
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    private func receiveRequest(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] _, _, isComplete, error in
            guard let self, error == nil else { return }
            if isComplete {
                requestReceived.fulfill()
            } else {
                receiveRequest(from: connection)
            }
        }
    }
}

private final class SelectionHelperLoopbackClientResultRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let returned: SelectionHelperNetworkTestExpectation
    private let returnedBeforeFIN: SelectionHelperNetworkTestExpectation?
    private var finReleased = false
    private var storedResult: Result<Data, SelectionAgentServiceFailure>?

    init(
        returned: SelectionHelperNetworkTestExpectation,
        returnedBeforeFIN: SelectionHelperNetworkTestExpectation? = nil
    ) {
        self.returned = returned
        self.returnedBeforeFIN = returnedBeforeFIN
    }

    var result: Result<Data, SelectionAgentServiceFailure>? {
        lock.withLock { storedResult }
    }

    func allowReturnAfterFIN() {
        lock.withLock { finReleased = true }
    }

    func record(_ result: Result<Data, SelectionAgentServiceFailure>) {
        let returnedTooEarly = lock.withLock {
            storedResult = result
            return !finReleased
        }
        if returnedTooEarly {
            returnedBeforeFIN?.fulfill()
        }
        returned.fulfill()
    }
}

private final class SelectionHelperResponseFrameTestClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.blocks.tests.selection-helper-response-client"
    )
    private let ready = XCTestExpectation(
        description: "temporary response client is ready"
    )
    private let responseFinished: XCTestExpectation?
    private let remoteTerminated: XCTestExpectation?
    private let receivesResponse: Bool
    private let lock = NSLock()
    private let connection: NWConnection
    private var storedResponse = Data()
    private var storedResponseIsComplete = false
    private var storedResponseError: String?
    private var hasSignalledResponseFinished = false
    private var hasSignalledRemoteTermination = false

    init(
        port: NWEndpoint.Port,
        receivesResponse: Bool = true,
        responseFinished: XCTestExpectation? = nil,
        remoteTerminated: XCTestExpectation? = nil
    ) {
        self.receivesResponse = receivesResponse
        self.responseFinished = responseFinished
        self.remoteTerminated = remoteTerminated
        connection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready.fulfill()
                if receivesResponse {
                    receiveResponse()
                }
            case .failed, .cancelled:
                signalRemoteTermination()
            default:
                break
            }
        }
    }

    var response: Data {
        lock.withLock { storedResponse }
    }

    var responseIsComplete: Bool {
        lock.withLock { storedResponseIsComplete }
    }

    var responseError: String? {
        lock.withLock { storedResponseError }
    }

    func start() -> Bool {
        connection.start(queue: queue)
        return XCTWaiter().wait(for: [ready], timeout: 1) == .completed
    }

    func sendRequest(
        _ frame: Data,
        completion: XCTestExpectation? = nil
    ) {
        connection.send(
            content: frame,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                completion?.fulfill()
            }
        )
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveResponse() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            lock.withLock {
                if let content {
                    self.storedResponse.append(content)
                }
                if isComplete {
                    self.storedResponseIsComplete = true
                }
                if let error {
                    self.storedResponseError = error.localizedDescription
                }
            }
            if isComplete || error != nil {
                signalResponseFinished()
            } else {
                receiveResponse()
            }
        }
    }

    private func signalResponseFinished() {
        let shouldSignal = lock.withLock {
            guard !hasSignalledResponseFinished else { return false }
            hasSignalledResponseFinished = true
            return true
        }
        if shouldSignal {
            responseFinished?.fulfill()
        }
    }

    private func signalRemoteTermination() {
        let shouldSignal = lock.withLock {
            guard !hasSignalledRemoteTermination else { return false }
            hasSignalledRemoteTermination = true
            return true
        }
        if shouldSignal {
            remoteTerminated?.fulfill()
        }
    }
}

@MainActor
final class TranslationEntryBridgeTests: XCTestCase {
    func testControlledXCTestHostInheritsVerificationTokenWhenRequired() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLOCKS_VERIFICATION_REQUIRE_TOKEN_PROBE"] == "1" else {
            return
        }
        guard let token = environment["BLOCKS_VERIFICATION_TARGET_TOKEN"] else {
            return XCTFail("Controlled XCTest host is missing its verification token.")
        }
        let tokenBytes = Array(token.utf8)
        XCTAssertEqual(
            tokenBytes.count,
            64,
            "Controlled XCTest host verification token must contain exactly 64 bytes."
        )
        XCTAssertTrue(
            tokenBytes.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
            },
            "Controlled XCTest host verification token must be 256-bit lowercase hexadecimal."
        )
    }

    private func requireSelectionHelperReceiverNetworkTests() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "BLOCKS_HELPER_RECEIVER_NETWORK_TESTS"
            ] == "1",
            "Requires an explicitly entitled loopback test host."
        )
    }

    func testSelectionHelperRequestFrameUsesDedicatedRequestBoundary() {
        let maximum = BlocksSelectionCaptureProtocol.maximumRequestBytes
        let exactPayload = Data(repeating: 0x61, count: maximum)
        let exactFrame = exactPayload + Data([0x0A])

        XCTAssertTrue(
            SelectionHelperRequestFrameValidator.canContinueReceiving(
                exactPayload
            )
        )
        XCTAssertTrue(
            SelectionHelperRequestFrameValidator.canContinueReceiving(
                exactFrame
            )
        )
        XCTAssertEqual(
            SelectionHelperRequestFrameValidator.payload(from: exactFrame),
            exactPayload
        )
        XCTAssertEqual(
            SelectionHelperRequestFrameValidator.disposition(
                for: exactFrame,
                peerDidCloseWrite: false
            ),
            .receiveMore
        )
        XCTAssertEqual(
            SelectionHelperRequestFrameValidator.disposition(
                for: exactFrame,
                peerDidCloseWrite: true
            ),
            .complete(exactPayload)
        )
        XCTAssertEqual(
            SelectionHelperRequestFrameValidator.disposition(
                for: exactPayload,
                peerDidCloseWrite: true
            ),
            .reject
        )

        let oversizedPayload = exactPayload + Data([0x62])
        XCTAssertFalse(
            SelectionHelperRequestFrameValidator.canContinueReceiving(
                oversizedPayload
            )
        )
        XCTAssertFalse(
            SelectionHelperRequestFrameValidator.canContinueReceiving(
                oversizedPayload + Data([0x0A])
            )
        )
        XCTAssertNil(
            SelectionHelperRequestFrameValidator.payload(
                from: oversizedPayload + Data([0x0A])
            )
        )
        let exactFrameWithTrailingBytes =
            exactFrame + Data(repeating: 0x63, count: 65_536)
        XCTAssertFalse(
            SelectionHelperRequestFrameValidator.canContinueReceiving(
                exactFrameWithTrailingBytes
            )
        )
        XCTAssertNil(
            SelectionHelperRequestFrameValidator.payload(
                from: exactFrameWithTrailingBytes
            )
        )
        XCTAssertEqual(
            SelectionHelperRequestFrameValidator.disposition(
                for: exactFrameWithTrailingBytes,
                peerDidCloseWrite: false
            ),
            .reject
        )
        XCTAssertEqual(BlocksSelectionHelperProtocol.version, 4)
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.minimumCompatibleVersion,
            4
        )
        XCTAssertEqual(
            BlocksSelectionHelperProtocol.requestFrameTimeout,
            2
        )
        XCTAssertGreaterThan(
            BlocksSelectionHelperProtocol.maximumWireBytes,
            BlocksSelectionCaptureProtocol.maximumRequestBytes
        )
    }

    func testSelectionHelperRequestFrameReceiverWaitsForFINAndRejectsTrailingData()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let delivery = SelectionHelperRequestFrameReceiverTestDelivery()
        let unexpectedDelivery = expectation(
            description: "request is not delivered before FIN"
        )
        unexpectedDelivery.isInverted = true
        let server = try SelectionHelperRequestFrameReceiverTestServer(
            timeout: 1
        ) { payload in
            delivery.append(payload)
            unexpectedDelivery.fulfill()
        }
        defer { server.stop() }

        let terminated = expectation(
            description: "trailing request data is rejected"
        )
        let client = SelectionHelperRequestFrameReceiverTestClient(
            port: try server.start(),
            terminated: terminated
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let exactFrame = Data(
            repeating: 0x61,
            count: BlocksSelectionCaptureProtocol.maximumRequestBytes
        ) + Data([0x0A])
        let firstSend = expectation(description: "exact frame sent")
        client.send(exactFrame, closeWrite: false, completion: firstSend)
        XCTAssertEqual(
            XCTWaiter().wait(for: [firstSend], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [unexpectedDelivery], timeout: 0.15),
            .completed
        )
        XCTAssertEqual(delivery.count, 0)

        let trailingSend = expectation(description: "trailing byte sent")
        client.send(Data([0x62]), closeWrite: false, completion: trailingSend)
        XCTAssertEqual(
            XCTWaiter().wait(for: [trailingSend], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [terminated], timeout: 1),
            .completed
        )
        XCTAssertEqual(delivery.count, 0)
    }

    func testSelectionHelperRequestFrameReceiverRejectsOversizedUnterminatedPayload()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let delivery = SelectionHelperRequestFrameReceiverTestDelivery()
        let server = try SelectionHelperRequestFrameReceiverTestServer(
            timeout: 1,
            receivedPayload: delivery.append
        )
        defer { server.stop() }

        let terminated = expectation(
            description: "oversized unterminated payload is rejected"
        )
        let client = SelectionHelperRequestFrameReceiverTestClient(
            port: try server.start(),
            terminated: terminated
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let oversizedPayload = Data(
            repeating: 0x61,
            count: BlocksSelectionCaptureProtocol.maximumRequestBytes + 1
        )
        client.send(oversizedPayload, closeWrite: false)

        XCTAssertEqual(
            XCTWaiter().wait(for: [terminated], timeout: 1),
            .completed
        )
        XCTAssertEqual(delivery.count, 0)
    }

    func testSelectionHelperRequestFrameReceiverRejectsExactPayloadWithoutNewlineAfterFIN()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let delivery = SelectionHelperRequestFrameReceiverTestDelivery()
        let server = try SelectionHelperRequestFrameReceiverTestServer(
            timeout: 1,
            receivedPayload: delivery.append
        )
        defer { server.stop() }

        let terminated = expectation(
            description: "unterminated payload after FIN is rejected"
        )
        let client = SelectionHelperRequestFrameReceiverTestClient(
            port: try server.start(),
            terminated: terminated
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let exactPayload = Data(
            repeating: 0x61,
            count: BlocksSelectionCaptureProtocol.maximumRequestBytes
        )
        client.send(exactPayload, closeWrite: true)

        XCTAssertEqual(
            XCTWaiter().wait(for: [terminated], timeout: 1),
            .completed
        )
        XCTAssertEqual(delivery.count, 0)
    }

    func testSelectionHelperRequestFrameReceiverDeliversSmallFrameExactlyOnceAfterFIN()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let delivery = SelectionHelperRequestFrameReceiverTestDelivery()
        let payload = Data("small valid request".utf8)
        let server = try SelectionHelperRequestFrameReceiverTestServer(
            timeout: 1
        ) { receivedPayload in
            delivery.append(receivedPayload)
        }
        defer { server.stop() }

        let client = SelectionHelperRequestFrameReceiverTestClient(
            port: try server.start()
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        client.send(payload + Data([0x0A]), closeWrite: true)

        let deadline = Date().addingTimeInterval(1)
        while delivery.count == 0, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        XCTAssertEqual(delivery.values, [payload])
    }

    func testSelectionHelperRequestFrameReceiverTimesOutUnclosedValidFrame()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let delivery = SelectionHelperRequestFrameReceiverTestDelivery()
        let server = try SelectionHelperRequestFrameReceiverTestServer(
            timeout: 0.1,
            receivedPayload: delivery.append
        )
        defer { server.stop() }

        let terminated = expectation(
            description: "unclosed valid frame times out"
        )
        let client = SelectionHelperRequestFrameReceiverTestClient(
            port: try server.start(),
            terminated: terminated
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let frame = Data("valid but not closed".utf8) + Data([0x0A])
        let sent = expectation(description: "unclosed frame sent")
        client.send(frame, closeWrite: false, completion: sent)
        XCTAssertEqual(
            XCTWaiter().wait(for: [sent], timeout: 1),
            .completed
        )

        XCTAssertEqual(
            XCTWaiter().wait(for: [terminated], timeout: 1),
            .completed
        )
        XCTAssertEqual(delivery.count, 0)
    }

    func testSelectionHelperProductionLoopbackSendClosesWriteAndReadsResponse()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let senderFinished = expectation(
            description: "production loopback sender observes client close"
        )
        let senderFinishedSignal = SelectionHelperNetworkTestExpectation(
            senderFinished
        )
        let server = SelectionHelperProductionLoopbackTestServer(
            didFinish: { senderFinishedSignal.fulfill() }
        )
        let port = try server.start()
        defer { server.stop() }
        let packet = SelectionHelperWirePacket(
            kind: .pair,
            payload: Data("production-loopback".utf8)
        )
        let result = SelectionHelperLoopbackConnection(
            host: "127.0.0.1",
            port: port
        ).send(packet, timeout: 1)
        guard case let .success(responseData) = result else {
            return XCTFail("Expected the production loopback response.")
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                SelectionHelperWirePacket.self,
                from: responseData
            ),
            packet
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [senderFinished], timeout: 1),
            .completed
        )
        XCTAssertEqual(server.responseSenderFinishCount, 1)
    }

    func testSelectionHelperProductionLoopbackWaitsForFINAfterResponseFrame()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let requestReceived = expectation(
            description: "production client closes request write"
        )
        let server = SelectionHelperLoopbackResponseTestServer(
            requestReceived: SelectionHelperNetworkTestExpectation(
                requestReceived
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let returned = expectation(
            description: "production client returns after response FIN"
        )
        let returnedBeforeFIN = expectation(
            description: "production client must not return before response FIN"
        )
        returnedBeforeFIN.isInverted = true
        let recorder = SelectionHelperLoopbackClientResultRecorder(
            returned: SelectionHelperNetworkTestExpectation(returned),
            returnedBeforeFIN: SelectionHelperNetworkTestExpectation(
                returnedBeforeFIN
            )
        )
        let packet = SelectionHelperWirePacket(
            kind: .pair,
            payload: Data("wait-for-fin".utf8)
        )
        DispatchQueue.global().async {
            recorder.record(
                SelectionHelperLoopbackConnection(
                    host: "127.0.0.1",
                    port: port
                ).send(packet, timeout: 1)
            )
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestReceived], timeout: 1),
            .completed
        )

        let frameSent = expectation(
            description: "response frame is sent without FIN"
        )
        server.send(
            Data("payload-before-fin\n".utf8),
            closeWrite: false,
            completion: SelectionHelperNetworkTestExpectation(frameSent)
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [frameSent], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [returnedBeforeFIN], timeout: 0.1),
            .completed
        )

        let finSent = expectation(description: "response FIN is sent")
        server.send(
            nil,
            closeWrite: true,
            completion: SelectionHelperNetworkTestExpectation(finSent),
            onCompletion: { error in
                guard error == nil else { return }
                recorder.allowReturnAfterFIN()
            }
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [finSent, returned], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            recorder.result,
            .success(Data("payload-before-fin".utf8))
        )
    }

    func testSelectionHelperProductionLoopbackTimesOutWithoutResponseFIN()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let requestReceived = expectation(
            description: "production client closes request write"
        )
        let server = SelectionHelperLoopbackResponseTestServer(
            requestReceived: SelectionHelperNetworkTestExpectation(
                requestReceived
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let returned = expectation(
            description: "production client times out without response FIN"
        )
        let recorder = SelectionHelperLoopbackClientResultRecorder(
            returned: SelectionHelperNetworkTestExpectation(returned)
        )
        let packet = SelectionHelperWirePacket(
            kind: .pair,
            payload: Data("timeout-without-fin".utf8)
        )
        DispatchQueue.global().async {
            recorder.record(
                SelectionHelperLoopbackConnection(
                    host: "127.0.0.1",
                    port: port
                ).send(packet, timeout: 0.2)
            )
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestReceived], timeout: 1),
            .completed
        )

        let frameSent = expectation(
            description: "response frame is sent without FIN"
        )
        server.send(
            Data("payload-without-fin\n".utf8),
            closeWrite: false,
            completion: SelectionHelperNetworkTestExpectation(frameSent)
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [frameSent, returned], timeout: 1),
            .completed
        )
        XCTAssertEqual(recorder.result, .failure(.timedOut))
    }

    func testSelectionHelperProductionLoopbackRejectsTrailingResponseBytes()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let requestReceived = expectation(
            description: "production client closes request write"
        )
        let server = SelectionHelperLoopbackResponseTestServer(
            requestReceived: SelectionHelperNetworkTestExpectation(
                requestReceived
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let returned = expectation(
            description: "production client returns after malformed response FIN"
        )
        let returnedBeforeFIN = expectation(
            description: "production client must not return before malformed response FIN"
        )
        returnedBeforeFIN.isInverted = true
        let recorder = SelectionHelperLoopbackClientResultRecorder(
            returned: SelectionHelperNetworkTestExpectation(returned),
            returnedBeforeFIN: SelectionHelperNetworkTestExpectation(
                returnedBeforeFIN
            )
        )
        let packet = SelectionHelperWirePacket(
            kind: .pair,
            payload: Data("reject-response-tail".utf8)
        )
        DispatchQueue.global().async {
            recorder.record(
                SelectionHelperLoopbackConnection(
                    host: "127.0.0.1",
                    port: port
                ).send(packet, timeout: 1)
            )
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestReceived], timeout: 1),
            .completed
        )

        let frameSent = expectation(
            description: "response frame is sent before trailing bytes"
        )
        server.send(
            Data("valid-payload\n".utf8),
            closeWrite: false,
            completion: SelectionHelperNetworkTestExpectation(frameSent)
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [frameSent], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [returnedBeforeFIN], timeout: 0.1),
            .completed
        )
        let trailingBytesSent = expectation(
            description: "response trailing bytes are sent"
        )
        server.send(
            Data("unexpected-tail".utf8),
            closeWrite: false,
            completion: SelectionHelperNetworkTestExpectation(
                trailingBytesSent
            )
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [trailingBytesSent], timeout: 1),
            .completed
        )

        let finSent = expectation(description: "malformed response FIN is sent")
        server.send(
            nil,
            closeWrite: true,
            completion: SelectionHelperNetworkTestExpectation(finSent),
            onCompletion: { error in
                guard error == nil else { return }
                recorder.allowReturnAfterFIN()
            }
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [finSent, returned], timeout: 1),
            .completed
        )
        XCTAssertEqual(recorder.result, .failure(.invalidResponse))
    }

    func testSelectionHelperResponseSenderDeliversFINBeforeClientCancels()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let senderFinished = expectation(
            description: "response sender finishes after client cancellation"
        )
        let senderFinishedSignal = SelectionHelperNetworkTestExpectation(
            senderFinished
        )
        let server = SelectionHelperProductionLoopbackTestServer(
            didFinish: { senderFinishedSignal.fulfill() }
        )
        let port = try server.start()
        defer { server.stop() }

        let responseFinished = expectation(
            description: "response client reads response FIN"
        )
        let client = SelectionHelperResponseFrameTestClient(
            port: port,
            responseFinished: responseFinished
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let expected = Data("response-fin".utf8)
        let requestSent = expectation(description: "response request is sent")
        client.sendRequest(
            expected + Data([0x0A]),
            completion: requestSent
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestSent], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [responseFinished], timeout: 1),
            .completed
        )
        XCTAssertEqual(client.response, expected + Data([0x0A]))
        XCTAssertTrue(client.responseIsComplete)
        XCTAssertNil(client.responseError)

        client.cancel()
        XCTAssertEqual(
            XCTWaiter().wait(for: [senderFinished], timeout: 1),
            .completed
        )
        XCTAssertEqual(server.responseSenderFinishCount, 1)
    }

    func testSelectionHelperResponseSenderFinishesOnceWhenPeerCancels()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let senderFinished = expectation(
            description: "response sender observes peer cancellation"
        )
        let senderFinishedSignal = SelectionHelperNetworkTestExpectation(
            senderFinished
        )
        let server = SelectionHelperProductionLoopbackTestServer(
            responseSenderTimeout: 0.2,
            didFinish: { senderFinishedSignal.fulfill() }
        )
        let port = try server.start()
        defer { server.stop() }

        let responseFinished = expectation(
            description: "response is complete before peer cancellation"
        )
        let client = SelectionHelperResponseFrameTestClient(
            port: port,
            responseFinished: responseFinished
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let requestSent = expectation(description: "response request is sent")
        client.sendRequest(
            Data("peer-cancel\n".utf8),
            completion: requestSent
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestSent], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [responseFinished], timeout: 1),
            .completed
        )

        client.cancel()
        XCTAssertEqual(
            XCTWaiter().wait(for: [senderFinished], timeout: 0.1),
            .completed
        )

        let settled = expectation(
            description: "sender remains finished beyond cleanup timeout"
        )
        let settledSignal = SelectionHelperNetworkTestExpectation(settled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            settledSignal.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 0.5),
            .completed
        )
        XCTAssertEqual(server.responseSenderFinishCount, 1)
    }

    func testSelectionHelperResponseSenderTimesOutOnceForOpenPeer()
        throws
    {
        try requireSelectionHelperReceiverNetworkTests()
        let senderFinished = expectation(
            description: "response sender cleanup timeout finishes"
        )
        let senderFinishedSignal = SelectionHelperNetworkTestExpectation(
            senderFinished
        )
        let server = SelectionHelperProductionLoopbackTestServer(
            responseSenderTimeout: 0.05,
            didFinish: { senderFinishedSignal.fulfill() }
        )
        let port = try server.start()
        defer { server.stop() }

        let remoteTerminated = expectation(
            description: "server terminates unconsumed response peer"
        )
        let client = SelectionHelperResponseFrameTestClient(
            port: port,
            receivesResponse: false,
            remoteTerminated: remoteTerminated
        )
        defer { client.cancel() }
        XCTAssertTrue(client.start())

        let requestSent = expectation(description: "response request is sent")
        client.sendRequest(
            Data("open-peer\n".utf8),
            completion: requestSent
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [requestSent], timeout: 1),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [senderFinished, remoteTerminated],
                timeout: 1
            ),
            .completed
        )

        let settled = expectation(
            description: "timed-out sender does not finish twice"
        )
        let settledSignal = SelectionHelperNetworkTestExpectation(settled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            settledSignal.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 0.25),
            .completed
        )
        XCTAssertEqual(server.responseSenderFinishCount, 1)
    }

    func testExplicitTranslationTextSnapshotUsesLiveCaptureCanonicalForm()
        throws
    {
        let text = "译文\n第二行"
        let createdAt = Date(timeIntervalSince1970: 100)
        let snapshot = try XCTUnwrap(
            ClipboardExplicitTextSnapshotFactory.make(
                text: text,
                recordID: "translation-copy",
                changeCount: 17,
                createdAt: createdAt
            )
        )

        XCTAssertEqual(snapshot.record.id, "translation-copy")
        XCTAssertEqual(snapshot.record.createdAt, createdAt)
        XCTAssertEqual(snapshot.record.lastCopiedAt, createdAt)
        XCTAssertEqual(snapshot.record.changeCount, 17)
        XCTAssertEqual(snapshot.record.kind, .text)
        XCTAssertEqual(snapshot.payload?.text, text)
        XCTAssertEqual(
            snapshot.record.signatureSHA256,
            ClipboardExplicitTextSnapshotFactory.signature(for: text)
        )
        XCTAssertEqual(snapshot.record.summary, "译文 第二行")
    }

    func testExplicitTranslationTextSnapshotRejectsEmptyOrOversizedText() {
        XCTAssertNil(
            ClipboardExplicitTextSnapshotFactory.make(
                text: "",
                recordID: "empty",
                changeCount: 1
            )
        )
        XCTAssertNil(
            ClipboardExplicitTextSnapshotFactory.make(
                text: String(
                    repeating: "x",
                    count: ClipboardBrokerLimits.maxTextBytes + 1
                ),
                recordID: "oversized",
                changeCount: 2
            )
        )
    }

    func testClipboardTextPreviewServiceReadsAndTrimsThroughBroker() async throws {
        let broker = TranslationClipboardBrokerStub(
            plainTextResult: ClipboardBrokerPlainTextResult(
                text: "  broker fixture \n",
                originalCharacterCount: 19,
                truncated: false,
                changeCount: 7
            )
        )
        let service = ClipboardTextPreviewService(broker: broker)

        let currentPreview = await service.currentPlainText(maxCharacters: 32)
        let preview = try XCTUnwrap(currentPreview)
        let requestedLimits = await broker.requestedPlainTextLimits()

        XCTAssertEqual(preview.text, "broker fixture")
        XCTAssertEqual(preview.originalCharacterCount, 14)
        XCTAssertFalse(preview.truncated)
        XCTAssertEqual(requestedLimits, [32])
    }

    func testClipboardTextPreviewServiceMapsBrokerWriteResultToBoolean() async {
        let successfulBroker = TranslationClipboardBrokerStub()
        let failingBroker = TranslationClipboardBrokerStub(writeFails: true)

        let succeeded = await ClipboardTextPreviewService(
            broker: successfulBroker
        ).writePlainText("translated")
        let failed = await ClipboardTextPreviewService(
            broker: failingBroker
        ).writePlainText("translated")
        let successfulWriteCount = await successfulBroker.writeRequestCount()
        let failingWriteCount = await failingBroker.writeRequestCount()

        XCTAssertTrue(succeeded)
        XCTAssertFalse(failed)
        XCTAssertEqual(successfulWriteCount, 1)
        XCTAssertEqual(failingWriteCount, 1)
    }

    func testManualFocusRequestAdvancesGeneration() {
        let suiteName = "TranslationSourceFocus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .selection, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let initialRequest = model.sourceFocusRequest

        model.requestSourceFocus()

        XCTAssertEqual(model.sourceFocusRequest, initialRequest + 1)
    }

    func testSourceEditorDoesNotConsumeFocusRequestBeforeWindowIsKey() {
        var focusAttemptCount = 0
        let coordinator = TranslationSourceTextEditor.Coordinator(
            onTextChange: { _ in },
            isEligibleForFocus: { _ in false },
            performFocus: { _ in
                focusAttemptCount += 1
                return true
            }
        )
        let textView = TranslationSourceNSTextView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100)
        )
        defer { coordinator.detach() }
        coordinator.attach(textView)

        coordinator.requestFocus(generation: 1)

        XCTAssertEqual(coordinator.lastFocusRequest, 0)
        XCTAssertEqual(focusAttemptCount, 0)
    }

    func testSourceEditorConsumesPendingFocusAfterWindowBecomesKey() {
        var isKeyWindow = false
        var focusAttemptCount = 0
        let coordinator = TranslationSourceTextEditor.Coordinator(
            onTextChange: { _ in },
            isEligibleForFocus: { _ in isKeyWindow },
            performFocus: { _ in
                focusAttemptCount += 1
                return true
            }
        )
        let textView = TranslationSourceNSTextView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100)
        )
        defer { coordinator.detach() }
        coordinator.attach(textView)
        coordinator.requestFocus(generation: 7)
        XCTAssertEqual(coordinator.lastFocusRequest, 0)

        isKeyWindow = true
        coordinator.retryPendingFocus()

        XCTAssertEqual(coordinator.lastFocusRequest, 7)
        XCTAssertEqual(focusAttemptCount, 1)
    }

    func testSourceEditorPublishesTextChangesFromAppKitNotification() {
        var publishedTexts: [String] = []
        let coordinator = TranslationSourceTextEditor.Coordinator(
            onTextChange: { publishedTexts.append($0) }
        )
        let textView = TranslationSourceNSTextView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100)
        )
        coordinator.attach(textView)
        defer { coordinator.detach() }

        textView.string = "hello"
        NotificationCenter.default.post(
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.post(
            name: NSText.didChangeNotification,
            object: textView
        )

        XCTAssertEqual(publishedTexts, ["hello"])
    }

    func testSourceEditorPublishesSemanticFocusState() {
        var focusStates: [Bool] = []
        let coordinator = TranslationSourceTextEditor.Coordinator(
            onTextChange: { _ in },
            onFocusChange: { focusStates.append($0) }
        )
        let textView = TranslationSourceNSTextView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100)
        )
        coordinator.attach(textView)
        defer { coordinator.detach() }

        coordinator.textDidBeginEditing(
            Notification(name: NSText.didBeginEditingNotification)
        )
        coordinator.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification)
        )

        XCTAssertEqual(focusStates, [true, false])
    }

    func testAXSelectionReaderReturnsPermissionFailureWithoutReadingElement() {
        let client = AXSelectionSystemClientStub(
            accessibilityTrusted: false,
            elementResult: .unavailable
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )

        XCTAssertEqual(
            reader.readFrontmostSelection(),
            .unavailable(AXSelectionReadFailure(
                reason: .accessibilityPermissionDenied,
                target: target()
            ))
        )
        XCTAssertEqual(client.readCount, 0)
    }

    func testAXSelectionReaderPreservesSelectionAgentFailureReason() {
        let client = AXSelectionSystemClientStub(
            accessibilityTrusted: false,
            defersAccessibilityTrustEvaluation: true,
            elementResult: .failure(.agentRequiresApproval)
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks"
        )

        XCTAssertEqual(
            reader.readSelection(from: target()),
            .unavailable(AXSelectionReadFailure(
                reason: .agentRequiresApproval,
                target: target()
            ))
        )
        XCTAssertEqual(client.readCount, 1)
    }

    func testSelectionHelperAuthenticatedCodecRoundTripsSharedKey()
        throws
    {
        let requestID = UUID().uuidString
        let clientKey = P256.KeyAgreement.PrivateKey()
        let helperKey = P256.KeyAgreement.PrivateKey()
        let clientSharedKey = try
            SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: clientKey,
                peerPublicKeyData:
                    helperKey.publicKey.rawRepresentation,
                requestID: requestID
            )
        let helperSharedKey = try
            SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: helperKey,
                peerPublicKeyData:
                    clientKey.publicKey.rawRepresentation,
                requestID: requestID
            )
        XCTAssertEqual(clientSharedKey, helperSharedKey)
        XCTAssertEqual(
            SelectionHelperAuthenticatedCodec.pairingProof(
                keyData: clientSharedKey,
                requestID: requestID
            ),
            SelectionHelperAuthenticatedCodec.pairingProof(
                keyData: helperSharedKey,
                requestID: requestID
            )
        )

        let command = SelectionHelperCommand(kind: .health)
        let sealed = try
            SelectionHelperAuthenticatedCodec.seal(
                command,
                requestID: requestID,
                expiresAt: Date().addingTimeInterval(5),
                keyData: clientSharedKey
            )
        XCTAssertEqual(
            try SelectionHelperAuthenticatedCodec.open(
                SelectionHelperCommand.self,
                from: sealed,
                keyData: helperSharedKey
            ),
            command
        )
    }

    func testSelectionHelperPairingKeyDerivationRejectsOversizedRequestIdentifiers()
        throws
    {
        let clientKey = P256.KeyAgreement.PrivateKey()
        let helperKey = P256.KeyAgreement.PrivateKey()
        let boundaryRequestID = String(repeating: "r", count: 128)

        XCTAssertNoThrow(
            try SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: clientKey,
                peerPublicKeyData: helperKey.publicKey.rawRepresentation,
                requestID: boundaryRequestID
            )
        )
        XCTAssertThrowsError(
            try SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: clientKey,
                peerPublicKeyData: helperKey.publicKey.rawRepresentation,
                requestID: String(repeating: "r", count: 129)
            )
        ) { error in
            XCTAssertEqual(
                error as? SelectionHelperAuthenticatedCodecError,
                .invalidEnvelope
            )
        }
        XCTAssertThrowsError(
            try SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: clientKey,
                peerPublicKeyData: helperKey.publicKey.rawRepresentation,
                requestID: String(repeating: "界", count: 43)
            )
        ) { error in
            XCTAssertEqual(
                error as? SelectionHelperAuthenticatedCodecError,
                .invalidEnvelope
            )
        }
    }

    func testSelectionHelperPairingAuthenticationBindsCanonicalTranscript()
        throws
    {
        let bootstrapKey = Data(repeating: 0x31, count: 32)
        let clientKey = P256.KeyAgreement.PrivateKey()
        let helperKey = P256.KeyAgreement.PrivateKey()
        let requestID = "request-id"
        let pairingCode = "123456"
        let clientPublicKey = clientKey.publicKey.rawRepresentation
        XCTAssertEqual(
            clientPublicKey.count,
            BlocksSelectionHelperProtocol.p256RawPublicKeyBytes
        )
        let clientProof = try XCTUnwrap(
            SelectionHelperPairingAuthentication.clientProof(
                bootstrapKey: bootstrapKey,
                requestID: requestID,
                pairingCode: pairingCode,
                clientPublicKey: clientPublicKey
            )
        )
        let request = SelectionHelperPairRequest(
            requestID: requestID,
            pairingCode: pairingCode,
            clientPublicKey: clientPublicKey,
            clientProof: clientProof
        )
        let helperPublicKey = helperKey.publicKey.rawRepresentation
        XCTAssertEqual(
            helperPublicKey.count,
            BlocksSelectionHelperProtocol.p256RawPublicKeyBytes
        )
        let helperProof = try XCTUnwrap(
            SelectionHelperPairingAuthentication.helperProof(
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: helperPublicKey
            )
        )

        XCTAssertTrue(
            SelectionHelperPairingAuthentication.verifiesClientProof(
                clientProof,
                bootstrapKey: bootstrapKey,
                request: request
            )
        )
        XCTAssertTrue(
            SelectionHelperPairingAuthentication.verifiesHelperProof(
                helperProof,
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: helperPublicKey
            )
        )

        let alteredClientPublicKey = Data(
            clientPublicKey.dropLast()
        ) + Data([clientPublicKey.last! ^ 0x01])
        let alteredHelperPublicKey = Data(
            helperPublicKey.dropLast()
        ) + Data([helperPublicKey.last! ^ 0x01])
        for alteredRequest in [
            SelectionHelperPairRequest(
                requestID: "other-request-id",
                pairingCode: pairingCode,
                clientPublicKey: clientPublicKey,
                clientProof: clientProof
            ),
            SelectionHelperPairRequest(
                requestID: requestID,
                pairingCode: "654321",
                clientPublicKey: clientPublicKey,
                clientProof: clientProof
            ),
            SelectionHelperPairRequest(
                requestID: requestID,
                pairingCode: pairingCode,
                clientPublicKey: alteredClientPublicKey,
                clientProof: clientProof
            ),
        ] {
            XCTAssertFalse(
                SelectionHelperPairingAuthentication.verifiesClientProof(
                    clientProof,
                    bootstrapKey: bootstrapKey,
                    request: alteredRequest
                )
            )
        }
        XCTAssertFalse(
            SelectionHelperPairingAuthentication.verifiesHelperProof(
                helperProof,
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: alteredHelperPublicKey
            )
        )
        var alteredClientProof = clientProof
        alteredClientProof[alteredClientProof.startIndex] ^= 0x01
        XCTAssertFalse(
            SelectionHelperPairingAuthentication.verifiesClientProof(
                alteredClientProof,
                bootstrapKey: bootstrapKey,
                request: request
            )
        )
        var alteredHelperProof = helperProof
        alteredHelperProof[alteredHelperProof.startIndex] ^= 0x01
        XCTAssertFalse(
            SelectionHelperPairingAuthentication.verifiesHelperProof(
                alteredHelperProof,
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: helperPublicKey
            )
        )
        XCTAssertFalse(
            SelectionHelperPairingAuthentication.verifiesClientProof(
                helperProof,
                bootstrapKey: bootstrapKey,
                request: request
            )
        )
        XCTAssertFalse(
            SelectionHelperPairingAuthentication.verifiesHelperProof(
                clientProof,
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: helperPublicKey
            )
        )
        XCTAssertNotEqual(clientProof, helperProof)
    }

    func testSelectionHelperPairingAuthenticationRejectsV3() {
        let privateKey = P256.KeyAgreement.PrivateKey()
        XCTAssertNil(
            SelectionHelperPairingAuthentication.clientProof(
                bootstrapKey: Data(repeating: 0x41, count: 32),
                requestID: "request-id",
                pairingCode: "123456",
                clientPublicKey: privateKey.publicKey.rawRepresentation,
                protocolVersion: 3
            )
        )
    }

    func testSelectionHelperBootstrapCreationDuplicateReturnsSingleWinner() {
        let generatedKey = Data(repeating: 0x51, count: 32)
        let winningKey = Data(repeating: 0x52, count: 32)
        var storedKey: Data?
        var addCount = 0

        let result = SelectionHelperBootstrapKeyCreationCoordinator
            .createOrLoad(
                load: { storedKey },
                generate: { generatedKey },
                add: { _ in
                    addCount += 1
                    storedKey = winningKey
                    return errSecDuplicateItem
                }
            )

        XCTAssertEqual(result, winningKey)
        XCTAssertEqual(storedKey, winningKey)
        XCTAssertEqual(addCount, 1)
    }

    func testSelectionHelperSharedKeyStoreLoadQueriesOnlyV4Key() throws {
        let key = Data(repeating: 0x51, count: 32)
        let recorder = SelectionHelperKeychainOperationRecorder(
            copyStatus: errSecSuccess,
            copyData: key
        )
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemCopyMatching: recorder.itemCopyMatching,
            itemDelete: recorder.itemDelete
        )

        XCTAssertEqual(store.load(), key)
        XCTAssertEqual(recorder.copyQueries.count, 1)
        let query = try XCTUnwrap(recorder.copyQueries.first)
        assertSelectionHelperKeychainQuery(
            query,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertFalse(
            recorder.copyQueries.contains { query in
                query[kSecAttrService as String] as? String ==
                    BlocksSelectionHelperProtocol.legacyKeychainService
                    || query[kSecAttrAccount as String] as? String ==
                    BlocksSelectionHelperProtocol.legacyKeychainAccount
            }
        )
        XCTAssertTrue(recorder.deleteQueries.isEmpty)
    }

    func testSelectionHelperSharedKeyStoreSaveUpdateSuccessDeletesLegacyKey()
        throws
    {
        let recorder = SelectionHelperKeychainOperationRecorder()
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemUpdate: recorder.itemUpdate,
            itemDelete: recorder.itemDelete
        )

        try store.save(Data(repeating: 0x52, count: 32))

        XCTAssertEqual(recorder.updateQueries.count, 1)
        let updateQuery = try XCTUnwrap(recorder.updateQueries.first)
        assertSelectionHelperKeychainQuery(
            updateQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertTrue(recorder.addQueries.isEmpty)
        XCTAssertEqual(recorder.deleteQueries.count, 1)
        let legacyQuery = try XCTUnwrap(recorder.deleteQueries.first)
        assertSelectionHelperKeychainQuery(
            legacyQuery,
            service: BlocksSelectionHelperProtocol.legacyKeychainService,
            account: BlocksSelectionHelperProtocol.legacyKeychainAccount
        )
    }

    func testSelectionHelperSharedKeyStoreSaveNotFoundAddsV4KeyThenDeletesLegacyKey()
        throws
    {
        let recorder = SelectionHelperKeychainOperationRecorder(
            updateStatus: errSecItemNotFound
        )
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemUpdate: recorder.itemUpdate,
            itemAdd: recorder.itemAdd,
            itemDelete: recorder.itemDelete
        )

        try store.save(Data(repeating: 0x53, count: 32))

        XCTAssertEqual(recorder.updateQueries.count, 1)
        let updateQuery = try XCTUnwrap(recorder.updateQueries.first)
        assertSelectionHelperKeychainQuery(
            updateQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertEqual(recorder.addQueries.count, 1)
        let addQuery = try XCTUnwrap(recorder.addQueries.first)
        assertSelectionHelperKeychainQuery(
            addQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertEqual(recorder.deleteQueries.count, 1)
        let legacyQuery = try XCTUnwrap(recorder.deleteQueries.first)
        assertSelectionHelperKeychainQuery(
            legacyQuery,
            service: BlocksSelectionHelperProtocol.legacyKeychainService,
            account: BlocksSelectionHelperProtocol.legacyKeychainAccount
        )
    }

    func testSelectionHelperSharedKeyStoreSaveNotFoundAddFailureKeepsLegacyKey()
        throws
    {
        let recorder = SelectionHelperKeychainOperationRecorder(
            updateStatus: errSecItemNotFound,
            addStatus: errSecAuthFailed
        )
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemUpdate: recorder.itemUpdate,
            itemAdd: recorder.itemAdd,
            itemDelete: recorder.itemDelete
        )

        do {
            try store.save(Data(repeating: 0x54, count: 32))
            XCTFail("A failed Keychain add must fail the save.")
        } catch {
            XCTAssertEqual(
                error as? SelectionAgentServiceFailure,
                .connectionFailed
            )
        }

        XCTAssertEqual(recorder.updateQueries.count, 1)
        let updateQuery = try XCTUnwrap(recorder.updateQueries.first)
        assertSelectionHelperKeychainQuery(
            updateQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertEqual(recorder.addQueries.count, 1)
        let addQuery = try XCTUnwrap(recorder.addQueries.first)
        assertSelectionHelperKeychainQuery(
            addQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertTrue(recorder.deleteQueries.isEmpty)
    }

    func testSelectionHelperSharedKeyStoreSaveUpdateFailureKeepsLegacyKey()
        throws
    {
        let recorder = SelectionHelperKeychainOperationRecorder(
            updateStatus: errSecAuthFailed
        )
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemUpdate: recorder.itemUpdate,
            itemAdd: recorder.itemAdd,
            itemDelete: recorder.itemDelete
        )

        do {
            try store.save(Data(repeating: 0x55, count: 32))
            XCTFail("A failed Keychain update must fail the save.")
        } catch {
            XCTAssertEqual(
                error as? SelectionAgentServiceFailure,
                .connectionFailed
            )
        }

        XCTAssertEqual(recorder.updateQueries.count, 1)
        let updateQuery = try XCTUnwrap(recorder.updateQueries.first)
        assertSelectionHelperKeychainQuery(
            updateQuery,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
        XCTAssertTrue(recorder.addQueries.isEmpty)
        XCTAssertTrue(recorder.deleteQueries.isEmpty)
    }

    func testSelectionHelperSharedKeyStoreDeleteTargetsV4Key() throws {
        let recorder = SelectionHelperKeychainOperationRecorder()
        let store = SelectionHelperSharedKeyStore(
            accessGroupProvider: { "test.access-group" },
            itemDelete: recorder.itemDelete
        )

        store.delete()

        XCTAssertEqual(recorder.deleteQueries.count, 1)
        let query = try XCTUnwrap(recorder.deleteQueries.first)
        assertSelectionHelperKeychainQuery(
            query,
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
    }

    func testSelectionHelperReplayGateRejectsInvalidEnvelopesWithoutExhaustingRegistry()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 0xA5, count: 32)
        let gate = SelectionHelperAuthenticatedReplayGate()
        for index in 0..<2_048 {
            let sealed = try SelectionHelperAuthenticatedCodec.seal(
                SelectionHelperCommand(kind: .health),
                requestID: "invalid-envelope-\(index)",
                expiresAt: now.addingTimeInterval(
                    index.isMultiple(of: 2)
                        ? 5
                        : BlocksSelectionHelperProtocol
                            .maximumAuthenticatedMessageLifetime + 1
                ),
                keyData: key,
                nonce: "invalid-envelope-nonce-\(index)"
            )
            let invalid = index.isMultiple(of: 2)
                ? SelectionHelperSealedMessage(
                    requestID: sealed.requestID,
                    expiresAt: sealed.expiresAt,
                    nonce: sealed.nonce,
                    combinedCiphertext: Data(
                        sealed.combinedCiphertext.dropLast()
                    )
                )
                : sealed
            XCTAssertThrowsError(
                try gate.authenticate(
                    SelectionHelperCommand.self,
                    from: invalid,
                    keyData: key,
                    now: now
                )
            )
        }

        let command = SelectionHelperCommand(kind: .health)
        let valid = try SelectionHelperAuthenticatedCodec.seal(
            command,
            requestID: "valid-after-invalid-ciphertext",
            expiresAt: now.addingTimeInterval(5),
            keyData: key,
            nonce: "valid-after-invalid-ciphertext-nonce"
        )
        XCTAssertEqual(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: valid,
                keyData: key,
                now: now
            ),
            command
        )
    }

    func testSelectionHelperReplayGateRejectsDistantFutureExpiryWithoutConsumingNonce()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 0x5A, count: 32)
        let gate = SelectionHelperAuthenticatedReplayGate()
        let command = SelectionHelperCommand(kind: .health)
        let nonce = "future-expiry-nonce"
        let distant = try SelectionHelperAuthenticatedCodec.seal(
            command,
            requestID: "distant-future",
            expiresAt: now.addingTimeInterval(
                BlocksSelectionHelperProtocol
                    .maximumAuthenticatedMessageLifetime + 1
            ),
            keyData: key,
            nonce: nonce
        )
        XCTAssertThrowsError(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: distant,
                keyData: key,
                now: now
            )
        )

        let valid = try SelectionHelperAuthenticatedCodec.seal(
            command,
            requestID: "valid-after-distant-future",
            expiresAt: now.addingTimeInterval(5),
            keyData: key,
            nonce: nonce
        )
        XCTAssertEqual(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: valid,
                keyData: key,
                now: now
            ),
            command
        )
    }

    func testSelectionHelperReplayGateRejectsSecondValidUseOfNonce()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 0x3C, count: 32)
        let gate = SelectionHelperAuthenticatedReplayGate()
        let command = SelectionHelperCommand(kind: .health)
        let sealed = try SelectionHelperAuthenticatedCodec.seal(
            command,
            requestID: "replayed-command",
            expiresAt: now.addingTimeInterval(5),
            keyData: key,
            nonce: "replayed-command-nonce"
        )
        XCTAssertEqual(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: sealed,
                keyData: key,
                now: now
            ),
            command
        )
        XCTAssertThrowsError(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: sealed,
                keyData: key,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? SelectionHelperAuthenticatedCodecError,
                .replayed
            )
        }
    }

    func testSelectionHelperLocatorPrefersStableInstallOverDerivedDataCopy()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-locator-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let derived = root
            .appendingPathComponent("DerivedData", isDirectory: true)
            .appendingPathComponent("Build/Products/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        let stable = root
            .appendingPathComponent("Applications/BlocksDev/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: derived)
        try makeSelectionHelperBundle(at: stable)
        let locator = selectionHelperFixtureLocator(
            candidates: [derived, stable]
        )

        XCTAssertEqual(
            locator.resolvedApplicationURL,
            stable.standardizedFileURL
        )
    }

    func testSelectionHelperLocatorIgnoresNonrunningUntrustedCandidate()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-nonrunning-candidate-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root
            .appendingPathComponent("Applications/BlocksDev/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        let untrusted = root
            .appendingPathComponent("DerivedData/Build/Products/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: stable)
        try makeSelectionHelperBundle(at: untrusted)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [stable, untrusted] },
            runningApplicationURLsProvider: { [stable] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [stable] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertFalse(locator.hasConflictingRunningApplication)
        XCTAssertTrue(locator.open(activates: false))
        XCTAssertEqual(launchCount, 0)
    }

    func testSelectionHelperLocatorRejectsUntrustedRunningCopy()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-untrusted-running-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root
            .appendingPathComponent("Applications/BlocksDev/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        let untrusted = root
            .appendingPathComponent("DerivedData/Build/Products/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: stable)
        try makeSelectionHelperBundle(at: untrusted)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [stable, untrusted] },
            runningApplicationURLsProvider: { [untrusted] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [stable] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertTrue(locator.hasConflictingRunningApplication)
        XCTAssertFalse(locator.open(activates: false))
        XCTAssertEqual(launchCount, 0)
    }

    func testSelectionHelperLocatorDoesNotReportConflictForNonrunningUntrustedCopy()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-untrusted-nonrunning-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let untrusted = root
            .appendingPathComponent("DerivedData/Build/Products/Debug", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: untrusted)
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [untrusted] },
            runningApplicationURLsProvider: { [] },
            allowedApplicationURLsProvider: { [] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertNil(locator.resolvedApplicationURL)
        XCTAssertFalse(locator.isInstalled)
        XCTAssertFalse(locator.hasConflictingRunningApplication)
    }

    func testSelectionHelperReplayGateRejectsOversizedIdentifiersWithoutConsumingRegistry()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 0x7E, count: 32)
        let gate = SelectionHelperAuthenticatedReplayGate()

        let oversizedRequestID = SelectionHelperSealedMessage(
            requestID: String(repeating: "r", count: 129),
            expiresAt: now.addingTimeInterval(5),
            nonce: "oversized-request-id-nonce",
            combinedCiphertext: Data()
        )
        XCTAssertThrowsError(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: oversizedRequestID,
                keyData: key,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? SelectionHelperAuthenticatedCodecError,
                .invalidEnvelope
            )
        }

        for index in 0..<2_048 {
            let oversized = SelectionHelperSealedMessage(
                requestID: "oversized-\(index)",
                expiresAt: now.addingTimeInterval(5),
                nonce: String(repeating: "n", count: 129) + "-\(index)",
                combinedCiphertext: Data()
            )
            XCTAssertThrowsError(
                try gate.authenticate(
                    SelectionHelperCommand.self,
                    from: oversized,
                    keyData: key,
                    now: now
                )
            ) { error in
                XCTAssertEqual(
                    error as? SelectionHelperAuthenticatedCodecError,
                    .invalidEnvelope
                )
            }
        }

        let valid = try SelectionHelperAuthenticatedCodec.seal(
            SelectionHelperCommand(kind: .health),
            requestID: "valid-after-oversized-identifiers",
            expiresAt: now.addingTimeInterval(5),
            keyData: key,
            nonce: "valid-after-oversized-identifiers-nonce"
        )
        XCTAssertEqual(
            try gate.authenticate(
                SelectionHelperCommand.self,
                from: valid,
                keyData: key,
                now: now
            ),
            SelectionHelperCommand(kind: .health)
        )
    }

    func testSelectionHelperLocatorReportsOtherRunningCopyWithoutLaunching()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-conflict-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root
            .appendingPathComponent("Applications/Current", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        let old = root
            .appendingPathComponent("Applications/Old", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: current)
        try makeSelectionHelperBundle(at: old)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [current] },
            runningApplicationURLsProvider: { [old] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [current] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertTrue(locator.hasConflictingRunningApplication)
        XCTAssertFalse(locator.open(activates: false))
        XCTAssertEqual(launchCount, 0)
    }

    func testSelectionHelperLocatorRequiresMatchingTeamAndSigningIdentifierBeforeLaunch()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-team-match-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [helper] },
            runningApplicationURLsProvider: { [] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [helper] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01",
                signingIdentifier:
                    BlocksSelectionHelperProtocol.bundleIdentifier
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertEqual(locator.resolvedApplicationURL, helper.standardizedFileURL)
        XCTAssertTrue(locator.open(activates: false))
        XCTAssertEqual(launchCount, 1)
    }

    func testSelectionHelperLocatorRejectsExpectedPlistBundleIDWithWrongSigningIdentifier()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-signing-identifier-mismatch-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [helper] },
            runningApplicationURLsProvider: { [] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [helper] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01",
                signingIdentifier: "app.blocks.forged-selection-helper"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertEqual(
            Bundle(url: helper)?.bundleIdentifier,
            BlocksSelectionHelperProtocol.bundleIdentifier
        )
        XCTAssertNil(locator.resolvedApplicationURL)
        XCTAssertFalse(locator.open(activates: false))
        XCTAssertEqual(launchCount, 0)
    }

    func testSelectionHelperLocatorRejectsDifferentTeamWithoutLaunching()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-team-mismatch-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        var launchCount = 0
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [helper] },
            runningApplicationURLsProvider: { [helper] },
            openApplication: { _, _ in launchCount += 1 },
            allowedApplicationURLsProvider: { [helper] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "OTHERTEAM2"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertNil(locator.resolvedApplicationURL)
        XCTAssertTrue(locator.hasConflictingRunningApplication)
        XCTAssertFalse(locator.open(activates: false))
        XCTAssertEqual(launchCount, 0)
    }

    func testSelectionHelperLocatorFailsClosedWhenSignatureCannotBeRead()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-signature-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        let locator = SelectionHelperApplicationLocator(
            candidateURLsProvider: { [helper] },
            runningApplicationURLsProvider: { [] },
            allowedApplicationURLsProvider: { [helper] },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: nil
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )

        XCTAssertNil(locator.resolvedApplicationURL)
        XCTAssertFalse(locator.hasConflictingRunningApplication)
    }

    func testSelectionHelperDisconnectFailureKeepsMainKeyAndReportsRetry()
        throws
    {
        let key = Data(repeating: 0xA5, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.connectionFailed)
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(
                candidates: []
            )
        )

        switch client.disconnect(timeout: 0.01) {
        case let .failure(failure):
            XCTAssertEqual(failure, .connectionFailed)
        case .success:
            XCTFail("Disconnect unexpectedly removed the main-App key")
        }
        XCTAssertEqual(keyStore.load(), key)
        XCTAssertEqual(keyStore.deleteCount, 0)
        XCTAssertEqual(connection.disconnectRequestCount, 1)
        XCTAssertTrue(connection.helperStillHasKey)
    }

    func testSelectionHelperDisconnectDeletesBothKeysOnlyAfterAuthenticatedTrue()
        throws
    {
        let key = Data(repeating: 0x5A, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .success(true)
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(
                candidates: []
            )
        )

        XCTAssertNoThrow(
            try client.disconnect(timeout: 0.01).get()
        )
        XCTAssertNil(keyStore.load())
        XCTAssertEqual(keyStore.deleteCount, 1)
        XCTAssertEqual(connection.disconnectRequestCount, 1)
        XCTAssertFalse(connection.helperStillHasKey)
    }

    func testSelectionHelperDisconnectFalseConfirmationKeepsMainKey()
        throws
    {
        let key = Data(repeating: 0x3C, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .success(false)
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(
                candidates: []
            )
        )

        switch client.disconnect(timeout: 0.01) {
        case let .failure(failure):
            XCTAssertEqual(failure, .disconnectNotConfirmed)
        case .success:
            XCTFail("Disconnect unexpectedly removed the main-App key")
        }
        XCTAssertEqual(keyStore.load(), key)
        XCTAssertEqual(keyStore.deleteCount, 0)
        XCTAssertTrue(connection.helperStillHasKey)
    }

    func testSelectionHelperSettingsDisconnectFailureKeepsPairedStateAndRetry()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-disconnect-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        let key = Data(repeating: 0xC3, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: SelectionHelperAuthenticatedConnectionStub(
                key: key,
                disconnectResult: .failure(.connectionFailed)
            ),
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [helper] },
                runningApplicationURLsProvider: { [] },
                allowedApplicationURLsProvider: { [helper] },
                identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                    teamID: "TESTTEAM01"
                ),
                trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
            )
        )
        let controller = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore:
                SelectionHelperDisconnectRecoveryStoreStub()
        )

        controller.disconnect()
        XCTAssertEqual(controller.state, .checking)
        await waitUntil { controller.lastError != nil }

        XCTAssertEqual(controller.state, .connectionFailed)
        XCTAssertEqual(
            controller.lastError,
            L10n.string(
                "translation.selectionHelper.error.disconnectFailed"
            )
        )
        XCTAssertTrue(client.isPaired)
    }

    func testSelectionHelperDisconnectRetriesPersistentAcknowledgementAfterLostReplies()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-disconnect-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        try makeSelectionHelperBundle(at: helper)
        let key = Data(repeating: 0xE1, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut),
            disconnectResults: [
                .failure(.timedOut),
                .failure(.timedOut),
                .success(true),
            ],
            helperRemovesKeyBeforeFailedDisconnectRequests: [1]
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [helper] },
                runningApplicationURLsProvider: { [] },
                allowedApplicationURLsProvider: { [helper] },
                identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                    teamID: "TESTTEAM01"
                ),
                trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
            )
        )
        let controller = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore:
                SelectionHelperDisconnectRecoveryStoreStub()
        )

        controller.disconnect()
        await waitUntil { connection.disconnectRequestCount == 1 }
        XCTAssertTrue(client.isPaired)
        XCTAssertFalse(connection.helperStillHasKey)
        XCTAssertTrue(connection.hasDisconnectTombstone)

        // The second attempt models a restarted Helper reading the same
        // persisted acknowledgement; its reply is lost as well.
        controller.refresh()
        await waitUntil { connection.disconnectRequestCount == 2 }
        XCTAssertTrue(client.isPaired)

        controller.refresh()
        await waitUntil { !client.isPaired }
        XCTAssertEqual(connection.disconnectRequestCount, 3)
        XCTAssertNil(keyStore.load())
        XCTAssertEqual(controller.state, .notPaired)
    }

    func testSelectionHelperDisconnectTombstoneRejectsHealthButAcceptsRetry()
        throws
    {
        let key = Data(repeating: 0x7E, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.connectionFailed),
            disconnectResults: [
                .failure(.connectionFailed),
                .success(true),
            ],
            helperRemovesKeyBeforeFailedDisconnectRequests: [1]
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(
                candidates: []
            )
        )

        switch client.disconnect(timeout: 0.01) {
        case let .failure(failure):
            XCTAssertEqual(failure, .connectionFailed)
        case .success:
            XCTFail("Disconnect unexpectedly removed the main-App key")
        }
        XCTAssertEqual(
            client.health(timeout: 0.01),
            .failure(.connectionFailed)
        )
        XCTAssertEqual(connection.rejectedTombstoneCommands, [.health])

        XCTAssertNoThrow(
            try client.disconnect(timeout: 0.01).get()
        )
        XCTAssertNil(keyStore.load())
    }

    func testSelectionHelperDisconnectRecoverySurvivesControllerRecreation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-disconnect-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        let otherHelper = root
            .appendingPathComponent("Previous", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: helper)
        try makeSelectionHelperBundle(at: otherHelper)
        let key = Data(repeating: 0x6D, count: 32)
        let keyStore = SelectionHelperKeyStoreStub(key: key)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut),
            disconnectResults: [
                .failure(.timedOut),
                .success(true),
            ],
            helperRemovesKeyBeforeFailedDisconnectRequests: [1]
        )
        let recoveryStore = SelectionHelperDisconnectRecoveryStoreStub()
        let client = SelectionHelperClient(
            keyStore: keyStore,
            connection: connection,
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [helper] },
                runningApplicationURLsProvider: { [otherHelper] },
                allowedApplicationURLsProvider: { [helper] },
                identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                    teamID: "TESTTEAM01"
                ),
                trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
            )
        )
        let firstController = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore: recoveryStore
        )

        XCTAssertTrue(client.hasInstallationConflict)
        firstController.disconnect()
        await waitUntil { connection.disconnectRequestCount == 1 }
        XCTAssertNotNil(recoveryStore.deadline)
        XCTAssertTrue(client.isPaired)

        // A new controller models a main-App restart. It restores the
        // deadline and sends the only authenticated command accepted by the
        // Helper's persisted tombstone.
        let restartedController = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore: recoveryStore
        )
        restartedController.refresh()
        await waitUntil { !client.isPaired }

        XCTAssertEqual(connection.disconnectRequestCount, 2)
        XCTAssertNil(recoveryStore.deadline)
        XCTAssertEqual(restartedController.state, .notPaired)
    }

    func testSelectionHelperExpiredDisconnectRecoveryRequiresRepair()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-disconnect-expired-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Blocks Selection Helper.app",
            isDirectory: true
        )
        let otherHelper = root
            .appendingPathComponent("Previous", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: helper)
        try makeSelectionHelperBundle(at: otherHelper)
        let recoveryStore = SelectionHelperDisconnectRecoveryStoreStub()
        recoveryStore.deadline = Date().addingTimeInterval(-1)
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(
                key: Data(repeating: 0xB4, count: 32)
            ),
            connection: SelectionHelperAuthenticatedConnectionStub(
                key: Data(repeating: 0xB4, count: 32),
                disconnectResult: .failure(.connectionFailed)
            ),
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [helper] },
                runningApplicationURLsProvider: { [otherHelper] },
                allowedApplicationURLsProvider: { [helper] },
                identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                    teamID: "TESTTEAM01"
                ),
                trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
            )
        )
        let controller = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore: recoveryStore
        )

        XCTAssertTrue(client.hasInstallationConflict)
        controller.refresh()

        XCTAssertEqual(controller.state, .notPaired)
        XCTAssertEqual(
            controller.lastError,
            L10n.string(
                "translation.selectionHelper.error.disconnectRepairRequired"
            )
        )
        XCTAssertNil(recoveryStore.deadline)
    }

    func testSelectionHelperPairRetriesExactPacketAfterTimedOutReply()
        throws
    {
        let bootstrapKey = Data(repeating: 0x10, count: 32)
        let keyStore = SelectionHelperKeyStoreStub()
        var pairRequestCount = 0
        var helperKeyCreationCount = 0
        var derivedKeys: [String: Data] = [:]
        var cachedPairReply: Data?
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x11, count: 32),
            disconnectResult: .failure(.timedOut),
            pairResponder: { request in
                pairRequestCount += 1
                if let cachedPairReply {
                    return .success(cachedPairReply)
                }
                helperKeyCreationCount += 1
                let helperKey = P256.KeyAgreement.PrivateKey()
                let helperPublicKey = helperKey.publicKey.rawRepresentation
                guard let helperProof =
                        SelectionHelperPairingAuthentication.helperProof(
                            bootstrapKey: bootstrapKey,
                            request: request,
                            helperPublicKey: helperPublicKey
                        ),
                      let derivedKey = try?
                        SelectionHelperAuthenticatedCodec.deriveSharedKey(
                            privateKey: helperKey,
                            peerPublicKeyData: request.clientPublicKey,
                            requestID: request.requestID
                        ) else {
                    return .failure(.invalidResponse)
                }
                derivedKeys[request.requestID] = derivedKey
                let response = SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: helperPublicKey,
                    helperProof: helperProof,
                    failureCode: nil
                )
                guard let payload = try? JSONEncoder().encode(response),
                      let data = try? JSONEncoder().encode(
                        SelectionHelperWirePacket(
                            kind: .pair,
                            payload: payload
                        )
                ) else {
                    return .failure(.invalidResponse)
                }
                cachedPairReply = data
                // Model the Helper committing K1 and losing only its first
                // reply. The retry must return this exact cached response;
                // it must not create or persist a second pairing key.
                return .failure(.timedOut)
            },
            pairingKeyProvider: { request in
                derivedKeys[request.requestID]
            },
            health: SelectionHelperHealth(
                helperVersion: "test",
                accessibilityTrusted: true
            )
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            bootstrapKeyStore: SelectionHelperBootstrapKeyStoreStub(
                key: bootstrapKey
            ),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(
                candidates: []
            )
        )

        XCTAssertEqual(
            client.pair(code: "123456", timeout: 0.01),
            Result<SelectionHelperHealth, SelectionAgentServiceFailure>.success(
                SelectionHelperHealth(
                    helperVersion: "test",
                    accessibilityTrusted: true
                )
            )
        )
        XCTAssertEqual(connection.pairRequestCount, 2)
        XCTAssertEqual(helperKeyCreationCount, 1)
        XCTAssertNotNil(cachedPairReply)
        XCTAssertEqual(connection.pairPackets.count, 2)
        XCTAssertEqual(
            connection.pairPackets[0].payload,
            connection.pairPackets[1].payload
        )
        let request = try XCTUnwrap(
            try? JSONDecoder().decode(
                SelectionHelperPairRequest.self,
                from: connection.pairPackets[0].payload
            )
        )
        XCTAssertEqual(keyStore.load(), derivedKeys[request.requestID])
    }

    func testSelectionHelperInvalidPairingCodeDoesNotRetry() throws {
        let failure = SelectionHelperPairResponse(
            requestID: "unused",
            helperPublicKey: nil,
            helperProof: nil,
            failureCode: "invalid_pairing_code"
        )
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x11, count: 32),
            disconnectResult: .failure(.timedOut),
            pairResponder: { request in
                let response = SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: failure.helperPublicKey,
                    helperProof: failure.helperProof,
                    failureCode: failure.failureCode
                )
                guard let payload = try? JSONEncoder().encode(response),
                      let data = try? JSONEncoder().encode(
                        SelectionHelperWirePacket(
                            kind: .pair,
                            payload: payload
                        )
                      ) else {
                    return .failure(.invalidResponse)
                }
                return .success(data)
            }
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(),
            bootstrapKeyStore: SelectionHelperBootstrapKeyStoreStub(
                key: Data(repeating: 0x10, count: 32)
            ),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        XCTAssertEqual(client.pair(code: "123456"), .failure(.invalidPairingCode))
        XCTAssertEqual(connection.pairRequestCount, 1)
    }

    func testSelectionHelperPairWithoutBootstrapFailsBeforeWireOrActiveKey()
        throws
    {
        let keyStore = SelectionHelperKeyStoreStub()
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x11, count: 32),
            disconnectResult: .failure(.timedOut)
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            bootstrapKeyStore: SelectionHelperBootstrapKeyStoreStub(),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        XCTAssertEqual(
            client.pair(code: "123456"),
            .failure(.bootstrapUnavailable)
        )
        XCTAssertNil(keyStore.load())
        XCTAssertEqual(connection.pairRequestCount, 0)
    }

    func testSelectionHelperSettingsBootstrapUnavailableUsesConnectionFailure()
        async throws
    {
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(),
            bootstrapKeyStore: SelectionHelperBootstrapKeyStoreStub(),
            connection: SelectionHelperAuthenticatedConnectionStub(
                key: Data(repeating: 0x11, count: 32),
                disconnectResult: .failure(.timedOut)
            ),
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )
        let controller = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore:
                SelectionHelperDisconnectRecoveryStoreStub()
        )
        controller.pairingCode = "123456"

        controller.pair()
        await waitUntil { controller.lastError != nil }

        XCTAssertEqual(controller.state, .connectionFailed)
        XCTAssertEqual(
            controller.lastError,
            L10n.string(
                "translation.selectionHelper.error.connectionFailed"
            )
        )
    }

    func testSelectionHelperInvalidHelperProofDoesNotRetryOrSaveActiveKey()
        throws
    {
        let bootstrapKey = Data(repeating: 0x12, count: 32)
        let keyStore = SelectionHelperKeyStoreStub()
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x34, count: 32),
            disconnectResult: .failure(.timedOut),
            pairResponder: { request in
                let helperKey = P256.KeyAgreement.PrivateKey()
                let helperPublicKey = helperKey.publicKey.rawRepresentation
                guard var helperProof =
                        SelectionHelperPairingAuthentication.helperProof(
                            bootstrapKey: bootstrapKey,
                            request: request,
                            helperPublicKey: helperPublicKey
                        ) else {
                    return .failure(.invalidResponse)
                }
                helperProof[helperProof.startIndex] ^= 0x01
                let response = SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: helperPublicKey,
                    helperProof: helperProof,
                    failureCode: nil
                )
                guard let payload = try? JSONEncoder().encode(response),
                      let data = try? JSONEncoder().encode(
                        SelectionHelperWirePacket(
                            kind: .pair,
                            payload: payload
                        )
                      ) else {
                    return .failure(.invalidResponse)
                }
                return .success(data)
            }
        )
        let client = SelectionHelperClient(
            keyStore: keyStore,
            bootstrapKeyStore: SelectionHelperBootstrapKeyStoreStub(
                key: bootstrapKey
            ),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        XCTAssertEqual(
            client.pair(code: "123456"),
            .failure(.invalidResponse)
        )
        XCTAssertEqual(connection.pairRequestCount, 1)
        XCTAssertNil(keyStore.load())
    }

    func testSelectionHelperLegacyKeyDoesNotMakeV4ClientPairedOrAuthenticated()
        throws
    {
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x21, count: 32),
            disconnectResult: .failure(.timedOut)
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(
                legacyKey: Data(repeating: 0x20, count: 32)
            ),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        XCTAssertFalse(client.isPaired)
        XCTAssertEqual(client.permissionStatus(), .failure(.notPaired))
        XCTAssertEqual(connection.authenticatedRequestCount, 0)
    }

    func testSelectionHelperHealthDecodesLegacyPayloadWithoutCapabilities()
        throws
    {
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": BlocksSelectionHelperProtocol.version,
            "helperVersion": "legacy",
            "accessibilityTrusted": true,
        ])

        let health = try JSONDecoder().decode(
            SelectionHelperHealth.self,
            from: legacyPayload
        )

        XCTAssertEqual(health.capabilities, [])
    }

    func testPasteTargetInspectionSkipsWireWhenNoLocalPairingKey() async {
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: Data(repeating: 0x31, count: 32),
            disconnectResult: .failure(.timedOut)
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        let result = await client.inspectPasteTargetIfAvailable(
            request: pasteTargetRequest()
        )

        XCTAssertNil(result)
        XCTAssertEqual(connection.authenticatedRequestCount, 0)
    }

    func testPasteTargetInspectionDoesNotSendCommandWhenCapabilityIsMissing()
        async
    {
        let key = Data(repeating: 0x32, count: 32)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut),
            health: SelectionHelperHealth(
                helperVersion: "legacy-v4",
                accessibilityTrusted: true
            )
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(key: key),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        let result = await client.inspectPasteTargetIfAvailable(
            request: pasteTargetRequest()
        )

        XCTAssertNil(result)
        XCTAssertEqual(
            connection.authenticatedCommands.map(\.kind),
            [.health]
        )
    }

    func testPasteTargetInspectionReturnsAuthenticatedMatchingResponse()
        async
    {
        let key = Data(repeating: 0x33, count: 32)
        let request = pasteTargetRequest()
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut),
            health: SelectionHelperHealth(
                helperVersion: "current",
                accessibilityTrusted: true,
                capabilities: [
                    BlocksSelectionHelperProtocol
                        .pasteTargetInspectionCapability,
                ]
            ),
            authenticatedResponder: { command in
                guard command.kind == .inspectPasteTarget,
                      let request = command.pasteTargetRequest else {
                    return .failure(.invalidResponse)
                }
                return .success(
                    SelectionHelperCommandResponse(
                        pasteTargetInspection:
                            SelectionHelperPasteTargetInspection(
                                requestID: request.requestID,
                                targetPID: request.targetPID,
                                targetBundleIdentifier:
                                    request.targetBundleIdentifier,
                                editability: .editable
                            )
                    )
                )
            }
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(key: key),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        let result = await client.inspectPasteTargetIfAvailable(
            request: request
        )

        XCTAssertEqual(
            result,
            SelectionHelperPasteTargetInspection(
                requestID: request.requestID,
                targetPID: request.targetPID,
                targetBundleIdentifier: request.targetBundleIdentifier,
                editability: .editable
            )
        )
        XCTAssertEqual(
            connection.authenticatedCommands.map(\.kind),
            [.health, .inspectPasteTarget]
        )
    }

    func testPasteTargetInspectionDeadlineAndBusyGateStayBounded() async {
        let key = Data(repeating: 0x34, count: 32)
        let request = pasteTargetRequest()
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut),
            health: SelectionHelperHealth(
                helperVersion: "current",
                accessibilityTrusted: true,
                capabilities: [
                    BlocksSelectionHelperProtocol
                        .pasteTargetInspectionCapability,
                ]
            ),
            authenticatedResponder: { _ in
                .failure(.invalidResponse)
            },
            delayForCommand: { command in
                command.kind == .inspectPasteTarget ? 0.3 : 0
            },
            ignoresTimeoutForCommand: { command in
                command.kind == .inspectPasteTarget
            }
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(key: key),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        async let first = client.inspectPasteTargetIfAvailable(
            request: request,
            timeout: 0.15
        )
        try? await Task.sleep(for: .milliseconds(20))
        let busy = await client.inspectPasteTargetIfAvailable(
            request: pasteTargetRequest(),
            timeout: 0.15
        )
        let timedOut = await first

        XCTAssertNil(busy)
        XCTAssertNil(timedOut)
        XCTAssertLessThan(
            CFAbsoluteTimeGetCurrent() - startedAt,
            0.25
        )
        XCTAssertEqual(
            connection.authenticatedCommands.map(\.kind),
            [.health, .inspectPasteTarget]
        )
    }

    func testPasteTargetInspectionTimeoutDoesNotWaitForSlowKeychainOrQueue()
        async
    {
        let key = Data(repeating: 0x35, count: 32)
        let connection = SelectionHelperAuthenticatedConnectionStub(
            key: key,
            disconnectResult: .failure(.timedOut)
        )
        let client = SelectionHelperClient(
            keyStore: SelectionHelperKeyStoreStub(
                key: key,
                loadDelay: 0.3
            ),
            connection: connection,
            applicationLocator: selectionHelperFixtureLocator(candidates: [])
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        async let first = client.inspectPasteTargetIfAvailable(
            request: pasteTargetRequest(),
            timeout: .infinity
        )
        try? await Task.sleep(for: .milliseconds(20))
        let busy = await client.inspectPasteTargetIfAvailable(
            request: pasteTargetRequest()
        )
        let timedOut = await first

        XCTAssertNil(busy)
        XCTAssertNil(timedOut)
        XCTAssertLessThan(
            CFAbsoluteTimeGetCurrent() - startedAt,
            0.25
        )
        XCTAssertEqual(connection.authenticatedRequestCount, 0)
    }

    private func pasteTargetRequest() -> SelectionHelperPasteTargetRequest {
        SelectionHelperPasteTargetRequest(
            requestID: UUID().uuidString,
            targetPID: 42,
            targetBundleIdentifier: "com.example.Target"
        )
    }

    @MainActor
    func testSelectionHelperConflictUsesDedicatedCaptureAndSettingsStates()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "selection-helper-client-conflict-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root
            .appendingPathComponent("Applications/Current", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        let old = root
            .appendingPathComponent("Applications/Old", isDirectory: true)
            .appendingPathComponent(
                "Blocks Selection Helper.app",
                isDirectory: true
            )
        try makeSelectionHelperBundle(at: current)
        try makeSelectionHelperBundle(at: old)
        let client = SelectionHelperClient(
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [current] },
                runningApplicationURLsProvider: { [old] },
                allowedApplicationURLsProvider: { [current] },
                identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                    teamID: "TESTTEAM01"
                ),
                trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
            )
        )

        XCTAssertEqual(
            client.capture(
                target: target(),
                requestID: UUID().uuidString
            ),
            .failure(.agentInstallationConflict)
        )

        let controller = SelectionHelperSettingsController(
            client: client,
            disconnectRecoveryStore:
                SelectionHelperDisconnectRecoveryStoreStub()
        )
        controller.refresh()
        XCTAssertEqual(controller.state, .installationConflict)
        XCTAssertEqual(
            controller.lastError,
            L10n.string(
                "translation.selectionHelper.error.installationConflict"
            )
        )
    }

    func testSelectionAgentCancellationRegistryRejectsReuseUntilFinishedTTLExpires() {
        var now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 1,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.begin("request"))
        XCTAssertTrue(registry.cancel("request"))
        XCTAssertTrue(registry.isCancelled("request"))
        registry.finish("request")

        XCTAssertFalse(registry.isCancelled("request"))
        XCTAssertFalse(registry.cancel("request"))
        XCTAssertFalse(registry.begin("request"))
        now = 11
        XCTAssertTrue(registry.begin("request"))
        XCTAssertFalse(registry.begin("request"))
        registry.finish("request")
    }

    func testSelectionAgentCancellationRegistryConsumesPreCancelAtBegin() {
        let now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 1,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.cancel("request"))
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 1)
        XCTAssertTrue(registry.begin("request"))
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 0)
        XCTAssertTrue(registry.isCancelled("request"))
    }

    func testSelectionAgentCancellationRegistryRejectsLateCancelAfterFinish() {
        let now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 1,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.begin("request"))
        registry.finish("request")
        XCTAssertFalse(registry.cancel("request"))
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 0)
    }

    func testSelectionAgentCancellationRegistryRejectsFinishedIDUntilTTLExpires() {
        var now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 1,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.begin("request"))
        registry.finish("request")
        XCTAssertFalse(registry.begin("request"))
        XCTAssertFalse(registry.cancel("request"))
        now = 11
        XCTAssertTrue(registry.begin("request"))
    }

    func testSelectionAgentCancellationRegistryAllowsExpiredPreCancel() {
        var now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 1,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.cancel("request"))
        now = 11
        XCTAssertTrue(registry.begin("request"))
        XCTAssertFalse(registry.isCancelled("request"))
    }

    func testSelectionAgentCancellationRegistryEvictsOldestPreCancelAtCapacity() {
        var now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 10,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.cancel("oldest"))
        now = 11
        XCTAssertTrue(registry.cancel("middle"))
        now = 12
        XCTAssertTrue(registry.cancel("newest"))
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 2)

        XCTAssertTrue(registry.begin("oldest"))
        XCTAssertFalse(registry.isCancelled("oldest"))
        XCTAssertTrue(registry.begin("middle"))
        XCTAssertTrue(registry.isCancelled("middle"))
        XCTAssertTrue(registry.begin("newest"))
        XCTAssertTrue(registry.isCancelled("newest"))
    }

    func testSelectionAgentCancellationRegistryEvictsOldestFinishedTombstone() {
        var now: TimeInterval = 10
        let registry = SelectionAgentCancellationRegistry(
            now: { now },
            preCancelTTL: 10,
            tombstoneCapacity: 2
        )

        XCTAssertTrue(registry.begin("oldest"))
        registry.finish("oldest")
        now = 11
        XCTAssertTrue(registry.begin("middle"))
        registry.finish("middle")
        now = 12
        XCTAssertTrue(registry.begin("newest"))
        registry.finish("newest")

        XCTAssertTrue(registry.cancel("oldest"))
        XCTAssertFalse(registry.cancel("middle"))
        XCTAssertFalse(registry.cancel("newest"))
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 1)
    }

    func testSelectionAgentCancellationRegistryRejectsEmptyAndOversizedUTF8IDs() {
        let registry = SelectionAgentCancellationRegistry()
        let validID = String(repeating: "é", count: 63)
        let oversizedID = String(repeating: "é", count: 64) + "a"

        XCTAssertEqual(validID.utf8.count, 126)
        XCTAssertTrue(registry.begin(validID))
        XCTAssertTrue(registry.cancel(validID))
        registry.finish(validID)

        XCTAssertFalse(registry.begin(""))
        XCTAssertFalse(registry.cancel(""))
        registry.finish("")
        XCTAssertFalse(registry.begin(oversizedID))
        XCTAssertFalse(registry.cancel(oversizedID))
        registry.finish(oversizedID)
        XCTAssertEqual(oversizedID.utf8.count, 129)
        XCTAssertEqual(registry.pendingPreCancelCountForTesting, 0)
    }

    func testSelectionAgentPayloadValidatorRejectsUntrustedOversizedMetadata()
    {
        let valid = SelectionAgentSelection(
            text: "selected",
            range: SelectionAgentRange(location: 3, length: 8),
            accessibilityScreenBounds: SelectionAgentRect(
                x: 10,
                y: 20,
                width: 120,
                height: 24
            ),
            role: "AXTextArea",
            subrole: nil,
            identifier: "editor",
            domIdentifier: nil,
            chromeNodeIdentifier: nil
        )
        XCTAssertTrue(SelectionAgentPayloadValidator.isValid(valid))

        let oversizedRole = SelectionAgentSelection(
            text: valid.text,
            range: valid.range,
            accessibilityScreenBounds:
                valid.accessibilityScreenBounds,
            role: String(
                repeating: "a",
                count:
                    BlocksSelectionCaptureProtocol.maximumRoleBytes + 1
            ),
            subrole: nil,
            identifier: nil,
            domIdentifier: nil,
            chromeNodeIdentifier: nil
        )
        XCTAssertFalse(
            SelectionAgentPayloadValidator.isValid(oversizedRole)
        )
        XCTAssertFalse(
            SelectionAgentPayloadValidator.isValid(
                SelectionAgentRange(
                    location: Int.max,
                    length: 1
                )
            )
        )
        XCTAssertFalse(
            SelectionAgentPayloadValidator.isValid(
                SelectionAgentRect(
                    x: .infinity,
                    y: 0,
                    width: 1,
                    height: 1
                )
            )
        )
        XCTAssertFalse(
            SelectionAgentPayloadValidator.isValid(
                SelectionAgentCaptureRequest(
                    requestID: UUID().uuidString,
                    targetProcessIdentifier: 42,
                    targetBundleIdentifier:
                        "com.example.target",
                    mouseScreenPoint: SelectionAgentPoint(
                        x: .infinity,
                        y: 10
                    ),
                    deadline: Date().addingTimeInterval(1),
                    maximumCharacters: 1_000
                )
            )
        )
    }

    func testSelectionAgentFreezeStartsOneCaptureAndCachesTriggerSelection()
        throws
    {
        let transport = ControlledSelectionAgentCaptureTransport(
            selectedText: "selection A"
        )
        let client = SelectionHelperAXSelectionSystemClient(
            client: transport
        )

        let frozenTarget = AXSelectionTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.target",
            applicationName: "Target",
            accessibilityMouseLocation: CGPoint(x: 320, y: 240),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let token = try XCTUnwrap(
            client.freezeSelection(
                from: frozenTarget,
                requestID: "freeze-preserves-target"
            )
        )
        XCTAssertTrue(transport.waitForCaptureStart())
        XCTAssertEqual(transport.lastTarget, frozenTarget)

        transport.selectedText = "selection B"
        transport.releaseCapture()

        guard case let .element(snapshot) = token.read() else {
            return XCTFail("Expected the frozen selection result")
        }
        XCTAssertEqual(snapshot.selectedText, "selection A")
        XCTAssertEqual(transport.captureCount, 1)
        XCTAssertEqual(token.read(), .element(snapshot))
        XCTAssertEqual(transport.captureCount, 1)
    }

    func testSelectionAgentCancelReturnsWithoutWaitingForSlowXPC()
        async throws
    {
        let transport = ControlledSelectionAgentCaptureTransport(
            selectedText: "selection",
            cancellationDelay: 0.3
        )
        let client = SelectionHelperAXSelectionSystemClient(
            client: transport
        )
        let token = try XCTUnwrap(
            client.freezeSelection(
                from: target(),
                requestID: "freeze-cancel"
            )
        )
        XCTAssertTrue(transport.waitForCaptureStart())

        let startedAt = ContinuousClock.now
        token.cancel()
        let elapsed = startedAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(50))
        XCTAssertEqual(token.read(), .failure(.cancelled))
        let didObserveCancellation = await Task.detached(
            priority: .utility
        ) {
            transport.waitForCancellation()
        }.value
        XCTAssertTrue(didObserveCancellation)
        XCTAssertEqual(token.read(), .failure(.cancelled))
    }

    func testSelectionAgentOperationTimesOutAndRejectsLateCaptureResult()
        async throws
    {
        let transport = ControlledSelectionAgentCaptureTransport(
            selectedText: "late selection"
        )
        let client = SelectionHelperAXSelectionSystemClient(
            client: transport,
            captureTimeout: 0.05
        )
        let token = try XCTUnwrap(
            client.freezeSelection(
                from: target(),
                requestID: "freeze-timeout"
            )
        )
        XCTAssertTrue(transport.waitForCaptureStart())

        let startedAt = ContinuousClock.now
        XCTAssertEqual(token.read(), .failure(.timedOut))
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .milliseconds(250)
        )
        let didObserveCancellation = await Task.detached(
            priority: .utility
        ) {
            transport.waitForCancellation()
        }.value
        XCTAssertTrue(didObserveCancellation)
        XCTAssertEqual(token.read(), .failure(.timedOut))
    }

    func testSelectionHelperSignedBundleLoopbackHandshake() throws {
        guard ProcessInfo.processInfo.environment[
            "BLOCKS_RUN_SELECTION_HELPER_INTEGRATION"
        ] == "1" else {
            throw XCTSkip(
                "Requires a separately installed and paired signed Helper."
            )
        }
        switch SelectionHelperClient()
            .permissionStatus(timeout: 2) {
        case .success:
            // Permission may legitimately be absent on a clean test machine;
            // receiving the Boolean proves the authenticated loopback round-trip.
            break
        case let .failure(failure):
            XCTFail("Selection Helper handshake failed: \(failure)")
        }
    }

    func testAXSelectionReaderRejectsSecureTextField() {
        let client = AXSelectionSystemClientStub(
            elementResult: .element(AXSelectionElementSnapshot(
                role: "AXTextField",
                subrole: kAXSecureTextFieldSubrole as String,
                selectedText: "must-not-be-read",
                selectedRange: NSRange(location: 0, length: 16),
                accessibilityScreenBounds: CGRect(x: 1, y: 2, width: 3, height: 4)
            ))
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks"
        )

        XCTAssertEqual(
            reader.readSelection(from: target()),
            .unavailable(AXSelectionReadFailure(reason: .passwordField, target: target()))
        )
    }

    func testAXSelectionReaderPreservesTextAndConvertsAnchor() throws {
        let element = AXSelectionElementSnapshot(
            role: "AXStaticText",
            subrole: nil,
            selectedText: "  Blocks 翻译  ",
            selectedRange: NSRange(location: 4, length: 9),
            accessibilityScreenBounds: CGRect(x: 10, y: 20, width: 100, height: 22)
        )
        let reader = AXSelectionReader(
            systemClient: AXSelectionSystemClientStub(elementResult: .element(element)),
            ownBundleIdentifier: "app.blocks",
            screenBoundsConverter: { $0.offsetBy(dx: 5, dy: 7) },
            now: { Date(timeIntervalSince1970: 42) }
        )

        guard case let .selected(selection) = reader.readSelection(from: target()) else {
            return XCTFail("Expected selected text")
        }
        XCTAssertEqual(selection.selectedText, "  Blocks 翻译  ")
        XCTAssertEqual(selection.selectedRange, NSRange(location: 4, length: 9))
        XCTAssertEqual(
            selection.screenBounds,
            CGRect(x: 15, y: 27, width: 100, height: 22)
        )
        XCTAssertEqual(selection.capturedAt, Date(timeIntervalSince1970: 42))
    }

    func testAXSelectionReadRequestFreezesFocusedElementBeforeDeferredAttributeRead() {
        let client = AXSelectionSystemClientStub(
            elementResult: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "shortcut selection",
                selectedRange: NSRange(location: 0, length: 18),
                accessibilityScreenBounds: nil
            ))
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks"
        )
        guard case let .ready(request) = reader.freezeSelectionRequest(
            from: target()
        ) else {
            return XCTFail("Expected a frozen AX selection request")
        }
        XCTAssertEqual(client.freezeCount, 1)
        XCTAssertEqual(client.readCount, 0)

        client.elementResult = .element(AXSelectionElementSnapshot(
            role: "AXTextArea",
            subrole: nil,
            selectedText: "later focus",
            selectedRange: NSRange(location: 0, length: 11),
            accessibilityScreenBounds: nil
        ))

        guard case let .selected(selection) = reader.readSelection(
            from: request
        ) else {
            return XCTFail("Expected the deferred selection")
        }
        XCTAssertEqual(selection.target, target())
        XCTAssertEqual(selection.selectedText, "shortcut selection")
        XCTAssertEqual(client.readCount, 1)
    }

    func testAXSelectionReaderTreatsWhitespaceSelectionAsEmpty() {
        let reader = AXSelectionReader(
            systemClient: AXSelectionSystemClientStub(
                elementResult: .element(AXSelectionElementSnapshot(
                    role: "AXTextArea",
                    subrole: nil,
                    selectedText: " \n ",
                    selectedRange: NSRange(location: 0, length: 3),
                    accessibilityScreenBounds: nil
                ))
            ),
            ownBundleIdentifier: "app.blocks"
        )

        XCTAssertEqual(
            reader.readSelection(from: target()),
            .unavailable(AXSelectionReadFailure(reason: .emptySelection, target: target()))
        )
    }

    func testAXSelectionReaderNeverReadsBlocksOwnWindow() {
        let client = AXSelectionSystemClientStub(
            elementResult: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "text",
                selectedRange: nil,
                accessibilityScreenBounds: nil
            ))
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks"
        )
        let blocksTarget = AXSelectionTarget(
            processIdentifier: 7,
            bundleIdentifier: "app.blocks",
            applicationName: "Blocks",
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            reader.readSelection(from: blocksTarget),
            .unavailable(AXSelectionReadFailure(
                reason: .blocksIsFrontmost,
                target: blocksTarget
            ))
        )
        XCTAssertEqual(client.readCount, 0)
    }

    func testScreenshotTranslationRequestsRegionWithoutEditingContext() async throws {
        let capture = try makeScreenshotCapture(
            sourceRect: CGRect(x: 20, y: 30, width: 300, height: 120)
        )
        let service = TranslationScreenshotCaptureServiceStub(capture: capture)
        let screen = TranslationScreenshotScreen(
            displayID: 88,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_000, height: 776),
            backingScaleFactor: 2
        )
        let provider = TranslationScreenshotCaptureProvider(
            captureService: service,
            screensProvider: { [screen] }
        )

        let result = try await provider.captureRegion()

        XCTAssertEqual(service.receivedIntent, try ScreenshotCaptureIntent(kind: .region))
        XCTAssertEqual(service.receivedRequiresEditingContext, false)
        XCTAssertEqual(service.receivedPurpose, .translationOCR)
        XCTAssertEqual(result.logicalRect, capture.sourceRect)
        XCTAssertEqual(result.pixelSize, capture.pixelSize)
        XCTAssertEqual(result.screen, screen)
    }

    func testScreenshotTranslationCancellationDelegatesToCaptureService() {
        let service = TranslationScreenshotCaptureServiceStub(
            capture: try! makeScreenshotCapture(sourceRect: CGRect(x: 0, y: 0, width: 20, height: 20))
        )
        let provider = TranslationScreenshotCaptureProvider(captureService: service)

        provider.cancelCurrentCapture()

        XCTAssertEqual(service.cancelCount, 1)
    }

    func testScreenshotTranslationTreatsCaptureArbitrationAsCancellation()
        async
    {
        let provider = TranslationScreenshotCaptureProvider(
            captureService:
                TranslationScreenshotCaptureFailureServiceStub(
                    error:
                        ScreenshotCaptureArbitrationError.busy(
                            activeOwner: .standard
                        )
                )
        )

        do {
            _ = try await provider.captureRegion()
            XCTFail("A blocked translation capture must cancel silently")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }
    }

    func testStandardCapturePreemptsTranslationBeforeSelectionAppears()
        async throws
    {
        let capture = try makeScreenshotCapture(
            sourceRect: CGRect(x: 0, y: 0, width: 120, height: 80)
        )
        let service = StagedPurposeCaptureService(capture: capture)
        let arbiter = ScreenshotCaptureArbiter(captureService: service)
        let translationService = arbiter.makeTranslationCaptureService()

        let translationTask = Task { @MainActor in
            try await translationService.capture(
                intent: ScreenshotCaptureIntent(kind: .region),
                requiresEditingContext: false,
                purpose: .translationOCR
            )
        }
        await waitUntil {
            service.translationLoadIsPending
        }

        let standardCapture = try await arbiter.capture(
            intent: ScreenshotCaptureIntent(kind: .smart),
            requiresEditingContext: true
        )

        XCTAssertEqual(standardCapture.id, capture.id)
        XCTAssertEqual(service.cancelCount, 1)
        XCTAssertEqual(
            service.receivedPurposes,
            [.translationOCR, .standard]
        )
        XCTAssertFalse(
            service.enteredSelectionPurposes.contains(.translationOCR)
        )
        XCTAssertEqual(service.maximumConcurrentCaptures, 1)
        do {
            _ = try await translationTask.value
            XCTFail("Preempted translation capture must be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected translation error: \(error)")
        }
        XCTAssertNil(arbiter.activeOwnerForTesting)
    }

    func testTranslationCaptureCannotInterruptStandardCapture()
        async throws
    {
        let capture = try makeScreenshotCapture(
            sourceRect: CGRect(x: 0, y: 0, width: 120, height: 80)
        )
        let service = StagedPurposeCaptureService(
            capture: capture,
            suspendsPurpose: .standard
        )
        let arbiter = ScreenshotCaptureArbiter(captureService: service)
        let standardTask = Task { @MainActor in
            try await arbiter.capture(
                intent: ScreenshotCaptureIntent(kind: .smart),
                requiresEditingContext: true
            )
        }
        await waitUntil {
            service.standardLoadIsPending
        }

        do {
            _ = try await arbiter.makeTranslationCaptureService().capture(
                intent: ScreenshotCaptureIntent(kind: .region),
                requiresEditingContext: false,
                purpose: .translationOCR
            )
            XCTFail("Translation must not overlap a standard capture")
        } catch let error as ScreenshotCaptureArbitrationError {
            XCTAssertEqual(error, .busy(activeOwner: .standard))
        } catch {
            XCTFail("Unexpected arbitration error: \(error)")
        }

        XCTAssertEqual(service.receivedPurposes, [.standard])
        XCTAssertEqual(service.cancelCount, 0)
        service.resumeSuspendedCapture()
        _ = try await standardTask.value
        XCTAssertNil(arbiter.activeOwnerForTesting)
    }

    func testRepeatedTranslationReplacementRemainsSerialized()
        async throws
    {
        let capture = try makeScreenshotCapture(
            sourceRect: CGRect(x: 0, y: 0, width: 120, height: 80)
        )
        let service = StagedPurposeCaptureService(capture: capture)
        let arbiter = ScreenshotCaptureArbiter(captureService: service)
        let translationService = arbiter.makeTranslationCaptureService()

        func startCapture() -> Task<ScreenshotCapture, Error> {
            Task { @MainActor in
                try await translationService.capture(
                    intent: ScreenshotCaptureIntent(kind: .region),
                    requiresEditingContext: false,
                    purpose: .translationOCR
                )
            }
        }

        let first = startCapture()
        await waitUntil {
            service.receivedPurposes.count == 1
                && service.translationLoadIsPending
        }
        let second = startCapture()
        await waitUntil {
            service.receivedPurposes.count == 2
                && service.translationLoadIsPending
        }
        let third = startCapture()
        await waitUntil {
            service.receivedPurposes.count == 3
                && service.translationLoadIsPending
        }

        XCTAssertEqual(service.maximumConcurrentCaptures, 1)
        XCTAssertEqual(service.cancelCount, 2)
        service.resumeSuspendedCapture()
        _ = try await third.value

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Replaced capture must be cancelled")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected replacement error: \(error)")
            }
        }
        XCTAssertNil(arbiter.activeOwnerForTesting)
    }

    func testScreenshotEntryClosesUnpinnedPanelBeforeCaptureAndDoesNotRestoreIt()
        async
    {
        let captureProvider =
            ControlledTranslationScreenshotCaptureProvider()
        let suiteName =
            "TranslationScreenshotEntry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider
        )
        defer {
            coordinator.closeFloatingPanel()
            defaults.removePersistentDomain(forName: suiteName)
        }

        coordinator.showManualPanel()
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
        }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }

        XCTAssertTrue(
            coordinator.presentedModelsForTesting.isEmpty,
            "The old unpinned panel must not cover screenshot selection."
        )

        captureProvider.fail(with: CancellationError())
        await waitUntil { !captureProvider.hasPendingCapture }
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
    }

    func testNewManualEntryCancelsScreenshotAndSuppressesItsLateFailure()
        async
    {
        let captureProvider =
            ControlledTranslationScreenshotCaptureProvider()
        let suiteName =
            "TranslationEntryLatestWins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var statuses: [AppStatus] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider
        )
        coordinator.configure(
            statusRecorder: { statuses.append($0) },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(
                    recordID: recordID,
                    purpose: purpose,
                    text: "fixture"
                )
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        coordinator.showManualPanel()
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
        }

        XCTAssertEqual(captureProvider.cancelCount, 1)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.inputSource,
            .manual
        )

        captureProvider.fail(
            with: TranslationEntryTestError.fixtureFailure
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.inputSource,
            .manual
        )
    }

    func testClosingUnpinnedTranslationPanelsCancelsPendingScreenshotEntry()
        async
    {
        let captureProvider =
            ControlledTranslationScreenshotCaptureProvider()
        let suiteName =
            "TranslationScreenshotStandardEntry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var statuses: [AppStatus] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider
        )
        coordinator.configure(
            statusRecorder: { statuses.append($0) },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(
                    recordID: recordID,
                    purpose: purpose,
                    text: "fixture"
                )
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }

        coordinator.closeUnpinnedPanels()

        XCTAssertEqual(captureProvider.cancelCount, 1)
        captureProvider.fail(
            with: TranslationEntryTestError.fixtureFailure
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
    }

    func testScreenshotEntryInvalidatesPendingSelectionRead()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let captureProvider =
            ControlledTranslationScreenshotCaptureProvider()
        let suiteName =
            "TranslationSelectionToScreenshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader,
            screenshotCaptureProvider: captureProvider
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            client.invocationCount == 1
                && coordinator.activeSelectionCaptureCountForTesting == 1
        }
        XCTAssertFalse(client.readObservedMainThread)

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            0
        )
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)

        client.finish(
            invocation: 0,
            result: .element(
                AXSelectionElementSnapshot(
                    role: "AXTextArea",
                    subrole: nil,
                    selectedText: "stale selection",
                    selectedRange: NSRange(location: 0, length: 15),
                    accessibilityScreenBounds: nil
                )
            )
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            0
        )

        captureProvider.fail(with: CancellationError())
    }

    func testScreenshotEntryInvalidatesPendingClipboardRead()
        async
    {
        let captureProvider =
            ControlledTranslationScreenshotCaptureProvider()
        let reader = ControlledClipboardTranslationReader()
        let suiteName =
            "TranslationClipboardToScreenshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                await reader.read(
                    recordID: recordID,
                    purpose: purpose
                )
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showClipboardRecord(recordID: "old-record")
        await waitUntil { await reader.hasPendingRead }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        XCTAssertFalse(coordinator.activeClipboardReadForTesting)

        await reader.finish(text: "stale clipboard text")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)

        captureProvider.fail(with: CancellationError())
    }

    func testDelayedClipboardCloseCallbackCannotPresentStaleEntry()
        async
    {
        let suiteName =
            "TranslationEntryCloseGeneration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var closeCompletions: [() -> Void] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults)
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: {
                closeCompletions.append($0)
            },
            readClipboardText: { recordID, purpose, _ in
                .success(
                    recordID: recordID,
                    purpose: purpose,
                    text: "fixture"
                )
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showManualPanel()
        coordinator.showManualPanel()
        XCTAssertEqual(closeCompletions.count, 2)

        closeCompletions[0]()
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)

        closeCompletions[1]()
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
        }
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.inputSource,
            .manual
        )
    }

    func testTranslationCapturePurposeUsesCleanNonPersistentOverlayOnlyPolicy() {
        XCTAssertEqual(
            ScreenshotCapturePurpose.translationOCR.selectionDefaultsOverride,
            ScreenshotCaptureDefaults()
        )
        XCTAssertFalse(ScreenshotCapturePurpose.translationOCR.showsSelectionParameterToolbar)
        XCTAssertFalse(ScreenshotCapturePurpose.translationOCR.persistsSelectionParameters)
        XCTAssertFalse(ScreenshotCapturePurpose.translationOCR.allowsScrollingCapture)

        XCTAssertNil(ScreenshotCapturePurpose.standard.selectionDefaultsOverride)
        XCTAssertTrue(ScreenshotCapturePurpose.standard.showsSelectionParameterToolbar)
        XCTAssertTrue(ScreenshotCapturePurpose.standard.persistsSelectionParameters)
        XCTAssertTrue(ScreenshotCapturePurpose.standard.allowsScrollingCapture)
    }

    func testTranslationRegionSelectionDoesNotCreateScreenshotParameterToolbar() async {
        let controller = ScreenshotSelectionController()
        let task = Task { @MainActor in
            await controller.select(
                intent: try! ScreenshotCaptureIntent(kind: .region),
                candidates: [],
                displays: [],
                frozenSnapshotProvider: { _ in
                    ScreenshotFrozenSelectionSnapshot(
                        images: [:],
                        candidates: [],
                        displayDescriptors: []
                    )
                },
                magnifierSnapshotProvider: { [:] },
                onParametersChanged: { _ in
                    XCTFail("Translation OCR selection must not publish screenshot parameters")
                },
                showsParameterToolbar: false,
                timeout: 2
            )
        }
        await waitUntilSelectionIsActive(controller)

        XCTAssertTrue(controller.selectionActiveForTesting)
        XCTAssertFalse(controller.parameterToolbarVisibleForTesting)

        controller.cancel()
        let result = await task.value
        controller.dismissSelectionSurfaces()
        guard case .cancelled = result else {
            return XCTFail("Expected the translation selection to cancel")
        }
    }

    func testStandardRegionSelectionStillCreatesScreenshotParameterToolbar() async {
        let controller = ScreenshotSelectionController()
        let task = Task { @MainActor in
            await controller.select(
                intent: try! ScreenshotCaptureIntent(kind: .region),
                candidates: [],
                displays: [],
                frozenSnapshotProvider: { _ in
                    ScreenshotFrozenSelectionSnapshot(
                        images: [:],
                        candidates: [],
                        displayDescriptors: []
                    )
                },
                magnifierSnapshotProvider: { [:] },
                onParametersChanged: { _ in },
                timeout: 2
            )
        }
        await waitUntilSelectionIsActive(controller)

        XCTAssertTrue(controller.selectionActiveForTesting)
        XCTAssertTrue(controller.parameterToolbarVisibleForTesting)

        controller.cancel()
        let result = await task.value
        controller.dismissSelectionSurfaces()
        guard case .cancelled = result else {
            return XCTFail("Expected the standard selection to cancel")
        }
    }

    func testVisionTranslationOCRAdapterMapsExistingOCRResult() async throws {
        let capture = try makeScreenshotCapture(
            sourceRect: CGRect(x: 0, y: 0, width: 20, height: 20)
        )
        let token = LocalVisionOCRRequestToken()
        let recorder = TranslationOCRRecognitionRecorder()
        let adapter = LocalVisionTranslationOCRAdapter { image, requestToken in
            await recorder.record(
                imageSize: CGSize(width: image.width, height: image.height),
                requestToken: requestToken
            )
            return LocalVisionOCRResult(text: "识别文字", lineCount: 2, meanConfidence: 0.91)
        }

        let result = try await adapter.recognizeText(
            in: TranslationScreenshotCapture(
                image: capture.image,
                cgImage: try XCTUnwrap(capture.image.cgImage(
                    forProposedRect: nil,
                    context: nil,
                    hints: nil
                )),
                logicalRect: capture.sourceRect,
                pixelSize: capture.pixelSize,
                screen: nil
            ),
            requestToken: token
        )

        XCTAssertEqual(result, TranslationScreenshotOCRSnapshot(
            text: "识别文字",
            lineCount: 2,
            meanConfidence: 0.91
        ))
        let invocation = await recorder.invocation()
        XCTAssertEqual(invocation.imageSize, CGSize(width: 20, height: 20))
        XCTAssertTrue(invocation.requestToken === token)
    }

    func testSelectionPanelSkeletonUsesFrozenElementAndPinnedSessionSurvivesNextEntry()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName = "TranslationPinnedSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            client.invocationCount == 1
        }
        XCTAssertEqual(coordinator.presentedModelsForTesting.count, 1)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting[0].selectionReadState,
            .reading
        )
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            1
        )

        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "first selection",
                selectedRange: NSRange(location: 0, length: 15),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            coordinator.presentedModelsForTesting.first?
                .selectionReadState == .selected
        }
        let firstModel = coordinator.presentedModelsForTesting[0]
        XCTAssertEqual(firstModel.sourceText, "first selection")
        XCTAssertEqual(firstModel.selectionReadState, .selected)
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            0
        )
        firstModel.isPinned = true

        coordinator.showSmartSelectionPanel()
        await waitUntil { client.invocationCount == 2 }
        XCTAssertEqual(coordinator.presentedModelsForTesting.count, 2)
        XCTAssertEqual(coordinator.activeSelectionCaptureCountForTesting, 1)
        let readingModel = coordinator.presentedModelsForTesting.first {
            $0.id != firstModel.id
        }
        XCTAssertEqual(readingModel?.selectionReadState, .reading)
        XCTAssertEqual(readingModel?.sourceText, "")
        client.finish(
            invocation: 1,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "second selection",
                selectedRange: NSRange(location: 0, length: 16),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            coordinator.presentedModelsForTesting.first {
                $0.id != firstModel.id
            }?.selectionReadState == .selected
        }
        let secondModel = coordinator.presentedModelsForTesting.first {
            $0.id != firstModel.id
        }
        XCTAssertEqual(secondModel?.sourceText, "second selection")
        XCTAssertEqual(firstModel.sourceText, "first selection")
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            0
        )
        coordinator.closeUnpinnedPanels()
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.map(\.id),
            [firstModel.id]
        )
        coordinator.closeFloatingPanel()
    }

    func testSelectionPanelPresentsSkeletonImmediatelyWhileSlowAXReadRunsOffMain()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName = "TranslationSlowSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()

        XCTAssertEqual(client.freezeInvocationCount, 1)
        XCTAssertEqual(coordinator.presentedModelsForTesting.count, 1)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.selectionReadState,
            .reading
        )
        await waitUntil { client.invocationCount == 1 }
        XCTAssertFalse(client.readObservedMainThread)
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            1
        )

        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "slow selection",
                selectedRange: NSRange(location: 0, length: 14),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            coordinator.presentedModelsForTesting.first?
                .selectionReadState == .selected
        }
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.sourceText,
            "slow selection"
        )
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            0
        )
    }

    func testSelectionPanelCloseCancelsPendingHelperCaptureAndRejectsLateResult()
        async throws
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let adapter = SelectionCaptureTranslationAdapter()
        let registry = TranslationServiceRegistry()
        let suiteName = "TranslationSelectionCloseCancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(
            defaults: defaults,
            serviceRegistry: registry
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            selectionReader: reader
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            client.invocationCount == 1
                && coordinator.activeSelectionCaptureCountForTesting == 1
        }
        let model = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        let presenter = try XCTUnwrap(coordinator.presenters[model.id])

        presenter.close()
        await waitUntil {
            client.cancelInvocationCount == 1
                && coordinator.activeSelectionCaptureCountForTesting == 0
        }

        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
        XCTAssertEqual(model.selectionReadState, .reading)
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(adapter.translateCallCount, 0)

        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "late selection",
                selectedRange: NSRange(location: 0, length: 14),
                accessibilityScreenBounds: nil
            ))
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(client.cancelInvocationCount, 1)
        XCTAssertEqual(model.selectionReadState, .reading)
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(adapter.translateCallCount, 0)
    }

    func testStaleSelectionPanelCloseDoesNotCancelNewSelectionCapture()
        async throws
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName = "TranslationSelectionStaleClose.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil { client.invocationCount == 1 }
        let firstModel = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        let firstPresenter = try XCTUnwrap(
            coordinator.presenters[firstModel.id]
        )
        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "first selection",
                selectedRange: NSRange(location: 0, length: 15),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            firstModel.selectionReadState == .selected
        }
        firstModel.isPinned = true

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            client.invocationCount == 2
                && coordinator.activeSelectionCaptureCountForTesting == 1
        }

        firstPresenter.close()
        await Task.yield()

        XCTAssertEqual(client.cancelInvocationCount, 0)
        XCTAssertEqual(
            coordinator.activeSelectionCaptureCountForTesting,
            1
        )

        client.finish(
            invocation: 1,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "second selection",
                selectedRange: NSRange(location: 0, length: 16),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            coordinator.presentedModelsForTesting.first {
                $0.id != firstModel.id
            }?.selectionReadState == .selected
        }
    }

    func testSelectionSkeletonUsesFrozenMouseAnchorBeforeHelperReturns()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let frozenTarget = AXSelectionTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.example.target",
            applicationName: "Target",
            accessibilityMouseLocation: CGPoint(x: 420, y: 260),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { frozenTarget }
        )
        let suiteName =
            "TranslationSelectionMouseAnchor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )
        defer {
            coordinator.closeFloatingPanel()
            defaults.removePersistentDomain(
                forName: suiteName
            )
        }

        coordinator.showSmartSelectionPanel()

        let expected = AXSelectionReader.appKitMouseAnchor(
            frozenTarget.accessibilityMouseLocation
        )
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?
                .inputContext?.anchor,
            expected
        )
    }

    func testSelectionFreezeContractStartsCaptureBeforeSkeletonPresentation()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName = "TranslationSlowFocusFreeze.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()

        XCTAssertEqual(client.freezeInvocationCount, 1)
        XCTAssertEqual(coordinator.presentedModelsForTesting.count, 1)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?
                .selectionReadState,
            .reading
        )
        await waitUntil { client.invocationCount == 1 }
        XCTAssertFalse(client.readObservedMainThread)

        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "frozen selection",
                selectedRange: NSRange(location: 0, length: 16),
                accessibilityScreenBounds: nil
            ))
        )
        await waitUntil {
            coordinator.presentedModelsForTesting.first?
                .selectionReadState == .selected
        }
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.sourceText,
            "frozen selection"
        )
    }

    func testUserEditingSelectionSkeletonWinsOverLateAXText() async {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName = "TranslationSelectionEdit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader
        )

        coordinator.showSmartSelectionPanel()
        await waitUntil { client.invocationCount == 1 }
        let model = try? XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        XCTAssertEqual(model?.selectionReadState, .reading)
        let initialFocusRequest = model?.sourceFocusRequest
        model?.updateSourceTextFromUser("user text")

        client.finish(
            invocation: 0,
            result: .element(AXSelectionElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                selectedText: "late selection",
                selectedRange: NSRange(location: 0, length: 14),
                accessibilityScreenBounds: CGRect(
                    x: 20,
                    y: 30,
                    width: 100,
                    height: 18
                )
            ))
        )
        await waitUntil {
            model?.selectionReadState == .selected
        }

        XCTAssertEqual(model?.sourceText, "user text")
        XCTAssertEqual(
            model?.sourceFocusRequest,
            initialFocusRequest.map { $0 + 1 }
        )
        XCTAssertEqual(
            model?.inputContext?.sourceApplicationBundleID,
            target().bundleIdentifier
        )
        XCTAssertNotNil(model?.inputContext?.anchor)
        model?.cancel()
        coordinator.closeFloatingPanel()
        settleTranslationAppKitFixture()
    }

    func testUnavailableConfiguredOCRPluginDoesNotFallBackToVision()
        throws
    {
        let defaults = UserDefaults.standard
        let key = "translation.ocr.defaultServiceID"
        let previous = defaults.object(forKey: key)
        defaults.set("plugin:missing-fixture", forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let suiteName = "TranslationMissingOCR.\(UUID().uuidString)"
        let storeDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            storeDefaults.removePersistentDomain(forName: suiteName)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: storeDefaults)
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: storeDefaults),
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(
            capture: try makeTranslationCapture(
                sourceRect: CGRect(x: 0, y: 0, width: 20, height: 20)
            ),
            model: model
        )

        guard case let .failed(code, _) = model.ocrState else {
            return XCTFail("Expected unavailable OCR service failure")
        }
        XCTAssertEqual(code, "ocr_service_unavailable")
        XCTAssertEqual(
            coordinator.activeScreenshotOCRSessionCountForTesting,
            0
        )
    }

    func testPinnedScreenshotOCRSessionDoesNotCancelAnotherPanel() async throws {
        let firstCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 101, y: 0, width: 20, height: 20)
        )
        let secondCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 202, y: 0, width: 20, height: 20)
        )
        let provider = ControlledTranslationOCRProvider()
        let defaults = UserDefaults(
            suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
        )!
        defaults.set(["apple-local"], forKey: "translation.services.enabledIDs")
        let store = TranslationStore(defaults: defaults)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotOCRProvider: provider
        )
        let direction = TranslationLanguageDirection(
            target: TranslationLanguageTag("zh-Hans")!
        )
        let firstModel = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: direction,
            translationStore: store,
            ocrState: .recognizing
        )
        let secondModel = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: direction,
            translationStore: store,
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(
            capture: firstCapture,
            model: firstModel
        )
        coordinator.startScreenshotOCRForTesting(
            capture: secondCapture,
            model: secondModel
        )
        await waitUntil {
            await provider.pendingKeys() == Set([101, 202])
        }

        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 2)
        await provider.finish(key: 101, text: "first")
        await waitUntil { firstModel.sourceText == "first" }
        await waitUntil {
            coordinator.activeScreenshotOCRSessionCountForTesting == 1
        }
        XCTAssertEqual(secondModel.ocrState, .recognizing)
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 1)

        await provider.finish(key: 202, text: "second")
        await waitUntil { secondModel.sourceText == "second" }
        await waitUntil {
            coordinator.activeScreenshotOCRSessionCountForTesting == 0
        }
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 0)
    }

    func testChangingOCRServiceTurnsInterruptedRecognitionIntoExplicitFailure()
        async throws
    {
        let capture = try makeTranslationCapture(
            sourceRect: CGRect(x: 909, y: 0, width: 20, height: 20)
        )
        let originalProvider = ControlledTranslationOCRProvider()
        let replacementProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationOCRServiceChange.\(UUID().uuidString)"
        let defaults = UserDefaults(
            suiteName: suiteName
        )!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = TranslationStore(defaults: defaults)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotOCRProvider: originalProvider
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(
            capture: capture,
            model: model
        )
        await waitUntil {
            await originalProvider.pendingKeys() == Set([909])
        }
        coordinator.setScreenshotOCRProvider(replacementProvider)

        guard case let .failed(code, _) = model.ocrState else {
            return XCTFail("Changing the OCR service must stop the spinner")
        }
        XCTAssertEqual(code, "ocr_service_changed")
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 0)

        await originalProvider.finish(key: 909, text: "stale")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.sourceText, "")
        guard case let .failed(finalCode, _) = model.ocrState else {
            return XCTFail("A late OCR result must not clear the service-change failure")
        }
        XCTAssertEqual(finalCode, "ocr_service_changed")
    }

    func testScreenshotOCREmptyResultBecomesExplicitNoTextFailure() async throws {
        let capture = try makeTranslationCapture(
            sourceRect: CGRect(x: 303, y: 0, width: 20, height: 20)
        )
        let provider = ControlledTranslationOCRProvider()
        let defaults = UserDefaults(
            suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
        )!
        let store = TranslationStore(defaults: defaults)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotOCRProvider: provider
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(capture: capture, model: model)
        await waitUntil { await provider.pendingKeys() == Set([303]) }
        await provider.finish(key: 303, text: " \n ")
        await waitUntil {
            if case let .failed(code, _) = model.ocrState {
                return code == "no_text"
            }
            return false
        }

        XCTAssertEqual(model.sourceText, "")
        XCTAssertNil(model.snapshot)
        await waitUntil {
            coordinator.activeScreenshotOCRSessionCountForTesting == 0
        }
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 0)
    }

    func testScreenshotOCREmitsUnifiedPluginEventsAfterAutomaticTranslation()
        async throws
    {
        let capture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1201, y: 0, width: 20, height: 20)
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationScreenshotPluginEvents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(defaults: defaults)
        let adapter = ScreenshotPluginEventTranslationAdapter()
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        var events: [BlocksPluginEventEnvelope] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "fixture")
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in },
            dispatchPluginEvent: { envelope in
                events.append(envelope)
                return .allowed(envelope)
            }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: capture)
        await waitUntil { await ocrProvider.pendingKeys() == Set([1201]) }
        await ocrProvider.finish(key: 1201, text: "recognized screenshot")
        await waitUntil {
            events.contains { $0.name == .translationSessionCompleted }
        }

        let expectedNames: Set<BlocksPluginEventName> = [
            .translationInputResolved,
            .translationWillRunSession,
            .translationSourceResult,
            .translationSessionCompleted,
        ]
        XCTAssertTrue(expectedNames.isSubset(of: Set(events.map(\.name))))
        guard let model = coordinator.presentedModelsForTesting.first,
              let translationSessionID = model.snapshot?.id else {
            return XCTFail("Expected the screenshot translation session.")
        }
        XCTAssertNotEqual(translationSessionID, model.id.uuidString)
        let runEvents = events.filter { expectedNames.contains($0.name) }
        let expectedRevision = runEvents.first?.revision
        let causationID = UUID(uuidString: translationSessionID)
        for event in runEvents {
            XCTAssertEqual(event.sessionID, translationSessionID)
            XCTAssertEqual(event.revision, expectedRevision)
            XCTAssertEqual(event.causationID, causationID)
            XCTAssertEqual(
                event.payload.string("panel_id"),
                model.id.uuidString
            )
            XCTAssertEqual(
                event.payload.string("translation_session_id"),
                translationSessionID
            )
            XCTAssertEqual(
                event.source["input_source"],
                .string(TranslationInputSource.screenshotOCR.rawValue)
            )
        }
    }

    func testScreenshotOCRCloseSuppressesLatePluginEvents() async throws {
        let capture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1202, y: 0, width: 20, height: 20)
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationScreenshotLatePluginEvents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var events: [BlocksPluginEventEnvelope] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "fixture")
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in },
            dispatchPluginEvent: { envelope in
                events.append(envelope)
                return .allowed(envelope)
            }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: capture)
        await waitUntil { await ocrProvider.pendingKeys() == Set([1202]) }

        coordinator.closeFloatingPanel()
        await ocrProvider.finish(key: 1202, text: "late screenshot")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(events.isEmpty)
    }

    func testClosingPanelInvalidatesPendingScreenshotRetake() async throws {
        let initialCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1203, y: 0, width: 20, height: 20)
        )
        let retakeCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1204, y: 0, width: 20, height: 20)
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationRetakeClose.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(defaults: defaults)
        let adapter = ScreenshotPluginEventTranslationAdapter()
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let attachmentCalls = TranslationAttachmentEncodingRecorder()
        var events: [BlocksPluginEventEnvelope] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider,
            screenshotAttachmentEncoder: { capture in
                await attachmentCalls.increment()
                return try await TranslationSourceAttachmentPayload
                    .screenshotImage(from: capture)
            }
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "fixture")
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in },
            dispatchPluginEvent: { envelope in
                events.append(envelope)
                return .allowed(envelope)
            }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: initialCapture)
        await waitUntil { await ocrProvider.pendingKeys() == Set([1203]) }
        let model = try XCTUnwrap(coordinator.presentedModelsForTesting.first)
        await ocrProvider.finish(key: 1203, text: "initial text")
        await waitUntil {
            let attachmentCount = await attachmentCalls.count()
            return model.sourceText == "initial text"
                && attachmentCount == 1
                && events.contains {
                    $0.name == .translationSessionCompleted
                }
        }
        events.removeAll()
        await attachmentCalls.reset()

        let retake = Task { @MainActor in
            await coordinator.retakeScreenshotForTesting(for: model)
        }
        await waitUntil { captureProvider.hasPendingCapture }
        let presenter = try XCTUnwrap(coordinator.presenters[model.id])
        presenter.close()
        await waitUntil { coordinator.presentedModelsForTesting.isEmpty }
        captureProvider.succeed(with: retakeCapture)
        await retake.value
        try? await Task.sleep(for: .milliseconds(20))

        let pendingOCRKeys = await ocrProvider.pendingKeys()
        let attachmentCount = await attachmentCalls.count()
        XCTAssertTrue(pendingOCRKeys.isEmpty)
        XCTAssertEqual(attachmentCount, 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(captureProvider.cancelCount, 1)
    }

    func testScreenshotOCRFocusesPresentedPanelAfterCurrentSuccess()
        async throws
    {
        let capture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1001, y: 0, width: 20, height: 20)
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationScreenshotFocusSuccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: capture)
        await waitUntil {
            let pendingKeys = await ocrProvider.pendingKeys()
            return coordinator.presentedModelsForTesting.count == 1
                && pendingKeys == Set([1001])
        }
        let model = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        let panel = try XCTUnwrap(
            coordinator.presenters[model.id]?.panelForTesting
        )
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(model.sourceFocusRequest, 0)

        await ocrProvider.finish(key: 1001, text: "recognized text")
        await waitUntil {
            model.sourceText == "recognized text"
                && model.sourceFocusRequest == 1
        }
        // A hosted `.nonactivatingPanel` cannot reliably become key while the
        // XCTest host is not the active application. The editor coordinator's
        // key-window retry behavior is covered independently above; here the
        // screenshot workflow contract is the real focus request.
        XCTAssertTrue(panel.isVisible)
    }

    func testScreenshotOCRNoTextAndFailureFocusPresentedSourceEditor()
        async throws
    {
        enum TerminalOutcome {
            case noText
            case failure

            var captureX: Int {
                switch self {
                case .noText: return 1002
                case .failure: return 1003
                }
            }
        }

        for outcome in [TerminalOutcome.noText, .failure] {
            let capture = try makeTranslationCapture(
                sourceRect: CGRect(
                    x: outcome.captureX,
                    y: 0,
                    width: 20,
                    height: 20
                )
            )
            let captureProvider =
                ControlledTranslationScreenshotCaptureProvider()
            let ocrProvider = ControlledTranslationOCRProvider()
            let suiteName =
                "TranslationScreenshotFocusTerminal.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let coordinator = TranslationFeatureCoordinator(
                translationStore: TranslationStore(defaults: defaults),
                screenshotCaptureProvider: captureProvider,
                screenshotOCRProvider: ocrProvider
            )
            defer { coordinator.closeFloatingPanel() }

            coordinator.showScreenshotTranslation()
            await waitUntil { captureProvider.hasPendingCapture }
            captureProvider.succeed(with: capture)
            await waitUntil {
                let pendingKeys = await ocrProvider.pendingKeys()
                return coordinator.presentedModelsForTesting.count == 1
                    && pendingKeys == Set([outcome.captureX])
            }
            let model = try XCTUnwrap(
                coordinator.presentedModelsForTesting.first
            )
            XCTAssertEqual(model.sourceFocusRequest, 0)

            switch outcome {
            case .noText:
                await ocrProvider.finish(
                    key: outcome.captureX,
                    text: " \n "
                )
            case .failure:
                await ocrProvider.fail(
                    key: outcome.captureX,
                    error: TranslationEntryTestError.fixtureFailure
                )
            }
            await waitUntil {
                if case .failed = model.ocrState {
                    return model.sourceFocusRequest == 1
                }
                return false
            }
        }
    }

    func testScreenshotOCRTerminalStatesRequestFocusForVisibleNonKeyPanel()
        async throws
    {
        enum TerminalOutcome: CaseIterable {
            case success
            case noText
            case failure

            var captureX: Int {
                switch self {
                case .success: return 1006
                case .noText: return 1007
                case .failure: return 1008
                }
            }
        }

        for outcome in TerminalOutcome.allCases {
            let capture = try makeTranslationCapture(
                sourceRect: CGRect(
                    x: outcome.captureX,
                    y: 0,
                    width: 20,
                    height: 20
                )
            )
            let captureProvider =
                ControlledTranslationScreenshotCaptureProvider()
            let ocrProvider = ControlledTranslationOCRProvider()
            let suiteName =
                "TranslationScreenshotExistingFocus.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let coordinator = TranslationFeatureCoordinator(
                translationStore: TranslationStore(defaults: defaults),
                screenshotCaptureProvider: captureProvider,
                screenshotOCRProvider: ocrProvider
            )
            defer { coordinator.closeFloatingPanel() }

            coordinator.showScreenshotTranslation()
            await waitUntil { captureProvider.hasPendingCapture }
            captureProvider.succeed(with: capture)
            await waitUntil {
                let pendingKeys = await ocrProvider.pendingKeys()
                return coordinator.presentedModelsForTesting.count == 1
                    && pendingKeys == Set([outcome.captureX])
            }
            let model = try XCTUnwrap(
                coordinator.presentedModelsForTesting.first
            )
            let panel = try XCTUnwrap(
                coordinator.presenters[model.id]?.panelForTesting
            )
            panel.orderFrontRegardless()
            XCTAssertTrue(panel.isVisible)
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertEqual(model.sourceFocusRequest, 0)

            switch outcome {
            case .success:
                await ocrProvider.finish(
                    key: outcome.captureX,
                    text: "recognized text"
                )
            case .noText:
                await ocrProvider.finish(key: outcome.captureX, text: " \n ")
            case .failure:
                await ocrProvider.fail(
                    key: outcome.captureX,
                    error: TranslationEntryTestError.fixtureFailure
                )
            }
            await waitUntil {
                switch outcome {
                case .success:
                    return model.sourceText == "recognized text"
                case .noText:
                    if case let .failed(code, _) = model.ocrState {
                        return code == "no_text"
                    }
                    return false
                case .failure:
                    if case let .failed(code, _) = model.ocrState {
                        return code == "ocr_failed"
                    }
                    return false
                }
            }

            XCTAssertEqual(model.sourceFocusRequest, 1)
            XCTAssertTrue(panel.isVisible)
        }
    }

    func testLateOCRResultsAfterRetakeOrCloseDoNotRequestFocus()
        async throws
    {
        let firstCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1004, y: 0, width: 20, height: 20)
        )
        let retakeCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 1005, y: 0, width: 20, height: 20)
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let suiteName = "TranslationScreenshotFocusLate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showScreenshotTranslation()
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: firstCapture)
        await waitUntil {
            let pendingKeys = await ocrProvider.pendingKeys()
            return coordinator.presentedModelsForTesting.count == 1
                && pendingKeys == Set([1004])
        }
        let model = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )

        Task { @MainActor in
            await coordinator.retakeScreenshotForTesting(for: model)
        }
        await waitUntil { captureProvider.hasPendingCapture }
        captureProvider.succeed(with: retakeCapture)
        await waitUntil {
            await ocrProvider.pendingKeys() == Set([1004, 1005])
        }
        await ocrProvider.finish(key: 1004, text: "late original")
        await Task.yield()
        XCTAssertEqual(model.sourceFocusRequest, 0)

        coordinator.closeFloatingPanel()
        await ocrProvider.finish(key: 1005, text: "late retake")
        await Task.yield()
        XCTAssertEqual(model.sourceFocusRequest, 0)
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
    }

    func testRetakeCancelsUnderlyingOCRAndRejectsLateResult() async throws {
        let firstCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 404, y: 0, width: 20, height: 20)
        )
        let secondCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 505, y: 0, width: 20, height: 20)
        )
        let provider = ControlledTranslationOCRProvider()
        let defaults = UserDefaults(
            suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
        )!
        let store = TranslationStore(defaults: defaults)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotOCRProvider: provider
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(
            capture: firstCapture,
            model: model
        )
        await waitUntil { await provider.pendingKeys() == Set([404]) }
        coordinator.startScreenshotOCRForTesting(
            capture: secondCapture,
            model: model
        )
        await waitUntil {
            let keys = await provider.pendingKeys()
            let firstWasCancelled = await provider.isCancelled(key: 404)
            return keys == Set([404, 505]) && firstWasCancelled
        }

        await provider.finish(key: 404, text: "stale")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.ocrState, .recognizing)

        await provider.finish(key: 505, text: "latest")
        await waitUntil {
            model.sourceText == "latest"
                && coordinator
                    .activeScreenshotOCRSessionCountForTesting == 0
        }
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 0)
    }

    func testCancelledOCRThatThrowsOrdinaryErrorCannotOverwriteNewExecution() async throws {
        let firstCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 606, y: 0, width: 20, height: 20)
        )
        let secondCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 707, y: 0, width: 20, height: 20)
        )
        let provider = ControlledTranslationOCRProvider()
        let defaults = UserDefaults(
            suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
        )!
        let store = TranslationStore(defaults: defaults)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotOCRProvider: provider
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognizing
        )

        coordinator.startScreenshotOCRForTesting(
            capture: firstCapture,
            model: model
        )
        await waitUntil { await provider.pendingKeys() == Set([606]) }
        coordinator.startScreenshotOCRForTesting(
            capture: secondCapture,
            model: model
        )
        await waitUntil {
            let isCancelled = await provider.isCancelled(key: 606)
            let pendingKeys = await provider.pendingKeys()
            return isCancelled && pendingKeys == Set([606, 707])
        }

        await provider.fail(
            key: 606,
            error: TranslationEntryTestError.fixtureFailure
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.ocrState, .recognizing)
        XCTAssertEqual(model.sourceText, "")

        await provider.finish(key: 707, text: "latest")
        await waitUntil {
            model.sourceText == "latest"
                && coordinator
                    .activeScreenshotOCRSessionCountForTesting == 0
        }
        XCTAssertEqual(coordinator.activeScreenshotOCRSessionCountForTesting, 0)
    }

    func testScreenshotRetakeKeepsOldContentUntilCaptureSucceeds() async throws {
        let newCapture = try makeTranslationCapture(
            sourceRect: CGRect(x: 808, y: 90, width: 80, height: 30),
            displayID: 42
        )
        let captureProvider = ControlledTranslationScreenshotCaptureProvider()
        let ocrProvider = ControlledTranslationOCRProvider()
        let defaults = UserDefaults(
            suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
        )!
        let store = TranslationStore(defaults: defaults)
        let oldAnchor = TranslationInputAnchor(
            x: 10,
            y: 20,
            width: 30,
            height: 40
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "old text",
                context: TranslationInputContext(
                    displayIdentifier: "1",
                    anchor: oldAnchor
                )
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognized(lineCount: 1, meanConfidence: 1)
        )
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            screenshotCaptureProvider: captureProvider,
            screenshotOCRProvider: ocrProvider
        )

        let retake = Task { @MainActor in
            await coordinator.retakeScreenshotForTesting(for: model)
        }
        await waitUntil { captureProvider.hasPendingCapture }
        XCTAssertEqual(model.sourceText, "old text")
        XCTAssertEqual(
            model.ocrState,
            .recognized(lineCount: 1, meanConfidence: 1)
        )
        XCTAssertEqual(model.inputContext?.anchor, oldAnchor)

        captureProvider.succeed(with: newCapture)
        await retake.value

        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.ocrState, .recognizing)
        XCTAssertEqual(model.inputContext?.displayIdentifier, "42")
        XCTAssertEqual(
            model.inputContext?.anchor,
            TranslationInputAnchor(
                x: 808,
                y: 90,
                width: 80,
                height: 30
            )
        )
        await waitUntil { await ocrProvider.pendingKeys() == Set([808]) }
        await ocrProvider.finish(key: 808, text: "new text")
        await waitUntil { model.sourceText == "new text" }
    }

    func testScreenshotRetakeCancellationAndFailurePreserveOldState() async {
        for error in [
            CancellationError() as Error,
            TranslationEntryTestError.fixtureFailure as Error,
        ] {
            let captureProvider = ControlledTranslationScreenshotCaptureProvider()
            let defaults = UserDefaults(
                suiteName: "TranslationEntryBridgeTests.\(UUID().uuidString)"
            )!
            let store = TranslationStore(defaults: defaults)
            let oldAnchor = TranslationInputAnchor(
                x: 12,
                y: 34,
                width: 56,
                height: 78
            )
            let model = TranslationPanelSessionModel(
                input: TranslationInput(
                    source: .screenshotOCR,
                    text: "preserved",
                    context: TranslationInputContext(
                        displayIdentifier: "old-display",
                        anchor: oldAnchor
                    )
                ),
                direction: TranslationLanguageDirection(
                    target: TranslationLanguageTag("zh-Hans")!
                ),
                translationStore: store,
                ocrState: .recognized(lineCount: 2, meanConfidence: 0.9)
            )
            let coordinator = TranslationFeatureCoordinator(
                translationStore: store,
                screenshotCaptureProvider: captureProvider
            )

            let retake = Task { @MainActor in
                await coordinator.retakeScreenshotForTesting(for: model)
            }
            await waitUntil { captureProvider.hasPendingCapture }
            captureProvider.fail(with: error)
            await retake.value

            XCTAssertEqual(model.sourceText, "preserved")
            XCTAssertEqual(
                model.ocrState,
                .recognized(lineCount: 2, meanConfidence: 0.9)
            )
            XCTAssertEqual(model.inputContext?.displayIdentifier, "old-display")
            XCTAssertEqual(model.inputContext?.anchor, oldAnchor)
        }
    }

    func testScreenshotRetakeClearsStaleTextAndTranslationSnapshot() {
        let suiteName = "TranslationRetakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["apple-local"], forKey: "translation.services.enabledIDs")
        let store = TranslationStore(defaults: defaults)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "stale recognized text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            ocrState: .recognized(lineCount: 1, meanConfidence: 0.99)
        )
        model.runImmediately()
        XCTAssertNotNil(model.snapshot)

        model.beginScreenshotRetake()

        XCTAssertEqual(model.sourceText, "")
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.ocrState, .recognizing)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUserEditedScreenshotTextWinsOverLateOCRResult() {
        let suiteName = "TranslationOCRSourceOwnership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults),
            ocrState: .recognizing
        )

        model.updateSourceTextFromUser("用户修正的原文")
        model.updateOCRResult(
            text: "迟到的 OCR 文本",
            lineCount: 2,
            meanConfidence: 0.92
        )

        XCTAssertEqual(model.sourceText, "用户修正的原文")
        XCTAssertEqual(
            model.ocrState,
            .recognized(lineCount: 2, meanConfidence: 0.92)
        )
    }

    func testScreenshotOCRAndAttachmentUseIndependentRevisions()
        throws
    {
        let suiteName =
            "TranslationScreenshotRevisions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .screenshotOCR,
                text: ""
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults),
            ocrState: .recognizing
        )
        let stale = model.beginScreenshotProcessing(
            expectsAttachment: true
        )
        let current = model.beginScreenshotProcessing(
            expectsAttachment: true
        )
        let attachment = TranslationSourceAttachmentPayload(
            descriptor: TranslationSourceAttachmentDescriptor(
                kind: .screenshotImage,
                mediaType: "image/jpeg",
                byteCount: 1,
                pixelWidth: 1,
                pixelHeight: 1
            ),
            data: Data([0x01])
        )

        model.updateOCRResult(
            text: "stale OCR",
            lineCount: 1,
            meanConfidence: 1,
            revision: stale.ocr
        )
        model.installScreenshotAttachment(
            attachment,
            revision: stale.attachment
        )
        XCTAssertEqual(model.sourceText, "")
        XCTAssertFalse(model.hasScreenshotAttachmentForTesting)

        model.updateOCRResult(
            text: "current OCR",
            lineCount: 1,
            meanConfidence: 1,
            revision: current.ocr
        )
        XCTAssertEqual(model.sourceText, "current OCR")
        XCTAssertFalse(model.hasScreenshotAttachmentForTesting)

        model.installScreenshotAttachment(
            attachment,
            revision: current.attachment
        )
        XCTAssertTrue(model.hasScreenshotAttachmentForTesting)
        XCTAssertEqual(
            model.screenshotProcessingRevisionForTesting,
            current
        )
    }

    func testLateOCRFailureDoesNotStopUserEditedTranslationState() {
        let suiteName = "TranslationOCRFailureOwnership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .screenshotOCR, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults),
            ocrState: .recognizing
        )

        model.updateSourceTextFromUser("用户修正的原文")
        XCTAssertEqual(model.runPhase, .debouncing)

        model.updateOCRFailure(
            code: "ocr_failed",
            message: "fixture failure"
        )

        XCTAssertEqual(model.sourceText, "用户修正的原文")
        XCTAssertEqual(model.runPhase, .debouncing)
        XCTAssertEqual(
            model.ocrState,
            .failed(code: "ocr_failed", message: "fixture failure")
        )
    }

    func testScreenshotOCRUserFacingStatusOmitsRawConfidence() {
        let state = TranslationScreenshotOCRState.recognized(
            lineCount: 2,
            meanConfidence: 0.5
        )
        let message = state.accessibilityMessage

        XCTAssertEqual(
            message,
            TranslationLocalizedFormat.ocrLines(2)
        )
        XCTAssertFalse(message?.contains("50") == true)
        XCTAssertFalse(message?.contains("%") == true)
    }

    func testTranslationPanelAcceptsFirstMouseAndRoutesEscape() {
        let hostingView = TranslationFirstMouseHostingView(
            rootView: EmptyView()
        )
        XCTAssertTrue(hostingView.acceptsFirstMouse(for: nil))
        XCTAssertTrue(
            BlocksPanelWindowDragArea.DragView()
                .acceptsFirstMouse(for: nil)
        )
        XCTAssertGreaterThanOrEqual(
            BlocksVisualTokens.Control.minimumHitTarget,
            36
        )
        XCTAssertEqual(
            TranslationPanelMetrics.compactIconHitTarget,
            28
        )
        XCTAssertEqual(
            TranslationPanelMetrics.headerContentHeight,
            28
        )
        XCTAssertEqual(
            TranslationPanelMetrics.headerVerticalPadding,
            11
        )
        XCTAssertEqual(
            TranslationPanelMetrics.headerTotalHeight,
            50
        )
        XCTAssertEqual(
            TranslationPanelMetrics.ocrStatusMinimumWidth,
            72
        )
        XCTAssertEqual(
            TranslationPanelMetrics.ocrStatusIdealWidth,
            156
        )
        XCTAssertLessThan(
            TranslationPanelMetrics.ocrStatusMinimumWidth,
            TranslationPanelMetrics.ocrStatusIdealWidth
        )
        let minimumPanelContentWidth =
            TranslationPanelMetrics.minimumWidth - 32
        let minimumScreenshotHeaderFixedBudget =
            TranslationPanelMetrics.ocrStatusMinimumWidth
                + TranslationPanelMetrics.compactIconHitTarget
                + TranslationPanelMetrics.sourceHeaderSpacing * 3
                + 120
        XCTAssertLessThanOrEqual(
            minimumScreenshotHeaderFixedBudget,
            minimumPanelContentWidth
        )
        XCTAssertEqual(
            BlocksVisualTokens.Control.compactIconSize,
            13
        )
        XCTAssertEqual(
            BlocksVisualTokens.Spacing.xs,
            4
        )
        XCTAssertEqual(
            BlocksCompactIconButtonDensity.micro.hitTarget,
            28
        )
        XCTAssertEqual(
            BlocksCompactIconButtonDensity.micro.visualSize,
            22
        )
        XCTAssertEqual(
            BlocksCompactIconButtonDensity.micro.iconSize,
            11.5
        )
        XCTAssertEqual(
            BlocksCompactActionGroupLayout.spacing(for: .compact),
            4
        )
        XCTAssertEqual(
            BlocksCompactActionGroupLayout.spacing(for: .micro),
            1
        )
        XCTAssertEqual(
            BlocksCompactActionGroupLayout.reservedWidth(
                density: .micro,
                slotCount: 4
            ),
            115
        )
        XCTAssertGreaterThanOrEqual(
            BlocksCompactIconButtonVisualMetrics
                .microIdleForegroundOpacity,
            0.82
        )
        XCTAssertGreaterThan(
            BlocksCompactIconButtonVisualMetrics
                .microActiveForegroundOpacity,
            BlocksCompactIconButtonVisualMetrics
                .microIdleForegroundOpacity
        )

        let normal = BlocksCompactIconButtonAppearance.resolve(
            emphasis: .standard,
            density: .micro,
            isEnabled: true,
            isHovered: false,
            isFocused: false,
            isSelected: false,
            isPressed: false,
            increasesContrast: false,
            isWindowActive: true
        )
        let increasedContrast =
            BlocksCompactIconButtonAppearance.resolve(
                emphasis: .standard,
                density: .micro,
                isEnabled: true,
                isHovered: false,
                isFocused: false,
                isSelected: false,
                isPressed: false,
                increasesContrast: true,
                isWindowActive: true
            )
        let inactive =
            BlocksCompactIconButtonAppearance.resolve(
                emphasis: .accent,
                density: .micro,
                isEnabled: true,
                isHovered: false,
                isFocused: false,
                isSelected: false,
                isPressed: false,
                increasesContrast: false,
                isWindowActive: false
            )

        XCTAssertEqual(normal.foregroundRole, .secondary)
        XCTAssertEqual(
            increasedContrast.foregroundRole,
            .primary
        )
        XCTAssertGreaterThan(
            increasedContrast.foregroundOpacity,
            normal.foregroundOpacity
        )
        XCTAssertGreaterThan(
            increasedContrast.strokeOpacity,
            normal.strokeOpacity
        )
        XCTAssertEqual(inactive.foregroundRole, .secondary)
        XCTAssertGreaterThanOrEqual(
            inactive.foregroundOpacity,
            0.82
        )
        XCTAssertEqual(inactive.backgroundOpacity, 0)

        XCTAssertFalse(
            TranslationResultHeaderStatusLayout.usesPrimaryText(
                increasesContrast: false
            )
        )
        XCTAssertTrue(
            TranslationResultHeaderStatusLayout.usesPrimaryText(
                increasesContrast: true
            )
        )
        XCTAssertFalse(
            TranslationResultHeaderStatusLayout.showsStateTitle(
                for: .succeeded
            )
        )
        for state in [
            TranslationResultState.waiting,
            .running,
            .streaming,
        ] {
            XCTAssertTrue(
                TranslationResultHeaderStatusLayout
                    .showsStateTitle(for: state)
            )
        }
        for state in [
            TranslationResultState.succeeded,
            .failed,
            .cancelled,
        ] {
            XCTAssertFalse(
                TranslationResultHeaderStatusLayout
                    .showsStateTitle(for: state)
            )
        }

        let panel = TranslationSessionPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        defer {
            panel.orderOut(nil)
            panel.close()
            settleTranslationAppKitFixture()
        }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        var escapeCount = 0
        panel.onEscape = {
            escapeCount += 1
        }

        panel.cancelOperation(nil)

        XCTAssertEqual(escapeCount, 1)

        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        XCTAssertTrue(
            TranslationPanelDismissalController
                .isUnmodifiedEscape(escapeEvent)
        )

        let commandEscapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        XCTAssertFalse(
            TranslationPanelDismissalController.isUnmodifiedEscape(
                commandEscapeEvent
            )
        )
        XCTAssertTrue(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            ).allowsImplicitDismissal
        )
        XCTAssertFalse(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: true,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            ).allowsImplicitDismissal
        )
        XCTAssertFalse(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: true,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            ).allowsImplicitDismissal
        )
        XCTAssertFalse(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: true,
                isDirectInteractionActive: false
            ).allowsImplicitDismissal
        )
        XCTAssertFalse(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: true
            ).allowsImplicitDismissal
        )

        let dismissalPanel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dismissalPanel.animationBehavior = .none
        dismissalPanel.orderFrontRegardless()
        defer {
            dismissalPanel.orderOut(nil)
            dismissalPanel.close()
            settleTranslationAppKitFixture()
        }
        var guardedDismissCount = 0
        let dismissalController = TranslationPanelDismissalController {
            guardedDismissCount += 1
        }
        dismissalController.attach(panel: dismissalPanel)
        dismissalController.update(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: true
            )
        )
        dismissalController.requestDismissIfAllowed()
        XCTAssertEqual(guardedDismissCount, 0)

        dismissalController.update(
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            )
        )
        dismissalController.requestDismissIfAllowed()
        XCTAssertEqual(guardedDismissCount, 1)
        dismissalController.shutdown()
    }

    func testTranslationPanelDismissalSkipsFallbackWhenHotKeyRegisters() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
            settleTranslationAppKitFixture()
        }
        let hotKey = TranslationPanelEscapeHotKeyLifecycleStub(
            startResult: true
        )
        let monitors = TranslationPanelKeyMonitorRegistrarStub()
        let controller = TranslationPanelDismissalController(
            onDismiss: {},
            escapeHotKeyLifecycle: hotKey,
            keyMonitorRegistrar: monitors
        )

        controller.attach(panel: panel)
        controller.update(.init(
            isVisible: true,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        ))

        XCTAssertEqual(hotKey.startCount, 1)
        XCTAssertEqual(monitors.localHandlerCount, 0)
        XCTAssertEqual(monitors.globalHandlerCount, 0)
        XCTAssertEqual(hotKey.stopCount, 1)

        controller.update(.init(
            isVisible: false,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        ))
        XCTAssertEqual(hotKey.stopCount, 2)
        XCTAssertEqual(monitors.removalCount, 0)

        controller.shutdown()
        XCTAssertEqual(hotKey.stopCount, 3)
        XCTAssertEqual(monitors.removalCount, 0)
    }

    func testTranslationPanelDismissalFallbackForwardsAndDeduplicatesPanelEscape()
        async throws
    {
        let panel = TranslationSessionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
            settleTranslationAppKitFixture()
        }
        let hotKey = TranslationPanelEscapeHotKeyLifecycleStub(
            startResult: false
        )
        let monitors = TranslationPanelKeyMonitorRegistrarStub()
        var dismissCount = 0
        let controller = TranslationPanelDismissalController(
            onDismiss: { dismissCount += 1 },
            escapeHotKeyLifecycle: hotKey,
            keyMonitorRegistrar: monitors
        )
        panel.onEscape = {
            controller.requestDismissIfAllowed()
        }
        let activeState = TranslationPanelDismissalState(
            isVisible: true,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        )
        let escapeEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let commandEscapeEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )

        controller.attach(panel: panel)
        controller.update(activeState)
        XCTAssertEqual(hotKey.startCount, 1)
        XCTAssertEqual(monitors.localHandlerCount, 1)
        XCTAssertEqual(monitors.globalHandlerCount, 1)

        let local = try XCTUnwrap(monitors.localHandlers.last)
        let global = try XCTUnwrap(monitors.globalHandlers.last)
        XCTAssertTrue(local(commandEscapeEvent) === commandEscapeEvent)
        global(commandEscapeEvent)
        await Task.yield()
        XCTAssertEqual(dismissCount, 0)

        XCTAssertTrue(local(escapeEvent) === escapeEvent)
        await waitUntil { dismissCount == 1 }
        controller.update(.init(
            isVisible: false,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        ))
        controller.update(activeState)
        let currentLocal = try XCTUnwrap(monitors.localHandlers.last)
        let currentGlobal = try XCTUnwrap(monitors.globalHandlers.last)
        XCTAssertTrue(currentLocal(escapeEvent) === escapeEvent)
        panel.cancelOperation(nil)
        await waitUntil { dismissCount == 2 }
        currentGlobal(escapeEvent)
        await Task.yield()
        XCTAssertEqual(dismissCount, 2)

        controller.shutdown()
        XCTAssertEqual(hotKey.stopCount, 3)
        XCTAssertEqual(monitors.removalCount, 4)
    }

    func testTranslationPanelDismissalFallbackRejectsBlockedAndStaleGlobalCallbacks()
        async throws
    {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
            settleTranslationAppKitFixture()
        }
        let hotKey = TranslationPanelEscapeHotKeyLifecycleStub(
            startResult: false
        )
        let monitors = TranslationPanelKeyMonitorRegistrarStub()
        var dismissCount = 0
        let controller = TranslationPanelDismissalController(
            onDismiss: { dismissCount += 1 },
            escapeHotKeyLifecycle: hotKey,
            keyMonitorRegistrar: monitors
        )
        let activeState = TranslationPanelDismissalState(
            isVisible: true,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        )
        let escapeEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )

        controller.attach(panel: panel)
        controller.update(activeState)
        let firstGlobal = try XCTUnwrap(monitors.globalHandlers.last)

        for blockedState in [
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: true,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            ),
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: true,
                isSystemInteractionActive: false,
                isDirectInteractionActive: false
            ),
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: true,
                isDirectInteractionActive: false
            ),
            TranslationPanelDismissalState(
                isVisible: true,
                isPinned: false,
                isSuspended: false,
                isSystemInteractionActive: false,
                isDirectInteractionActive: true
            ),
        ] {
            let removalCount = monitors.removalCount
            controller.update(blockedState)
            XCTAssertEqual(monitors.removalCount, removalCount + 2)
            firstGlobal(escapeEvent)
            await Task.yield()
            XCTAssertEqual(dismissCount, 0)
            controller.update(activeState)
        }

        let staleGlobal = try XCTUnwrap(monitors.globalHandlers.last)
        firstGlobal(escapeEvent)
        await waitUntil { dismissCount == 1 }
        let removalCount = monitors.removalCount
        controller.update(.init(
            isVisible: false,
            isPinned: false,
            isSuspended: false,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        ))
        XCTAssertEqual(monitors.removalCount, removalCount + 2)
        staleGlobal(escapeEvent)
        await Task.yield()
        XCTAssertEqual(dismissCount, 1)

        controller.update(activeState)
        staleGlobal(escapeEvent)
        await Task.yield()
        XCTAssertEqual(dismissCount, 1)

        let currentGlobal = try XCTUnwrap(monitors.globalHandlers.last)
        currentGlobal(escapeEvent)
        await waitUntil { dismissCount == 2 }

        controller.shutdown()
        XCTAssertEqual(hotKey.startCount, 6)
        XCTAssertEqual(hotKey.stopCount, 7)
        XCTAssertEqual(monitors.localHandlerCount, 6)
        XCTAssertEqual(monitors.globalHandlerCount, 6)
        XCTAssertEqual(monitors.removalCount, 12)
        currentGlobal(escapeEvent)
        await Task.yield()
        XCTAssertEqual(dismissCount, 2)
    }

    func testTranslationPanelSourceLayoutKeepsStableCompactGeometry() {
        for source in [
            TranslationInputSource.manual,
            .selection,
            .clipboardRecord,
        ] {
            XCTAssertEqual(
                TranslationPanelSourceLayout.expandedEditorHeight(
                    for: source
                ),
                72
            )
        }
        XCTAssertEqual(
            TranslationPanelSourceLayout.expandedEditorHeight(
                for: .screenshotOCR
            ),
            96
        )

        for source in TranslationInputSource.allCases {
            let expanded =
                TranslationPanelSourceLayout.expandedEditorHeight(
                    for: source
                )
            let collapseRange =
                TranslationPanelSourceLayout.collapseRange(
                    for: source
                )

            XCTAssertEqual(
                TranslationPanelSourceLayout.editorHeight(
                    for: source,
                    scrollOffset: 0
                ),
                expanded
            )
            XCTAssertEqual(
                TranslationPanelSourceLayout.editorHeight(
                    for: source,
                    scrollOffset: collapseRange
                ),
                48
            )
            XCTAssertEqual(
                TranslationPanelSourceLayout.editorHeight(
                    for: source,
                    scrollOffset: collapseRange + 200
                ),
                48
            )
            XCTAssertEqual(
                TranslationPanelSourceLayout.fixedControlsHeight(
                    for: source,
                    scrollOffset: 0
                )
                    - TranslationPanelSourceLayout.fixedControlsHeight(
                        for: source,
                        scrollOffset: collapseRange
                ),
                collapseRange
            )

            XCTAssertEqual(
                TranslationPanelSourceLayout.fixedRegionHeight(
                    for: source,
                    scrollOffset: 0
                )
                    - TranslationPanelSourceLayout.fixedRegionHeight(
                        for: source,
                        scrollOffset: collapseRange
                    ),
                collapseRange
            )
        }

        XCTAssertEqual(
            TranslationPanelSourceLayout.fixedRegionHeight(
                for: .manual,
                scrollOffset: 0
            ),
            196
        )
        XCTAssertEqual(
            TranslationPanelSourceLayout.sourceSectionHeight(
                for: .manual,
                scrollOffset: 0
            ),
            108
        )
        XCTAssertEqual(
            TranslationPanelSourceLayout.fixedRegionHeight(
                for: .manual,
                scrollOffset: 24
            ),
            172
        )
        XCTAssertEqual(
            TranslationPanelSourceLayout.fixedRegionHeight(
                for: .screenshotOCR,
                scrollOffset: 0
            ),
            220
        )
    }

    func testRenderedTranslationPanelPreservesLanguageBarWithTallResults() {
        let capture = TranslationPanelLanguageBarFrameCapture()
        let content = TranslationPanelContentLayout(
            inputSource: .manual,
            sourceContent: { editorHeight in
                VStack(spacing: TranslationPanelSourceLayout.sourceEditorSpacing) {
                    Color.clear.frame(
                        height: TranslationPanelSourceLayout.sourceHeaderHeight
                    )
                    TranslationSourceTextEditor(
                        text: "hello",
                        focusRequest: 0,
                        onTextChange: { _ in }
                    )
                    .frame(height: editorHeight)
                }
            },
            languageContent: {
                TranslationPanelLanguageBarFrameProbe(capture: capture)
                    .frame(height: TranslationPanelSourceLayout.languageBarHeight)
            },
            resultsContent: {
                VStack(spacing: BlocksVisualTokens.Spacing.sm) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        Color.clear.frame(height: 112)
                    }
                }
            }
        )
        .frame(width: 680, height: 260)

        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(
                x: -4_000,
                y: -4_000,
                width: 680,
                height: 260
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        defer {
            window.orderOut(nil)
            window.contentView = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        window.contentView = host
        host.frame = window.contentView!.bounds
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(
            capture.height,
            TranslationPanelSourceLayout.languageBarHeight,
            accuracy: 1,
            "tall result content must compress the results viewport, not the fixed language controls"
        )
    }

    func testTranslationPanelScrollCoordinatorConsumesCollapseBeforeResults() {
        var coordinator = TranslationPanelScrollCoordinator()

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: 12,
                collapseRange: 24,
                resultsAreAtTop: true
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: 12,
                remainingResultsDelta: 0
            )
        )
        XCTAssertEqual(coordinator.resultsOffset, 12)

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: 40,
                collapseRange: 24,
                resultsAreAtTop: true
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: 12,
                remainingResultsDelta: 28
            ),
            "one wheel event must continue into results after the source reaches its minimum height"
        )
        XCTAssertEqual(coordinator.resultsOffset, 24)

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: 5,
                collapseRange: 24,
                resultsAreAtTop: true
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: 0,
                remainingResultsDelta: 5
            ),
            "after collapse, wheel events must reach the results list"
        )

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: -8,
                collapseRange: 24,
                resultsAreAtTop: false
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: 0,
                remainingResultsDelta: -8
            ),
            "the source must not expand while results are scrolled"
        )

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: -8,
                collapseRange: 24,
                resultsAreAtTop: true
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: -8,
                remainingResultsDelta: 0
            )
        )
        XCTAssertEqual(coordinator.resultsOffset, 16)

        XCTAssertEqual(
            coordinator.consume(
                contentDelta: -24,
                collapseRange: 24,
                resultsAreAtTop: true
            ),
            TranslationPanelScrollCoordinator.Consumption(
                sourceDelta: -16,
                remainingResultsDelta: -8
            )
        )
        XCTAssertEqual(coordinator.resultsOffset, 0)
        coordinator.reset()
        XCTAssertEqual(coordinator.resultsOffset, 0)
    }

    func testTranslationDragPayloadUsesNativeItemProviderType() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "translation.drag.\(UUID().uuidString)"
            )
        )
        let payload = TranslationServiceOrderDragPayload(
            serviceID: "community:mymemory"
        )
        let encoded = payload.encodedData()
        let provider = NSItemProvider(
            item: encoded as NSData?,
            typeIdentifier:
                TranslationServiceOrderDragPayload
                    .pasteboardType.rawValue
        )

        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(
                TranslationServiceOrderDragPayload
                    .pasteboardType.rawValue
            )
        )
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                encoded,
                forType:
                    TranslationServiceOrderDragPayload
                        .pasteboardType
            )
        )
        XCTAssertEqual(
            TranslationServiceOrderDragPayload.decode(
                from: pasteboard
            ),
            payload
        )
    }

    func testTranslationCompactActionGeometryIsAppearanceIndependent() {
        func fittingSize(
            appearance: NSAppearance.Name,
            activeState: ControlActiveState = .key
        ) -> NSSize {
            let content = BlocksCompactActionGroup(
                density: .micro,
                reservedSlotCount: 4
            ) {
                ForEach(0 ..< 4, id: \.self) { index in
                    BlocksCompactIconButton(
                        systemImage: "circle",
                        label: "Action \(index)",
                        density: .micro
                    ) {}
                }
            }
            .environment(\.controlActiveState, activeState)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }

        let light = fittingSize(appearance: .aqua)
        let dark = fittingSize(appearance: .darkAqua)
        let inactive = fittingSize(
            appearance: .darkAqua,
            activeState: .inactive
        )

        XCTAssertEqual(light.width, 115, accuracy: 0.5)
        XCTAssertEqual(light.height, 28, accuracy: 0.5)
        XCTAssertEqual(light.width, dark.width, accuracy: 0.5)
        XCTAssertEqual(light.height, dark.height, accuracy: 0.5)
        XCTAssertEqual(light.width, inactive.width, accuracy: 0.5)
        XCTAssertEqual(light.height, inactive.height, accuracy: 0.5)
    }

    func testTranslationPanelGeometryShrinksToNarrowVisibleFrame() {
        let visible = CGRect(x: 100, y: 50, width: 500, height: 410)

        let frame = TranslationPanelGeometry.centeredFrame(
            preferredSize: CGSize(width: 680, height: 640),
            visibleFrame: visible
        )

        XCTAssertEqual(frame.width, 476)
        XCTAssertEqual(frame.height, 386)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 12)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 12)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 12)
    }

    func testTranslationPanelGeometryCentersRegardlessOfSelectionLocation() {
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let size = CGSize(width: 420, height: 300)

        let frame = TranslationPanelGeometry.centeredFrame(
            preferredSize: size,
            visibleFrame: visible
        )
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.midY, visible.midY)
    }

    func testTranslationPanelGeometryCentersOnNegativeOriginScreen() {
        let visible = CGRect(x: -1_400, y: 40, width: 1_300, height: 400)
        let frame = TranslationPanelGeometry.centeredFrame(
            preferredSize: CGSize(width: 360, height: 330),
            visibleFrame: visible
        )

        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.midY, visible.midY)
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            visible.minY + TranslationPanelGeometry.screenInset
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            visible.maxY - TranslationPanelGeometry.screenInset
        )
    }

    func testTranslationEntryScreenContextPreservesFrozenDisplayAcrossAsyncWork() {
        let input = TranslationInput(
            id: "clipboard-entry",
            source: .clipboardRecord,
            text: "fixture",
            createdAt: Date(timeIntervalSince1970: 42),
            context: TranslationInputContext(
                clipboardRecordID: "record-1"
            )
        )

        let resolved = TranslationEntryScreenContext.resolving(
            input,
            frozenDisplayIdentifier: "721"
        )

        XCTAssertEqual(resolved.id, input.id)
        XCTAssertEqual(resolved.createdAt, input.createdAt)
        XCTAssertEqual(
            resolved.context?.clipboardRecordID,
            "record-1"
        )
        XCTAssertEqual(resolved.context?.displayIdentifier, "721")
    }

    func testTranslationEntryScreenContextDoesNotOverrideExplicitCaptureScreen() {
        let input = TranslationInput(
            source: .screenshotOCR,
            text: "",
            context: TranslationInputContext(
                displayIdentifier: "42"
            )
        )

        let resolved = TranslationEntryScreenContext.resolving(
            input,
            frozenDisplayIdentifier: "721"
        )

        XCTAssertEqual(resolved, input)
    }

    func testEmptySelectionFailuresAreSilentButRuntimeFaultsRemainVisible() {
        let silent: [AXSelectionReadFailureReason] = [
            .noFrontmostApplication,
            .blocksIsFrontmost,
            .cancelled,
            .focusedElementUnavailable,
            .selectionUnavailable,
            .emptySelection,
        ]
        let actionable: [AXSelectionReadFailureReason] = [
            .accessibilityPermissionDenied,
            .agentUnavailable,
            .agentInstallationConflict,
            .agentRequiresApproval,
            .agentVersionOutdated,
            .agentConnectionFailed,
            .targetExited,
            .timedOut,
            .selectionTooLarge,
            .passwordField,
        ]

        XCTAssertTrue(
            silent.allSatisfy(
                TranslationSelectionFailurePresentation
                    .isSilentManualInput
            )
        )
        XCTAssertTrue(
            actionable.allSatisfy {
                !TranslationSelectionFailurePresentation
                    .isSilentManualInput($0)
            }
        )
    }

    func testAppStoreSelectionShortcutFallsBackToManualInputWithoutReadingHelper()
        async
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let suiteName =
            "TranslationAppStoreManualFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader,
            distributionChannel: .appStoreBeta
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
        }

        XCTAssertEqual(client.invocationCount, 0)
        let model = try? XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        XCTAssertEqual(model?.inputSource, .manual)
        XCTAssertEqual(model?.selectionReadState, .notApplicable)
        XCTAssertEqual(model?.sourceText, "")
    }

    func testAppStoreSelectionShortcutShowsExternalFallbackFeedback()
        async throws
    {
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { self.target() }
        )
        let notificationPresenter = TranslationNotificationPresenterSpy()
        let suiteName =
            "TranslationAppStoreManualFallbackFeedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var statuses: [AppStatus] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: TranslationStore(defaults: defaults),
            selectionReader: reader,
            distributionChannel: .appStoreBeta,
            notificationPresenter: notificationPresenter
        )
        coordinator.configure(
            statusRecorder: { statuses.append($0) },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(
                    recordID: recordID,
                    purpose: purpose,
                    text: "fixture"
                )
            },
            copyText: { _ in .copiedAndRecorded },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
                && notificationPresenter.presentedDescriptors.count == 1
        }

        XCTAssertEqual(client.invocationCount, 0)
        XCTAssertEqual(
            coordinator.presentedModelsForTesting.first?.inputSource,
            .manual
        )
        let model = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )
        let panel = try XCTUnwrap(
            coordinator.presenters[model.id]?.panelForTesting
        )
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(panel.firstResponder)
        XCTAssertEqual(
            statuses.last?.detail,
            L10n.string("translation.selection.unsupportedChannel.detail")
        )
        let descriptor = try XCTUnwrap(
            notificationPresenter.presentedDescriptors.first
        )
        XCTAssertEqual(descriptor.level, .warning)
        XCTAssertEqual(
            descriptor.detail,
            L10n.string("translation.selection.unsupportedChannel.detail")
        )
        XCTAssertNil(descriptor.action)
    }

    func testPluginHostActionsRejectCrossPanelUnknownAndStaleSessions()
        async throws
    {
        let suiteName =
            "TranslationPluginHostActionIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(defaults: defaults)
        for serviceID in store.enabledServiceIDs {
            store.setServiceEnabled(false, serviceID: serviceID)
        }
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store
        )
        defer { coordinator.closeFloatingPanel() }

        func makeModel(_ text: String) throws
            -> TranslationPanelSessionModel
        {
            let model = TranslationPanelSessionModel(
                input: TranslationInput(source: .manual, text: text),
                direction: TranslationLanguageDirection(
                    target: try XCTUnwrap(
                        TranslationLanguageTag("zh-Hans")
                    )
                ),
                translationStore: store
            )
            model.runImmediately()
            return model
        }

        let first = try makeModel("first")
        let second = try makeModel("second")
        let firstSessionID = try XCTUnwrap(first.snapshot?.id)
        let secondSessionID = try XCTUnwrap(second.snapshot?.id)
        for model in [first, second] {
            coordinator.presenters[model.id] = TranslationPanelPresenter(
                model: model,
                actions: translationPanelActions(),
                onClose: { _ in }
            )
        }
        let context = BlocksPluginHostActionRegistry.Context(
            requestingPluginID: "com.example.translation-isolation",
            causationID: UUID(),
            expectedRevision: 1,
            origin: .explicitUser
        )

        do {
            _ = try await coordinator.performPluginHostAction(
                "translation.cancel",
                context: context,
                input: [
                    "panel_id": .string(first.id.uuidString),
                    "translation_session_id": .string(secondSessionID),
                ]
            )
            XCTFail("A session from another panel must be rejected.")
        } catch {}
        XCTAssertTrue(first.acceptsPluginHostAction(
            translationSessionID: firstSessionID,
            expectedRevision: 1
        ))

        do {
            _ = try await coordinator.performPluginHostAction(
                "translation.cancel",
                context: context,
                input: [
                    "panel_id": .string(UUID().uuidString),
                    "translation_session_id": .string(firstSessionID),
                ]
            )
            XCTFail("An unknown panel must be rejected.")
        } catch {}

        do {
            _ = try await coordinator.performPluginHostAction(
                "translation.cancel",
                context: .init(
                    requestingPluginID:
                        "com.example.translation-isolation",
                    causationID: UUID(),
                    expectedRevision: 0,
                    origin: .explicitUser
                ),
                input: [
                    "panel_id": .string(first.id.uuidString),
                    "translation_session_id": .string(firstSessionID),
                ]
            )
            XCTFail("A stale revision must be rejected.")
        } catch {}

        let accepted = try await coordinator.performPluginHostAction(
            "translation.cancel",
            context: context,
            input: [
                "panel_id": .string(first.id.uuidString),
                "translation_session_id": .string(firstSessionID),
            ]
        )
        XCTAssertEqual(accepted, .bool(true))
        XCTAssertFalse(first.acceptsPluginHostAction(
            translationSessionID: firstSessionID,
            expectedRevision: 1
        ))
    }

    func testPluginTranslationRunRequiresUserInitiatedOriginBeforePresentationOrTransport()
        async throws
    {
        let suiteName = "TranslationPluginRunOrigin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(defaults: defaults)
        let adapter = SelectionCaptureTranslationAdapter()
        store.replacePluginAdapters([adapter])
        for serviceID in store.enabledServiceIDs
            where serviceID != adapter.descriptor.id {
            store.setServiceEnabled(false, serviceID: serviceID)
        }
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store
        )
        defer { coordinator.closeFloatingPanel() }

        XCTAssertFalse(coordinator.showPluginTranslation(
            text: "scheduled",
            origin: .scheduled
        ))
        XCTAssertFalse(coordinator.showPluginTranslation(
            text: "background",
            origin: .background
        ))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.presentedModelsForTesting.isEmpty)
        XCTAssertEqual(adapter.translateCallCount, 0)

        XCTAssertTrue(coordinator.showPluginTranslation(
            text: "explicit user",
            origin: .explicitUser
        ))
        await waitUntil {
            coordinator.presentedModelsForTesting.count == 1
                && adapter.translateCallCount == 1
        }
    }

    func testPluginCopyRequiresUserInitiatedOriginBeforeClipboardWrite()
        async throws
    {
        let suiteName = "TranslationPluginCopyOrigin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranslationStore(defaults: defaults)
        let adapter = SelectionCaptureTranslationAdapter()
        store.replacePluginAdapters([adapter])
        for serviceID in store.enabledServiceIDs
            where serviceID != adapter.descriptor.id {
            store.setServiceEnabled(false, serviceID: serviceID)
        }
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store
        )
        var copiedTexts: [String] = []
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "")
            },
            copyText: { text in
                copiedTexts.append(text)
                return .copiedAndRecorded
            },
            openMainWindow: { _ in }
        )
        defer { coordinator.closeFloatingPanel() }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
            ),
            translationStore: store
        )
        model.runImmediately()
        await waitUntil { model.snapshot?.successfulResults.count == 1 }
        let identity = try XCTUnwrap(model.currentPluginEventIdentity)
        coordinator.presenters[model.id] = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        let input: [String: JSONValue] = [
            "panel_id": .string(model.id.uuidString),
            "translation_session_id": .string(identity.translationSessionID),
        ]

        do {
            _ = try await coordinator.performPluginHostAction(
                "translation.copy",
                context: .init(
                    requestingPluginID: "com.example.translation-copy",
                    causationID: UUID(),
                    expectedRevision: identity.revision,
                    origin: .background
                ),
                input: input
            )
            XCTFail("A background plugin action must not write the clipboard.")
        } catch {}
        XCTAssertTrue(copiedTexts.isEmpty)

        let result = try await coordinator.performPluginHostAction(
            "translation.copy",
            context: .init(
                requestingPluginID: "com.example.translation-copy",
                causationID: UUID(),
                expectedRevision: identity.revision,
                origin: .explicitUser
            ),
            input: input
        )
        XCTAssertEqual(result, .object([
            "copied": .bool(true),
            "history_recorded": .bool(true),
        ]))
        XCTAssertEqual(copiedTexts, ["translated source"])
    }

    func testSelectionPanelIsCenteredOnResolvedScreen() throws {
        let restoreFramePreference =
            preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let suiteName =
            "TranslationSelectionOriginIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(
                forName: suiteName
            )
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .selection, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )

        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertEqual(panel.frame.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, visible.midY, accuracy: 1)
        presenter.close()
    }

    func testTranslationPanelOnlyTakesKeyOnManualPresentation() {
        XCTAssertTrue(
            TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation(
                inputSource: .manual
            )
        )
        XCTAssertFalse(
            TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation(
                inputSource: .selection
            )
        )
        XCTAssertFalse(
            TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation(
                inputSource: .screenshotOCR
            )
        )
        XCTAssertFalse(
            TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation(
                inputSource: .clipboardRecord
            )
        )
    }

    func testTranslationPanelSourceFocusPolicyPreservesExistingKeyPanel() {
        XCTAssertFalse(
            TranslationPanelSourceFocusPolicy.shouldRequestSourceFocus(
                isVisible: true,
                isKeyWindow: true
            )
        )
        XCTAssertTrue(
            TranslationPanelSourceFocusPolicy.shouldRequestSourceFocus(
                isVisible: true,
                isKeyWindow: false
            )
        )
        XCTAssertFalse(
            TranslationPanelSourceFocusPolicy.shouldRequestSourceFocus(
                isVisible: false,
                isKeyWindow: false
            )
        )
    }

    func testSelectionFailureDoesNotActivateTranslationPanel() throws {
        let restoreFramePreference =
            preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let suiteName =
            "TranslationSelectionFailureFocus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .selection, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)

        model.updateSelection(
            .unavailable(
                AXSelectionReadFailure(
                    reason: .emptySelection,
                    target: nil
                )
            )
        )

        XCTAssertFalse(panel.isKeyWindow)
        presenter.close()
    }

    func testCompatibilitySelectionPreservesFrozenMouseAnchor() throws {
        let suiteName =
            "TranslationSelectionAnchor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let frozenAnchor = TranslationInputAnchor(
            x: 340,
            y: 520,
            width: 1,
            height: 1
        )
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .selection,
                text: "",
                context: TranslationInputContext(
                    sourceApplicationBundleID: "com.example.target",
                    sourceApplicationName: "Target",
                    anchor: frozenAnchor
                )
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let target = AXSelectionTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.example.target",
            applicationName: "Target",
            capturedAt: Date()
        )

        model.updateSelection(
            .selected(
                AXSelectionSnapshot(
                    target: target,
                    focusedElement: AXSelectionFocusedElementIdentity(
                        role: "AXWebArea",
                        subrole: nil,
                        identifier: nil,
                        domIdentifier: nil,
                        chromeNodeIdentifier: nil
                    ),
                    selectedText: "compatibility selection",
                    selectedRange: nil,
                    captureStrategy: .focusedElement,
                    candidateDepth: 0,
                    screenBounds: nil,
                    capturedAt: Date()
                )
            )
        )

        XCTAssertEqual(model.inputContext?.anchor, frozenAnchor)
        XCTAssertEqual(
            model.inputContext?.sourceApplicationBundleID,
            "com.example.target"
        )
    }

    func testTranslationPanelStandardCloseCancelsModelExactlyOnce() throws {
        let restoreFramePreference = preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let defaults = UserDefaults(
            suiteName: "TranslationPanelCloseTests.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        model.updateSourceTextFromUser("pending")
        XCTAssertEqual(model.runPhase, .debouncing)
        var closeCount = 0
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in closeCount += 1 }
        )
        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)

        panel.performClose(nil)
        presenter.close()

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(model.runPhase, .idle)
        XCTAssertNil(presenter.panelForTesting)
        settleTranslationAppKitFixture()
    }

    func testTranslationPanelRejectsEveryClosePathDuringAppleSystemInteraction()
        throws
    {
        let restoreFramePreference =
            preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let defaults = UserDefaults(
            suiteName:
                "TranslationPanelSystemInteractionClose.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        var closeCount = 0
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in closeCount += 1 }
        )
        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        let requestID = UUID()
        AppleTranslationSystemInteractionGuard.shared.begin(requestID)
        defer {
            AppleTranslationSystemInteractionGuard.shared.end(requestID)
            presenter.forceClose()
            settleTranslationAppKitFixture()
        }

        panel.cancelOperation(nil)
        panel.performClose(nil)
        presenter.close()

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(closeCount, 0)
        XCTAssertTrue(presenter.panelForTesting === panel)

        AppleTranslationSystemInteractionGuard.shared.end(requestID)
        presenter.close()
        XCTAssertEqual(closeCount, 1)
        XCTAssertNil(presenter.panelForTesting)
    }

    func testTranslationPanelSuspendAndResumePreservesFrameWithoutTakingKey() throws {
        let restoreFramePreference = preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let defaults = UserDefaults(
            suiteName: "TranslationPanelSuspendTests.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .selection, text: "selection"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        let frame = panel.frame

        let suspension = try XCTUnwrap(presenter.suspendForCapture())
        XCTAssertFalse(panel.isVisible)
        presenter.resumeAfterCapture(suspension)

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, frame)
        presenter.close()
        settleTranslationAppKitFixture()
    }

    func testTranslationNotificationUsesSeparateNonKeyChildPanel()
        throws
    {
        let suiteName =
            "TranslationNotificationPanel.\(UUID().uuidString)"
        let defaults = UserDefaults(
            suiteName: suiteName
        )!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        presenter.present()
        let contentPanel = try XCTUnwrap(
            presenter.panelForTesting
        )
        let originalFrame = contentPanel.frame

        presenter.notificationStateForTesting.present(
            BlocksNotificationDescriptor(
                level: .info,
                title: "Reading",
                dismissPolicy: .manual
            )
        )
        let notificationPanel = try XCTUnwrap(
            presenter.notificationPanelForTesting
        )

        XCTAssertEqual(contentPanel.frame, originalFrame)
        XCTAssertTrue(notificationPanel.isVisible)
        XCTAssertFalse(notificationPanel.canBecomeKey)
        XCTAssertTrue(notificationPanel.parent === contentPanel)
        XCTAssertFalse(notificationPanel.frame.intersects(originalFrame))
        presenter.close()
        settleTranslationAppKitFixture()
    }

    func testTranslationPanelRestoresSavedSizeAndRepositionsAcrossScreenOrigin() throws {
        let key = "floatingPanel.translation.center.size"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set([512.0, 444.0], forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let modelDefaults = UserDefaults(
            suiteName: "TranslationPanelSizeTests.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .selection, text: "selection"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: modelDefaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )

        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertEqual(panel.frame.size, CGSize(width: 512, height: 444))

        let visible = CGRect(x: -1_600, y: 40, width: 1_500, height: 900)
        let frame = TranslationPanelGeometry.centeredFrame(
            preferredSize: panel.frame.size,
            visibleFrame: visible
        )
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 12)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 12)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 12)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 12)
        presenter.close()
        settleTranslationAppKitFixture()
    }

    func testManualTranslationPanelIgnoresLegacySavedOriginAndCenters() throws {
        let restoreFramePreference = preserveTranslationPanelFramePreference()
        defer { restoreFramePreference() }
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let savedOrigin = CGPoint(
            x: visible.minX + 48,
            y: visible.minY + 52
        )
        UserDefaults.standard.set(
            [500.0, 420.0],
            forKey: "floatingPanel.translation.center.size"
        )
        UserDefaults.standard.set(
            [Double(savedOrigin.x), Double(savedOrigin.y)],
            forKey: "floatingPanel.translation.center.origin"
        )
        let defaults = UserDefaults(
            suiteName: "TranslationPanelOriginTests.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )

        presenter.present()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        let expected = TranslationPanelGeometry.centeredFrame(
            preferredSize: CGSize(width: 500, height: 420),
            visibleFrame: visible
        )
        XCTAssertEqual(panel.frame, expected)
        presenter.close()
    }

    func testTranslationFavoritesUsesStackedLayoutOnNarrowContent() {
        XCTAssertEqual(
            TranslationFavoritesLayoutMode.resolve(availableWidth: 759),
            .stacked
        )
        XCTAssertEqual(
            TranslationFavoritesLayoutMode.resolve(availableWidth: 760),
            .columns
        )
    }

    func testFavoriteRetranslationRequestRestoresSourceAndLanguageDirection() throws {
        let source = try XCTUnwrap(TranslationLanguageTag("en-US"))
        let target = try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
        let favorite = TranslationFavorite(
            id: "favorite-id",
            sessionID: "original-session",
            sourceText: "Translate this again",
            inputSource: .screenshotOCR,
            sourceLanguage: source,
            targetLanguage: target,
            results: [
                TranslationFavoriteResult(
                    serviceID: "service",
                    serviceDisplayName: "Service",
                    serviceKind: .plugin,
                    translatedText: "重新翻译",
                    sortOrder: 0
                ),
            ],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let request = TranslationFavoriteRetranslationRequest(
            favorite: favorite
        )

        XCTAssertEqual(request.input.source, .screenshotOCR)
        XCTAssertEqual(request.input.text, "Translate this again")
        XCTAssertNil(request.input.context)
        XCTAssertEqual(request.sourceLanguage, source)
        XCTAssertEqual(request.targetLanguage, target)
    }

    func testScreenshotFavoriteRetranslationDoesNotWaitForOCR() {
        let defaults = UserDefaults(
            suiteName: "TranslationFavoriteRetranslationTests.\(UUID().uuidString)"
        )!
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "Saved screenshot text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )

        XCTAssertEqual(model.ocrState, .notApplicable)
        XCTAssertTrue(model.shouldRunOnPresentation)
    }

    func testTranslationSpeechLanguageResolverPreservesBCP47ThenFallsBackToBase() {
        XCTAssertEqual(
            TranslationSpeechLanguageResolver.candidates(
                for: TranslationLanguageTag("zh-Hans")!
            ),
            ["zh-Hans", "zh"]
        )
        XCTAssertEqual(
            TranslationSpeechLanguageResolver.candidates(
                for: TranslationLanguageTag("ja")!
            ),
            ["ja"]
        )
    }

    func testLanguageMenuKeepsCurrentValueOutsideServiceCapabilities() {
        let supported = [TranslationLanguageTag("en")!]
        let current = TranslationLanguageTag("cy")!

        let options = TranslationLanguagePreferences.menuOptions(
            available: supported,
            current: current,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(Set(options), Set(supported + [current]))
        XCTAssertEqual(options.filter { $0 == current }.count, 1)
    }

    func testCompatibilitySelectionRestoresClipboardBeforeReturningText()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "selected text"
        )
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: { 99 },
            postCopyShortcut: { true }
        )

        let result = await service.capture(
            target: target(),
            requestID: UUID()
        )

        XCTAssertEqual(try? result.get(), "selected text")
        let state = await broker.state()
        XCTAssertEqual(state.suppressedChangeCounts, [11])
        XCTAssertEqual(state.writeRequests.count, 1)
        XCTAssertEqual(
            state.writeRequests.first?.expectedChangeCount,
            11
        )
        XCTAssertEqual(
            state.writeRequests.first?.items.first?
                .representations.first?.value,
            .string("original clipboard")
        )
    }

    func testCompatibilitySelectionRestoresClipboardWhenCopiedTextIsEmpty()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "  "
        )
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: { 99 },
            postCopyShortcut: { true }
        )

        let result = await service.capture(
            target: target(),
            requestID: UUID()
        )

        guard case .failure(.selectionUnavailable) = result else {
            return XCTFail("Expected an empty selection failure.")
        }
        let state = await broker.state()
        XCTAssertEqual(state.writeRequests.count, 1)
        XCTAssertEqual(
            state.writeRequests.first?.expectedChangeCount,
            11
        )
    }

    func testCompatibilitySelectionDoesNotOverwriteNewExternalClipboard()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "selected text",
            restorationError: .writeChanged
        )
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: { 99 },
            postCopyShortcut: { true }
        )

        let result = await service.capture(
            target: target(),
            requestID: UUID()
        )

        guard case .failure(.pasteboardChanged) = result else {
            return XCTFail("Expected the external clipboard change to win.")
        }
        let state = await broker.state()
        XCTAssertEqual(state.writeRequests.count, 1)
    }

    func testCompatibilitySelectionCancellationBeforeCopyDoesNotPostShortcut()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "selected text",
            suspendsSnapshot: true
        )
        let copyShortcut = CompatibilitySelectionCopyShortcutRecorder()
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: { 99 },
            postCopyShortcut: { copyShortcut.post() }
        )
        let capture = Task {
            await service.capture(target: self.target(), requestID: UUID())
        }

        await waitUntil { await broker.hasSuspendedSnapshot }
        capture.cancel()
        await broker.resumeSnapshot()

        let result = await capture.value
        guard case .failure = result else {
            return XCTFail("A cancelled capture must fail before Cmd-C.")
        }
        let state = await broker.state()
        let postCopyShortcutCount = await MainActor.run {
            copyShortcut.count
        }
        XCTAssertEqual(postCopyShortcutCount, 0)
        XCTAssertTrue(state.suppressedChangeCounts.isEmpty)
        XCTAssertTrue(state.writeRequests.isEmpty)
    }

    func testCompatibilitySelectionCancellationAtFinalMainActorAdmissionDoesNotPostShortcut()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "selected text"
        )
        let copyShortcut = CompatibilitySelectionCopyShortcutRecorder()
        var capture: Task<
            Result<String, TranslationCompatibilitySelectionFailure>,
            Never
        >?
        var frontmostReadCount = 0
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: {
                frontmostReadCount += 1
                if frontmostReadCount == 2 {
                    capture?.cancel()
                }
                return 99
            },
            postCopyShortcut: { copyShortcut.post() }
        )
        capture = Task {
            await service.capture(target: self.target(), requestID: UUID())
        }

        let result = await capture?.value
        guard case .failure = result else {
            return XCTFail(
                "A task cancelled at final MainActor admission must not post Cmd-C."
            )
        }
        let state = await broker.state()
        XCTAssertEqual(frontmostReadCount, 2)
        XCTAssertEqual(copyShortcut.count, 0)
        XCTAssertTrue(state.suppressedChangeCounts.isEmpty)
        XCTAssertTrue(state.writeRequests.isEmpty)
    }

    func testCompatibilitySelectionCancellationAfterCopyWaitsAndRestores()
        async
    {
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "selected text",
            baselineDelay: .milliseconds(20)
        )
        let copyShortcut = CompatibilitySelectionCopyShortcutRecorder()
        var capture: Task<
            Result<String, TranslationCompatibilitySelectionFailure>,
            Never
        >?
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: { 99 },
            postCopyShortcut: {
                let posted = copyShortcut.post()
                capture?.cancel()
                return posted
            }
        )
        capture = Task {
            await service.capture(target: self.target(), requestID: UUID())
        }

        // waitUntil has a one-second watchdog. The broker exposes the new
        // change count only after Cmd-C's bounded cleanup has started.
        await waitUntil { await broker.state().writeRequests.count == 1 }
        let result = await capture?.value

        XCTAssertEqual(try? result?.get(), "selected text")
        XCTAssertEqual(copyShortcut.count, 1)
        let state = await broker.state()
        XCTAssertEqual(state.writeRequests.count, 1)
        XCTAssertEqual(
            state.writeRequests.first?.expectedChangeCount,
            11
        )
        XCTAssertEqual(
            state.writeRequests.first?.items.first?
                .representations.first?.value,
            .string("original clipboard")
        )
    }

    func testAuthorizedCompatibilityFallbackDoesNotTrustUnattributedClipboardChange()
        async throws
    {
        let suiteName =
            "TranslationCompatibilityFailClosed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let target = target()
        let authorizationStore =
            TranslationCompatibilitySelectionAuthorizationStore(
                defaults: defaults
            )
        authorizationStore.authorize(
            bundleIdentifier: target.bundleIdentifier
        )
        let broker = CompatibilitySelectionBrokerStub(
            capturedText: "unrelated background clipboard text"
        )
        let service = TranslationCompatibilitySelectionService(
            broker: broker,
            frontmostProcessIdentifier: {
                XCTFail(
                    "An unverifiable compatibility fallback must not post Cmd-C."
                )
                return target.processIdentifier
            },
            postCopyShortcut: {
                XCTFail(
                    "An unverifiable compatibility fallback must not post Cmd-C."
                )
                return true
            }
        )
        let client = ControlledAXSelectionSystemClient()
        let reader = AXSelectionReader(
            systemClient: client,
            ownBundleIdentifier: "app.blocks",
            frontmostTargetProvider: { target }
        )
        let adapter = SelectionCaptureTranslationAdapter()
        let registry = TranslationServiceRegistry()
        let store = TranslationStore(
            defaults: defaults,
            serviceRegistry: registry
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(
            true,
            serviceID: adapter.descriptor.id
        )
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store,
            selectionReader: reader,
            compatibilitySelectionService: service,
            compatibilitySelectionAuthorizationStore:
                authorizationStore
        )
        defer { coordinator.closeFloatingPanel() }

        coordinator.showSmartSelectionPanel()
        await waitUntil {
            client.invocationCount == 1
                && coordinator.activeSelectionCaptureCountForTesting == 1
        }
        let model = try XCTUnwrap(
            coordinator.presentedModelsForTesting.first
        )

        client.finish(
            invocation: 0,
            result: .failure(.selectionUnavailable)
        )
        await waitUntil {
            model.selectionReadState
                == .unavailable(.selectionUnavailable)
                && coordinator.activeSelectionCaptureCountForTesting == 0
        }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(
            authorizationStore.isAuthorized(
                bundleIdentifier: target.bundleIdentifier
            )
        )
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(adapter.translateCallCount, 0)
        let state = await broker.state()
        XCTAssertTrue(state.suppressedChangeCounts.isEmpty)
        XCTAssertTrue(state.writeRequests.isEmpty)

        model.updateSourceTextFromUser("explicit user text")
        await waitUntil { adapter.translateCallCount == 1 }
    }

    private func target() -> AXSelectionTarget {
        AXSelectionTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.example.target",
            applicationName: "Target",
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeSelectionHelperBundle(at url: URL) throws {
        let contents = url.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier":
                BlocksSelectionHelperProtocol.bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Blocks Selection Helper",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(
            to: contents.appendingPathComponent("Info.plist")
        )
    }

    private func assertSelectionHelperKeychainQuery(
        _ query: [String: Any],
        service: String,
        account: String
    ) {
        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            "test.access-group"
        )
        XCTAssertEqual(
            query[kSecUseDataProtectionKeychain as String] as? Bool,
            true
        )
    }

    private func selectionHelperFixtureLocator(
        candidates: [URL],
        running: [URL] = []
    ) -> SelectionHelperApplicationLocator {
        SelectionHelperApplicationLocator(
            candidateURLsProvider: { candidates },
            runningApplicationURLsProvider: { running },
            allowedApplicationURLsProvider: { candidates },
            identityVerifier: SelectionHelperBundleIdentityVerifierStub(
                teamID: "TESTTEAM01"
            ),
            trustedHostTeamIdentifierProvider: { "TESTTEAM01" }
        )
    }

    private func translationPanelActions() -> TranslationPanelActions {
        TranslationPanelActions(
            copyText: { _ in .copiedAndRecorded },
            openFavorites: {},
            openTranslationSettings: {},
            retakeScreenshot: {}
        )
    }

    private func preserveTranslationPanelFramePreference() -> () -> Void {
        let keys = [
            "floatingPanel.translation.center.size",
            "floatingPanel.translation.center.origin",
        ]
        let defaults = UserDefaults.standard
        var previous: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                previous[key] = value
            }
        }
        keys.forEach(defaults.removeObject)
        return ({
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        })
    }

    private func settleTranslationAppKitFixture() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func makeScreenshotCapture(sourceRect: CGRect) throws -> ScreenshotCapture {
        let width = max(1, Int(sourceRect.width.rounded()))
        let height = max(1, Int(sourceRect.height.rounded()))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try XCTUnwrap(context.makeImage())
        return ScreenshotCapture(
            id: "translation-capture",
            image: NSImage(cgImage: cgImage, size: CGSize(width: width, height: height)),
            pixelSize: CGSize(width: width, height: height),
            sourceRect: sourceRect,
            kind: .region,
            displayScope: nil,
            sourceSummary: "translation fixture"
        )
    }

    private func makeTranslationCapture(
        sourceRect: CGRect,
        displayID: UInt32? = nil
    ) throws -> TranslationScreenshotCapture {
        let capture = try makeScreenshotCapture(sourceRect: sourceRect)
        let cgImage = try XCTUnwrap(
            capture.image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        return TranslationScreenshotCapture(
            image: capture.image,
            cgImage: cgImage,
            logicalRect: sourceRect,
            pixelSize: capture.pixelSize,
            screen: displayID.map {
                TranslationScreenshotScreen(
                    displayID: $0,
                    frame: CGRect(
                        x: sourceRect.minX - 100,
                        y: sourceRect.minY - 100,
                        width: 1_000,
                        height: 800
                    ),
                    visibleFrame: CGRect(
                        x: sourceRect.minX - 100,
                        y: sourceRect.minY - 76,
                        width: 1_000,
                        height: 776
                    ),
                    backingScaleFactor: 2
                )
            }
        )
    }

    private func waitUntilSelectionIsActive(
        _ controller: ScreenshotSelectionController
    ) async {
        for _ in 0..<100 where !controller.selectionActiveForTesting {
            await Task.yield()
        }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

}

@MainActor
private final class TranslationNotificationPresenterSpy:
    BlocksNotificationPanelPresenting
{
    private(set) var presentedDescriptors: [BlocksNotificationDescriptor] = []

    func present(
        _ descriptor: BlocksNotificationDescriptor,
        on _: NSScreen?,
        avoiding _: [CGRect]
    ) {
        presentedDescriptors.append(descriptor)
    }

    func dismiss() {}

    func shutdown() {}
}

@MainActor
private final class TranslationPanelEscapeHotKeyLifecycleStub:
    TranslationPanelEscapeHotKeyLifecycle
{
    let startResult: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startResult: Bool) {
        self.startResult = startResult
    }

    @discardableResult
    func start() -> Bool {
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class TranslationPanelKeyMonitorRegistrarStub:
    TranslationPanelKeyMonitorRegistering
{
    private final class Token {}

    private(set) var localHandlers: [(NSEvent) -> NSEvent?] = []
    private(set) var globalHandlers: [(NSEvent) -> Void] = []
    private(set) var removalCount = 0

    var localHandlerCount: Int { localHandlers.count }
    var globalHandlerCount: Int { globalHandlers.count }

    func addLocalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        localHandlers.append(handler)
        return Token()
    }

    func addGlobalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        globalHandlers.append(handler)
        return Token()
    }

    func removeMonitor(_: Any) {
        removalCount += 1
    }
}

private actor CompatibilitySelectionBrokerStub:
    ClipboardBrokerServing
{
    struct State: Sendable {
        let suppressedChangeCounts: [Int]
        let writeRequests: [ClipboardBrokerWriteRequest]
    }

    private let capturedText: String?
    private let restorationError: ClipboardBrokerClientError?
    private let suspendsSnapshot: Bool
    private let baselineDelay: Duration?
    private var suppressed: [Int] = []
    private var writes: [ClipboardBrokerWriteRequest] = []
    private var snapshotSuspension: CheckedContinuation<Void, Never>?

    init(
        capturedText: String?,
        restorationError: ClipboardBrokerClientError? = nil,
        suspendsSnapshot: Bool = false,
        baselineDelay: Duration? = nil
    ) {
        self.capturedText = capturedText
        self.restorationError = restorationError
        self.suspendsSnapshot = suspendsSnapshot
        self.baselineDelay = baselineDelay
    }

    func baseline() async throws -> Int {
        if let baselineDelay {
            try? await Task.sleep(for: baselineDelay)
        }
        return 11
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .noChange,
            changeCount: request.baselineChangeCount ?? 11,
            observedAfterChangeCount:
                request.baselineChangeCount ?? 11
        )
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        writes.append(request)
        if let restorationError {
            throw restorationError
        }
        return ClipboardPasteboardWriteLease(
            changeCount: 12,
            brokerGeneration: 0
        )
    }

    func validate(_: ClipboardPasteboardWriteLease) async -> Bool {
        true
    }

    func currentPlainText(
        limit _: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        ClipboardBrokerPlainTextResult(
            text: capturedText,
            originalCharacterCount: capturedText?.count ?? 0,
            truncated: false,
            changeCount: 11
        )
    }

    func snapshot() async throws -> ClipboardBrokerSnapshotResult {
        if suspendsSnapshot {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        snapshotSuspension = continuation
                    }
                }
            } onCancel: {
                Task { await self.resumeSnapshot() }
            }
        }
        return ClipboardBrokerSnapshotResult(
            status: .captured,
            changeCount: 10,
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType:
                            NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("original clipboard")
                    ),
                ]),
            ]
        )
    }

    func suppressExternalChangeCounts(
        _ changeCounts: [Int]
    ) async {
        suppressed.append(contentsOf: changeCounts)
    }

    func shutdown() async {}

    var hasSuspendedSnapshot: Bool {
        snapshotSuspension != nil
    }

    func resumeSnapshot() {
        let continuation = snapshotSuspension
        snapshotSuspension = nil
        continuation?.resume()
    }

    func state() -> State {
        State(
            suppressedChangeCounts: suppressed,
            writeRequests: writes
        )
    }
}

@MainActor
private final class CompatibilitySelectionCopyShortcutRecorder {
    private(set) var count = 0

    func post() -> Bool {
        count += 1
        return true
    }
}

private actor TranslationClipboardBrokerStub: ClipboardBrokerServing {
    private let plainTextResult: ClipboardBrokerPlainTextResult
    private let writeFails: Bool
    private var plainTextLimits: [Int] = []
    private var writes: [ClipboardBrokerWriteRequest] = []

    init(
        plainTextResult: ClipboardBrokerPlainTextResult = ClipboardBrokerPlainTextResult(
            text: nil,
            originalCharacterCount: 0,
            truncated: false,
            changeCount: 0
        ),
        writeFails: Bool = false
    ) {
        self.plainTextResult = plainTextResult
        self.writeFails = writeFails
    }

    func baseline() async throws -> Int {
        plainTextResult.changeCount
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .skipped,
            changeCount: request.baselineChangeCount ?? 0,
            observedAfterChangeCount: request.baselineChangeCount ?? 0,
            skipReason: .unsupported,
            prefilterDisposition: request.prefilterDisposition
        )
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        writes.append(request)
        if writeFails {
            throw ClipboardBrokerClientError.writeFailed
        }
        return ClipboardPasteboardWriteLease(
            changeCount: plainTextResult.changeCount + 1,
            brokerGeneration: 1
        )
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        lease.brokerGeneration == 1
    }

    func currentPlainText(
        limit: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        plainTextLimits.append(limit)
        return plainTextResult
    }

    func shutdown() async {}

    func requestedPlainTextLimits() -> [Int] {
        plainTextLimits
    }

    func writeRequestCount() -> Int {
        writes.count
    }
}

private final class ControlledSelectionAgentCaptureTransport:
    SelectionHelperCaptureTransport,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var storedSelectedText: String
    private var storedCaptureCount = 0
    private var storedLastTarget: AXSelectionTarget?
    private var captureStarted = false
    private var captureReleased = false
    private var cancellationFinished = false
    private let cancellationDelay: TimeInterval

    init(
        selectedText: String,
        cancellationDelay: TimeInterval = 0
    ) {
        storedSelectedText = selectedText
        self.cancellationDelay = cancellationDelay
    }

    var selectedText: String {
        get { condition.withLock { storedSelectedText } }
        set { condition.withLock { storedSelectedText = newValue } }
    }

    var captureCount: Int {
        condition.withLock { storedCaptureCount }
    }

    var lastTarget: AXSelectionTarget? {
        condition.withLock { storedLastTarget }
    }

    func capture(
        target: AXSelectionTarget,
        requestID _: String,
        timeout _: TimeInterval,
        maximumCharacters _: Int
    ) -> AXSelectionElementReadResult {
        condition.lock()
        storedCaptureCount += 1
        storedLastTarget = target
        let frozenText = storedSelectedText
        captureStarted = true
        condition.broadcast()
        while !captureReleased {
            condition.wait()
        }
        condition.unlock()
        return .element(AXSelectionElementSnapshot(
            role: "AXTextArea",
            subrole: nil,
            selectedText: frozenText,
            selectedRange: NSRange(
                location: 0,
                length: frozenText.count
            ),
            accessibilityScreenBounds: nil
        ))
    }

    func cancel(
        requestID _: String,
        timeout _: TimeInterval
    ) {
        if cancellationDelay > 0 {
            Thread.sleep(forTimeInterval: cancellationDelay)
        }
        condition.withLock {
            captureReleased = true
            cancellationFinished = true
            condition.broadcast()
        }
    }

    func requestPermission(
        timeout _: TimeInterval
    ) -> Result<Bool, SelectionAgentServiceFailure> {
        .success(true)
    }

    func releaseCapture() {
        condition.withLock {
            captureReleased = true
            condition.broadcast()
        }
    }

    func waitForCaptureStart(
        timeout: TimeInterval = 1
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !captureStarted {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func waitForCancellation(
        timeout: TimeInterval = 1
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancellationFinished {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }
}

private final class SelectionHelperKeyStoreStub:
    SelectionHelperSharedKeyStoring
{
    private var storedKey: Data?
    private let loadDelay: TimeInterval
    private(set) var deleteCount = 0

    init(
        key: Data? = nil,
        legacyKey _: Data? = nil,
        loadDelay: TimeInterval = 0
    ) {
        storedKey = key
        self.loadDelay = loadDelay
    }

    func load() -> Data? {
        if loadDelay > 0 {
            Thread.sleep(forTimeInterval: loadDelay)
        }
        return storedKey
    }

    func save(_ data: Data) throws {
        storedKey = data
    }

    func delete() {
        deleteCount += 1
        storedKey = nil
    }
}

private final class SelectionHelperBootstrapKeyStoreStub:
    SelectionHelperBootstrapKeyCreating
{
    private var storedKey: Data?

    init(key: Data? = nil) {
        storedKey = key
    }

    func load() -> Data? {
        storedKey
    }

    func createOrLoad() -> Data? {
        storedKey
    }
}

private final class SelectionHelperDisconnectRecoveryStoreStub:
    SelectionHelperDisconnectRecoveryStoring
{
    var deadline: Date?

    func loadDeadline() -> Date? {
        deadline
    }

    func save(deadline: Date) {
        self.deadline = deadline
    }

    func clear() {
        deadline = nil
    }
}

private final class SelectionHelperAuthenticatedConnectionStub:
    SelectionHelperLoopbackConnecting
{
    private var key: Data
    private var disconnectResults:
        [Result<Bool, SelectionAgentServiceFailure>]
    private let helperRemovesKeyBeforeFailedDisconnectRequests: Set<Int>
    private let pairResult: Result<Data, SelectionAgentServiceFailure>
    private let pairResponder: (
        (SelectionHelperPairRequest) -> Result<Data, SelectionAgentServiceFailure>
    )?
    private let pairingKeyProvider: ((SelectionHelperPairRequest) -> Data?)?
    private let health: SelectionHelperHealth?
    private let authenticatedResponder: (
        (SelectionHelperCommand) -> Result<
            SelectionHelperCommandResponse,
            SelectionAgentServiceFailure
        >
    )?
    private let delayForCommand: (SelectionHelperCommand) -> TimeInterval
    private let ignoresTimeoutForCommand: (SelectionHelperCommand) -> Bool
    private(set) var disconnectRequestCount = 0
    private(set) var authenticatedRequestCount = 0
    private(set) var authenticatedCommands: [SelectionHelperCommand] = []
    private(set) var pairRequestCount = 0
    private(set) var pairPackets: [SelectionHelperWirePacket] = []
    private(set) var helperStillHasKey = true
    private(set) var hasDisconnectTombstone = false
    private(set) var rejectedTombstoneCommands:
        [SelectionHelperCommandKind] = []

    init(
        key: Data,
        disconnectResult: Result<Bool, SelectionAgentServiceFailure>,
        disconnectResults: [
            Result<Bool, SelectionAgentServiceFailure>
        ]? = nil,
        helperRemovesKeyBeforeFailedDisconnectRequests: Set<Int> = [],
        pairResult: Result<Data, SelectionAgentServiceFailure> =
            .failure(.invalidResponse),
        pairResponder: (
            (SelectionHelperPairRequest) -> Result<Data, SelectionAgentServiceFailure>
        )? = nil,
        pairingKeyProvider: ((SelectionHelperPairRequest) -> Data?)? = nil,
        health: SelectionHelperHealth? = nil,
        authenticatedResponder: (
            (SelectionHelperCommand) -> Result<
                SelectionHelperCommandResponse,
                SelectionAgentServiceFailure
            >
        )? = nil,
        delayForCommand: @escaping (SelectionHelperCommand) -> TimeInterval = {
            _ in 0
        },
        ignoresTimeoutForCommand: @escaping (SelectionHelperCommand) -> Bool = {
            _ in false
        }
    ) {
        self.key = key
        self.disconnectResults = disconnectResults ?? [disconnectResult]
        self.helperRemovesKeyBeforeFailedDisconnectRequests =
            helperRemovesKeyBeforeFailedDisconnectRequests
        self.pairResult = pairResult
        self.pairResponder = pairResponder
        self.pairingKeyProvider = pairingKeyProvider
        self.health = health
        self.authenticatedResponder = authenticatedResponder
        self.delayForCommand = delayForCommand
        self.ignoresTimeoutForCommand = ignoresTimeoutForCommand
    }

    func send(
        _ packet: SelectionHelperWirePacket,
        timeout: TimeInterval
    ) -> Result<Data, SelectionAgentServiceFailure> {
        guard packet.kind == .authenticated else {
            pairRequestCount += 1
            pairPackets.append(packet)
            guard let pairResponder,
                  let request = try? JSONDecoder().decode(
                    SelectionHelperPairRequest.self,
                    from: packet.payload
                  ) else {
                return pairResult
            }
            let result = pairResponder(request)
            if let pairedKey = pairingKeyProvider?(request) {
                // A lost response does not roll back a Helper-side key
                // commit. Keeping this key before the retry makes the stub
                // exercise the real one-sided reply-loss boundary.
                key = pairedKey
            }
            return result
        }
        authenticatedRequestCount += 1
        guard let envelope = try? JSONDecoder().decode(
            SelectionHelperSealedMessage.self,
            from: packet.payload
        ), let command = try? SelectionHelperAuthenticatedCodec.open(
            SelectionHelperCommand.self,
            from: envelope,
            keyData: key
        ) else {
            return .failure(.invalidResponse)
        }
        authenticatedCommands.append(command)
        let delay = max(0, delayForCommand(command))
        if delay > 0 {
            let boundedDelay = ignoresTimeoutForCommand(command)
                ? delay : min(delay, max(0, timeout))
            Thread.sleep(forTimeInterval: boundedDelay)
            if delay > timeout, !ignoresTimeoutForCommand(command) {
                return .failure(.timedOut)
            }
        }
        if hasDisconnectTombstone,
           command.kind != .disconnect {
            rejectedTombstoneCommands.append(command.kind)
            return .failure(.connectionFailed)
        }
        if command.kind == .health,
           let health {
            return sealedResponse(
                SelectionHelperCommandResponse(health: health),
                requestID: envelope.requestID
            )
        }
        if let authenticatedResponder {
            switch authenticatedResponder(command) {
            case let .success(response):
                return sealedResponse(
                    response,
                    requestID: envelope.requestID
                )
            case let .failure(failure):
                return .failure(failure)
            }
        }
        guard command.kind == .disconnect else {
            return .failure(.invalidResponse)
        }
        disconnectRequestCount += 1
        let result: Result<Bool, SelectionAgentServiceFailure>
        if disconnectResults.count > 1 {
            result = disconnectResults.removeFirst()
        } else {
            result = disconnectResults.first ?? .failure(.connectionFailed)
        }

        switch result {
        case let .failure(failure):
            if helperRemovesKeyBeforeFailedDisconnectRequests.contains(
                disconnectRequestCount
            ) {
                helperStillHasKey = false
                hasDisconnectTombstone = true
            }
            return .failure(failure)
        case let .success(confirmed):
            if confirmed {
                helperStillHasKey = false
                hasDisconnectTombstone = true
            }
            return sealedResponse(
                SelectionHelperCommandResponse(booleanValue: confirmed),
                requestID: envelope.requestID
            )
        }
    }

    private func sealedResponse(
        _ response: SelectionHelperCommandResponse,
        requestID: String
    ) -> Result<Data, SelectionAgentServiceFailure> {
        guard let sealed = try? SelectionHelperAuthenticatedCodec.seal(
            response,
            requestID: requestID,
            expiresAt: Date().addingTimeInterval(1),
            keyData: key
        ), let payload = try? JSONEncoder().encode(sealed),
          let data = try? JSONEncoder().encode(
            SelectionHelperWirePacket(
                kind: .authenticated,
                payload: payload
            )
          ) else {
            return .failure(.invalidResponse)
        }
        return .success(data)
    }
}

private final class AXSelectionSystemClientStub:
    AXSelectionSystemClient,
    @unchecked Sendable
{
    let accessibilityTrusted: Bool
    let defersAccessibilityTrustEvaluation: Bool
    private let lock = NSLock()
    private var storedElementResult: AXSelectionElementReadResult
    private var storedFreezeCount = 0
    private var storedReadCount = 0

    init(
        accessibilityTrusted: Bool = true,
        defersAccessibilityTrustEvaluation: Bool = false,
        elementResult: AXSelectionElementReadResult
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.defersAccessibilityTrustEvaluation =
            defersAccessibilityTrustEvaluation
        storedElementResult = elementResult
    }

    var elementResult: AXSelectionElementReadResult {
        get {
            lock.withLock { storedElementResult }
        }
        set {
            lock.withLock { storedElementResult = newValue }
        }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    var freezeCount: Int {
        lock.withLock { storedFreezeCount }
    }

    func readSelection(
        from _: AXSelectionTarget
    ) -> AXSelectionElementReadResult {
        lock.withLock {
            storedReadCount += 1
            return storedElementResult
        }
    }

    func freezeSelection(
        from _: AXSelectionTarget,
        requestID _: String
    ) -> AXSelectionElementReadToken? {
        let frozenResult = lock.withLock {
            storedFreezeCount += 1
            return storedElementResult
        }
        return AXSelectionElementReadToken { [self] in
            lock.withLock {
                storedReadCount += 1
                return frozenResult
            }
        }
    }
}

private final class ControlledAXSelectionSystemClient:
    AXSelectionSystemClient,
    @unchecked Sendable
{
    let accessibilityTrusted = true
    private let condition = NSCondition()
    private var completed: [Int: AXSelectionElementReadResult] = [:]
    private var completedFreezes: [Int: Bool] = [:]
    private var nextFreezeInvocation = 0
    private var startedReadInvocations: Set<Int> = []
    private var cancelledReadInvocations: Set<Int> = []
    private var observedReadOnMainThread = false
    private var observedFreezeOnMainThread = false
    private let holdsFreeze: Bool

    init(holdsFreeze: Bool = false) {
        self.holdsFreeze = holdsFreeze
    }

    var invocationCount: Int {
        condition.withLock { startedReadInvocations.count }
    }

    var freezeInvocationCount: Int {
        condition.withLock { nextFreezeInvocation }
    }

    var cancelInvocationCount: Int {
        condition.withLock { cancelledReadInvocations.count }
    }

    var readObservedMainThread: Bool {
        condition.withLock { observedReadOnMainThread }
    }

    var freezeObservedMainThread: Bool {
        condition.withLock { observedFreezeOnMainThread }
    }

    func readSelection(
        from _: AXSelectionTarget
    ) -> AXSelectionElementReadResult {
        readFrozenSelection(invocation: 0)
    }

    private func readFrozenSelection(
        invocation: Int
    ) -> AXSelectionElementReadResult {
        condition.lock()
        observedReadOnMainThread =
            observedReadOnMainThread || Thread.isMainThread
        startedReadInvocations.insert(invocation)
        condition.broadcast()
        while completed[invocation] == nil {
            condition.wait()
        }
        let result = completed.removeValue(forKey: invocation)!
        condition.unlock()
        return result
    }

    func freezeSelection(
        from _: AXSelectionTarget,
        requestID _: String
    ) -> AXSelectionElementReadToken? {
        condition.lock()
        observedFreezeOnMainThread =
            observedFreezeOnMainThread || Thread.isMainThread
        let invocation = nextFreezeInvocation
        nextFreezeInvocation += 1
        condition.broadcast()
        if holdsFreeze {
            while completedFreezes[invocation] == nil {
                condition.wait()
            }
            let succeeded =
                completedFreezes.removeValue(forKey: invocation) ?? false
            condition.unlock()
            guard succeeded else { return nil }
        } else {
            condition.unlock()
        }
        return AXSelectionElementReadToken { [self] in
            readFrozenSelection(invocation: invocation)
        } canceller: { [self] in
            cancelFrozenSelection(invocation: invocation)
        }
    }

    private func cancelFrozenSelection(invocation: Int) {
        condition.withLock {
            guard cancelledReadInvocations.insert(invocation).inserted else {
                return
            }
            condition.broadcast()
        }
    }

    func finishFreeze(
        invocation: Int,
        succeeds: Bool = true
    ) {
        condition.withLock {
            completedFreezes[invocation] = succeeds
            condition.broadcast()
        }
    }

    func finish(
        invocation: Int,
        result: AXSelectionElementReadResult
    ) {
        condition.withLock {
            completed[invocation] = result
            condition.broadcast()
        }
    }
}

private actor TranslationOCRRecognitionRecorder {
    private var imageSize: CGSize?
    private var requestToken: LocalVisionOCRRequestToken?

    func record(
        imageSize: CGSize,
        requestToken: LocalVisionOCRRequestToken
    ) {
        self.imageSize = imageSize
        self.requestToken = requestToken
    }

    func invocation() -> (
        imageSize: CGSize?,
        requestToken: LocalVisionOCRRequestToken?
    ) {
        (imageSize, requestToken)
    }
}

private actor ControlledTranslationOCRProvider: TranslationScreenshotOCRProviding {
    private var pending: [
        Int: CheckedContinuation<TranslationScreenshotOCRSnapshot, Error>
    ] = [:]
    private var requestTokens: [Int: LocalVisionOCRRequestToken] = [:]

    func recognizeText(
        in capture: TranslationScreenshotCapture,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> TranslationScreenshotOCRSnapshot {
        let key = Int(capture.logicalRect.minX.rounded())
        requestTokens[key] = requestToken
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = continuation
        }
    }

    func pendingKeys() -> Set<Int> {
        Set(pending.keys)
    }

    func isCancelled(key: Int) -> Bool {
        requestTokens[key]?.isCancelled == true
    }

    func finish(key: Int, text: String) {
        requestTokens.removeValue(forKey: key)
        pending.removeValue(forKey: key)?.resume(
            returning: TranslationScreenshotOCRSnapshot(
                text: text,
                lineCount: 1,
                meanConfidence: 1
            )
        )
    }

    func fail(key: Int, error: Error) {
        requestTokens.removeValue(forKey: key)
        pending.removeValue(forKey: key)?.resume(throwing: error)
    }
}

private actor TranslationAttachmentEncodingRecorder {
    private var calls = 0

    func increment() {
        calls += 1
    }

    func reset() {
        calls = 0
    }

    func count() -> Int {
        calls
    }
}

@MainActor
private final class ScreenshotPluginEventTranslationAdapter:
    TranslationServiceAdapter
{
    let descriptor = TranslationServiceDescriptor(
        id: "plugin:screenshot-event-fixture",
        displayName: "Screenshot Event Fixture",
        kind: .plugin,
        availability: .available,
        supportsStreaming: false
    )

    let acceptedInputs: Set<TranslationSourceAcceptedInput> = [
        .text,
        .screenshotImage,
    ]

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .completed("translated \(request.input.text)", warnings: [])
            )
            continuation.finish()
        }
    }
}

@MainActor
private final class SelectionCaptureTranslationAdapter: TranslationServiceAdapter {
    let descriptor = TranslationServiceDescriptor(
        id: "plugin:selection-capture-fixture",
        displayName: "Selection Capture Fixture",
        kind: .plugin,
        availability: .available,
        supportsStreaming: false
    )

    let acceptedInputs: Set<TranslationSourceAcceptedInput> = [.text]
    private(set) var translateCallCount = 0

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        translateCallCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .completed("translated \(request.input.text)", warnings: [])
            )
            continuation.finish()
        }
    }
}

private actor ControlledClipboardTranslationReader {
    private var continuation:
        CheckedContinuation<ClipboardTextReadResult, Never>?
    private var recordID = ""
    private var purpose = ClipboardPayloadReadPurpose.translationPreview

    var hasPendingRead: Bool {
        continuation != nil
    }

    func read(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose
    ) async -> ClipboardTextReadResult {
        self.recordID = recordID
        self.purpose = purpose
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(text: String) {
        let pending = continuation
        continuation = nil
        pending?.resume(
            returning: .success(
                recordID: recordID,
                purpose: purpose,
                text: text
            )
        )
    }
}

@MainActor
private final class ControlledTranslationScreenshotCaptureProvider:
    TranslationScreenshotCaptureProviding
{
    private var continuation:
        CheckedContinuation<TranslationScreenshotCapture, Error>?
    private(set) var cancelCount = 0

    var hasPendingCapture: Bool {
        continuation != nil
    }

    func captureRegion() async throws -> TranslationScreenshotCapture {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancelCurrentCapture() {
        cancelCount += 1
    }

    func succeed(with capture: TranslationScreenshotCapture) {
        continuation?.resume(returning: capture)
        continuation = nil
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum TranslationEntryTestError: Error {
    case fixtureFailure
}

@MainActor
private final class TranslationScreenshotCaptureServiceStub: ScreenshotPurposeCapturing {
    let capture: ScreenshotCapture
    private(set) var receivedIntent: ScreenshotCaptureIntent?
    private(set) var receivedRequiresEditingContext: Bool?
    private(set) var receivedPurpose: ScreenshotCapturePurpose?
    private(set) var cancelCount = 0

    init(capture: ScreenshotCapture) {
        self.capture = capture
    }

    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        receivedIntent = intent
        receivedRequiresEditingContext = requiresEditingContext
        receivedPurpose = purpose
        return capture
    }

    func cancelCurrentCapture() {
        cancelCount += 1
    }
}

@MainActor
private final class TranslationScreenshotCaptureFailureServiceStub:
    ScreenshotPurposeCapturing
{
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func capture(
        intent _: ScreenshotCaptureIntent,
        requiresEditingContext _: Bool,
        purpose _: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        throw error
    }

    func cancelCurrentCapture() {}
}

@MainActor
private final class StagedPurposeCaptureService:
    ScreenshotPurposeCapturing
{
    private let captureResult: ScreenshotCapture
    private let suspendsPurpose: ScreenshotCapturePurpose
    private var continuation: CheckedContinuation<Void, Never>?
    private var pendingPurpose: ScreenshotCapturePurpose?
    private var activeCaptureCount = 0

    private(set) var cancelCount = 0
    private(set) var receivedPurposes: [ScreenshotCapturePurpose] = []
    private(set) var enteredSelectionPurposes:
        [ScreenshotCapturePurpose] = []
    private(set) var maximumConcurrentCaptures = 0

    var translationLoadIsPending: Bool {
        continuation != nil && pendingPurpose == .translationOCR
    }

    var standardLoadIsPending: Bool {
        continuation != nil && pendingPurpose == .standard
    }

    init(
        capture: ScreenshotCapture,
        suspendsPurpose: ScreenshotCapturePurpose = .translationOCR
    ) {
        captureResult = capture
        self.suspendsPurpose = suspendsPurpose
    }

    func capture(
        intent _: ScreenshotCaptureIntent,
        requiresEditingContext _: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        receivedPurposes.append(purpose)
        activeCaptureCount += 1
        maximumConcurrentCaptures = max(
            maximumConcurrentCaptures,
            activeCaptureCount
        )
        defer { activeCaptureCount -= 1 }

        if purpose == suspendsPurpose {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pendingPurpose = purpose
                    self.continuation = continuation
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.resumeSuspendedCapture()
                }
            }
            try Task.checkCancellation()
        }

        enteredSelectionPurposes.append(purpose)
        return captureResult
    }

    func cancelCurrentCapture() {
        cancelCount += 1
    }

    func resumeSuspendedCapture() {
        let pending = continuation
        continuation = nil
        pendingPurpose = nil
        pending?.resume()
    }
}

@MainActor
private final class TranslationPanelLanguageBarFrameCapture {
    var height: CGFloat = 0
}

private struct TranslationPanelLanguageBarFrameProbe: NSViewRepresentable {
    let capture: TranslationPanelLanguageBarFrameCapture

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView(capture: capture)
    }

    func updateNSView(_ nsView: ProbeView, context _: Context) {
        nsView.capture = capture
        nsView.reportFrame()
    }

    @MainActor
    final class ProbeView: NSView {
        var capture: TranslationPanelLanguageBarFrameCapture

        init(capture: TranslationPanelLanguageBarFrameCapture) {
            self.capture = capture
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        func reportFrame() {
            capture.height = bounds.height
        }
    }
}
