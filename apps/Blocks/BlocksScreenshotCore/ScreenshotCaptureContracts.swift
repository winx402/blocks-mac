import Foundation

public enum ScreenshotCaptureIntentKind: String, Codable, Sendable {
    case smart
    case region
    case window
    case display
}

public enum ScreenshotDisplayScope: Codable, Equatable, Sendable {
    case current
    case all
    case displayID(UInt32)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case current
        case all
        case displayID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current
        case .all:
            self = .all
        case .displayID:
            self = .displayID(try container.decode(UInt32.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode(Kind.current, forKey: .kind)
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case let .displayID(id):
            try container.encode(Kind.displayID, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

public enum ScreenshotCaptureIntentError: Error, Equatable {
    case displayScopeRequiresDisplayIntent
}

public struct ScreenshotCaptureIntent: Codable, Equatable, Sendable {
    public let kind: ScreenshotCaptureIntentKind
    public let displayScope: ScreenshotDisplayScope?

    public init(
        kind: ScreenshotCaptureIntentKind,
        displayScope: ScreenshotDisplayScope? = nil
    ) throws {
        if kind == .display {
            self.kind = kind
            self.displayScope = displayScope ?? .current
            return
        }

        guard displayScope == nil else {
            throw ScreenshotCaptureIntentError.displayScopeRequiresDisplayIntent
        }
        self.kind = kind
        self.displayScope = nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ScreenshotCaptureIntentKind.self, forKey: .kind),
            displayScope: container.decodeIfPresent(ScreenshotDisplayScope.self, forKey: .displayScope)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(displayScope, forKey: .displayScope)
    }
}

public struct ScreenshotSelectionPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenshotSelectionRect: Codable, Equatable, Sendable {
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

    public init(from start: ScreenshotSelectionPoint, to end: ScreenshotSelectionPoint) {
        self.init(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }
}

public struct ScreenshotWindowCandidate: Codable, Equatable, Sendable {
    public let id: UInt32
    public let frame: ScreenshotSelectionRect
    public let visibleHitRegions: [ScreenshotSelectionRect]

    public init(
        id: UInt32,
        frame: ScreenshotSelectionRect,
        visibleHitRegions: [ScreenshotSelectionRect]? = nil
    ) {
        self.id = id
        self.frame = frame
        self.visibleHitRegions = visibleHitRegions ?? [frame]
    }
}

public struct ScreenshotDisplayCandidate: Codable, Equatable, Sendable {
    public let id: UInt32
    public let frame: ScreenshotSelectionRect

    public init(id: UInt32, frame: ScreenshotSelectionRect) {
        self.id = id
        self.frame = frame
    }
}

public enum ScreenshotResolvedCaptureKind: String, Codable, Equatable, Sendable {
    case region
    case window
    case display
}

public enum ScreenshotCaptureColorSpace: String, Codable, Equatable, Sendable {
    case sRGB
}

public struct ScreenshotCaptureResultMetadata: Codable, Equatable, Sendable {
    public let captureID: String
    public let kind: ScreenshotResolvedCaptureKind
    public let displayScope: ScreenshotDisplayScope?
    public let pixelSize: ScreenshotPixelSize
    public let colorSpace: ScreenshotCaptureColorSpace

    public init(
        captureID: String,
        kind: ScreenshotResolvedCaptureKind,
        displayScope: ScreenshotDisplayScope? = nil,
        pixelSize: ScreenshotPixelSize,
        colorSpace: ScreenshotCaptureColorSpace
    ) {
        self.captureID = captureID
        self.kind = kind
        self.displayScope = displayScope
        self.pixelSize = pixelSize
        self.colorSpace = colorSpace
    }
}

public struct ScreenshotSessionError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ScreenshotSessionOutcome: Codable, Equatable, Sendable {
    case completed(ScreenshotCaptureResultMetadata)
    case cancelled
    case failed(ScreenshotSessionError)
}
