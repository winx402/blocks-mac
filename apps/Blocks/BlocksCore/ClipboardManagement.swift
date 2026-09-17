import AppKit
import CryptoKit
import Foundation
import ImageIO

public enum ClipboardManagementLimits {
    public static let maxDocumentBytes = 32 * 1024 * 1024
    public static let maxRecords = 1_000
    public static let maxImagePixels = 40_000_000
}

public struct ClipboardManagementError: Error, LocalizedError, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? { "Clipboard management failed (\(code))." }
}

public struct ClipboardManagementActionInput: Codable, Sendable {
    public let operation: String
    public let document: ClipboardImportDocument?
    public let dryRun: Bool
    public let recordIDs: [String]
    public let query: String?
    public let pinboardID: String?
    public let tag: String?
    public let name: String?
    public let limit: Int
    public let offset: Int
    public let all: Bool
    public let confirmationToken: String?
    public var isMutating: Bool {
        !["list", "search", "show", "export", "pinboard_list"].contains(operation)
    }
    public init(operation: String, document: ClipboardImportDocument? = nil, dryRun: Bool = false,
                recordIDs: [String] = [], query: String? = nil, pinboardID: String? = nil,
                tag: String? = nil, name: String? = nil, limit: Int = 100, offset: Int = 0,
                all: Bool = false, confirmationToken: String? = nil) {
        self.operation = operation; self.document = document; self.dryRun = dryRun
        self.recordIDs = recordIDs; self.query = query; self.pinboardID = pinboardID
        self.tag = tag; self.name = name; self.limit = limit; self.offset = offset
        self.all = all; self.confirmationToken = confirmationToken
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case operation, document, query, tag, name, limit, offset, all
        case dryRun = "dry_run", recordIDs = "record_ids", pinboardID = "pinboard_id"
        case confirmationToken = "confirmation_token"
    }
    public init(from decoder: Decoder) throws {
        try managementValidateKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operation: try c.decode(String.self, forKey: .operation),
                  document: try c.decodeIfPresent(ClipboardImportDocument.self, forKey: .document),
                  dryRun: try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false,
                  recordIDs: try c.decodeIfPresent([String].self, forKey: .recordIDs) ?? [],
                  query: try c.decodeIfPresent(String.self, forKey: .query),
                  pinboardID: try c.decodeIfPresent(String.self, forKey: .pinboardID),
                  tag: try c.decodeIfPresent(String.self, forKey: .tag),
                  name: try c.decodeIfPresent(String.self, forKey: .name),
                  limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100,
                  offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                  all: try c.decodeIfPresent(Bool.self, forKey: .all) ?? false,
                  confirmationToken: try c.decodeIfPresent(String.self, forKey: .confirmationToken))
    }
}

public struct ClipboardImportDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let pinboards: [String]
    public let records: [ClipboardImportRecord]
    public init(schemaVersion: Int = 1, pinboards: [String] = [], records: [ClipboardImportRecord]) {
        self.schemaVersion = schemaVersion; self.pinboards = pinboards; self.records = records
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion = "schema_version", pinboards, records }
    public init(from decoder: Decoder) throws {
        try managementValidateKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
                  pinboards: try c.decodeIfPresent([String].self, forKey: .pinboards) ?? [],
                  records: try c.decode([ClipboardImportRecord].self, forKey: .records))
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ClipboardManagementLimits.maxDocumentBytes else { throw ClipboardManagementError("document_too_large") }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ClipboardManagementError("invalid_document") }
    }
    /// Canonical on-disk form: compact sorted JSON, no trailing newline.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= ClipboardManagementLimits.maxDocumentBytes else { throw ClipboardManagementError("document_too_large") }
        return data
    }
}

public struct ClipboardImportRecord: Codable, Sendable {
    public let kind: String
    public let text: String?
    public let url: String?
    public let rtfBase64: String?
    public let pngBase64: String?
    public let fileURLs: [String]?
    public let pinboard: String?
    public let tags: [String]
    public let title: String?
    public let createdAt: String?
    public let lastCopiedAt: String?
    public let isFavorite: Bool?
    public init(kind: String, text: String? = nil, url: String? = nil, rtfBase64: String? = nil,
                pngBase64: String? = nil, fileURLs: [String]? = nil, pinboard: String? = nil,
                tags: [String] = [], title: String? = nil, createdAt: String? = nil,
                lastCopiedAt: String? = nil, isFavorite: Bool? = nil) {
        self.kind = kind; self.text = text; self.url = url; self.rtfBase64 = rtfBase64
        self.pngBase64 = pngBase64; self.fileURLs = fileURLs; self.pinboard = pinboard
        self.tags = tags; self.title = title
        self.createdAt = createdAt; self.lastCopiedAt = lastCopiedAt; self.isFavorite = isFavorite
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, text, url, pinboard, tags, title
        case rtfBase64 = "rtf_base64", pngBase64 = "png_base64", fileURLs = "file_urls"
        case createdAt = "created_at", lastCopiedAt = "last_copied_at", isFavorite = "is_favorite"
    }
    public init(from decoder: Decoder) throws {
        try managementValidateKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(String.self, forKey: .kind), text: try c.decodeIfPresent(String.self, forKey: .text),
                  url: try c.decodeIfPresent(String.self, forKey: .url),
                  rtfBase64: try c.decodeIfPresent(String.self, forKey: .rtfBase64),
                  pngBase64: try c.decodeIfPresent(String.self, forKey: .pngBase64),
                  fileURLs: try c.decodeIfPresent([String].self, forKey: .fileURLs),
                  pinboard: try c.decodeIfPresent(String.self, forKey: .pinboard),
                  tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
                  title: try c.decodeIfPresent(String.self, forKey: .title),
                  createdAt: try c.decodeIfPresent(String.self, forKey: .createdAt),
                  lastCopiedAt: try c.decodeIfPresent(String.self, forKey: .lastCopiedAt),
                  isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite))
    }
}

public struct ClipboardManagementRecord: Codable, Sendable {
    public let id: String
    public let kind: String
    public let title: String?
    public let pinned: Bool
    public let pinboardID: String?
    public let tags: [String]
    public let contentRevision: Int64
    public let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, kind, title, pinned, tags
        case pinboardID = "pinboard_id", contentRevision = "content_revision", createdAt = "created_at"
    }
}
public struct ClipboardManagementPinboard: Codable, Sendable {
    public let id: String
    public let name: String
}
public struct ClipboardManagementCounts: Codable, Sendable {
    public var selected = 0
    public var inserted = 0
    public var duplicates = 0
    public var updated = 0
    public var deleted = 0
    public var pinboardsCreated = 0
    public init() {}
    enum CodingKeys: String, CodingKey {
        case selected, inserted, duplicates, updated, deleted
        case pinboardsCreated = "pinboards_created"
    }
}
public struct ClipboardManagementResult: Codable, Sendable {
    public let operation: String
    public var dryRun: Bool
    public var records: [ClipboardManagementRecord] = []
    public var pinboards: [ClipboardManagementPinboard] = []
    public var document: ClipboardImportDocument?
    public var counts = ClipboardManagementCounts()
    public var confirmationToken: String?
    public var warnings: [String] = []
    public var mutatedRecordIDs: [String] = []
    public init(operation: String, dryRun: Bool = false) { self.operation = operation; self.dryRun = dryRun }
    enum CodingKeys: String, CodingKey {
        case operation, records, pinboards, document, counts, warnings
        case dryRun = "dry_run", confirmationToken = "confirmation_token"
        case mutatedRecordIDs = "mutated_record_ids"
    }
}

struct ValidatedClipboardImport {
    let wire: ClipboardImportRecord
    let payload: ClipboardRecorderPayload
    let signature: String
}

extension ClipboardImportRecord {
    func validated() throws -> ValidatedClipboardImport {
        func fail(_ code: String = "invalid_payload") throws -> Never { throw ClipboardManagementError(code) }
        guard let itemKind = ClipboardRecorderItemKind(rawValue: kind), itemKind != .mixed, itemKind != .unknown else { try fail("unsupported_kind") }
        guard (text?.utf8.count ?? 0) <= ClipboardBrokerLimits.maxTextBytes,
              (url?.utf8.count ?? 0) <= ClipboardBrokerLimits.maxTextBytes,
              (title?.utf8.count ?? 0) <= 4096, tags.count <= 100 else { try fail("payload_too_large") }
        guard [text, url, title].compactMap({ $0 }).allSatisfy({ !$0.contains("\0") }),
              (fileURLs ?? []).allSatisfy({ !$0.contains("\0") }) else { try fail("invalid_text") }
        for tag in tags {
            guard tag.utf8.count <= 256 else { try fail("invalid_tag") }
            // Stable reserved favorite alias is supported for faithful exports.
            let normalized = try ClipboardTagNameNormalizer().normalizedName(tag)
            if !ClipboardTagNameNormalizer.reservedAliases.contains(normalized) {
                _ = try ClipboardTagNameNormalizer().validateUserTagName(tag)
            }
        }
        if let pinboard { _ = try managementName(pinboard) }
        let created = try managementDate(createdAt) ?? Date()
        let copied = try managementDate(lastCopiedAt) ?? created
        guard copied >= created else { try fail("invalid_date") }
        guard (itemKind == .richText || rtfBase64 == nil), (itemKind == .image || pngBase64 == nil),
              (itemKind == .fileURL || fileURLs == nil), (itemKind == .url || url == nil) else { try fail() }
        var rtf: Data?, png: Data?, urlValue: String?, textValue = text
        let bytes: Data
        switch itemKind {
        case .text:
            guard let text else { try fail() }; bytes = Data(text.utf8)
        case .url:
            guard let value = url ?? text, let parsed = URL(string: value), parsed.scheme != nil, !parsed.isFileURL else { try fail("invalid_url") }
            urlValue = value; bytes = Data(value.utf8)
        case .fileURL:
            guard let fileURLs, fileURLs.count == 1, let value = fileURLs.first,
                  value.utf8.count <= ClipboardBrokerLimits.maxTextBytes,
                  let parsed = URL(string: value), parsed.isFileURL else { try fail("invalid_file_urls") }
            urlValue = value; textValue = text ?? parsed.path(percentEncoded: false); bytes = Data(value.utf8)
        case .richText:
            guard let rtfBase64, let data = Data(base64Encoded: rtfBase64), !data.isEmpty,
                  data.count <= ClipboardBrokerLimits.maxRTFBytes else { try fail("invalid_rtf") }
            // Decode only RTF, never HTML/RTFD. Reject embedded objects and fields
            // before invoking the parser; no URL or file references are loaded.
            let source = String(decoding: data, as: UTF8.self)
            guard source.hasPrefix("{\\rtf"), source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"),
                  managementRTFHasBalancedGroups(data),
                  source.range(of: #"\\(object|objdata|field|filetbl|datastore|bin|pict|shppict|nonshppict|htmltag|nextgraphic|attachment)(?![A-Za-z])"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  let decoded = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
                  decoded.string.utf8.count <= ClipboardBrokerLimits.maxTextBytes,
                  !decoded.string.contains("\0") else { try fail("invalid_rtf") }
            var unsupportedAttribute = false
            decoded.enumerateAttributes(in: NSRange(location: 0, length: decoded.length)) { attributes, _, stop in
                if attributes[.attachment] != nil || attributes[.link] != nil {
                    unsupportedAttribute = true
                    stop.pointee = true
                }
            }
            guard !unsupportedAttribute else { try fail("invalid_rtf") }
            rtf = data; textValue = text ?? decoded.string; bytes = data
        case .image:
            guard let pngBase64, let data = Data(base64Encoded: pngBase64), data.count <= ClipboardBrokerLimits.maxCanonicalPNGBytes,
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
                  width <= ClipboardManagementLimits.maxImagePixels / height,
                  CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { try fail("invalid_png") }
            png = data; bytes = data
        case .mixed, .unknown: try fail("unsupported_kind")
        }
        var digest = SHA256(); digest.update(data: Data("\(kind):".utf8)); digest.update(data: bytes)
        return ValidatedClipboardImport(wire: self,
            payload: ClipboardRecorderPayload(recordID: "", kind: itemKind, text: textValue, rtfData: rtf, pngData: png, urlString: urlValue),
            signature: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

func managementName(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 256,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ClipboardManagementError("invalid_name") }
    return name
}

func managementDate(_ value: String?) throws -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    guard let date, date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
          date <= Date().addingTimeInterval(300) else { throw ClipboardManagementError("invalid_date") }
    return date
}

private struct ManagementJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func managementValidateKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: ManagementJSONKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: allowed) else { throw ClipboardManagementError("unknown_field") }
}

private func managementRTFHasBalancedGroups(_ data: Data) -> Bool {
    var depth = 0
    var escaped = false
    var closedRoot = false
    for byte in data {
        if closedRoot {
            if ![9, 10, 13, 32].contains(byte) { return false }
            continue
        }
        if escaped { escaped = false; continue }
        if byte == 92 { escaped = true; continue }
        if byte == 123 { depth += 1 }
        if byte == 125 {
            depth -= 1
            if depth < 0 { return false }
            if depth == 0 { closedRoot = true }
        }
        if depth > 256 { return false }
    }
    return depth == 0 && closedRoot && !escaped
}
