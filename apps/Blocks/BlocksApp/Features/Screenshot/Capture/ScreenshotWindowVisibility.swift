import AppKit
import BlocksScreenshotCore

enum ScreenshotWindowSurfaceRole: Equatable {
    case appWindow
    case appFloatingSurface
    case transientSurface
    case systemOverlay
    case blocksSelectionSurface
    case ineligible

    var isSelectable: Bool {
        switch self {
        case .appWindow, .appFloatingSurface:
            true
        case .transientSurface, .systemOverlay, .blocksSelectionSurface, .ineligible:
            false
        }
    }

    var isOccluding: Bool { isSelectable }
}

enum ScreenshotWindowOwnerKind: Equatable {
    case regular
    case accessory
    case prohibited
    case unknown
}

struct ScreenshotWindowSurfaceMetadata: Equatable {
    let layer: Int
    let frame: CGRect
    let alpha: CGFloat
    let hasOwningApplication: Bool
    let ownerKind: ScreenshotWindowOwnerKind
    let isAppleOwned: Bool
    let isBlocksSelectionSurface: Bool
}

enum ScreenshotWindowSurfaceClassifier {
    static let transientWindowLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    static func role(for metadata: ScreenshotWindowSurfaceMetadata) -> ScreenshotWindowSurfaceRole {
        guard metadata.alpha > 0,
              metadata.hasOwningApplication,
              !metadata.frame.isEmpty,
              metadata.frame.width >= 16,
              metadata.frame.height >= 16 else {
            return .ineligible
        }
        if metadata.isBlocksSelectionSurface {
            return .blocksSelectionSurface
        }
        guard metadata.layer >= 0 else { return .systemOverlay }
        if metadata.layer >= transientWindowLevel {
            return .transientSurface
        }
        if metadata.isAppleOwned, metadata.ownerKind != .regular {
            return .systemOverlay
        }
        if metadata.layer == 0 {
            return .appWindow
        }
        if metadata.ownerKind == .regular || !metadata.isAppleOwned {
            return .appFloatingSurface
        }
        return .systemOverlay
    }
}

struct ScreenshotWindowVisibility {
    struct Candidate {
        let id: UInt32
        let frame: CGRect
        let title: String
        let isSelectable: Bool
        let isOccluding: Bool
        let alpha: CGFloat

        init(
            id: UInt32,
            frame: CGRect,
            title: String,
            isSelectable: Bool = true,
            isOccluding: Bool = true,
            alpha: CGFloat = 1
        ) {
            self.id = id
            self.frame = frame
            self.title = title
            self.isSelectable = isSelectable
            self.isOccluding = isOccluding
            self.alpha = alpha
        }
    }

    static let minimumHitSize: CGFloat = 8

    static func selectionCandidates(frontToBack windows: [Candidate]) -> [ScreenshotSelectionCandidate] {
        var occludingFrames: [CGRect] = []
        var selectableCandidates: [ScreenshotSelectionCandidate] = []

        for window in windows {
            guard window.alpha > 0 else { continue }
            let visibleHitRegions = visibleRegions(
                of: window.frame,
                occludedBy: occludingFrames
            ).filter { region in
                region.width >= minimumHitSize && region.height >= minimumHitSize
            }
            if window.isSelectable, !visibleHitRegions.isEmpty {
                selectableCandidates.append(ScreenshotSelectionCandidate(
                    id: window.id,
                    frame: window.frame,
                    visibleHitRegions: visibleHitRegions,
                    title: window.title
                ))
            }
            if window.isOccluding, !window.frame.isEmpty {
                occludingFrames.append(window.frame)
            }
        }
        return selectableCandidates
    }

    static func orderedFrontToBack(
        _ windows: [Candidate],
        windowNumbers: [UInt32]
    ) -> [Candidate] {
        var rankByWindowNumber: [UInt32: Int] = [:]
        for (rank, windowNumber) in windowNumbers.enumerated() where rankByWindowNumber[windowNumber] == nil {
            rankByWindowNumber[windowNumber] = rank
        }
        return windows.enumerated().sorted { lhs, rhs in
            switch (rankByWindowNumber[lhs.element.id], rankByWindowNumber[rhs.element.id]) {
            case let (lhsRank?, rhsRank?):
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func visibleRegions(of frame: CGRect, occludedBy occluders: [CGRect]) -> [CGRect] {
        // Frame subtraction is intentionally conservative; per-pixel alpha is unavailable here.
        occluders.reduce([frame]) { regions, occluder in
            regions.flatMap { subtract(occluder, from: $0) }
        }
    }

    private static func subtract(_ occluder: CGRect, from region: CGRect) -> [CGRect] {
        let overlap = region.intersection(occluder)
        guard !overlap.isNull, !overlap.isEmpty else { return [region] }

        return [
            CGRect(x: region.minX, y: overlap.maxY, width: region.width, height: region.maxY - overlap.maxY),
            CGRect(x: region.minX, y: region.minY, width: region.width, height: overlap.minY - region.minY),
            CGRect(x: region.minX, y: overlap.minY, width: overlap.minX - region.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: region.maxX - overlap.maxX, height: overlap.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
