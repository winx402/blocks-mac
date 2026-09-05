@preconcurrency import BlocksCore
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

struct ClipboardRecordActionRead {
    let record: ClipboardRecorderRecord?
    let payload: ClipboardRecorderPayload?
    let failure: ClipboardPayloadReadFailure?
}

struct ClipboardImagePreviewRead: @unchecked Sendable {
    let pngData: Data?
    let failure: ClipboardPayloadReadFailure?
}

struct ClipboardDetailPreviewRead: @unchecked Sendable {
    let text: String?
    let thumbnailImage: CGImage?
    let failure: ClipboardPayloadReadFailure?
}

/// Owns payload reads required by user actions.
///
/// Payloads may contain large images or file manifests, so they must never be
/// fetched synchronously from a panel gesture on `MainActor`.
final class ClipboardRecordActionPipeline: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-record-action"
    )
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-image-preview"
    )

    private let repository: ClipboardRepository?
    private let queue = DispatchQueue(
        label: "app.blocks.clipboard.record-action",
        qos: .userInitiated
    )

    init(repository: ClipboardRepository?) {
        self.repository = repository
    }

    func readText(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        maximumCharacterCount: Int
    ) async -> ClipboardTextReadResult {
        await withCheckedContinuation { continuation in
            queue.async { [repository] in
                guard let repository else {
                    continuation.resume(returning: .failure(
                        recordID: recordID,
                        purpose: purpose,
                        failure: .repositoryUnavailable
                    ))
                    return
                }
                do {
                    guard let record = try repository.loadRecord(
                        recordID: recordID
                    ) else {
                        continuation.resume(returning: .failure(
                            recordID: recordID,
                            purpose: purpose,
                            failure: .recordNotFound
                        ))
                        return
                    }
                    guard record.restorable else {
                        continuation.resume(returning: .failure(
                            recordID: recordID,
                            purpose: purpose,
                            failure: .recordNotRestorable
                        ))
                        return
                    }
                    guard let text = try repository.readBoundedText(
                        recordID: recordID,
                        maximumCharacterCount: maximumCharacterCount
                    ) else {
                        continuation.resume(returning: .failure(
                            recordID: recordID,
                            purpose: purpose,
                            failure: .payloadUnavailable
                        ))
                        return
                    }
                    continuation.resume(returning: .success(
                        recordID: recordID,
                        purpose: purpose,
                        text: text
                    ))
                } catch {
                    continuation.resume(returning: .failure(
                        recordID: recordID,
                        purpose: purpose,
                        failure: .repositoryUnavailable
                    ))
                }
            }
        }
    }

    func read(recordID: String) async -> ClipboardRecordActionRead {
        await withCheckedContinuation { continuation in
            queue.async { [repository] in
                let interval = Self.signposter.beginInterval("PayloadRead")
                defer { Self.signposter.endInterval("PayloadRead", interval) }
                guard let repository else {
                    continuation.resume(returning: ClipboardRecordActionRead(
                        record: nil,
                        payload: nil,
                        failure: .repositoryUnavailable
                    ))
                    return
                }
                do {
                    guard let record = try repository.loadRecord(recordID: recordID) else {
                        continuation.resume(returning: ClipboardRecordActionRead(
                            record: nil,
                            payload: nil,
                            failure: .recordNotFound
                        ))
                        return
                    }
                    guard record.restorable else {
                        continuation.resume(returning: ClipboardRecordActionRead(
                            record: record,
                            payload: nil,
                            failure: .recordNotRestorable
                        ))
                        return
                    }
                    guard let payload = try repository.readPayload(recordID: recordID) else {
                        continuation.resume(returning: ClipboardRecordActionRead(
                            record: record,
                            payload: nil,
                            failure: .payloadUnavailable
                        ))
                        return
                    }
                    continuation.resume(returning: ClipboardRecordActionRead(
                        record: record,
                        payload: payload,
                        failure: nil
                    ))
                } catch {
                    continuation.resume(returning: ClipboardRecordActionRead(
                        record: nil,
                        payload: nil,
                        failure: .repositoryUnavailable
                    ))
                }
            }
        }
    }

    func readDetailPreview(
        recordID: String,
        maxPixelSize: Int = 720
    ) async -> ClipboardDetailPreviewRead {
        await withCheckedContinuation { continuation in
            queue.async { [repository] in
                let startedAt = ContinuousClock.now
                let interval = Self.signposter.beginInterval("DetailPreviewRead")
                defer { Self.signposter.endInterval("DetailPreviewRead", interval) }
                guard let repository else {
                    continuation.resume(returning: ClipboardDetailPreviewRead(
                        text: nil,
                        thumbnailImage: nil,
                        failure: .repositoryUnavailable
                    ))
                    return
                }
                do {
                    guard let record = try repository.loadRecord(recordID: recordID) else {
                        continuation.resume(returning: ClipboardDetailPreviewRead(
                            text: nil,
                            thumbnailImage: nil,
                            failure: .recordNotFound
                        ))
                        return
                    }
                    guard record.restorable else {
                        continuation.resume(returning: ClipboardDetailPreviewRead(
                            text: nil,
                            thumbnailImage: nil,
                            failure: .recordNotRestorable
                        ))
                        return
                    }
                    guard let payload = try repository.readPayload(recordID: recordID) else {
                        continuation.resume(returning: ClipboardDetailPreviewRead(
                            text: nil,
                            thumbnailImage: nil,
                            failure: .payloadUnavailable
                        ))
                        return
                    }
                    // Keep the decoded thumbnail produced by ImageIO. Returning
                    // PNG data here forced the detail view to decode the same
                    // image again on MainActor whenever a panel opened.
                    let thumbnail = payload.pngData
                        .flatMap { Self.makeThumbnailImage($0, maxPixelSize: maxPixelSize) }
                    Self.logger.debug(
                        "stage=detail-preview-finished record=\(String(recordID.suffix(8)), privacy: .public) kind=\(record.kind.rawValue, privacy: .public) hasText=\((payload.text ?? payload.urlString) != nil) hasImage=\(thumbnail != nil) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                    continuation.resume(returning: ClipboardDetailPreviewRead(
                        text: payload.text ?? payload.urlString,
                        thumbnailImage: thumbnail,
                        failure: nil
                    ))
                } catch {
                    Self.logger.error(
                        "stage=detail-preview-failed record=\(String(recordID.suffix(8)), privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                    continuation.resume(returning: ClipboardDetailPreviewRead(
                        text: nil,
                        thumbnailImage: nil,
                        failure: .repositoryUnavailable
                    ))
                }
            }
        }
    }

    func readImagePreview(
        recordID: String,
        maxPixelSize: Int = 720
    ) async -> ClipboardImagePreviewRead {
        await withCheckedContinuation { continuation in
            queue.async { [repository] in
                let startedAt = ContinuousClock.now
                let interval = Self.signposter.beginInterval("ImagePreviewRead")
                defer { Self.signposter.endInterval("ImagePreviewRead", interval) }
                guard let repository else {
                    Self.logImagePreview(
                        stage: "repository-unavailable",
                        recordID: recordID,
                        startedAt: startedAt
                    )
                    continuation.resume(returning: ClipboardImagePreviewRead(
                        pngData: nil,
                        failure: .repositoryUnavailable
                    ))
                    return
                }
                do {
                    guard let sourceData = try repository.readImageData(recordID: recordID) else {
                        Self.logImagePreview(
                            stage: "payload-unavailable",
                            recordID: recordID,
                            startedAt: startedAt
                        )
                        continuation.resume(returning: ClipboardImagePreviewRead(
                            pngData: nil,
                            failure: .payloadUnavailable
                        ))
                        return
                    }
                    guard let pngData = Self.makeThumbnailPNG(
                        sourceData,
                        maxPixelSize: maxPixelSize
                    ) else {
                        Self.logImagePreview(
                            stage: "thumbnail-failed",
                            recordID: recordID,
                            sourceBytes: sourceData.count,
                            startedAt: startedAt
                        )
                        continuation.resume(returning: ClipboardImagePreviewRead(
                            pngData: nil,
                            failure: .payloadUnavailable
                        ))
                        return
                    }
                    Self.logImagePreview(
                        stage: "finished",
                        recordID: recordID,
                        sourceBytes: sourceData.count,
                        thumbnailBytes: pngData.count,
                        startedAt: startedAt
                    )
                    continuation.resume(returning: ClipboardImagePreviewRead(
                        pngData: pngData,
                        failure: nil
                    ))
                } catch {
                    Self.logImagePreview(
                        stage: "repository-failed",
                        recordID: recordID,
                        startedAt: startedAt,
                        error: error
                    )
                    continuation.resume(returning: ClipboardImagePreviewRead(
                        pngData: nil,
                        failure: .repositoryUnavailable
                    ))
                }
            }
        }
    }

    private static func makeThumbnailPNG(
        _ sourceData: Data,
        maxPixelSize: Int
    ) -> Data? {
        guard let thumbnail = makeThumbnailImage(
            sourceData,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }
        return encodePNG(thumbnail)
    }

    private static func makeThumbnailImage(
        _ sourceData: Data,
        maxPixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            sourceData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
    }

    private static func encodePNG(_ thumbnail: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func logImagePreview(
        stage: String,
        recordID: String,
        sourceBytes: Int? = nil,
        thumbnailBytes: Int? = nil,
        startedAt: ContinuousClock.Instant,
        error: Error? = nil
    ) {
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMilliseconds = max(
            0,
            Int(
                Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            )
        )
        let errorDescription = error.map { String(describing: $0) } ?? "none"
        logger.debug(
            "stage=\(stage, privacy: .public) record=\(recordID, privacy: .public) sourceBytes=\(sourceBytes ?? -1) thumbnailBytes=\(thumbnailBytes ?? -1) elapsedMS=\(elapsedMilliseconds) error=\(errorDescription, privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(
        since startedAt: ContinuousClock.Instant
    ) -> Int {
        let elapsed = startedAt.duration(to: .now).components
        return max(
            0,
            Int(
                Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            )
        )
    }
}
