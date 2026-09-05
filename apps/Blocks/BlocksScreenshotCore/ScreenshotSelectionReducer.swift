import CoreGraphics

public enum ScreenshotSelectionKey: Equatable, Sendable {
    case displayMode
    case allDisplays
    case escape
}

public enum ScreenshotSelectionState: Equatable, Sendable {
    case ready
    case windowPreview(ScreenshotWindowCandidate)
    case pendingClick(start: ScreenshotSelectionPoint, windowCandidate: ScreenshotWindowCandidate?)
    case regionDrawing(start: ScreenshotSelectionPoint, current: ScreenshotSelectionPoint)
    case displaySelection(ScreenshotDisplayCandidate?)
    case capturing
    case cancelled
}

public enum ScreenshotSelectionEvent: Equatable, Sendable {
    case pointerMoved(
        point: ScreenshotSelectionPoint,
        windowCandidate: ScreenshotWindowCandidate?
    )
    case pointerDown(point: ScreenshotSelectionPoint, windowCandidate: ScreenshotWindowCandidate?)
    case pointerDragged(current: ScreenshotSelectionPoint, exceededThreshold: Bool)
    case pointerUp(
        point: ScreenshotSelectionPoint,
        windowCandidate: ScreenshotWindowCandidate?,
        resolvedRegion: ScreenshotSelectionRect?
    )
    case displayHovered(ScreenshotDisplayCandidate?)
    case allDisplaysSelected
    case keyPressed(
        ScreenshotSelectionKey,
        currentDisplay: ScreenshotDisplayCandidate?
    )
}

public enum ScreenshotSelectionEffect: Equatable, Sendable {
    case captureWindow(ScreenshotWindowCandidate)
    case captureRegion(ScreenshotSelectionRect)
    case captureDisplay(ScreenshotDisplayScope)
    case cancel
}

public enum ScreenshotSelectionHintState: Equatable, Sendable {
    case ready
    case window
    case regionDrawing
    case display
    case noCandidate
}

public struct ScreenshotSelectionTransition: Equatable, Sendable {
    public let state: ScreenshotSelectionState
    public let effects: [ScreenshotSelectionEffect]

    public init(
        state: ScreenshotSelectionState,
        effects: [ScreenshotSelectionEffect] = []
    ) {
        self.state = state
        self.effects = effects
    }
}

public struct ScreenshotSelectionReducer: Sendable {
    public init() {}

    public func reduce(
        state: ScreenshotSelectionState,
        event: ScreenshotSelectionEvent
    ) -> ScreenshotSelectionTransition {
        switch event {
        case let .pointerMoved(_, windowCandidate):
            guard state != .capturing, state != .cancelled else {
                return ScreenshotSelectionTransition(state: state)
            }
            guard state == .ready || state.isWindowPreview else {
                return ScreenshotSelectionTransition(state: state)
            }
            if let windowCandidate {
                return ScreenshotSelectionTransition(state: .windowPreview(windowCandidate))
            }
            return ScreenshotSelectionTransition(state: .ready)

        case let .pointerDown(point, windowCandidate):
            guard state != .capturing, state != .cancelled else {
                return ScreenshotSelectionTransition(state: state)
            }
            if case .displaySelection = state {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(
                state: .pendingClick(start: point, windowCandidate: windowCandidate)
            )

        case let .pointerDragged(current, exceededThreshold):
            if case let .regionDrawing(start, _) = state {
                return ScreenshotSelectionTransition(
                    state: .regionDrawing(start: start, current: current)
                )
            }
            guard exceededThreshold,
                  case let .pendingClick(start, _) = state else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(
                state: .regionDrawing(start: start, current: current)
            )

        case let .pointerUp(_, windowCandidate, resolvedRegion):
            switch state {
            case let .pendingClick(_, candidateAtDown):
                guard let candidateAtDown,
                      candidateAtDown.id == windowCandidate?.id else {
                    return ScreenshotSelectionTransition(state: windowCandidate.map(ScreenshotSelectionState.windowPreview) ?? .ready)
                }
                return ScreenshotSelectionTransition(
                    state: .capturing,
                    effects: [.captureWindow(candidateAtDown)]
                )
            case .regionDrawing:
                guard let resolvedRegion, !resolvedRegion.isEmpty else {
                    return ScreenshotSelectionTransition(state: .ready)
                }
                return ScreenshotSelectionTransition(
                    state: .capturing,
                    effects: [.captureRegion(resolvedRegion)]
                )
            case let .displaySelection(candidate?):
                return ScreenshotSelectionTransition(
                    state: .capturing,
                    effects: [.captureDisplay(.displayID(candidate.id))]
                )
            default:
                return ScreenshotSelectionTransition(state: state)
            }

        case let .displayHovered(candidate):
            guard case .displaySelection = state else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(state: .displaySelection(candidate))

        case .allDisplaysSelected:
            guard case .displaySelection = state else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(
                state: .capturing,
                effects: [.captureDisplay(.all)]
            )

        case let .keyPressed(.displayMode, currentDisplay):
            guard state != .capturing, state != .cancelled else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(state: .displaySelection(currentDisplay))

        case .keyPressed(.allDisplays, _):
            guard state != .capturing, state != .cancelled else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(
                state: .capturing,
                effects: [.captureDisplay(.all)]
            )

        case .keyPressed(.escape, _):
            guard state != .capturing else {
                return ScreenshotSelectionTransition(state: state)
            }
            return ScreenshotSelectionTransition(state: .cancelled, effects: [.cancel])
        }
    }

    public func hintState(
        for state: ScreenshotSelectionState,
        hasWindowCandidates: Bool
    ) -> ScreenshotSelectionHintState {
        switch state {
        case .windowPreview:
            return .window
        case let .pendingClick(_, windowCandidate):
            return windowCandidate == nil ? .ready : .window
        case .regionDrawing:
            return .regionDrawing
        case .displaySelection:
            return .display
        case .ready:
            return hasWindowCandidates ? .ready : .noCandidate
        case .capturing, .cancelled:
            return .ready
        }
    }
}

private extension ScreenshotSelectionState {
    var isWindowPreview: Bool {
        if case .windowPreview = self { return true }
        return false
    }
}

public enum ScreenshotRegionConstraint: Codable, Equatable, Sendable {
    case free
    case ratio(width: Double, height: Double)
    case fixedPixels(width: Int, height: Int)
}

public enum ScreenshotAspectOrientation: String, Codable, CaseIterable, Sendable {
    case landscape
    case portrait
}

public struct ScreenshotAspectSelection: Codable, Equatable, Sendable {
    public var orientation: ScreenshotAspectOrientation
    public var constraint: ScreenshotRegionConstraint

    public init(
        orientation: ScreenshotAspectOrientation,
        constraint: ScreenshotRegionConstraint
    ) {
        self.orientation = orientation
        self.constraint = constraint
    }

    public var resolvedConstraint: ScreenshotRegionConstraint {
        switch constraint {
        case .free:
            return .free
        case let .ratio(width, height):
            guard width > 0, height > 0 else { return constraint }
            let dimensions = oriented(width: width, height: height)
            return .ratio(width: dimensions.width, height: dimensions.height)
        case let .fixedPixels(width, height):
            guard width > 0, height > 0 else { return constraint }
            let dimensions = oriented(width: width, height: height)
            return .fixedPixels(width: dimensions.width, height: dimensions.height)
        }
    }

    private func oriented<T: Comparable>(width: T, height: T) -> (width: T, height: T) {
        switch orientation {
        case .landscape:
            width >= height ? (width, height) : (height, width)
        case .portrait:
            width <= height ? (width, height) : (height, width)
        }
    }
}

public extension ScreenshotRegionConstraint {
    var aspectRatio: Double? {
        switch self {
        case .free:
            nil
        case let .ratio(width, height):
            width > 0 && height > 0 ? width / height : nil
        case let .fixedPixels(width, height):
            width > 0 && height > 0 ? Double(width) / Double(height) : nil
        }
    }

    var aspectConstraint: ScreenshotRegionConstraint {
        guard let aspectRatio else { return .free }
        return .ratio(width: aspectRatio, height: 1)
    }
}

public struct ScreenshotResolvedFixedPixelRegion: Equatable, Sendable {
    public let rect: ScreenshotSelectionRect
    public let outputScale: Double

    public init(rect: ScreenshotSelectionRect, outputScale: Double) {
        self.rect = rect
        self.outputScale = outputScale
    }
}

public struct ScreenshotRegionGeometry: Sendable {
    public init() {}

    public func constrain(
        _ rect: ScreenshotSelectionRect,
        to constraint: ScreenshotRegionConstraint,
        outputScale: Double
    ) -> ScreenshotSelectionRect {
        guard outputScale > 0 else { return rect }
        switch constraint {
        case .free:
            return rect
        case let .ratio(width, height):
            guard width > 0, height > 0 else { return rect }
            let ratio = width / height
            let heightFromWidth = rect.width / ratio
            if heightFromWidth <= rect.height {
                return ScreenshotSelectionRect(x: rect.x, y: rect.y, width: rect.width, height: heightFromWidth)
            }
            return ScreenshotSelectionRect(x: rect.x, y: rect.y, width: rect.height * ratio, height: rect.height)
        case let .fixedPixels(width, height):
            guard width > 0, height > 0 else { return rect }
            return ScreenshotSelectionRect(
                x: rect.x,
                y: rect.y,
                width: Double(width) / outputScale,
                height: Double(height) / outputScale
            )
        }
    }

    public func resolveFixedPixelRegion(
        _ raw: ScreenshotSelectionRect,
        width: Int,
        height: Int,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> ScreenshotResolvedFixedPixelRegion {
        guard !raw.isEmpty, width > 0, height > 0 else {
            throw ScreenshotCapturePlanError.invalidRegion
        }
        let intersecting = displays.compactMap { display -> (ScreenshotDisplayDescriptor, Double)? in
            guard let intersection = intersection(raw, display.selectionFrame) else { return nil }
            return (display, intersection.width * intersection.height)
        }
        guard let target = intersecting.max(by: { lhs, rhs in
            if lhs.0.backingScale != rhs.0.backingScale {
                return lhs.0.backingScale < rhs.0.backingScale
            }
            return lhs.1 < rhs.1
        })?.0 else {
            throw ScreenshotCapturePlanError.regionOutsideDisplays
        }
        guard target.backingScale > 0 else {
            throw ScreenshotCapturePlanError.invalidDisplayScale
        }

        let resolvedWidth = Double(width) / target.backingScale
        let resolvedHeight = Double(height) / target.backingScale
        let frame = target.selectionFrame
        let x = clampOrigin(raw.x, length: resolvedWidth, within: frame.x ... frame.x + frame.width)
        let y = clampOrigin(raw.y, length: resolvedHeight, within: frame.y ... frame.y + frame.height)
        return ScreenshotResolvedFixedPixelRegion(
            rect: ScreenshotSelectionRect(x: x, y: y, width: resolvedWidth, height: resolvedHeight),
            outputScale: target.backingScale
        )
    }

    public func nudge(
        _ rect: ScreenshotSelectionRect,
        outputPixelsX: Double,
        outputPixelsY: Double,
        outputScale: Double
    ) -> ScreenshotSelectionRect {
        guard outputScale > 0 else { return rect }
        return ScreenshotSelectionRect(
            x: rect.x + outputPixelsX / outputScale,
            y: rect.y + outputPixelsY / outputScale,
            width: rect.width,
            height: rect.height
        )
    }

    public func snap(
        _ rect: ScreenshotSelectionRect,
        verticalEdges: [Double],
        horizontalEdges: [Double],
        threshold: Double
    ) -> ScreenshotSelectionRect {
        var minX = rect.x
        var maxX = rect.x + rect.width
        var minY = rect.y
        var maxY = rect.y + rect.height

        if let edge = closestEdge(to: minX, in: verticalEdges, threshold: threshold) { minX = edge }
        if let edge = closestEdge(to: maxX, in: verticalEdges, threshold: threshold) { maxX = edge }
        if let edge = closestEdge(to: minY, in: horizontalEdges, threshold: threshold) { minY = edge }
        if let edge = closestEdge(to: maxY, in: horizontalEdges, threshold: threshold) { maxY = edge }

        guard maxX > minX, maxY > minY else { return rect }
        return ScreenshotSelectionRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    public func snapPreservingSize(
        _ rect: ScreenshotSelectionRect,
        verticalEdges: [Double],
        horizontalEdges: [Double],
        threshold: Double
    ) -> ScreenshotSelectionRect {
        let xOffsets = verticalEdges.flatMap { edge in
            [edge - rect.x, edge - (rect.x + rect.width)]
        }
        let yOffsets = horizontalEdges.flatMap { edge in
            [edge - rect.y, edge - (rect.y + rect.height)]
        }
        let dx = xOffsets.filter { abs($0) <= threshold }.min(by: { abs($0) < abs($1) }) ?? 0
        let dy = yOffsets.filter { abs($0) <= threshold }.min(by: { abs($0) < abs($1) }) ?? 0
        return ScreenshotSelectionRect(
            x: rect.x + dx,
            y: rect.y + dy,
            width: rect.width,
            height: rect.height
        )
    }

    public func meetsMinimumOutputSize(
        _ rect: ScreenshotSelectionRect,
        outputScale: Double,
        minimumPixels: Int = 16
    ) -> Bool {
        rect.width * outputScale >= Double(minimumPixels)
            && rect.height * outputScale >= Double(minimumPixels)
    }

    private func closestEdge(to value: Double, in edges: [Double], threshold: Double) -> Double? {
        edges
            .map { (edge: $0, distance: abs($0 - value)) }
            .filter { $0.distance <= threshold }
            .min(by: { $0.distance < $1.distance })?
            .edge
    }


    private func clampOrigin(_ origin: Double, length: Double, within range: ClosedRange<Double>) -> Double {
        guard length <= range.upperBound - range.lowerBound else { return range.lowerBound }
        return min(max(origin, range.lowerBound), range.upperBound - length)
    }

    private func intersection(
        _ lhs: ScreenshotSelectionRect,
        _ rhs: ScreenshotSelectionRect
    ) -> ScreenshotSelectionRect? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        guard maxX > minX, maxY > minY else { return nil }
        return ScreenshotSelectionRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
