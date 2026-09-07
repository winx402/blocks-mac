import Foundation
import CryptoKit
import Network

public enum BlocksSelectionCaptureProtocol {
    public static let appBundleIdentifier =
        BlocksRuntimeIdentity.applicationBundleIdentifier
    public static let maximumSelectionCharacters = 200_000
    public static let maximumSelectionUTF8Bytes = 1_000_000
    public static let maximumRequestBytes = 16_384
    public static let maximumResponseBytes = 6_500_000
    public static let maximumRequestIdentifierBytes = 128
    public static let maximumBundleIdentifierBytes = 512
    public static let maximumRoleBytes = 128
    public static let maximumSubroleBytes = 128
    public static let maximumIdentifierBytes = 512
    public static let maximumDOMIdentifierBytes = 2_048
    public static let maximumChromeNodeIdentifierBytes = 512
    public static let maximumCandidateDepth = 32
    public static let maximumAbsoluteScreenCoordinate = 10_000_000.0
}

public enum SelectionAgentPayloadValidator {
    public static func isValid(
        _ request: SelectionAgentCaptureRequest
    ) -> Bool {
        request.targetProcessIdentifier > 0
            && bounded(
                request.requestID,
                maximumBytes:
                    BlocksSelectionCaptureProtocol
                        .maximumRequestIdentifierBytes
            )
            && optionalBounded(
                request.targetBundleIdentifier,
                maximumBytes:
                    BlocksSelectionCaptureProtocol
                        .maximumBundleIdentifierBytes
            )
            && (request.mouseScreenPoint.map(isValid) ?? true)
            && request.deadline.timeIntervalSince1970.isFinite
            && (1...BlocksSelectionCaptureProtocol
                .maximumSelectionCharacters)
                .contains(request.maximumCharacters)
    }

    public static func isValid(
        _ response: SelectionAgentCaptureResponse
    ) -> Bool {
        guard bounded(
            response.requestID,
            maximumBytes:
                BlocksSelectionCaptureProtocol
                    .maximumRequestIdentifierBytes
        ) else {
            return false
        }
        switch (response.selection, response.failureCode) {
        case let (.some(selection), .none):
            return isValid(selection)
        case (.none, .some):
            return true
        case (.none, .none), (.some, .some):
            return false
        }
    }

    public static func isValid(
        _ selection: SelectionAgentSelection
    ) -> Bool {
        guard !selection.text.isEmpty,
              selection.text.count <=
                BlocksSelectionCaptureProtocol
                    .maximumSelectionCharacters,
              selection.text.utf8.count <=
                BlocksSelectionCaptureProtocol
                    .maximumSelectionUTF8Bytes,
              (0...BlocksSelectionCaptureProtocol.maximumCandidateDepth)
                .contains(selection.candidateDepth),
              optionalBounded(
                selection.role,
                maximumBytes:
                    BlocksSelectionCaptureProtocol.maximumRoleBytes
              ),
              optionalBounded(
                selection.subrole,
                maximumBytes:
                    BlocksSelectionCaptureProtocol.maximumSubroleBytes
              ),
              optionalBounded(
                selection.identifier,
                maximumBytes:
                    BlocksSelectionCaptureProtocol.maximumIdentifierBytes
              ),
              optionalBounded(
                selection.domIdentifier,
                maximumBytes:
                    BlocksSelectionCaptureProtocol
                        .maximumDOMIdentifierBytes
              ),
              optionalBounded(
                selection.chromeNodeIdentifier,
                maximumBytes:
                    BlocksSelectionCaptureProtocol
                        .maximumChromeNodeIdentifierBytes
              ) else {
            return false
        }
        if let range = selection.range,
           !isValid(range) {
            return false
        }
        if let rect = selection.accessibilityScreenBounds,
           !isValid(rect) {
            return false
        }
        return true
    }

    public static func isValid(_ point: SelectionAgentPoint) -> Bool {
        let values = [point.x, point.y]
        guard values.allSatisfy(\.isFinite) else {
            return false
        }
        let limit =
            BlocksSelectionCaptureProtocol.maximumAbsoluteScreenCoordinate
        return abs(point.x) <= limit && abs(point.y) <= limit
    }

    public static func isValid(_ range: SelectionAgentRange) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= Int.max - range.length
    }

    public static func isValid(_ rect: SelectionAgentRect) -> Bool {
        let values = [rect.x, rect.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite),
              rect.width >= 0,
              rect.height >= 0 else {
            return false
        }
        let limit =
            BlocksSelectionCaptureProtocol.maximumAbsoluteScreenCoordinate
        return abs(rect.x) <= limit
            && abs(rect.y) <= limit
            && rect.width <= limit
            && rect.height <= limit
    }

    public static func truncatedMetadata(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        guard let value else { return nil }
        guard value.utf8.count > maximumBytes else {
            return value
        }
        var byteCount = 0
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumBytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func bounded(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
    }

    private static func optionalBounded(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map { $0.utf8.count <= maximumBytes } ?? true
    }
}

/// Tracks active capture requests and a short, bounded pre-cancel window.
/// Finished requests are remembered just long enough to reject a late cancel
/// without allowing it to become a cancellation for a future request.
public final class SelectionAgentCancellationRegistry:
    @unchecked Sendable
{
    private struct TimedRequest {
        let expiresAt: TimeInterval
        let sequence: UInt64
    }

    private static let preCancelTTL: TimeInterval = 1
    private static let tombstoneCapacity = 256

    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let preCancelTTL: TimeInterval
    private let tombstoneCapacity: Int
    private var activeRequestIDs: Set<String> = []
    private var cancelledRequestIDs: Set<String> = []
    private var pendingPreCancels: [String: TimedRequest] = [:]
    private var recentlyFinished: [String: TimedRequest] = [:]
    private var nextSequence: UInt64 = 0

    public init() {
        now = { ProcessInfo.processInfo.systemUptime }
        preCancelTTL = Self.preCancelTTL
        tombstoneCapacity = Self.tombstoneCapacity
    }

    internal init(
        now: @escaping () -> TimeInterval,
        preCancelTTL: TimeInterval,
        tombstoneCapacity: Int
    ) {
        self.now = now
        self.preCancelTTL = max(0, preCancelTTL)
        self.tombstoneCapacity = max(0, tombstoneCapacity)
    }

    @discardableResult
    public func begin(_ requestID: String) -> Bool {
        guard isValidRequestID(requestID) else { return false }
        return lock.withLock {
            let currentTime = now()
            pruneExpiredTombstones(now: currentTime)
            guard !activeRequestIDs.contains(requestID),
                  recentlyFinished[requestID] == nil else {
                return false
            }
            activeRequestIDs.insert(requestID)
            if pendingPreCancels.removeValue(forKey: requestID) != nil {
                cancelledRequestIDs.insert(requestID)
            } else {
                cancelledRequestIDs.remove(requestID)
            }
            return true
        }
    }

    @discardableResult
    public func cancel(_ requestID: String) -> Bool {
        guard isValidRequestID(requestID) else { return false }
        return lock.withLock {
            let currentTime = now()
            pruneExpiredTombstones(now: currentTime)
            if activeRequestIDs.contains(requestID) {
                cancelledRequestIDs.insert(requestID)
                return true
            }
            guard recentlyFinished[requestID] == nil,
                  insertPreCancel(requestID, now: currentTime) else {
                return false
            }
            return true
        }
    }

    public func isCancelled(_ requestID: String) -> Bool {
        guard isValidRequestID(requestID) else { return false }
        return lock.withLock {
            activeRequestIDs.contains(requestID)
                && cancelledRequestIDs.contains(requestID)
        }
    }

    public func finish(_ requestID: String) {
        guard isValidRequestID(requestID) else { return }
        lock.withLock {
            let didFinishActiveRequest =
                activeRequestIDs.remove(requestID) != nil
            _ = cancelledRequestIDs.remove(requestID)
            guard didFinishActiveRequest else { return }
            let currentTime = now()
            pruneExpiredTombstones(now: currentTime)
            insertRecentlyFinished(requestID, now: currentTime)
        }
    }

    internal var pendingPreCancelCountForTesting: Int {
        lock.withLock {
            pruneExpiredTombstones(now: now())
            return pendingPreCancels.count
        }
    }

    private func isValidRequestID(_ requestID: String) -> Bool {
        !requestID.isEmpty
            && requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes
    }

    private func insertPreCancel(_ requestID: String, now: TimeInterval) -> Bool {
        guard preCancelTTL > 0, tombstoneCapacity > 0 else { return false }
        if pendingPreCancels[requestID] != nil {
            return true
        }
        evictOldestIfNeeded(from: &pendingPreCancels)
        pendingPreCancels[requestID] = timedRequest(now: now)
        return true
    }

    private func insertRecentlyFinished(
        _ requestID: String,
        now: TimeInterval
    ) {
        guard preCancelTTL > 0, tombstoneCapacity > 0 else { return }
        if recentlyFinished[requestID] != nil {
            return
        }
        evictOldestIfNeeded(from: &recentlyFinished)
        recentlyFinished[requestID] = timedRequest(now: now)
    }

    private func timedRequest(now: TimeInterval) -> TimedRequest {
        defer { nextSequence &+= 1 }
        return TimedRequest(
            expiresAt: now + preCancelTTL,
            sequence: nextSequence
        )
    }

    private func pruneExpiredTombstones(now: TimeInterval) {
        // Expiration is strict: a tombstone is invalid at its exact deadline.
        pendingPreCancels = pendingPreCancels.filter { $0.value.expiresAt > now }
        recentlyFinished = recentlyFinished.filter { $0.value.expiresAt > now }
    }

    private func evictOldestIfNeeded(
        from tombstones: inout [String: TimedRequest]
    ) {
        guard tombstones.count >= tombstoneCapacity,
              let oldest = tombstones.min(by: {
                  $0.value.sequence < $1.value.sequence
              }) else {
            return
        }
        tombstones.removeValue(forKey: oldest.key)
    }
}

public struct SelectionAgentCaptureRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let targetProcessIdentifier: Int32
    public let targetBundleIdentifier: String?
    public let mouseScreenPoint: SelectionAgentPoint?
    public let deadline: Date
    public let maximumCharacters: Int

    public init(
        requestID: String,
        targetProcessIdentifier: Int32,
        targetBundleIdentifier: String?,
        mouseScreenPoint: SelectionAgentPoint? = nil,
        deadline: Date,
        maximumCharacters: Int
    ) {
        self.requestID = requestID
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetBundleIdentifier = targetBundleIdentifier
        self.mouseScreenPoint = mouseScreenPoint
        self.deadline = deadline
        self.maximumCharacters = maximumCharacters
    }
}

public struct SelectionAgentPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SelectionAgentRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SelectionAgentRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SelectionAgentSelection: Codable, Equatable, Sendable {
    public let text: String
    public let range: SelectionAgentRange?
    public let accessibilityScreenBounds: SelectionAgentRect?
    public let captureStrategy: SelectionAgentCaptureStrategy
    public let candidateDepth: Int
    public let role: String?
    public let subrole: String?
    public let identifier: String?
    public let domIdentifier: String?
    public let chromeNodeIdentifier: String?

    public init(
        text: String,
        range: SelectionAgentRange?,
        accessibilityScreenBounds: SelectionAgentRect?,
        captureStrategy: SelectionAgentCaptureStrategy = .focusedElement,
        candidateDepth: Int = 0,
        role: String?,
        subrole: String?,
        identifier: String?,
        domIdentifier: String?,
        chromeNodeIdentifier: String?
    ) {
        self.text = text
        self.range = range
        self.accessibilityScreenBounds = accessibilityScreenBounds
        self.captureStrategy = captureStrategy
        self.candidateDepth = candidateDepth
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.chromeNodeIdentifier = chromeNodeIdentifier
    }
}

public enum SelectionAgentCaptureStrategy:
    String,
    Codable,
    Equatable,
    Sendable
{
    case focusedElement
    case mouseHitTest
    case focusedWindowDocument
}

public enum SelectionAgentFailureCode: String, Codable, Sendable {
    case invalidRequest
    case unauthorizedClient
    case accessibilityPermissionDenied
    case targetUnavailable
    case targetIdentityChanged
    case focusedElementUnavailable
    case passwordField
    case selectionUnavailable
    case emptySelection
    case selectionTooLarge
    case timedOut
    case cancelled
    case internalFailure
}

public struct SelectionAgentCaptureResponse:
    Codable,
    Equatable,
    Sendable
{
    public let requestID: String
    public let selection: SelectionAgentSelection?
    public let failureCode: SelectionAgentFailureCode?

    public init(
        requestID: String,
        selection: SelectionAgentSelection?,
        failureCode: SelectionAgentFailureCode?
    ) {
        self.requestID = requestID
        self.selection = selection
        self.failureCode = failureCode
    }

    public static func success(
        requestID: String,
        selection: SelectionAgentSelection
    ) -> Self {
        Self(
            requestID: requestID,
            selection: selection,
            failureCode: nil
        )
    }

    public static func failure(
        requestID: String,
        code: SelectionAgentFailureCode
    ) -> Self {
        Self(
            requestID: requestID,
            selection: nil,
            failureCode: code
        )
    }
}

public enum BlocksSelectionHelperProtocol {
    /// Version 4 requires clients to half-close their request stream. The
    /// Helper does not decode or execute the single request frame until it has
    /// observed that write-side close, so delayed bytes cannot arrive after
    /// the authenticated request has already taken effect.
    public static let version = 4
    public static let minimumCompatibleVersion = 4
    public static let bundleIdentifier =
        BlocksRuntimeIdentity.selectionHelperBundleIdentifier
    public static let urlScheme = BlocksRuntimeIdentity.selectionHelperURLScheme
    public static let loopbackPort =
        BlocksRuntimeIdentity.selectionHelperLoopbackPort
    public static let maximumWireBytes =
        BlocksSelectionCaptureProtocol.maximumResponseBytes + 65_536
    public static let maximumClockSkew: TimeInterval = 5
    /// Authenticated loopback packets are short-lived. Bounding their future
    /// lifetime also bounds replay-registry retention for verified packets.
    public static let maximumAuthenticatedMessageLifetime: TimeInterval = 60
    public static let maximumAuthenticatedNonceBytes = 128
    /// CryptoKit's P-256 `rawRepresentation` is the 64-byte X || Y payload.
    /// Pairing, transcript authentication, and ECDH must use this same wire
    /// representation on both sides.
    public static let p256RawPublicKeyBytes = 64
    public static let requestFrameTimeout: TimeInterval = 2
    public static let disconnectAcknowledgementLifetime: TimeInterval = 5 * 60
    /// V4 never reads the v3 active-key identity. Keeping the legacy identity
    /// separate prevents a previously compromised v3 key from authenticating
    /// a v4 envelope after an upgrade.
    public static let legacyKeychainService =
        BlocksRuntimeIdentity.selectionHelperLegacyKeychainService
    public static let legacyKeychainAccount = "paired-device"
    public static let keychainService =
        BlocksRuntimeIdentity.selectionHelperKeychainService
    public static let keychainAccount = "paired-device-v4"
    public static let bootstrapKeychainService =
        BlocksRuntimeIdentity.selectionHelperBootstrapKeychainService
    public static let bootstrapKeychainAccount = "pairing-bootstrap-v1"
    public static let sharedKeychainAccessGroupSuffix =
        BlocksRuntimeIdentity.selectionHelperSharedKeychainAccessGroupSuffix
    /// Optional capability. Clients must treat its absence as an unavailable
    /// enhancement and keep the normal paste path available.
    public static let pasteTargetInspectionCapability =
        "paste-target-inspection-v1"
    public static let updateLifecycleCapability = "update-lifecycle-v1"
}

/// Validates newline-delimited Helper request frames before any JSON,
/// pairing, or authenticated-envelope decoding is attempted. Responses keep
/// using `maximumWireBytes`; only inbound requests use this smaller boundary.
public enum SelectionHelperRequestFrameValidator {
    public enum Disposition: Equatable, Sendable {
        case receiveMore
        case complete(Data)
        case reject
    }

    public static func payload(
        from bufferedData: Data
    ) -> Data? {
        guard let newline = bufferedData.firstIndex(of: 0x0A) else {
            return nil
        }
        let payload = bufferedData[..<newline]
        guard payload.count <=
            BlocksSelectionCaptureProtocol.maximumRequestBytes,
              bufferedData.count == payload.count + 1 else {
            return nil
        }
        return Data(payload)
    }

    public static func canContinueReceiving(
        _ bufferedData: Data
    ) -> Bool {
        if let newline = bufferedData.firstIndex(of: 0x0A) {
            let payloadByteCount = bufferedData.distance(
                from: bufferedData.startIndex,
                to: newline
            )
            return payloadByteCount <=
                    BlocksSelectionCaptureProtocol.maximumRequestBytes
                && bufferedData.count == payloadByteCount + 1
        }
        return bufferedData.count <=
            BlocksSelectionCaptureProtocol.maximumRequestBytes
    }

    /// A newline only delimits the payload. It does not authorize execution:
    /// the peer must also close its write side, proving that no delayed bytes
    /// can follow on this one-request connection.
    public static func disposition(
        for bufferedData: Data,
        peerDidCloseWrite: Bool
    ) -> Disposition {
        guard canContinueReceiving(bufferedData) else {
            return .reject
        }
        guard peerDidCloseWrite else {
            return .receiveMore
        }
        guard let payload = payload(from: bufferedData) else {
            return .reject
        }
        return .complete(payload)
    }
}

/// Receives exactly one Helper request frame. A frame is delivered only after
/// its peer has closed the write side, so a valid newline cannot be followed
/// by delayed trailing bytes after the request has been acted on.
final class SelectionHelperRequestFrameReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let receivedPayload: (Data) -> Void
    private var bufferedData = Data()
    private var didFinish = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval =
            BlocksSelectionHelperProtocol.requestFrameTimeout,
        receivedPayload: @escaping (Data) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.timeout = timeout
        self.receivedPayload = receivedPayload
    }

    func start() {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.reject()
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                receiveNext()
            case .failed, .cancelled:
                _ = finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        guard !didFinish else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !didFinish else { return }
            if let data {
                bufferedData.append(data)
            }
            guard error == nil else {
                reject()
                return
            }
            switch SelectionHelperRequestFrameValidator.disposition(
                for: bufferedData,
                peerDidCloseWrite: isComplete
            ) {
            case .reject:
                reject()
            case .receiveMore:
                receiveNext()
            case let .complete(payload):
                guard finish() else { return }
                receivedPayload(payload)
            }
        }
    }

    private func reject() {
        guard finish() else { return }
        connection.cancel()
    }

    @discardableResult
    private func finish() -> Bool {
        guard !didFinish else { return false }
        didFinish = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        return true
    }
}

/// Sends exactly one newline-delimited Helper response and closes only the
/// write side of the TCP stream. Cancelling the connection from the send
/// completion can race the peer's pending receive, so the connection remains
/// alive until the peer closes it or this bounded cleanup deadline expires.
final class SelectionHelperResponseFrameSender: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let didFinish: @Sendable () -> Void
    private var isFinished = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval =
            BlocksSelectionHelperProtocol.requestFrameTimeout,
        didFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.timeout = timeout
        self.didFinish = didFinish
    }

    func send(_ payload: Data) {
        queue.async { [self] in
            guard !isFinished else { return }
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(cancelConnection: true)
            }
            self.timeoutWorkItem = timeoutWorkItem
            queue.asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.finish(cancelConnection: false)
                default:
                    break
                }
            }
            connection.send(
                content: payload + Data([0x0A]),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.finish(cancelConnection: true)
                    }
                }
            )
        }
    }

    func cancel() {
        queue.async { [self] in
            finish(cancelConnection: true)
        }
    }

    private func finish(cancelConnection: Bool) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        if cancelConnection {
            connection.cancel()
        }
        didFinish()
    }
}

public struct SelectionHelperPairRequest:
    Codable,
    Equatable,
    Sendable
{
    public let protocolVersion: Int
    public let requestID: String
    public let pairingCode: String
    public let clientPublicKey: Data
    public let clientProof: Data

    public init(
        protocolVersion: Int =
            BlocksSelectionHelperProtocol.version,
        requestID: String,
        pairingCode: String,
        clientPublicKey: Data,
        clientProof: Data
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.pairingCode = pairingCode
        self.clientPublicKey = clientPublicKey
        self.clientProof = clientProof
    }
}

public struct SelectionHelperPairResponse:
    Codable,
    Equatable,
    Sendable
{
    public let protocolVersion: Int
    public let requestID: String
    public let helperPublicKey: Data?
    public let helperProof: Data?
    public let failureCode: String?

    public init(
        protocolVersion: Int =
            BlocksSelectionHelperProtocol.version,
        requestID: String,
        helperPublicKey: Data?,
        helperProof: Data?,
        failureCode: String?
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.helperPublicKey = helperPublicKey
        self.helperProof = helperProof
        self.failureCode = failureCode
    }
}

/// Authenticates pairing independently of the ECDH-derived active key. The
/// two domains prevent a proof generated for one direction from being
/// reflected into the other direction.
public enum SelectionHelperPairingAuthentication {
    private static let clientDomain = "BlocksSelectionHelper/pair/client/v4"
    private static let helperDomain = "BlocksSelectionHelper/pair/helper/v4"

    public static func clientProof(
        bootstrapKey: Data,
        requestID: String,
        pairingCode: String,
        clientPublicKey: Data,
        protocolVersion: Int = BlocksSelectionHelperProtocol.version
    ) -> Data? {
        authenticationCode(
            domain: clientDomain,
            bootstrapKey: bootstrapKey,
            protocolVersion: protocolVersion,
            requestID: requestID,
            pairingCode: pairingCode,
            clientPublicKey: clientPublicKey,
            helperPublicKey: nil
        )
    }

    public static func helperProof(
        bootstrapKey: Data,
        request: SelectionHelperPairRequest,
        helperPublicKey: Data
    ) -> Data? {
        authenticationCode(
            domain: helperDomain,
            bootstrapKey: bootstrapKey,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            pairingCode: request.pairingCode,
            clientPublicKey: request.clientPublicKey,
            helperPublicKey: helperPublicKey
        )
    }

    public static func verifiesClientProof(
        _ proof: Data,
        bootstrapKey: Data,
        request: SelectionHelperPairRequest
    ) -> Bool {
        guard let transcript = transcript(
            domain: clientDomain,
            bootstrapKey: bootstrapKey,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            pairingCode: request.pairingCode,
            clientPublicKey: request.clientPublicKey,
            helperPublicKey: nil
        ) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript,
            using: SymmetricKey(data: bootstrapKey)
        )
    }

    public static func verifiesHelperProof(
        _ proof: Data,
        bootstrapKey: Data,
        request: SelectionHelperPairRequest,
        helperPublicKey: Data
    ) -> Bool {
        guard let transcript = transcript(
            domain: helperDomain,
            bootstrapKey: bootstrapKey,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            pairingCode: request.pairingCode,
            clientPublicKey: request.clientPublicKey,
            helperPublicKey: helperPublicKey
        ) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript,
            using: SymmetricKey(data: bootstrapKey)
        )
    }

    private static func authenticationCode(
        domain: String,
        bootstrapKey: Data,
        protocolVersion: Int,
        requestID: String,
        pairingCode: String,
        clientPublicKey: Data,
        helperPublicKey: Data?
    ) -> Data? {
        guard let transcript = transcript(
            domain: domain,
            bootstrapKey: bootstrapKey,
            protocolVersion: protocolVersion,
            requestID: requestID,
            pairingCode: pairingCode,
            clientPublicKey: clientPublicKey,
            helperPublicKey: helperPublicKey
        ) else {
            return nil
        }
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: transcript,
                using: SymmetricKey(data: bootstrapKey)
            )
        )
    }

    private static func transcript(
        domain: String,
        bootstrapKey: Data,
        protocolVersion: Int,
        requestID: String,
        pairingCode: String,
        clientPublicKey: Data,
        helperPublicKey: Data?
    ) -> Data? {
        guard bootstrapKey.count == 32,
              protocolVersion == BlocksSelectionHelperProtocol.version,
              !requestID.isEmpty,
              requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes,
              pairingCode.count == 6,
              pairingCode.allSatisfy(\.isNumber),
              clientPublicKey.count ==
                BlocksSelectionHelperProtocol.p256RawPublicKeyBytes,
              (helperPublicKey == nil
                || helperPublicKey?.count ==
                    BlocksSelectionHelperProtocol.p256RawPublicKeyBytes) else {
            return nil
        }
        var transcript = Data()
        append(domain, to: &transcript)
        append(UInt64(protocolVersion), to: &transcript)
        append(requestID, to: &transcript)
        append(pairingCode, to: &transcript)
        append(clientPublicKey, to: &transcript)
        append(helperPublicKey ?? Data(), to: &transcript)
        return transcript
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}

public enum SelectionHelperWireKind:
    String,
    Codable,
    Sendable
{
    case pair
    case authenticated
}

public struct SelectionHelperWirePacket:
    Codable,
    Equatable,
    Sendable
{
    public let kind: SelectionHelperWireKind
    public let payload: Data

    public init(kind: SelectionHelperWireKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

public enum SelectionHelperCommandKind:
    String,
    Codable,
    Sendable
{
    case health
    case capture
    case inspectPasteTarget
    case permissionStatus
    case requestPermission
    case cancel
    case disconnect
    case prepareForApplicationUpdate
    case resumeAfterCancelledApplicationUpdate
    case terminateForApplicationUpdate
}

public struct SelectionHelperCommand:
    Codable,
    Equatable,
    Sendable
{
    public let kind: SelectionHelperCommandKind
    public let captureRequest: SelectionAgentCaptureRequest?
    public let pasteTargetRequest: SelectionHelperPasteTargetRequest?
    public let cancellationRequestID: String?

    public init(
        kind: SelectionHelperCommandKind,
        captureRequest: SelectionAgentCaptureRequest? = nil,
        pasteTargetRequest: SelectionHelperPasteTargetRequest? = nil,
        cancellationRequestID: String? = nil
    ) {
        self.kind = kind
        self.captureRequest = captureRequest
        self.pasteTargetRequest = pasteTargetRequest
        self.cancellationRequestID = cancellationRequestID
    }
}

/// A deliberately narrow, read-only request for whether the current focused
/// control in a foreground target appears editable. The Helper must never read
/// AXValue/AXSelectedText or change focus while processing it.
public struct SelectionHelperPasteTargetRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let targetPID: Int32
    public let targetBundleIdentifier: String

    public init(
        requestID: String,
        targetPID: Int32,
        targetBundleIdentifier: String
    ) {
        self.requestID = requestID
        self.targetPID = targetPID
        self.targetBundleIdentifier = targetBundleIdentifier
    }

    public var isValid: Bool {
        targetPID > 0
            && !requestID.isEmpty
            && requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes
            && !targetBundleIdentifier.isEmpty
            && targetBundleIdentifier.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumBundleIdentifierBytes
    }
}

public enum SelectionHelperPasteTargetEditability:
    String,
    Codable,
    Equatable,
    Sendable
{
    case editable
    case nonEditable
    case unknown
}

public struct SelectionHelperPasteTargetInspection:
    Codable,
    Equatable,
    Sendable
{
    public let requestID: String
    public let targetPID: Int32
    public let targetBundleIdentifier: String
    public let editability: SelectionHelperPasteTargetEditability

    public init(
        requestID: String,
        targetPID: Int32,
        targetBundleIdentifier: String,
        editability: SelectionHelperPasteTargetEditability
    ) {
        self.requestID = requestID
        self.targetPID = targetPID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.editability = editability
    }
}

public struct SelectionHelperHealth:
    Codable,
    Equatable,
    Sendable
{
    public let protocolVersion: Int
    public let helperVersion: String
    public let accessibilityTrusted: Bool
    public let capabilities: [String]

    public init(
        protocolVersion: Int =
            BlocksSelectionHelperProtocol.version,
        helperVersion: String,
        accessibilityTrusted: Bool,
        capabilities: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.accessibilityTrusted = accessibilityTrusted
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case helperVersion
        case accessibilityTrusted
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        helperVersion = try container.decode(String.self, forKey: .helperVersion)
        accessibilityTrusted = try container.decode(
            Bool.self,
            forKey: .accessibilityTrusted
        )
        capabilities = try container.decodeIfPresent(
            [String].self,
            forKey: .capabilities
        ) ?? []
    }
}

public struct SelectionHelperCommandResponse:
    Codable,
    Equatable,
    Sendable
{
    public let captureResponse: SelectionAgentCaptureResponse?
    public let pasteTargetInspection: SelectionHelperPasteTargetInspection?
    public let booleanValue: Bool?
    public let health: SelectionHelperHealth?
    public let failureCode: String?

    public init(
        captureResponse: SelectionAgentCaptureResponse? = nil,
        pasteTargetInspection: SelectionHelperPasteTargetInspection? = nil,
        booleanValue: Bool? = nil,
        health: SelectionHelperHealth? = nil,
        failureCode: String? = nil
    ) {
        self.captureResponse = captureResponse
        self.pasteTargetInspection = pasteTargetInspection
        self.booleanValue = booleanValue
        self.health = health
        self.failureCode = failureCode
    }
}

public struct SelectionHelperSealedMessage:
    Codable,
    Equatable,
    Sendable
{
    public let protocolVersion: Int
    public let requestID: String
    public let expiresAt: Date
    public let nonce: String
    public let combinedCiphertext: Data

    public init(
        protocolVersion: Int =
            BlocksSelectionHelperProtocol.version,
        requestID: String,
        expiresAt: Date,
        nonce: String,
        combinedCiphertext: Data
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.combinedCiphertext = combinedCiphertext
    }
}

public enum SelectionHelperAuthenticatedCodecError: Error, Equatable {
    case incompatibleVersion
    case expired
    case invalidEnvelope
    case authenticationFailed
    case replayed
}

public enum SelectionHelperAuthenticatedCodec {
    public static func seal<Value: Encodable>(
        _ value: Value,
        requestID: String,
        expiresAt: Date,
        keyData: Data,
        nonce: String = UUID().uuidString
    ) throws -> SelectionHelperSealedMessage {
        guard keyData.count == 32,
              !requestID.isEmpty,
              requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes,
              !nonce.isEmpty,
              nonce.utf8.count <=
                BlocksSelectionHelperProtocol.maximumAuthenticatedNonceBytes else {
            throw SelectionHelperAuthenticatedCodecError.invalidEnvelope
        }
        let payload = try JSONEncoder().encode(value)
        let metadata = authenticatedMetadata(
            requestID: requestID,
            expiresAt: expiresAt,
            nonce: nonce
        )
        let sealed = try AES.GCM.seal(
            payload,
            using: SymmetricKey(data: keyData),
            authenticating: metadata
        )
        guard let combined = sealed.combined else {
            throw SelectionHelperAuthenticatedCodecError.invalidEnvelope
        }
        return SelectionHelperSealedMessage(
            requestID: requestID,
            expiresAt: expiresAt,
            nonce: nonce,
            combinedCiphertext: combined
        )
    }

    public static func open<Value: Decodable>(
        _ type: Value.Type,
        from message: SelectionHelperSealedMessage,
        keyData: Data,
        now: Date = Date()
    ) throws -> Value {
        guard !message.requestID.isEmpty,
              message.requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes,
              !message.nonce.isEmpty,
              message.nonce.utf8.count <=
                BlocksSelectionHelperProtocol.maximumAuthenticatedNonceBytes else {
            throw SelectionHelperAuthenticatedCodecError.invalidEnvelope
        }
        guard message.protocolVersion >=
                BlocksSelectionHelperProtocol.minimumCompatibleVersion,
              message.protocolVersion <=
                BlocksSelectionHelperProtocol.version else {
            throw SelectionHelperAuthenticatedCodecError
                .incompatibleVersion
        }
        guard keyData.count == 32,
              message.expiresAt.timeIntervalSince(now) >=
                -BlocksSelectionHelperProtocol.maximumClockSkew,
              message.expiresAt.timeIntervalSince(now) <=
                BlocksSelectionHelperProtocol
                    .maximumAuthenticatedMessageLifetime else {
            throw SelectionHelperAuthenticatedCodecError.expired
        }
        do {
            let sealed = try AES.GCM.SealedBox(
                combined: message.combinedCiphertext
            )
            let payload = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: keyData),
                authenticating: authenticatedMetadata(
                    requestID: message.requestID,
                    expiresAt: message.expiresAt,
                    nonce: message.nonce
                )
            )
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw SelectionHelperAuthenticatedCodecError
                .authenticationFailed
        }
    }

    public static func deriveSharedKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKeyData: Data,
        requestID: String
    ) throws -> Data {
        guard !requestID.isEmpty,
              requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes else {
            throw SelectionHelperAuthenticatedCodecError.invalidEnvelope
        }
        let publicKey = try P256.KeyAgreement.PublicKey(
            rawRepresentation: peerPublicKeyData
        )
        let secret = try privateKey.sharedSecretFromKeyAgreement(
            with: publicKey
        )
        let salt = Data(
            "BlocksSelectionHelper/v1".utf8
        )
        let info = Data(requestID.utf8)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    public static func pairingProof(
        keyData: Data,
        requestID: String
    ) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Data("pair:\(requestID)".utf8),
                using: SymmetricKey(data: keyData)
            )
        )
    }

    private static func authenticatedMetadata(
        requestID: String,
        expiresAt: Date,
        nonce: String
    ) -> Data {
        let value =
            "\(BlocksSelectionHelperProtocol.version)|"
            + "\(requestID)|"
            + "\(expiresAt.timeIntervalSince1970)|"
            + nonce
        return Data(value.utf8)
    }
}

/// Shared authenticated replay gate for the main App and the independent
/// Helper. Authentication always completes before a nonce is consumed, so an
/// unauthenticated packet cannot fill the bounded replay registry.
public final class SelectionHelperAuthenticatedReplayGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var expirations: [String: Date] = [:]

    public init() {}

    public func authenticate<Value: Decodable>(
        _ type: Value.Type,
        from message: SelectionHelperSealedMessage,
        keyData: Data,
        now: Date = Date(),
        accepting: (Value) -> Bool = { _ in true }
    ) throws -> Value {
        let value = try SelectionHelperAuthenticatedCodec.open(
            type,
            from: message,
            keyData: keyData,
            now: now
        )
        guard accepting(value) else {
            throw SelectionHelperAuthenticatedCodecError.invalidEnvelope
        }
        guard consume(
            nonce: message.nonce,
            expiresAt: message.expiresAt,
            now: now
        ) else {
            throw SelectionHelperAuthenticatedCodecError.replayed
        }
        return value
    }

    private func consume(
        nonce: String,
        expiresAt: Date,
        now: Date
    ) -> Bool {
        lock.withLock {
            expirations = expirations.filter { $0.value >= now }
            guard expirations[nonce] == nil,
                  expirations.count < 2_048 else {
                return false
            }
            // A message remains acceptable through maximumClockSkew, so keep
            // its nonce for that entire acceptance interval.
            expirations[nonce] = expiresAt.addingTimeInterval(
                BlocksSelectionHelperProtocol.maximumClockSkew
            )
            return true
        }
    }
}
