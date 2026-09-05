import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A validated, canonicalized BCP-47 language tag used at service boundaries.
///
/// Automatic language detection is represented by `nil` at the call site. It is
/// deliberately not encoded as a synthetic language tag such as `"auto"`.
public struct TranslationLanguageTag: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let canonical = Self.canonicalize(rawValue) else {
            return nil
        }
        self.rawValue = canonical
    }

    public init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let canonical = Self.canonicalize(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid BCP-47 language tag: \(value)"
            )
        }
        rawValue = canonical
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func canonicalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
            return nil
        }

        let subtags = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let language = subtags.first,
              language.caseInsensitiveCompare("auto") != .orderedSame,
              !subtags.contains(where: \.isEmpty),
              isASCIIAlpha(language),
              (2...8).contains(language.count) || language.caseInsensitiveCompare("x") == .orderedSame
        else {
            return nil
        }

        let isPrivateUse = language.caseInsensitiveCompare("x") == .orderedSame
        if isPrivateUse {
            guard subtags.count >= 2,
                  subtags.dropFirst().allSatisfy({
                      (1...8).contains($0.count) && isASCIIAlphanumeric($0)
                  }) else {
                return nil
            }
            return subtags.map { $0.lowercased() }.joined(separator: "-")
        }

        var canonical: [String] = [language.lowercased()]
        var sawScript = false
        var sawRegion = false
        var inExtension = false
        var extensionHasValue = false

        for (index, subtag) in subtags.dropFirst().enumerated() {
            guard (1...8).contains(subtag.count), isASCIIAlphanumeric(subtag) else {
                return nil
            }

            if subtag.count == 1 {
                guard !inExtension || extensionHasValue else {
                    return nil
                }
                guard index < subtags.count - 2 else {
                    return nil
                }
                canonical.append(subtag.lowercased())
                inExtension = true
                extensionHasValue = false
                continue
            }

            if inExtension {
                guard subtag.count >= 2 else {
                    return nil
                }
                canonical.append(subtag.lowercased())
                extensionHasValue = true
                continue
            }

            if !sawScript, subtag.count == 4, isASCIIAlpha(subtag) {
                canonical.append(
                    subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
                )
                sawScript = true
            } else if !sawRegion,
                      (subtag.count == 2 && isASCIIAlpha(subtag))
                        || (subtag.count == 3 && subtag.allSatisfy(\.isNumber)) {
                canonical.append(subtag.uppercased())
                sawRegion = true
            } else {
                canonical.append(subtag.lowercased())
            }
        }

        guard !inExtension || extensionHasValue else {
            return nil
        }
        return canonical.joined(separator: "-")
    }

    private static func isASCIIAlpha(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        }
    }

    private static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
        }
    }
}

public enum TranslationInputSource: String, Codable, CaseIterable, Sendable {
    case manual
    case selection
    case screenshotOCR = "screenshot_ocr"
    case clipboardRecord = "clipboard_record"
}

public struct TranslationInputAnchor: Codable, Equatable, Sendable {
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

/// Ephemeral source context used to place the translation panel.
///
/// Favorites intentionally do not persist this value.
public struct TranslationInputContext: Codable, Equatable, Sendable {
    public let sourceApplicationBundleID: String?
    public let sourceApplicationName: String?
    public let clipboardRecordID: String?
    public let displayIdentifier: String?
    public let anchor: TranslationInputAnchor?

    public init(
        sourceApplicationBundleID: String? = nil,
        sourceApplicationName: String? = nil,
        clipboardRecordID: String? = nil,
        displayIdentifier: String? = nil,
        anchor: TranslationInputAnchor? = nil
    ) {
        self.sourceApplicationBundleID = sourceApplicationBundleID
        self.sourceApplicationName = sourceApplicationName
        self.clipboardRecordID = clipboardRecordID
        self.displayIdentifier = displayIdentifier
        self.anchor = anchor
    }
}

public struct TranslationInput: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let source: TranslationInputSource
    public let text: String
    public let createdAt: Date
    public let context: TranslationInputContext?

    public init(
        id: String = UUID().uuidString,
        source: TranslationInputSource,
        text: String,
        createdAt: Date = Date(),
        context: TranslationInputContext? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.createdAt = createdAt
        self.context = context
    }
}

public struct TranslationLanguageDirection: Codable, Equatable, Sendable {
    /// `nil` means automatic source-language detection.
    public let source: TranslationLanguageTag?
    public let target: TranslationLanguageTag

    public init(source: TranslationLanguageTag? = nil, target: TranslationLanguageTag) {
        self.source = source
        self.target = target
    }
}

public enum TranslationSourceAcceptedInput:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case text
    case screenshotImage = "screenshot_image"
}

public enum TranslationSourceContextField:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case inputSource = "input_source"
    case sourceApplicationBundleID = "source_application_bundle_id"
    case ocrSummary = "ocr_summary"
}

public struct TranslationSourceOCRSummary:
    Codable,
    Equatable,
    Sendable
{
    public let lineCount: Int

    public init(lineCount: Int) {
        self.lineCount = max(0, lineCount)
    }
}

public enum TranslationSourceAttachmentKind:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case screenshotImage = "screenshot_image"
}

/// Metadata for an invocation-scoped attachment.
///
/// The descriptor may cross process boundaries. Attachment bytes are owned by
/// the host runtime and are never persisted in translation sessions or
/// favorites.
public struct TranslationSourceAttachmentDescriptor:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let kind: TranslationSourceAttachmentKind
    public let mediaType: String
    public let byteCount: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let sha256: String?

    public init(
        id: String = UUID().uuidString,
        kind: TranslationSourceAttachmentKind,
        mediaType: String,
        byteCount: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sha256 = sha256
    }
}

public enum TranslationSourceImageEncodingError:
    Error,
    LocalizedError,
    Equatable,
    Sendable
{
    case sourceTooLarge
    case unsupportedFormat
    case invalidDimensions
    case decodeFailed
    case encodeFailed
    case encodedImageTooLarge

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge:
            return "The source image exceeds the 20 MB input limit."
        case .unsupportedFormat:
            return "The source image must be PNG, JPEG, or HEIC."
        case .invalidDimensions:
            return "The source image dimensions are invalid or exceed 40 megapixels."
        case .decodeFailed:
            return "The source image could not be decoded."
        case .encodeFailed:
            return "The source image could not be encoded safely."
        case .encodedImageTooLarge:
            return "The normalized image exceeds the 2.5 MB plugin input limit."
        }
    }
}

/// A normalized, invocation-scoped image suitable for a translation source.
///
/// Callers may serialize this value across the local action boundary. It must
/// never be written to translation history, favorites, logs, or preferences.
public struct TranslationSourceEncodedImage:
    Codable,
    Equatable,
    Sendable
{
    public let data: Data
    public let mediaType: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        data: Data,
        mediaType: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.data = data
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Shared image normalization used by screenshot translation and CLI source
/// tests. It bounds the encoded payload before it reaches the plugin runner.
public enum TranslationSourceImageEncoder {
    public static let maximumSourceImageBytes = 20_000_000
    public static let maximumSourcePixelCount = 40_000_000
    public static let maximumEncodedImageBytes = 2_500_000
    public static let maximumImageDimension = 4_096

    public static func encode(
        sourceData: Data
    ) throws -> TranslationSourceEncodedImage {
        guard !sourceData.isEmpty,
              sourceData.count <= maximumSourceImageBytes else {
            throw TranslationSourceImageEncodingError.sourceTooLarge
        }
        guard let imageSource = CGImageSourceCreateWithData(
            sourceData as CFData,
            nil
        ) else {
            throw TranslationSourceImageEncodingError.decodeFailed
        }
        try validateSourceType(imageSource)
        try validateSourceDimensions(imageSource)
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize:
                    maximumImageDimension,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary
        ) else {
            throw TranslationSourceImageEncodingError.decodeFailed
        }
        return try encode(image)
    }

    public static func encode(
        _ source: CGImage
    ) throws -> TranslationSourceEncodedImage {
        let firstImage = try resizedIfNeeded(
            source,
            maximumDimension: maximumImageDimension
        )
        for quality in [0.82, 0.68, 0.52, 0.38] as [CGFloat] {
            let data = try encodeJPEG(firstImage, quality: quality)
            if data.count <= maximumEncodedImageBytes {
                return TranslationSourceEncodedImage(
                    data: data,
                    mediaType: "image/jpeg",
                    pixelWidth: firstImage.width,
                    pixelHeight: firstImage.height
                )
            }
        }
        let compactImage = try resizedIfNeeded(
            firstImage,
            maximumDimension: 2_048
        )
        let compactData = try encodeJPEG(
            compactImage,
            quality: 0.42
        )
        guard compactData.count <= maximumEncodedImageBytes else {
            throw TranslationSourceImageEncodingError
                .encodedImageTooLarge
        }
        return TranslationSourceEncodedImage(
            data: compactData,
            mediaType: "image/jpeg",
            pixelWidth: compactImage.width,
            pixelHeight: compactImage.height
        )
    }

    private static func validateSourceType(
        _ source: CGImageSource
    ) throws {
        guard let rawType = CGImageSourceGetType(source),
              let type = UTType(rawType as String),
              type.conforms(to: .png)
                || type.conforms(to: .jpeg)
                || type.conforms(to: .heic) else {
            throw TranslationSourceImageEncodingError.unsupportedFormat
        }
    }

    private static func validateSourceDimensions(
        _ source: CGImageSource
    ) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = (
                properties[kCGImagePropertyPixelWidth] as? NSNumber
              )?.intValue,
              let height = (
                properties[kCGImagePropertyPixelHeight] as? NSNumber
              )?.intValue,
              width > 0,
              height > 0,
              width <= maximumSourcePixelCount / height else {
            throw TranslationSourceImageEncodingError.invalidDimensions
        }
    }

    private static func resizedIfNeeded(
        _ image: CGImage,
        maximumDimension: Int
    ) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumDimension else { return image }
        let scale = CGFloat(maximumDimension) / CGFloat(longest)
        let width = max(
            1,
            Int((CGFloat(image.width) * scale).rounded())
        )
        let height = max(
            1,
            Int((CGFloat(image.height) * scale).rounded())
        )
        guard let colorSpace = CGColorSpace(
            name: CGColorSpace.sRGB
        ),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo:
                CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TranslationSourceImageEncodingError.encodeFailed
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let resizedImage = context.makeImage() else {
            throw TranslationSourceImageEncodingError.encodeFailed
        }
        return resizedImage
    }

    private static func encodeJPEG(
        _ image: CGImage,
        quality: CGFloat
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TranslationSourceImageEncodingError.encodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality:
                    quality,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw TranslationSourceImageEncodingError.encodeFailed
        }
        return data as Data
    }
}

/// Explicit, bounded context made available to a translation source.
///
/// Adapters must filter this value using the source manifest before invoking
/// third-party code.
public struct TranslationSourceContext: Codable, Equatable, Sendable {
    public let inputSource: TranslationInputSource
    public let sourceApplicationBundleID: String?
    public let ocrSummary: TranslationSourceOCRSummary?

    public init(
        inputSource: TranslationInputSource,
        sourceApplicationBundleID: String? = nil,
        ocrSummary: TranslationSourceOCRSummary? = nil
    ) {
        self.inputSource = inputSource
        self.sourceApplicationBundleID = sourceApplicationBundleID
        self.ocrSummary = ocrSummary
    }
}

/// The single host-side request contract shared by built-in and custom
/// translation sources.
public struct TranslationSourceInvocation:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    public let id: UUID
    public let sessionID: String
    public let input: TranslationInput
    public let direction: TranslationLanguageDirection
    public let context: TranslationSourceContext
    public let attachments: [TranslationSourceAttachmentDescriptor]

    public init(
        id: UUID = UUID(),
        sessionID: String,
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        context: TranslationSourceContext? = nil,
        attachments: [TranslationSourceAttachmentDescriptor] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.input = input
        self.direction = direction
        self.context = context ?? TranslationSourceContext(
            inputSource: input.source,
            sourceApplicationBundleID:
                input.context?.sourceApplicationBundleID
        )
        self.attachments = attachments
    }
}

public struct TranslationSourceStatus: Codable, Equatable, Sendable {
    public let code: String
    public let message: String?
    public let fraction: Double?

    public init(
        code: String,
        message: String? = nil,
        fraction: Double? = nil
    ) {
        self.code = code
        self.message = message
        self.fraction = fraction
    }
}

public struct TranslationSourceDiagnostics: Codable, Equatable, Sendable {
    public let code: String
    public let message: String?
    public let metadata: [String: JSONValue]

    public init(
        code: String,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.metadata = metadata
    }
}

public struct TranslationSourceOutput: Codable, Equatable, Sendable {
    public let text: String
    public let detectedSourceLanguage: TranslationLanguageTag?
    public let warnings: [String]
    public let metadata: [String: JSONValue]

    public init(
        text: String,
        detectedSourceLanguage: TranslationLanguageTag? = nil,
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.text = text
        self.detectedSourceLanguage = detectedSourceLanguage
        self.warnings = warnings
        self.metadata = metadata
    }
}

public struct TranslationSourceFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let isRetryable: Bool

    public init(
        code: String,
        message: String,
        isRetryable: Bool = true
    ) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
    }
}

/// Custom translation sources intentionally do not expose token streaming in
/// the first contract version. They may report bounded status and diagnostics
/// before exactly one terminal event.
public enum TranslationSourceEvent: Codable, Equatable, Sendable {
    case status(TranslationSourceStatus)
    case diagnostics(TranslationSourceDiagnostics)
    case completed(TranslationSourceOutput)
    case failed(TranslationSourceFailure)
}

public enum TranslationServiceKind: String, Codable, CaseIterable, Sendable {
    case appleLocal = "apple_local"
    case openAICompatible = "openai_compatible"
    case officialExternal = "official_external"
    case communityWeb = "community_web"
    case plugin
}

public enum TranslationServiceAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case requiresConfiguration = "requires_configuration"
    case requiresDownload = "requires_download"
    case unsupported
    case disabled
}

public struct TranslationServiceDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: TranslationServiceKind
    public let version: String?
    public let availability: TranslationServiceAvailability
    public let supportsStreaming: Bool
    public let supportedSourceLanguages: [TranslationLanguageTag]
    public let supportedTargetLanguages: [TranslationLanguageTag]

    public init(
        id: String,
        displayName: String,
        kind: TranslationServiceKind,
        version: String? = nil,
        availability: TranslationServiceAvailability = .available,
        supportsStreaming: Bool = false,
        supportedSourceLanguages: [TranslationLanguageTag] = [],
        supportedTargetLanguages: [TranslationLanguageTag] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.version = version
        self.availability = availability
        self.supportsStreaming = supportsStreaming
        self.supportedSourceLanguages = supportedSourceLanguages
        self.supportedTargetLanguages = supportedTargetLanguages
    }
}

public enum TranslationResultState: String, Codable, CaseIterable, Sendable {
    case waiting
    case running
    case streaming
    case succeeded
    case failed
    case cancelled
}

/// Low-sensitive runtime metadata that helps diagnose a service result without
/// persisting request/response bodies or credentials.
public struct TranslationResultDiagnostics: Codable, Equatable, Sendable {
    public let auditID: String
    public let durationMS: Int
    public let route: String
    public let status: String

    public init(
        auditID: String,
        durationMS: Int,
        route: String,
        status: String
    ) {
        self.auditID = auditID
        self.durationMS = durationMS
        self.route = route
        self.status = status
    }
}

public struct TranslationResultSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let service: TranslationServiceDescriptor
    public let state: TranslationResultState
    public let translatedText: String
    public let errorCode: String?
    public let errorMessage: String?
    /// `nil` preserves the legacy error-code based recovery policy.
    /// Custom translation sources may set an explicit terminal policy.
    public let isRetryable: Bool?
    public let warnings: [String]
    public let startedAt: Date?
    public let completedAt: Date?
    public let diagnostics: TranslationResultDiagnostics?
    public let sourceStatus: TranslationSourceStatus?
    /// Optional language detected by the active translation source. This is
    /// runtime result data only; favorites deliberately persist the resolved
    /// session direction instead of source-specific metadata.
    public let detectedSourceLanguage: TranslationLanguageTag?
    /// Bounded, source-provided result metadata. Plugin runners validate the
    /// payload before it reaches this snapshot.
    public let sourceMetadata: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case id
        case service
        case state
        case translatedText
        case errorCode
        case errorMessage
        case isRetryable
        case warnings
        case startedAt
        case completedAt
        case diagnostics
        case sourceStatus
        case detectedSourceLanguage
        case sourceMetadata
    }

    public init(
        id: String = UUID().uuidString,
        service: TranslationServiceDescriptor,
        state: TranslationResultState,
        translatedText: String = "",
        errorCode: String? = nil,
        errorMessage: String? = nil,
        isRetryable: Bool? = nil,
        warnings: [String] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        diagnostics: TranslationResultDiagnostics? = nil,
        sourceStatus: TranslationSourceStatus? = nil,
        detectedSourceLanguage: TranslationLanguageTag? = nil,
        sourceMetadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.service = service
        self.state = state
        self.translatedText = translatedText
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.isRetryable = isRetryable
        self.warnings = warnings
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.diagnostics = diagnostics
        self.sourceStatus = sourceStatus
        self.detectedSourceLanguage = detectedSourceLanguage
        self.sourceMetadata = sourceMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        service = try container.decode(
            TranslationServiceDescriptor.self,
            forKey: .service
        )
        state = try container.decode(
            TranslationResultState.self,
            forKey: .state
        )
        translatedText = try container.decode(
            String.self,
            forKey: .translatedText
        )
        errorCode = try container.decodeIfPresent(
            String.self,
            forKey: .errorCode
        )
        errorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
        isRetryable = try container.decodeIfPresent(
            Bool.self,
            forKey: .isRetryable
        )
        warnings = try container.decodeIfPresent(
            [String].self,
            forKey: .warnings
        ) ?? []
        startedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .startedAt
        )
        completedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .completedAt
        )
        diagnostics = try container.decodeIfPresent(
            TranslationResultDiagnostics.self,
            forKey: .diagnostics
        )
        sourceStatus = try container.decodeIfPresent(
            TranslationSourceStatus.self,
            forKey: .sourceStatus
        )
        detectedSourceLanguage = try container.decodeIfPresent(
            TranslationLanguageTag.self,
            forKey: .detectedSourceLanguage
        )
        sourceMetadata = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .sourceMetadata
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(service, forKey: .service)
        try container.encode(state, forKey: .state)
        try container.encode(translatedText, forKey: .translatedText)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(isRetryable, forKey: .isRetryable)
        try container.encode(warnings, forKey: .warnings)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
        try container.encodeIfPresent(sourceStatus, forKey: .sourceStatus)
        try container.encodeIfPresent(
            detectedSourceLanguage,
            forKey: .detectedSourceLanguage
        )
        if !sourceMetadata.isEmpty {
            try container.encode(sourceMetadata, forKey: .sourceMetadata)
        }
    }

    public var isSuccessful: Bool {
        state == .succeeded && !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct TranslationSessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let input: TranslationInput
    public let direction: TranslationLanguageDirection
    /// Result order is the configured service order and must not be completion order.
    public let results: [TranslationResultSnapshot]
    public let isFavorite: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        results: [TranslationResultSnapshot],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.input = input
        self.direction = direction
        self.results = results
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var successfulResults: [TranslationResultSnapshot] {
        results.filter(\.isSuccessful)
    }
}
