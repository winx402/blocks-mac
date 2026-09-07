import CryptoKit
import Foundation

public enum ClipboardRecorderItemKind: String, Codable, CaseIterable {
    case text
    case richText = "rich_text"
    case image
    case url
    case fileURL = "file_url"
    case mixed
    case unknown
}

public enum ClipboardRecordOrigin: String, Codable, CaseIterable, Sendable {
    case clipboard
    case screenshot
}

public enum ClipboardRecordOrdering {
    public static func isMoreRecent(
        _ lhs: ClipboardRecorderRecord,
        than rhs: ClipboardRecorderRecord
    ) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt { return lhs.lastCopiedAt > rhs.lastCopiedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        if lhs.changeCount != rhs.changeCount { return lhs.changeCount > rhs.changeCount }
        return lhs.id > rhs.id
    }

    public static func sorted(_ records: [ClipboardRecorderRecord]) -> [ClipboardRecorderRecord] {
        records.sorted { isMoreRecent($0, than: $1) }
    }
}

public struct ClipboardRecorderSourceApp: Codable {
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let sourceAppIsCandidate: Bool
    public let bundlePathHash: String?
    public let bundlePathSummary: String?
    public let sourceDirectory: PrivacyAppSourceDirectory?

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_identifier"
        case localizedName = "localized_name"
        case sourceAppIsCandidate = "source_app_is_candidate"
        case bundlePathHash = "bundle_path_hash"
        case bundlePathSummary = "bundle_path_summary"
        case sourceDirectory = "source_directory"
    }

    public init(
        bundleIdentifier: String?,
        localizedName: String?,
        sourceAppIsCandidate: Bool = true,
        bundlePathHash: String? = nil,
        bundlePathSummary: String? = nil,
        sourceDirectory: PrivacyAppSourceDirectory? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.sourceAppIsCandidate = sourceAppIsCandidate
        self.bundlePathHash = bundlePathHash
        self.bundlePathSummary = bundlePathSummary
        self.sourceDirectory = sourceDirectory
    }
}

public struct ClipboardRecorderFormatSummary: Codable {
    public let itemCount: Int
    public let types: [String]
    public let textLength: Int?
    public let byteCount: Int?
    public let fileCount: Int?
    public let urlCount: Int?

    enum CodingKeys: String, CodingKey {
        case itemCount = "item_count"
        case types
        case textLength = "text_length"
        case byteCount = "byte_count"
        case fileCount = "file_count"
        case urlCount = "url_count"
    }

    public init(
        itemCount: Int,
        types: [String],
        textLength: Int? = nil,
        byteCount: Int? = nil,
        fileCount: Int? = nil,
        urlCount: Int? = nil
    ) {
        self.itemCount = itemCount
        self.types = types.sorted()
        self.textLength = textLength
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.urlCount = urlCount
    }
}

public struct ClipboardRecorderPolicy: Codable {
    public let retentionSeconds: Int
    public let maxItems: Int
    public let excludedBundleIdentifiers: [String]

    enum CodingKeys: String, CodingKey {
        case retentionSeconds = "retention_seconds"
        case maxItems = "max_items"
        case excludedBundleIdentifiers = "excluded_bundle_identifiers"
    }

    public init(retentionSeconds: Int = 2_592_000, maxItems: Int = 500, excludedBundleIdentifiers: [String] = []) {
        self.retentionSeconds = max(0, retentionSeconds)
        self.maxItems = max(1, maxItems)
        self.excludedBundleIdentifiers = excludedBundleIdentifiers.sorted()
    }
}

public struct ClipboardRecorderRecord: Codable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let changeCount: Int
    public let kind: ClipboardRecorderItemKind
    public let formatSummary: ClipboardRecorderFormatSummary
    public let sourceApp: ClipboardRecorderSourceApp?
    public let signatureSHA256: String
    public let signatureSHA256_12: String
    public let fixtureOwned: Bool
    public let pinned: Bool
    public let restorable: Bool
    public let excluded: Bool
    public let snapshotSkipped: Bool
    public let customTitle: String?
    public let lastCopiedAt: Date
    public let summary: String
    public let origin: ClipboardRecordOrigin

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case changeCount = "change_count"
        case kind
        case formatSummary = "format_summary"
        case sourceApp = "source_app"
        case signatureSHA256 = "signature_sha256"
        case signatureSHA256_12 = "signature_sha256_12"
        case fixtureOwned = "fixture_owned"
        case pinned
        case restorable
        case excluded
        case snapshotSkipped = "snapshot_skipped"
        case customTitle = "custom_title"
        case lastCopiedAt = "last_copied_at"
        case summary
        case origin = "origin_kind"
    }

    public init(
        id: String,
        createdAt: Date,
        changeCount: Int,
        kind: ClipboardRecorderItemKind,
        formatSummary: ClipboardRecorderFormatSummary,
        sourceApp: ClipboardRecorderSourceApp?,
        signatureSHA256: String? = nil,
        signatureSHA256_12: String,
        fixtureOwned: Bool,
        pinned: Bool = false,
        restorable: Bool,
        excluded: Bool = false,
        snapshotSkipped: Bool = false,
        customTitle: String? = nil,
        lastCopiedAt: Date? = nil,
        summary: String,
        origin: ClipboardRecordOrigin = .clipboard
    ) {
        self.id = id
        self.createdAt = createdAt
        self.changeCount = changeCount
        self.kind = kind
        self.formatSummary = formatSummary
        self.sourceApp = sourceApp
        self.signatureSHA256 = signatureSHA256 ?? signatureSHA256_12
        self.signatureSHA256_12 = signatureSHA256_12
        self.fixtureOwned = fixtureOwned
        self.pinned = pinned
        self.restorable = restorable
        self.excluded = excluded
        self.snapshotSkipped = snapshotSkipped
        self.customTitle = customTitle
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.summary = summary
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        changeCount = try container.decode(Int.self, forKey: .changeCount)
        kind = try container.decode(ClipboardRecorderItemKind.self, forKey: .kind)
        formatSummary = try container.decode(ClipboardRecorderFormatSummary.self, forKey: .formatSummary)
        sourceApp = try container.decodeIfPresent(ClipboardRecorderSourceApp.self, forKey: .sourceApp)
        signatureSHA256_12 = try container.decode(String.self, forKey: .signatureSHA256_12)
        signatureSHA256 = try container.decodeIfPresent(String.self, forKey: .signatureSHA256) ?? signatureSHA256_12
        fixtureOwned = try container.decodeIfPresent(Bool.self, forKey: .fixtureOwned) ?? false
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        restorable = try container.decodeIfPresent(Bool.self, forKey: .restorable) ?? false
        excluded = try container.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
        snapshotSkipped = try container.decodeIfPresent(Bool.self, forKey: .snapshotSkipped) ?? false
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        lastCopiedAt = try container.decodeIfPresent(Date.self, forKey: .lastCopiedAt) ?? createdAt
        summary = try container.decode(String.self, forKey: .summary)
        origin = try container.decodeIfPresent(ClipboardRecordOrigin.self, forKey: .origin) ?? .clipboard
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(changeCount, forKey: .changeCount)
        try container.encode(kind, forKey: .kind)
        try container.encode(formatSummary, forKey: .formatSummary)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encode(signatureSHA256, forKey: .signatureSHA256)
        try container.encode(signatureSHA256_12, forKey: .signatureSHA256_12)
        try container.encode(fixtureOwned, forKey: .fixtureOwned)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(restorable, forKey: .restorable)
        try container.encode(excluded, forKey: .excluded)
        try container.encode(snapshotSkipped, forKey: .snapshotSkipped)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(lastCopiedAt, forKey: .lastCopiedAt)
        try container.encode(summary, forKey: .summary)
        try container.encode(origin, forKey: .origin)
    }

    public func replacing(
        pinned: Bool? = nil,
        excluded: Bool? = nil,
        snapshotSkipped: Bool? = nil,
        customTitle: String? = nil,
        lastCopiedAt: Date? = nil,
        summary: String? = nil
    ) -> ClipboardRecorderRecord {
        ClipboardRecorderRecord(
            id: id,
            createdAt: createdAt,
            changeCount: changeCount,
            kind: kind,
            formatSummary: formatSummary,
            sourceApp: sourceApp,
            signatureSHA256: signatureSHA256,
            signatureSHA256_12: signatureSHA256_12,
            fixtureOwned: fixtureOwned,
            pinned: pinned ?? self.pinned,
            restorable: restorable,
            excluded: excluded ?? self.excluded,
            snapshotSkipped: snapshotSkipped ?? self.snapshotSkipped,
            customTitle: customTitle ?? self.customTitle,
            lastCopiedAt: lastCopiedAt ?? self.lastCopiedAt,
            summary: summary ?? self.summary,
            origin: origin
        )
    }
}

public struct ClipboardRecorderStoreDocument: Codable {
    public let schemaVersion: String
    public let storeName: String
    public let updatedAt: Date
    public let policy: ClipboardRecorderPolicy
    public let records: [ClipboardRecorderRecord]
    public let payloads: [String: ClipboardRecorderPayload]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storeName = "store_name"
        case updatedAt = "updated_at"
        case policy
        case records
        case payloads
    }

    public init(
        schemaVersion: String = ClipboardRecorderStore.schemaVersion,
        storeName: String,
        updatedAt: Date,
        policy: ClipboardRecorderPolicy,
        records: [ClipboardRecorderRecord],
        payloads: [String: ClipboardRecorderPayload] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.storeName = storeName
        self.updatedAt = updatedAt
        self.policy = policy
        self.records = records
        self.payloads = payloads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        storeName = try container.decode(String.self, forKey: .storeName)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        policy = try container.decode(ClipboardRecorderPolicy.self, forKey: .policy)
        records = try container.decode([ClipboardRecorderRecord].self, forKey: .records)
        payloads = try container.decodeIfPresent([String: ClipboardRecorderPayload].self, forKey: .payloads) ?? [:]
    }
}

public struct ClipboardRecorderPayload: Codable {
    public let recordID: String
    public let kind: ClipboardRecorderItemKind
    public let text: String?
    public let rtfData: Data?
    public let pngData: Data?
    public let urlString: String?

    enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case kind
        case text
        case rtfData = "rtf_data_base64"
        case pngData = "png_data_base64"
        case urlString = "url_string"
    }

    public init(
        recordID: String,
        kind: ClipboardRecorderItemKind,
        text: String? = nil,
        rtfData: Data? = nil,
        pngData: Data? = nil,
        urlString: String? = nil
    ) {
        self.recordID = recordID
        self.kind = kind
        self.text = text
        self.rtfData = rtfData
        self.pngData = pngData
        self.urlString = urlString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(String.self, forKey: .recordID)
        kind = try container.decode(ClipboardRecorderItemKind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        pngData = try container.decodeIfPresent(Data.self, forKey: .pngData)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(rtfData, forKey: .rtfData)
        try container.encodeIfPresent(pngData, forKey: .pngData)
        try container.encodeIfPresent(urlString, forKey: .urlString)
    }
}

public struct ClipboardRecorderFixtureReport: Codable {
    public let ok: Bool
    public let storeName: String
    public let storeFile: String
    public let schemaVersion: String
    public let recordCount: Int
    public let restorableCount: Int
    public let pinnedCount: Int
    public let excludedCount: Int
    public let payloadCount: Int
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case storeName = "store_name"
        case storeFile = "store_file"
        case schemaVersion = "schema_version"
        case recordCount = "record_count"
        case restorableCount = "restorable_count"
        case pinnedCount = "pinned_count"
        case excludedCount = "excluded_count"
        case payloadCount = "payload_count"
        case warnings
    }
}

public struct ClipboardRecorderInspectReport: Codable {
    public let ok: Bool
    public let storeName: String
    public let storeFile: String
    public let schemaVersion: String
    public let recordCount: Int
    public let restorableCount: Int
    public let pinnedCount: Int
    public let excludedCount: Int
    public let skippedCount: Int
    public let realEventCount: Int
    public let duplicateSkippedCount: Int
    public let records: [ClipboardRecorderRecord]
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case storeName = "store_name"
        case storeFile = "store_file"
        case schemaVersion = "schema_version"
        case recordCount = "record_count"
        case restorableCount = "restorable_count"
        case pinnedCount = "pinned_count"
        case excludedCount = "excluded_count"
        case skippedCount = "skipped_count"
        case realEventCount = "real_event_count"
        case duplicateSkippedCount = "duplicate_skipped_count"
        case records
        case warnings
    }
}

public struct ClipboardRecorderWatchReport: Codable {
    public let ok: Bool
    public let storeName: String
    public let storeFile: String
    public let schemaVersion: String
    public let seconds: Int
    public let observedChangeCount: Int
    public let storedCount: Int
    public let skippedCount: Int
    public let duplicateSkippedCount: Int
    public let records: [ClipboardRecorderRecord]
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case storeName = "store_name"
        case storeFile = "store_file"
        case schemaVersion = "schema_version"
        case seconds
        case observedChangeCount = "observed_change_count"
        case storedCount = "stored_count"
        case skippedCount = "skipped_count"
        case duplicateSkippedCount = "duplicate_skipped_count"
        case records
        case warnings
    }
}

public enum ClipboardRecorderFixture {
    public static let textValue = "blocks fixture text"
    public static let richTextValue = "blocks fixture rtf"
    public static let imageValue = "blocks fixture image"
    public static let urlValue = "https://example.com/blocks-fixture"
    public static let excludedValue = "excluded fixture"

    public static func records(now: Date = Date()) -> [ClipboardRecorderRecord] {
        let source = ClipboardRecorderSourceApp(
            bundleIdentifier: "app.blocks.fixture",
            localizedName: "Blocks Fixture",
            sourceAppIsCandidate: true
        )
        return [
            record(
                id: "clip_fixture_text",
                now: now,
                changeCount: 1,
                kind: .text,
                types: ["public.utf8-plain-text"],
                textLength: textValue.count,
                source: source,
                fixture: textValue,
                restorable: true,
                summary: "Low-sensitive text fixture; content redacted."
            ),
            record(
                id: "clip_fixture_rich_text",
                now: now,
                changeCount: 2,
                kind: .richText,
                types: ["public.rtf", "public.utf8-plain-text"],
                textLength: richTextValue.count,
                byteCount: 96,
                source: source,
                fixture: richTextValue,
                restorable: true,
                summary: "Low-sensitive rich text fixture; payload omitted from report."
            ),
            record(
                id: "clip_fixture_image",
                now: now,
                changeCount: 3,
                kind: .image,
                types: ["public.png"],
                byteCount: 128,
                source: source,
                fixture: imageValue,
                restorable: true,
                summary: "Low-sensitive image fixture; no base64 emitted."
            ),
            record(
                id: "clip_fixture_url",
                now: now,
                changeCount: 4,
                kind: .url,
                types: ["public.url", "public.utf8-plain-text"],
                textLength: urlValue.count,
                urlCount: 1,
                source: source,
                fixture: urlValue,
                restorable: true,
                summary: "Low-sensitive URL fixture; URL value redacted from record summary."
            ),
            record(
                id: "clip_fixture_excluded",
                now: now,
                changeCount: 5,
                kind: .text,
                types: ["public.utf8-plain-text"],
                textLength: nil,
                source: ClipboardRecorderSourceApp(
                    bundleIdentifier: "app.blocks.fixture.excluded",
                    localizedName: "Excluded Fixture",
                    sourceAppIsCandidate: true
                ),
                fixture: excludedValue,
                restorable: false,
                excluded: true,
                snapshotSkipped: true,
                summary: "Excluded fixture event; content snapshot skipped."
            )
        ]
    }

    public static func payloads() -> [String: ClipboardRecorderPayload] {
        [
            "clip_fixture_text": ClipboardRecorderPayload(
                recordID: "clip_fixture_text",
                kind: .text,
                text: textValue
            ),
            "clip_fixture_rich_text": ClipboardRecorderPayload(
                recordID: "clip_fixture_rich_text",
                kind: .richText,
                text: richTextValue,
                rtfData: Data("{\\rtf1\\ansi blocks fixture rtf}".utf8)
            ),
            "clip_fixture_image": ClipboardRecorderPayload(
                recordID: "clip_fixture_image",
                kind: .image,
                pngData: onePixelPNGData
            ),
            "clip_fixture_url": ClipboardRecorderPayload(
                recordID: "clip_fixture_url",
                kind: .url,
                text: urlValue,
                urlString: urlValue
            )
        ]
    }

    private static func record(
        id: String,
        now: Date,
        changeCount: Int,
        kind: ClipboardRecorderItemKind,
        types: [String],
        textLength: Int? = nil,
        byteCount: Int? = nil,
        fileCount: Int? = nil,
        urlCount: Int? = nil,
        source: ClipboardRecorderSourceApp,
        fixture: String,
        restorable: Bool,
        excluded: Bool = false,
        snapshotSkipped: Bool = false,
        summary: String
    ) -> ClipboardRecorderRecord {
        ClipboardRecorderRecord(
            id: id,
            createdAt: now.addingTimeInterval(Double(changeCount)),
            changeCount: changeCount,
            kind: kind,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: types,
                textLength: textLength,
                byteCount: byteCount,
                fileCount: fileCount,
                urlCount: urlCount
            ),
            sourceApp: source,
            signatureSHA256: fullSHA256(fixture),
            signatureSHA256_12: shortSHA256(fixture),
            fixtureOwned: true,
            pinned: id == "clip_fixture_text",
            restorable: restorable,
            excluded: excluded,
            snapshotSkipped: snapshotSkipped,
            summary: summary
        )
    }

    private static func shortSHA256(_ value: String) -> String {
        fullSHA256(value).prefix(12).description
    }

    private static func fullSHA256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let onePixelPNGData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axW804AAAAASUVORK5CYII="
    )
}

public enum ClipboardRecorderStore {
    public static let applicationGroupIdentifier =
        BlocksRuntimeIdentity.clipboardRecorderApplicationGroupIdentifier
    public static let schemaVersion = "0.2.0"

    public static func fixtureDocument(
        storeName: String,
        now: Date = Date(),
        includePayloads: Bool = false
    ) -> ClipboardRecorderStoreDocument {
        ClipboardRecorderStoreDocument(
            storeName: sanitizedStoreName(storeName),
            updatedAt: now,
            policy: ClipboardRecorderPolicy(
                retentionSeconds: 2_592_000,
                maxItems: 500,
                excludedBundleIdentifiers: ["app.blocks.fixture.excluded"]
            ),
            records: ClipboardRecorderFixture.records(now: now),
            payloads: includePayloads ? ClipboardRecorderFixture.payloads() : [:]
        )
    }

    public static func writeFixture(
        storeName: String,
        directory: URL,
        reset: Bool = false,
        includePayloads: Bool = false,
        now: Date = Date()
    ) throws -> ClipboardRecorderFixtureReport {
        let safeName = sanitizedStoreName(storeName)
        let document = fixtureDocument(storeName: safeName, now: now, includePayloads: includePayloads)
        let url = try storeURL(storeName: safeName, directory: directory)
        if reset, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
        return ClipboardRecorderFixtureReport(
            ok: true,
            storeName: safeName,
            storeFile: url.lastPathComponent,
            schemaVersion: schemaVersion,
            recordCount: document.records.count,
            restorableCount: document.records.filter(\.restorable).count,
            pinnedCount: document.records.filter(\.pinned).count,
            excludedCount: document.records.filter(\.excluded).count,
            payloadCount: document.payloads.count,
            warnings: [
                "fixture_only",
                "raw_clipboard_content_not_read",
                "raw_clipboard_content_not_stored"
            ] + (includePayloads ? ["fixture_payloads_low_sensitive_only"] : [])
        )
    }

    public static func load(storeName: String, directory: URL) throws -> ClipboardRecorderStoreDocument {
        let url = try storeURL(storeName: sanitizedStoreName(storeName), directory: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClipboardRecorderStoreDocument.self, from: Data(contentsOf: url))
    }

    public static func loadIfPresent(storeName: String, directory: URL) throws -> ClipboardRecorderStoreDocument? {
        let safeName = sanitizedStoreName(storeName)
        let url = try storeURL(storeName: safeName, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try load(storeName: safeName, directory: directory)
    }

    public static func appendRecords(
        _ newRecords: [ClipboardRecorderRecord],
        storeName: String,
        directory: URL,
        policy: ClipboardRecorderPolicy = ClipboardRecorderPolicy(),
        seconds: Int = 0,
        observedChangeCount: Int? = nil
    ) throws -> ClipboardRecorderWatchReport {
        let safeName = sanitizedStoreName(storeName)
        let url = try storeURL(storeName: safeName, directory: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = try loadIfPresent(storeName: safeName, directory: directory)
        var records = existing?.records ?? []
        let existingSignatures = Set(records.map(\.signatureSHA256))
        var seenSignatures = existingSignatures
        var appended: [ClipboardRecorderRecord] = []
        var duplicateSkippedCount = 0

        for record in newRecords {
            if seenSignatures.contains(record.signatureSHA256) {
                duplicateSkippedCount += 1
                continue
            }
            records.append(record)
            appended.append(record)
            seenSignatures.insert(record.signatureSHA256)
        }

        records = Array(ClipboardRecordOrdering.sorted(records).prefix(policy.maxItems))
        let document = ClipboardRecorderStoreDocument(
            storeName: safeName,
            updatedAt: Date(),
            policy: policy,
            records: records,
            payloads: existing?.payloads ?? [:]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)

        return ClipboardRecorderWatchReport(
            ok: true,
            storeName: safeName,
            storeFile: url.lastPathComponent,
            schemaVersion: schemaVersion,
            seconds: seconds,
            observedChangeCount: observedChangeCount ?? newRecords.count,
            storedCount: appended.count,
            skippedCount: newRecords.filter(\.snapshotSkipped).count,
            duplicateSkippedCount: duplicateSkippedCount,
            records: appended,
            warnings: redactedWarnings
        )
    }

    public static func inspect(storeName: String, directory: URL) throws -> ClipboardRecorderInspectReport {
        let safeName = sanitizedStoreName(storeName)
        let url = try storeURL(storeName: safeName, directory: directory)
        let document = try loadIfPresent(storeName: safeName, directory: directory) ?? ClipboardRecorderStoreDocument(
            storeName: safeName,
            updatedAt: Date(),
            policy: ClipboardRecorderPolicy(),
            records: []
        )
        return ClipboardRecorderInspectReport(
            ok: true,
            storeName: safeName,
            storeFile: url.lastPathComponent,
            schemaVersion: document.schemaVersion,
            recordCount: document.records.count,
            restorableCount: document.records.filter(\.restorable).count,
            pinnedCount: document.records.filter(\.pinned).count,
            excludedCount: document.records.filter(\.excluded).count,
            skippedCount: document.records.filter(\.snapshotSkipped).count,
            realEventCount: document.records.filter { !$0.fixtureOwned }.count,
            duplicateSkippedCount: 0,
            records: document.records,
            warnings: redactedWarnings
        )
    }

    public static func reset(storeName: String, directory: URL) throws -> ClipboardRecorderInspectReport {
        let safeName = sanitizedStoreName(storeName)
        let url = try storeURL(storeName: safeName, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return ClipboardRecorderInspectReport(
            ok: true,
            storeName: safeName,
            storeFile: url.lastPathComponent,
            schemaVersion: schemaVersion,
            recordCount: 0,
            restorableCount: 0,
            pinnedCount: 0,
            excludedCount: 0,
            skippedCount: 0,
            realEventCount: 0,
            duplicateSkippedCount: 0,
            records: [],
            warnings: redactedWarnings
        )
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(
                BlocksRuntimeIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("ClipboardRecorder", isDirectory: true)
    }

    public static func debugDirectory() throws -> URL {
        if let sharedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        ),
           FileManager.default.isWritableFile(atPath: sharedContainer.path) {
            return sharedContainer.appendingPathComponent("ClipboardRecorderDebug", isDirectory: true)
        }
        return try defaultDirectory().appendingPathComponent("Debug", isDirectory: true)
    }

    public static func sanitizedStoreName(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let filtered = String(value.filter { allowed.contains($0) })
        return filtered.isEmpty ? "default" : String(filtered.prefix(64))
    }

    private static var redactedWarnings: [String] {
        [
            "redacted_metadata_only",
            "raw_clipboard_content_not_output",
            "real_user_events_not_restorable"
        ]
    }

    private static func storeURL(storeName: String, directory: URL) throws -> URL {
        let safeName = sanitizedStoreName(storeName)
        guard safeName == storeName else {
            throw NSError(
                domain: "BlocksClipboardRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid recorder store name."]
            )
        }
        return directory.appendingPathComponent("\(safeName).json", isDirectory: false)
    }
}
