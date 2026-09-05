import CryptoKit
import Foundation

public enum ClipboardCaptureSkipReason: String, Codable {
    case paused
    case privacyPolicyUnavailable = "privacy_policy_unavailable"
    case excludedSource = "excluded_source"
    case unsupportedContent = "unsupported_content"

    private static let summaryPrefix = "clipboard.capture.skipped:"

    public var summaryCode: String {
        Self.summaryPrefix + rawValue
    }

    public init?(summaryCode: String) {
        guard summaryCode.hasPrefix(Self.summaryPrefix) else {
            return nil
        }
        self.init(rawValue: String(summaryCode.dropFirst(Self.summaryPrefix.count)))
    }
}

public struct ClipboardCapturePolicyDecision {
    public let record: ClipboardRecorderRecord
    public let payload: ClipboardRecorderPayload?
    public let skippedReason: ClipboardCaptureSkipReason?

    public var shouldPersistPayload: Bool {
        skippedReason == nil && payload != nil
    }

    public var skipped: Bool {
        skippedReason != nil
    }
}

public struct ClipboardCapturePolicy: @unchecked Sendable {
    public var paused: Bool
    public var privacyPolicyAvailable: Bool
    public var privacySnapshot: PrivacyPolicySnapshot
    public var supportedKinds: Set<ClipboardRecorderItemKind>

    public init(
        paused: Bool = false,
        privacyPolicyAvailable: Bool = true,
        privacySnapshot: PrivacyPolicySnapshot = PrivacyPolicySnapshot(),
        supportedKinds: Set<ClipboardRecorderItemKind> = ClipboardCapturePolicy.defaultSupportedKinds
    ) {
        self.paused = paused
        self.privacyPolicyAvailable = privacyPolicyAvailable
        self.privacySnapshot = privacySnapshot
        self.supportedKinds = supportedKinds
    }

    public func evaluate(
        record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?
    ) -> ClipboardCapturePolicyDecision {
        if !privacyPolicyAvailable {
            return skippedDecision(record: record, reason: .privacyPolicyUnavailable)
        }
        if paused {
            return skippedDecision(record: record, reason: .paused)
        }

        if privacySnapshot.match(sourceApp: record.sourceApp).decision == .deny {
            return skippedDecision(record: record, reason: .excludedSource)
        }

        if record.snapshotSkipped {
            return skippedDecision(record: record, reason: .unsupportedContent)
        }

        guard supportedKinds.contains(record.kind), payloadIsSupported(payload, for: record.kind) else {
            return skippedDecision(record: record, reason: .unsupportedContent)
        }

        return ClipboardCapturePolicyDecision(record: record, payload: payload, skippedReason: nil)
    }

    public static let defaultSupportedKinds: Set<ClipboardRecorderItemKind> = [
        .text,
        .richText,
        .image,
        .url,
        .fileURL
    ]

    private func payloadIsSupported(_ payload: ClipboardRecorderPayload?, for kind: ClipboardRecorderItemKind) -> Bool {
        guard let payload else {
            return false
        }
        switch kind {
        case .text:
            return payload.text != nil
        case .richText:
            return payload.text != nil || payload.rtfData != nil
        case .image:
            return payload.pngData != nil
        case .url:
            return payload.urlString != nil || payload.text != nil
        case .fileURL:
            return payload.urlString != nil || payload.text != nil
        case .mixed, .unknown:
            return false
        }
    }

    private func skippedDecision(
        record: ClipboardRecorderRecord,
        reason: ClipboardCaptureSkipReason
    ) -> ClipboardCapturePolicyDecision {
        ClipboardCapturePolicyDecision(
            record: redactedSkippedRecord(from: record, reason: reason),
            payload: nil,
            skippedReason: reason
        )
    }

    private func redactedSkippedRecord(
        from record: ClipboardRecorderRecord,
        reason: ClipboardCaptureSkipReason
    ) -> ClipboardRecorderRecord {
        let excluded: Bool
        switch reason {
        case .paused:
            excluded = record.excluded
        case .privacyPolicyUnavailable:
            excluded = true
        case .excludedSource:
            excluded = true
        case .unsupportedContent:
            excluded = record.excluded
        }

        let signature = Self.sanitizedSkippedSignature(recordID: record.id, reason: reason)
        return ClipboardRecorderRecord(
            id: record.id,
            createdAt: record.createdAt,
            changeCount: record.changeCount,
            kind: .unknown,
            formatSummary: ClipboardRecorderFormatSummary(itemCount: 1, types: []),
            sourceApp: record.sourceApp,
            signatureSHA256: signature,
            signatureSHA256_12: String(signature.prefix(12)),
            fixtureOwned: record.fixtureOwned,
            pinned: false,
            restorable: false,
            excluded: excluded,
            snapshotSkipped: true,
            summary: reason.summaryCode
        )
    }

    static func sanitizedSkippedSignature(
        recordID: String,
        reason: ClipboardCaptureSkipReason
    ) -> String {
        let seed = "clipboard-skipped:\(reason.rawValue):\(recordID)"
        return SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
