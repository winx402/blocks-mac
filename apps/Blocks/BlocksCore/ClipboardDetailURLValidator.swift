import Foundation

public struct ClipboardDetailURLValidationResult: Equatable {
    public let normalizedURLString: String
    public let scheme: String

    public init(normalizedURLString: String, scheme: String) {
        self.normalizedURLString = normalizedURLString
        self.scheme = scheme
    }
}

public enum ClipboardDetailURLValidationError: Error, Equatable {
    case empty
    case controlCharacter
    case missingScheme
    case unsupportedScheme
    case invalidHTTPURL
    case invalidMailtoURL
    case invalidURL
}

public struct ClipboardDetailURLValidator {
    // localhost is accepted as a normal HTTP host; custom scheme input is blocked.
    public init() {}

    public func validate(_ input: String) -> Result<ClipboardDetailURLValidationResult, ClipboardDetailURLValidationError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.empty)
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .failure(.controlCharacter)
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty else {
            return .failure(.missingScheme)
        }

        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else {
                return .failure(.invalidHTTPURL)
            }
        case "mailto":
            guard !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidMailtoURL)
            }
        case "file":
            return .failure(.unsupportedScheme)
        default:
            // Custom scheme is blocked by default for Step 4.
            return .failure(.unsupportedScheme)
        }

        guard URL(string: trimmed) != nil else {
            return .failure(.invalidURL)
        }
        return .success(ClipboardDetailURLValidationResult(normalizedURLString: trimmed, scheme: scheme))
    }
}
