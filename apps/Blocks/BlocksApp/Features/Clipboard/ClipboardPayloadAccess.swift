import BlocksCore
import Foundation

enum ClipboardPayloadReadPurpose: String, CaseIterable {
    case previewBuild
    case searchIndex
    case ocrInput
    case imagePreview
    case paste
    case copyPlainText
    case translationPreview
    case detailEditRead
    case detailFullValueRead
    case detailEditSave
    case detailCopyFullValue
}

struct ClipboardPayloadCacheKey: Hashable {
    let recordID: String
    let purpose: ClipboardPayloadReadPurpose
}

enum ClipboardPayloadReadFailure: String, Equatable {
    case recordNotFound
    case repositoryUnavailable
    case payloadUnavailable
    case recordNotRestorable
    case policyBlocked
}

struct ClipboardPayloadReadResult {
    let recordID: String
    let purpose: ClipboardPayloadReadPurpose
    let payload: ClipboardRecorderPayload?
    let failure: ClipboardPayloadReadFailure?

    var isAvailable: Bool {
        payload != nil && failure == nil
    }

    static func success(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        payload: ClipboardRecorderPayload
    ) -> ClipboardPayloadReadResult {
        ClipboardPayloadReadResult(
            recordID: recordID,
            purpose: purpose,
            payload: payload,
            failure: nil
        )
    }

    static func failure(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        failure: ClipboardPayloadReadFailure
    ) -> ClipboardPayloadReadResult {
        ClipboardPayloadReadResult(
            recordID: recordID,
            purpose: purpose,
            payload: nil,
            failure: failure
        )
    }
}

struct ClipboardTextReadResult {
    let recordID: String
    let purpose: ClipboardPayloadReadPurpose
    let text: String?
    let failure: ClipboardPayloadReadFailure?

    var isAvailable: Bool {
        text != nil && failure == nil
    }

    static func success(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        text: String
    ) -> ClipboardTextReadResult {
        ClipboardTextReadResult(
            recordID: recordID,
            purpose: purpose,
            text: text,
            failure: nil
        )
    }

    static func failure(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        failure: ClipboardPayloadReadFailure
    ) -> ClipboardTextReadResult {
        ClipboardTextReadResult(
            recordID: recordID,
            purpose: purpose,
            text: nil,
            failure: failure
        )
    }
}
