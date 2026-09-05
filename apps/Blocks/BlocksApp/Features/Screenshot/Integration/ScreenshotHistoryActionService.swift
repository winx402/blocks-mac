import AppKit
import BlocksCore
import BlocksScreenshotCore
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum ScreenshotHistoryActionServiceError: Error, Equatable {
    case invalidCursor
    case repositoryUnavailable
    case recordNotFound
    case notImage
    case ocrLocked
    case alreadyRunning
    case retryRejected
    case outputFileRequired
    case exportFailed

    var code: String {
        switch self {
        case .invalidCursor: "invalid_cursor"
        case .repositoryUnavailable: "repository_unavailable"
        case .recordNotFound: "record_not_found"
        case .notImage: "not_image"
        case .ocrLocked: "ocr_locked"
        case .alreadyRunning: "already_running"
        case .retryRejected: "retry_rejected"
        case .outputFileRequired: "output_file_required"
        case .exportFailed: "export_failed"
        }
    }
}

@MainActor
final class ScreenshotHistoryActionService {
    typealias TemporaryFileWriter = @Sendable (Data, URL) async throws -> Void

    private let repository: ClipboardRepository?
    private let ocrQueue: ClipboardVisionOCRQueue?
    private let temporaryFileWriter: TemporaryFileWriter
    private var activeExportIDs: [String: UUID] = [:]

    init(
        repository: ClipboardRepository?,
        ocrQueue: ClipboardVisionOCRQueue?,
        temporaryFileWriter: TemporaryFileWriter? = nil
    ) {
        self.repository = repository
        self.ocrQueue = ocrQueue
        self.temporaryFileWriter = temporaryFileWriter ?? { data, url in
            try await ScreenshotHistoryActionService.writeTemporaryFile(data, to: url)
        }
    }

    func query(
        _ input: ScreenshotHistoryQueryActionInput
    ) async throws -> ScreenshotHistoryPageActionResult {
        try await page(
            query: nil,
            cursor: input.cursor,
            limit: input.limit,
            includeOCR: input.includeOCR
        )
    }

    func search(
        _ input: ScreenshotHistorySearchActionInput
    ) async throws -> ScreenshotHistoryPageActionResult {
        try await page(
            query: input.query,
            cursor: input.cursor,
            limit: input.limit,
            includeOCR: input.includeOCR
        )
    }

    func status(
        _ input: ScreenshotOCRStatusActionInput
    ) async throws -> ScreenshotOCRStatusActionResult {
        let repository = try resolvedRepository()
        let documents = try await Task.detached(priority: .utility) {
            for recordID in input.recordIDs {
                _ = try Self.requireScreenshotRecord(recordID: recordID, repository: repository)
            }
            return try repository.loadScreenshotOCRDocuments(recordIDs: input.recordIDs)
        }.value
        return ScreenshotOCRStatusActionResult(items: try input.recordIDs.map { recordID in
            guard let document = documents[recordID] else {
                throw ScreenshotHistoryActionServiceError.recordNotFound
            }
            return ScreenshotOCRStatusActionItem(
                recordID: recordID,
                ocrState: document.ocrState.actionState,
                captureIdentityRevision: document.revision,
                contentRevision: document.contentRevision
            )
        })
    }

    func retry(
        _ input: ScreenshotOCRRetryActionInput
    ) async throws -> ScreenshotOCRRetryActionResult {
        let repository = try resolvedRepository()
        let document: ClipboardSearchDocument
        do {
            document = try await Task.detached(priority: .utility) {
                _ = try Self.requireScreenshotRecord(recordID: input.recordID, repository: repository)
                return try repository.enqueueScreenshotOCRRetry(recordID: input.recordID)
            }.value
        } catch let error as ScreenshotHistoryRepositoryActionError {
            throw mapRepositoryError(error)
        }
        if let ocrQueue {
            Task.detached(priority: .utility) {
                _ = await ocrQueue.processQueued(
                    recordID: document.recordID,
                    revision: document.revision
                )
            }
        }
        return ScreenshotOCRRetryActionResult(
            recordID: input.recordID,
            captureIdentityRevision: document.revision,
            contentRevision: document.contentRevision
        )
    }

    func export(
        _ input: ScreenshotHistoryExportActionInput,
        outputFile: FileHandle?
    ) async throws -> ScreenshotHistoryExportActionResult {
        guard let outputFile else {
            throw ScreenshotHistoryActionServiceError.outputFileRequired
        }
        let repository = try resolvedRepository()
        let payload = try await Task.detached(priority: .utility) {
            try Self.requireScreenshotRecord(recordID: input.recordID, repository: repository)
        }.value
        guard payload.kind == .image,
              let png = payload.pngData,
              !png.isEmpty else {
            throw ScreenshotHistoryActionServiceError.notImage
        }
        let outputURL = try Self.outputURL(for: outputFile)
        let exportKey = outputURL.standardizedFileURL.path
        let exportID = UUID()
        activeExportIDs[exportKey] = exportID
        let temporaryURL = Self.temporaryURL(for: outputURL)
        let temporaryFileWriter = self.temporaryFileWriter
        defer {
            if activeExportIDs[exportKey] == exportID {
                activeExportIDs.removeValue(forKey: exportKey)
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        let exportWork = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data: Data
            switch input.format {
            case .png:
                data = png
            case .jpeg:
                guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ScreenshotHistoryActionServiceError.exportFailed
                }
                data = try ScreenshotImageEncoder().jpegData(image, quality: 0.9)
            }
            try Task.checkCancellation()
            try await temporaryFileWriter(data, temporaryURL)
            try Task.checkCancellation()
            return Int64(data.count)
        }
        let bytesWritten = try await withTaskCancellationHandler(operation: {
            try await exportWork.value
        }, onCancel: {
            exportWork.cancel()
        })
        try Task.checkCancellation()
        guard activeExportIDs[exportKey] == exportID else {
            throw CancellationError()
        }
        do {
            try Self.replaceItem(at: outputURL, with: temporaryURL)
        } catch {
            throw ScreenshotHistoryActionServiceError.exportFailed
        }
        return ScreenshotHistoryExportActionResult(
            bytesWritten: bytesWritten,
            format: input.format
        )
    }

    private func page(
        query: String?,
        cursor: String?,
        limit: Int,
        includeOCR: Bool
    ) async throws -> ScreenshotHistoryPageActionResult {
        let repository = try resolvedRepository()
        let digest = queryDigest(query)
        let cursorKey = try cursor.map { try decodeCursor($0, expectedQueryDigest: digest) }
        let records = try await Task.detached(priority: .utility) {
            if let query {
                return try repository.searchScreenshotHistory(
                    query: query,
                    after: cursorKey,
                    limit: limit + 1
                )
            }
            return try repository.loadScreenshotHistory(
                after: cursorKey,
                limit: limit + 1
            )
        }.value
        let pageRecords = Array(records.prefix(limit))
        let recordIDs = pageRecords.map(\.id)
        let tagsByRecord = try await Task.detached(priority: .utility) {
            try ClipboardTagRepository(repository: repository).loadRecordTags(recordIDs: recordIDs)
        }.value
        let documents = try await Task.detached(priority: .utility) {
            try repository.loadScreenshotOCRDocuments(recordIDs: recordIDs)
        }.value

        var items: [ScreenshotHistoryActionItem] = []
        items.reserveCapacity(pageRecords.count)
        for record in pageRecords {
            guard let document = documents[record.id] else { continue }
            let tags = tagsByRecord[record.id, default: []]
            try Self.requireScreenshotRecord(record: record)
            let payload = try await Task.detached(priority: .utility) {
                try repository.readPayload(recordID: record.id)
            }.value
            items.append(ScreenshotHistoryActionItem(
                recordID: record.id,
                createdAt: record.createdAt,
                lastCopiedAt: record.lastCopiedAt,
                pixelSize: pixelSize(payload),
                isFavorite: tags.contains(where: \.isFavorite),
                tags: tags.map(\.displayName),
                title: record.customTitle,
                ocrState: document.ocrState.actionState,
                contentRevision: document.contentRevision,
                ocrSummary: Self.ocrSummary(document.ocrText),
                ocr: includeOCR ? document.ocrText : nil
            ))
        }
        let nextCursor: String?
        if records.count > limit, let last = pageRecords.last {
            nextCursor = try encodeCursor(
                ScreenshotHistoryCursorEnvelope(
                    version: 2,
                    queryDigest: digest,
                    lastCopiedAt: last.lastCopiedAt.timeIntervalSince1970,
                    createdAt: last.createdAt.timeIntervalSince1970,
                    changeCount: last.changeCount,
                    recordID: last.id
                )
            )
        } else {
            nextCursor = nil
        }
        return ScreenshotHistoryPageActionResult(items: items, nextCursor: nextCursor)
    }

    private func resolvedRepository() throws -> ClipboardRepository {
        guard let repository else {
            throw ScreenshotHistoryActionServiceError.repositoryUnavailable
        }
        return repository
    }

    private nonisolated static func requireScreenshotRecord(
        recordID: String,
        repository: ClipboardRepository
    ) throws -> ClipboardRecorderPayload {
        do {
            _ = try repository.requireScreenshotRecord(recordID: recordID)
        } catch let error as ScreenshotHistoryRepositoryActionError {
            switch error {
            case .recordNotFound:
                throw ScreenshotHistoryActionServiceError.recordNotFound
            case .notImage:
                throw ScreenshotHistoryActionServiceError.notImage
            case .ocrLocked:
                throw ScreenshotHistoryActionServiceError.ocrLocked
            case .alreadyRunning:
                throw ScreenshotHistoryActionServiceError.alreadyRunning
            case .retryRejected:
                throw ScreenshotHistoryActionServiceError.retryRejected
            }
        }
        guard let payload = try repository.readPayload(recordID: recordID) else {
            throw ScreenshotHistoryActionServiceError.recordNotFound
        }
        guard payload.kind == .image else {
            throw ScreenshotHistoryActionServiceError.notImage
        }
        return payload
    }

    private nonisolated static func requireScreenshotRecord(
        record: ClipboardRecorderRecord
    ) throws {
        guard record.kind == .image else {
            throw ScreenshotHistoryActionServiceError.notImage
        }
        guard record.origin == .screenshot else {
            throw ScreenshotHistoryActionServiceError.recordNotFound
        }
    }

    private func queryDigest(_ query: String?) -> String {
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "history"
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func encodeCursor(_ cursor: ScreenshotHistoryCursorEnvelope) throws -> String {
        try JSONEncoder().encode(cursor).base64URLEncodedString()
    }

    private func decodeCursor(
        _ value: String,
        expectedQueryDigest: String
    ) throws -> ScreenshotHistoryCursorKey {
        guard let data = Data(base64URLString: value),
              let envelope = try? JSONDecoder().decode(ScreenshotHistoryCursorEnvelope.self, from: data),
              envelope.version == 2,
              envelope.queryDigest == expectedQueryDigest,
              !envelope.recordID.isEmpty else {
            throw ScreenshotHistoryActionServiceError.invalidCursor
        }
        return ScreenshotHistoryCursorKey(
            lastCopiedAt: Date(timeIntervalSince1970: envelope.lastCopiedAt),
            createdAt: Date(timeIntervalSince1970: envelope.createdAt),
            changeCount: envelope.changeCount,
            recordID: envelope.recordID
        )
    }

    private func pixelSize(_ payload: ClipboardRecorderPayload?) -> ScreenshotPixelDimensions {
        guard let data = payload?.pngData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return ScreenshotPixelDimensions(width: 0, height: 0)
        }
        return ScreenshotPixelDimensions(width: width.intValue, height: height.intValue)
    }

    private static func ocrSummary(_ text: String?) -> String {
        guard let text else { return "" }
        return String(text.prefix(160))
    }

    private func mapRepositoryError(
        _ error: ScreenshotHistoryRepositoryActionError
    ) -> ScreenshotHistoryActionServiceError {
        switch error {
        case .recordNotFound: .recordNotFound
        case .notImage: .notImage
        case .ocrLocked: .ocrLocked
        case .alreadyRunning: .alreadyRunning
        case .retryRejected: .retryRejected
        }
    }

    private nonisolated static func outputURL(for outputFile: FileHandle) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(outputFile.fileDescriptor, F_GETPATH, &path) != -1 else {
            throw ScreenshotHistoryActionServiceError.exportFailed
        }
        return URL(fileURLWithPath: String(cString: path))
    }

    private nonisolated static func temporaryURL(for outputURL: URL) -> URL {
        outputURL.deletingLastPathComponent()
            .appendingPathComponent(".blocks-export-\(UUID().uuidString).tmp")
    }

    private nonisolated static func writeTemporaryFile(_ data: Data, to url: URL) async throws {
        do {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            try file.synchronize()
        } catch {
            throw ScreenshotHistoryActionServiceError.exportFailed
        }
    }

    private nonisolated static func replaceItem(at outputURL: URL, with temporaryURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(
                outputURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}

private struct ScreenshotHistoryCursorEnvelope: Codable {
    let version: Int
    let queryDigest: String
    let lastCopiedAt: TimeInterval
    let createdAt: TimeInterval
    let changeCount: Int
    let recordID: String
}

private extension ClipboardOCRState {
    var actionState: ScreenshotOCRActionState {
        switch self {
        case .notRequired: .notRequired
        case .pending: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
    }
}

private extension Data {
    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
