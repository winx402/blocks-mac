import Foundation

public enum ClipboardTagBuiltInKind: String, Codable, CaseIterable, Sendable {
    case none
    case favorite
    case screenshot
}

public struct ClipboardTag: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let normalizedName: String
    public let colorToken: String
    public let sortOrder: Int
    public let builtInKind: ClipboardTagBuiltInKind
    public let isEnabled: Bool
    public let contentRevision: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        displayName: String,
        normalizedName: String,
        colorToken: String,
        sortOrder: Int,
        builtInKind: ClipboardTagBuiltInKind,
        isEnabled: Bool = true,
        contentRevision: Int64 = 1,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.colorToken = colorToken
        self.sortOrder = sortOrder
        self.builtInKind = builtInKind
        self.isEnabled = isEnabled
        self.contentRevision = contentRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isFavorite: Bool {
        builtInKind == .favorite
    }

    public var isScreenshot: Bool {
        builtInKind == .screenshot
    }

    public var isBuiltIn: Bool {
        builtInKind != .none
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, normalizedName, colorToken, sortOrder, builtInKind
        case isEnabled, contentRevision, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        normalizedName = try values.decode(String.self, forKey: .normalizedName)
        colorToken = try values.decode(String.self, forKey: .colorToken)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        builtInKind = try values.decode(ClipboardTagBuiltInKind.self, forKey: .builtInKind)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        contentRevision = try values.decodeIfPresent(Int64.self, forKey: .contentRevision) ?? 1
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ClipboardRecordTag: Codable, Equatable, Sendable {
    public let recordID: String
    public let tagID: String
    public let createdAt: Date

    public init(recordID: String, tagID: String, createdAt: Date) {
        self.recordID = recordID
        self.tagID = tagID
        self.createdAt = createdAt
    }
}

public enum ClipboardTagNameValidationError: String, Error, Codable, Sendable {
    case empty
    case controlCharacter
    case reservedFavoriteName
    case reservedSystemName
}

public struct ClipboardTagNameNormalizer: Sendable {
    public static let reservedAliases: Set<String> = ["favorite", "收藏"]
    public static let reservedScreenshotAliases: Set<String> = ["screenshot", "截图", "スクリーンショット"]
    private static let stableLocale = Locale(identifier: "en_US_POSIX")

    public init() {}

    public func normalizedName(_ value: String) throws -> String {
        let compatibilityMapped = value.precomposedStringWithCompatibilityMapping
        let trimmed = compatibilityMapped.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedWhitespace = Self.foldedWhitespace(trimmed)
        guard !foldedWhitespace.isEmpty else {
            throw ClipboardTagNameValidationError.empty
        }
        guard !Self.containsControlCharacter(foldedWhitespace) else {
            throw ClipboardTagNameValidationError.controlCharacter
        }
        let folded = foldedWhitespace
            .folding(options: [.caseInsensitive], locale: Self.stableLocale)
            .lowercased(with: Self.stableLocale)
        return folded
    }

    public func validateUserTagName(_ value: String) throws -> (displayName: String, normalizedName: String) {
        let displayName = Self.foldedWhitespace(
            value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let normalizedName = try normalizedName(displayName)
        guard !Self.reservedAliases.contains(normalizedName) else {
            throw ClipboardTagNameValidationError.reservedFavoriteName
        }
        guard !Self.reservedScreenshotAliases.contains(normalizedName) else {
            throw ClipboardTagNameValidationError.reservedSystemName
        }
        return (displayName, normalizedName)
    }

    static func foldedWhitespace(_ value: String) -> String {
        var scalars: [UnicodeScalar] = []
        var previousWasWhitespace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    scalars.append(" ")
                }
                previousWasWhitespace = true
            } else {
                scalars.append(scalar)
                previousWasWhitespace = false
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public enum ClipboardTagSelectionTransition: Codable, Equatable, Sendable {
    case none
    case clear
    case switchTo(String)
}

public struct ClipboardTagSearchInvalidation: Codable, Equatable, Sendable {
    public let affectedRecordIDs: [String]
    public let succeeded: Bool
    public let errorCode: String?

    public init(affectedRecordIDs: [String], succeeded: Bool = true, errorCode: String? = nil) {
        self.affectedRecordIDs = affectedRecordIDs
        self.succeeded = succeeded
        self.errorCode = errorCode
    }
}

public struct ClipboardTagMutationResult: Codable, Equatable, Sendable {
    public let changedTagIDs: [String]
    public let affectedRecordIDs: [String]
    public let removedTagIDs: [String]
    public let selectedTagTransition: ClipboardTagSelectionTransition
    public let searchInvalidation: ClipboardTagSearchInvalidation

    public init(
        changedTagIDs: [String],
        affectedRecordIDs: [String],
        removedTagIDs: [String] = [],
        selectedTagTransition: ClipboardTagSelectionTransition = .none,
        searchInvalidation: ClipboardTagSearchInvalidation? = nil
    ) {
        let uniqueAffected = Array(Set(affectedRecordIDs)).sorted()
        self.changedTagIDs = Array(Set(changedTagIDs)).sorted()
        self.affectedRecordIDs = uniqueAffected
        self.removedTagIDs = Array(Set(removedTagIDs)).sorted()
        self.selectedTagTransition = selectedTagTransition
        self.searchInvalidation = searchInvalidation ?? ClipboardTagSearchInvalidation(affectedRecordIDs: uniqueAffected)
    }
}

public enum ClipboardTagMutationError: Error, LocalizedError, Equatable, Sendable {
    case invalidName(ClipboardTagNameValidationError)
    case duplicateName
    case tagNotFound(String)
    case recordNotFound(String)
    case favoriteImmutable
    case builtInImmutable
    case systemMembershipImmutable
    case sourceEqualsTarget
    case invalidMergeTarget
    case revisionConflict

    public var errorDescription: String? {
        switch self {
        case let .invalidName(error):
            return "Invalid clipboard tag name: \(error.rawValue)."
        case .duplicateName:
            return "Clipboard tag name already exists."
        case let .tagNotFound(tagID):
            return "Clipboard tag \(tagID) was not found."
        case let .recordNotFound(recordID):
            return "Clipboard record \(recordID) was not found."
        case .favoriteImmutable:
            return "Favorite is a built-in clipboard tag and cannot be changed."
        case .builtInImmutable:
            return "The built-in clipboard tag cannot be changed."
        case .systemMembershipImmutable:
            return "The system-managed clipboard tag membership cannot be changed."
        case .sourceEqualsTarget:
            return "Clipboard tag merge source and target must differ."
        case .invalidMergeTarget:
            return "Clipboard tags can only merge ordinary tags into ordinary tags."
        case .revisionConflict:
            return "Clipboard tag changed before this operation could be completed."
        }
    }
}
