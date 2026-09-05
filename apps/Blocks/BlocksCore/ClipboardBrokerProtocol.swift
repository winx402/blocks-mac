import Foundation

public enum ClipboardBrokerLimits {
    public static let maxTextBytes = 4 * 1024 * 1024
    public static let maxRTFBytes = 16 * 1024 * 1024
    public static let maxRawImageBytes = 32 * 1024 * 1024
    public static let maxCanonicalPNGBytes = 25 * 1024 * 1024
    public static let inlineImageBytes = 1024 * 1024
    public static let maxFrameBytes = 40 * 1024 * 1024
}

public enum ClipboardBrokerOperation: String, Codable, Sendable {
    case observe
    case resolve
    case write
    case prepareWrite = "prepare_write"
    case commitWrite = "commit_write"
    case cancelWrite = "cancel_write"
    case validate
    case currentPlainText = "current_plain_text"
    case snapshot
    case baseline
    case shutdown
}

public enum ClipboardBrokerRepresentationFamily: String, Codable, Sendable {
    case fileURL = "file_url"
    case imagePNG = "image_png"
    case imageTIFF = "image_tiff"
    case url
    case richText = "rich_text"
    case text
}

public enum ClipboardBrokerPrefilterDisposition: String, Codable, Sendable {
    case allow
    case redactPaused = "redact_paused"
    case redactPrivacyUnavailable = "redact_privacy_unavailable"
    case redactExcludedSource = "redact_excluded_source"
}

public enum ClipboardBrokerSkipReason: String, Codable, Sendable {
    case selfWrite = "self_write"
    case poisonedChange = "poisoned_change"
    case remoteClipboard = "remote_clipboard"
    case sensitiveMarker = "sensitive_marker"
    case unsupported
    case stale
    case oversized
}

public enum ClipboardBrokerDataReference: Codable, Equatable, Sendable {
    case inline(Data)
    case staged(token: String, byteCount: Int)

    public var byteCount: Int {
        switch self {
        case let .inline(data):
            data.count
        case let .staged(_, byteCount):
            byteCount
        }
    }
}

public struct ClipboardBrokerObserveRequest: Codable, Sendable {
    public let baselineChangeCount: Int?
    public let poisonedChangeCount: Int?
    public let suppressedChangeCounts: [Int]
    public let prefilterDisposition: ClipboardBrokerPrefilterDisposition
    public let screenSharingActive: Bool

    public init(
        baselineChangeCount: Int?,
        poisonedChangeCount: Int? = nil,
        suppressedChangeCounts: [Int] = [],
        prefilterDisposition: ClipboardBrokerPrefilterDisposition = .allow,
        screenSharingActive: Bool = false
    ) {
        self.baselineChangeCount = baselineChangeCount
        self.poisonedChangeCount = poisonedChangeCount
        self.suppressedChangeCounts = Array(Set(suppressedChangeCounts)).sorted()
        self.prefilterDisposition = prefilterDisposition
        self.screenSharingActive = screenSharingActive
    }
}

public struct ClipboardBrokerCapturedRepresentation: Codable, Equatable, Sendable {
    public let family: ClipboardBrokerRepresentationFamily
    public let pasteboardType: String
    public let advertisedTypes: [String]
    public let value: String?
    public let plainText: String?
    public let data: ClipboardBrokerDataReference?

    public init(
        family: ClipboardBrokerRepresentationFamily,
        pasteboardType: String,
        advertisedTypes: [String],
        value: String? = nil,
        plainText: String? = nil,
        data: ClipboardBrokerDataReference? = nil
    ) {
        self.family = family
        self.pasteboardType = pasteboardType
        self.advertisedTypes = advertisedTypes.sorted()
        self.value = value
        self.plainText = plainText
        self.data = data
    }
}

/// A content-free capability for resolving one pasteboard representation later.
///
/// The ticket deliberately carries no clipboard payload and no provider-owned
/// object. The Broker revalidates `changeCount` before and after the single
/// representation read.
public struct ClipboardBrokerResolutionTicket: Codable, Equatable, Sendable {
    public let changeCount: Int
    public let family: ClipboardBrokerRepresentationFamily
    public let pasteboardType: String
    public let advertisedTypes: [String]

    public init(
        changeCount: Int,
        family: ClipboardBrokerRepresentationFamily,
        pasteboardType: String,
        advertisedTypes: [String]
    ) {
        self.changeCount = changeCount
        self.family = family
        self.pasteboardType = pasteboardType
        self.advertisedTypes = advertisedTypes.sorted()
    }
}

public struct ClipboardBrokerResolveRequest: Codable, Equatable, Sendable {
    public let ticket: ClipboardBrokerResolutionTicket

    public init(ticket: ClipboardBrokerResolutionTicket) {
        self.ticket = ticket
    }
}

public enum ClipboardBrokerObservationStatus: String, Codable, Sendable {
    case noChange = "no_change"
    case deferred
    case captured
    case redacted
    case skipped
}

public struct ClipboardBrokerObservationResult: Codable, Equatable, Sendable {
    public let status: ClipboardBrokerObservationStatus
    public let changeCount: Int
    public let observedAfterChangeCount: Int
    public let representation: ClipboardBrokerCapturedRepresentation?
    public let resolutionTicket: ClipboardBrokerResolutionTicket?
    public let skipReason: ClipboardBrokerSkipReason?
    public let prefilterDisposition: ClipboardBrokerPrefilterDisposition
    /// Assigned by the App-side client after the Broker response is accepted.
    ///
    /// The helper emits zero because its process-local generation is owned by
    /// the supervisor. Test backends may also leave this at zero.
    public let brokerGeneration: UInt64

    public init(
        status: ClipboardBrokerObservationStatus,
        changeCount: Int,
        observedAfterChangeCount: Int,
        representation: ClipboardBrokerCapturedRepresentation? = nil,
        resolutionTicket: ClipboardBrokerResolutionTicket? = nil,
        skipReason: ClipboardBrokerSkipReason? = nil,
        prefilterDisposition: ClipboardBrokerPrefilterDisposition = .allow,
        brokerGeneration: UInt64 = 0
    ) {
        self.status = status
        self.changeCount = changeCount
        self.observedAfterChangeCount = observedAfterChangeCount
        self.representation = representation
        self.resolutionTicket = resolutionTicket
        self.skipReason = skipReason
        self.prefilterDisposition = prefilterDisposition
        self.brokerGeneration = brokerGeneration
    }

    public func tagged(brokerGeneration: UInt64) -> Self {
        Self(
            status: status,
            changeCount: changeCount,
            observedAfterChangeCount: observedAfterChangeCount,
            representation: representation,
            resolutionTicket: resolutionTicket,
            skipReason: skipReason,
            prefilterDisposition: prefilterDisposition,
            brokerGeneration: brokerGeneration
        )
    }
}

public enum ClipboardBrokerWriteRepresentation: Codable, Equatable, Sendable {
    case string(String)
    case data(ClipboardBrokerDataReference)
    case stringList([String])
}

public struct ClipboardBrokerWriteRepresentationEntry: Codable, Equatable, Sendable {
    public let pasteboardType: String
    public let value: ClipboardBrokerWriteRepresentation

    public init(pasteboardType: String, value: ClipboardBrokerWriteRepresentation) {
        self.pasteboardType = pasteboardType
        self.value = value
    }
}

public struct ClipboardBrokerWriteItem: Codable, Equatable, Sendable {
    public let representations: [ClipboardBrokerWriteRepresentationEntry]
    /// A file reference that must be published through AppKit's native URL
    /// writer. Encoding `public.file-url` as an arbitrary string is not
    /// equivalent for sandboxed pasteboard consumers.
    public let semanticFileURLString: String?

    public init(
        representations: [ClipboardBrokerWriteRepresentationEntry],
        semanticFileURLString: String? = nil
    ) {
        self.representations = representations.sorted {
            $0.pasteboardType < $1.pasteboardType
        }
        self.semanticFileURLString = semanticFileURLString
    }
}

public struct ClipboardBrokerWriteRequest: Codable, Equatable, Sendable {
    public let items: [ClipboardBrokerWriteItem]
    public let expectedChangeCount: Int?

    public init(items: [ClipboardBrokerWriteItem], expectedChangeCount: Int? = nil) {
        self.items = items
        self.expectedChangeCount = expectedChangeCount
    }
}

/// A prepared write is materialized by the Broker but has not mutated the
/// pasteboard. The ID is single-use: either commit or cancel consumes it.
public struct ClipboardBrokerPrepareWriteRequest: Codable, Equatable, Sendable {
    public let write: ClipboardBrokerWriteRequest

    public init(write: ClipboardBrokerWriteRequest) {
        self.write = write
    }
}

public struct ClipboardBrokerPreparedWriteResult: Codable, Equatable, Sendable {
    public let preparedWriteID: UUID
    public let itemCount: Int
    public let representationCount: Int
    /// Monotonic system-uptime deadline owned by the Broker. Both processes
    /// run on the same boot clock, so wall-clock changes cannot prolong a
    /// process-local prepared lease.
    public let expiresAtSystemUptime: TimeInterval

    public init(
        preparedWriteID: UUID,
        itemCount: Int,
        representationCount: Int,
        expiresAtSystemUptime: TimeInterval
    ) {
        self.preparedWriteID = preparedWriteID
        self.itemCount = itemCount
        self.representationCount = representationCount
        self.expiresAtSystemUptime = expiresAtSystemUptime
    }

    private enum CodingKeys: String, CodingKey {
        case preparedWriteID
        case itemCount
        case representationCount
        case expiresAtSystemUptime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preparedWriteID = try container.decode(UUID.self, forKey: .preparedWriteID)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        representationCount = try container.decode(
            Int.self,
            forKey: .representationCount
        )
        guard let expiry = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .expiresAtSystemUptime
        ), expiry.isFinite, expiry >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAtSystemUptime,
                in: container,
                debugDescription: "Prepared-write expiry is required."
            )
        }
        expiresAtSystemUptime = expiry
    }
}

public struct ClipboardBrokerCommitWriteRequest: Codable, Equatable, Sendable {
    public let preparedWriteID: UUID

    public init(preparedWriteID: UUID) {
        self.preparedWriteID = preparedWriteID
    }
}

public struct ClipboardBrokerCancelWriteRequest: Codable, Equatable, Sendable {
    public let preparedWriteID: UUID

    public init(preparedWriteID: UUID) {
        self.preparedWriteID = preparedWriteID
    }
}

public enum ClipboardBrokerWriteStatus: String, Codable, Sendable {
    case succeeded
    case changed
    case failed
}

public struct ClipboardBrokerWriteResult: Codable, Equatable, Sendable {
    public let status: ClipboardBrokerWriteStatus
    public let beforeChangeCount: Int
    public let afterChangeCount: Int
    public let changedCounts: [Int]
    public let itemCount: Int
    public let representationCount: Int

    public init(
        status: ClipboardBrokerWriteStatus,
        beforeChangeCount: Int,
        afterChangeCount: Int,
        changedCounts: [Int],
        itemCount: Int,
        representationCount: Int
    ) {
        self.status = status
        self.beforeChangeCount = beforeChangeCount
        self.afterChangeCount = afterChangeCount
        self.changedCounts = changedCounts
        self.itemCount = itemCount
        self.representationCount = representationCount
    }
}

public struct ClipboardBrokerValidateRequest: Codable, Equatable, Sendable {
    public let expectedChangeCount: Int

    public init(expectedChangeCount: Int) {
        self.expectedChangeCount = expectedChangeCount
    }
}

public struct ClipboardBrokerValidationResult: Codable, Equatable, Sendable {
    public let current: Bool
    public let changeCount: Int

    public init(current: Bool, changeCount: Int) {
        self.current = current
        self.changeCount = changeCount
    }
}

public struct ClipboardBrokerPlainTextRequest: Codable, Equatable, Sendable {
    public let maximumCharacterCount: Int

    public init(maximumCharacterCount: Int) {
        self.maximumCharacterCount = max(1, maximumCharacterCount)
    }
}

public struct ClipboardBrokerPlainTextResult: Codable, Equatable, Sendable {
    public let text: String?
    public let originalCharacterCount: Int
    public let truncated: Bool
    public let changeCount: Int

    public init(
        text: String?,
        originalCharacterCount: Int,
        truncated: Bool,
        changeCount: Int
    ) {
        self.text = text
        self.originalCharacterCount = originalCharacterCount
        self.truncated = truncated
        self.changeCount = changeCount
    }
}

public enum ClipboardBrokerSnapshotStatus:
    String,
    Codable,
    Sendable
{
    case captured
    case unsupported
    case stale
    case oversized
}

public struct ClipboardBrokerSnapshotRequest:
    Codable,
    Equatable,
    Sendable
{
    public init() {}
}

/// A bounded, restorable pasteboard snapshot used only for explicitly
/// authorized compatibility selection. Unknown or provider-owned
/// representations are rejected rather than silently discarded.
public struct ClipboardBrokerSnapshotResult:
    Codable,
    Equatable,
    Sendable
{
    public let status: ClipboardBrokerSnapshotStatus
    public let changeCount: Int
    public let items: [ClipboardBrokerWriteItem]
    public let unsupportedTypes: [String]

    public init(
        status: ClipboardBrokerSnapshotStatus,
        changeCount: Int,
        items: [ClipboardBrokerWriteItem] = [],
        unsupportedTypes: [String] = []
    ) {
        self.status = status
        self.changeCount = changeCount
        self.items = items
        self.unsupportedTypes = unsupportedTypes.sorted()
    }
}

public enum ClipboardBrokerCommand: Codable, Sendable {
    case observe(ClipboardBrokerObserveRequest)
    case resolve(ClipboardBrokerResolveRequest)
    case write(ClipboardBrokerWriteRequest)
    case prepareWrite(ClipboardBrokerPrepareWriteRequest)
    case commitWrite(ClipboardBrokerCommitWriteRequest)
    case cancelWrite(ClipboardBrokerCancelWriteRequest)
    case validate(ClipboardBrokerValidateRequest)
    case currentPlainText(ClipboardBrokerPlainTextRequest)
    case snapshot(ClipboardBrokerSnapshotRequest)
    case baseline
    case shutdown

    public var operation: ClipboardBrokerOperation {
        switch self {
        case .observe:
            .observe
        case .resolve:
            .resolve
        case .write:
            .write
        case .prepareWrite:
            .prepareWrite
        case .commitWrite:
            .commitWrite
        case .cancelWrite:
            .cancelWrite
        case .validate:
            .validate
        case .currentPlainText:
            .currentPlainText
        case .snapshot:
            .snapshot
        case .baseline:
            .baseline
        case .shutdown:
            .shutdown
        }
    }
}

public struct ClipboardBrokerRequestEnvelope: Codable, Sendable {
    public let requestID: UUID
    public let command: ClipboardBrokerCommand

    public init(requestID: UUID = UUID(), command: ClipboardBrokerCommand) {
        self.requestID = requestID
        self.command = command
    }
}

public enum ClipboardBrokerTerminalResult: Codable, Sendable {
    case observation(ClipboardBrokerObservationResult)
    case write(ClipboardBrokerWriteResult)
    case preparedWrite(ClipboardBrokerPreparedWriteResult)
    case cancelledWrite(preparedWriteID: UUID)
    case validation(ClipboardBrokerValidationResult)
    case plainText(ClipboardBrokerPlainTextResult)
    case snapshot(ClipboardBrokerSnapshotResult)
    case baseline(changeCount: Int)
    case shutdown
    case failure(code: String)
}

public enum ClipboardBrokerResponseEvent: Codable, Sendable {
    case started(operation: ClipboardBrokerOperation, changeCount: Int?)
    case terminal(ClipboardBrokerTerminalResult)
}

public struct ClipboardBrokerResponseEnvelope: Codable, Sendable {
    public let requestID: UUID
    public let event: ClipboardBrokerResponseEvent

    public init(requestID: UUID, event: ClipboardBrokerResponseEvent) {
        self.requestID = requestID
        self.event = event
    }
}

public enum ClipboardBrokerFrameError: Error, Equatable {
    case oversized(Int)
    case malformedLength
}

public enum ClipboardBrokerFrameCodec {
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(value)
        guard payload.count <= ClipboardBrokerLimits.maxFrameBytes else {
            throw ClipboardBrokerFrameError.oversized(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    public static func takePayload(from buffer: inout Data) throws -> Data? {
        let prefixSize = MemoryLayout<UInt32>.size
        guard buffer.count >= prefixSize else { return nil }
        let length = buffer.prefix(prefixSize).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length <= ClipboardBrokerLimits.maxFrameBytes else {
            throw ClipboardBrokerFrameError.oversized(Int(length))
        }
        let frameSize = prefixSize + Int(length)
        guard frameSize >= prefixSize else {
            throw ClipboardBrokerFrameError.malformedLength
        }
        guard buffer.count >= frameSize else { return nil }
        let payload = Data(buffer[prefixSize..<frameSize])
        buffer.removeSubrange(0..<frameSize)
        return payload
    }
}

public enum ClipboardBrokerStaging {
    public static let directoryName = "BlocksClipboardBroker-Staging"
    public static let fileExtension = "payload"

    public static func makeToken() -> String {
        UUID().uuidString.lowercased()
    }

    public static func fileURL(rootDirectory: URL, token: String) -> URL? {
        guard UUID(uuidString: token) != nil,
              token == token.lowercased() else {
            return nil
        }
        let root = rootDirectory.standardizedFileURL
        let candidate = root
            .appendingPathComponent(token, isDirectory: false)
            .appendingPathExtension(fileExtension)
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}
