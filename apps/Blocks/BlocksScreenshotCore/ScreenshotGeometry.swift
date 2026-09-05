import Foundation

public struct ScreenshotCurvatureAnchorResolution: Equatable, Sendable {
    public let value: Double
    public let isAnchored: Bool
    public let didEnterAnchor: Bool

    public init(value: Double, isAnchored: Bool, didEnterAnchor: Bool) {
        self.value = value
        self.isAnchored = isAnchored
        self.didEnterAnchor = didEnterAnchor
    }
}

public struct ScreenshotCurvatureAnchor: Equatable, Sendable {
    public let enterThreshold: Double
    public let exitThreshold: Double
    public private(set) var isAnchored: Bool

    public init(
        initialValue: Double,
        enterThreshold: Double,
        exitThreshold: Double
    ) {
        let normalizedEnter = max(0, enterThreshold)
        self.enterThreshold = normalizedEnter
        self.exitThreshold = max(normalizedEnter, exitThreshold)
        isAnchored = abs(initialValue) <= normalizedEnter
    }

    public mutating func resolve(
        _ proposedValue: Double,
        bypassesAnchor: Bool = false
    ) -> ScreenshotCurvatureAnchorResolution {
        guard !bypassesAnchor else {
            isAnchored = false
            return ScreenshotCurvatureAnchorResolution(
                value: proposedValue,
                isAnchored: false,
                didEnterAnchor: false
            )
        }

        if isAnchored {
            if abs(proposedValue) <= exitThreshold {
                return ScreenshotCurvatureAnchorResolution(
                    value: 0,
                    isAnchored: true,
                    didEnterAnchor: false
                )
            }
            isAnchored = false
            return ScreenshotCurvatureAnchorResolution(
                value: proposedValue,
                isAnchored: false,
                didEnterAnchor: false
            )
        }

        if abs(proposedValue) <= enterThreshold {
            isAnchored = true
            return ScreenshotCurvatureAnchorResolution(
                value: 0,
                isAnchored: true,
                didEnterAnchor: true
            )
        }

        return ScreenshotCurvatureAnchorResolution(
            value: proposedValue,
            isAnchored: false,
            didEnterAnchor: false
        )
    }
}

public struct ScreenshotLineEndpoints: Equatable, Sendable {
    public let start: ScreenshotPixelPoint
    public let end: ScreenshotPixelPoint

    public init(start: ScreenshotPixelPoint, end: ScreenshotPixelPoint) {
        self.start = start
        self.end = end
    }
}

public enum ScreenshotResizeHandle: String, CaseIterable, Sendable {
    case northWest
    case north
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
}

public enum ScreenshotObjectHitKind: String, Equatable, Sendable {
    case body
    case stroke
    case pointer
    case stepBadge
    case stepNote
    case stepConnector
    case calloutTarget
    case calloutNote
    case calloutConnector
}

public struct ScreenshotObjectHitResult: Equatable, Sendable {
    public let elementID: UUID
    public let kind: ScreenshotObjectHitKind
    public let zIndex: Int

    public init(elementID: UUID, kind: ScreenshotObjectHitKind, zIndex: Int) {
        self.elementID = elementID
        self.kind = kind
        self.zIndex = zIndex
    }
}

public struct ScreenshotMagnifierResolvedLayout: Equatable, Sendable {
    public let center: ScreenshotPixelPoint
    public let diameter: Double
    public let lensRect: ScreenshotPixelRect

    public init?(
        element: ScreenshotElement,
        constrainedTo sourceBounds: ScreenshotPixelRect? = nil
    ) {
        guard case let .magnifier(rawCenter) = element.geometry,
              case let .magnifier(appearance) = element.appearance.payload else { return nil }
        let requestedDiameter = ScreenshotMagnifierMetrics.resolvedDiameter(appearance.diameter).rounded()
        guard requestedDiameter > 0 else { return nil }
        let requestedRadius = requestedDiameter / 2
        guard let sourceBounds else {
            let resolvedCenter = ScreenshotPixelPoint(
                x: (rawCenter.x - requestedRadius).rounded() + requestedRadius,
                y: (rawCenter.y - requestedRadius).rounded() + requestedRadius
            )
            center = resolvedCenter
            diameter = requestedDiameter
            lensRect = Self.lensRect(center: resolvedCenter, diameter: requestedDiameter)
            return
        }

        let bounds = Self.normalized(sourceBounds)
        let resolvedDiameter = min(requestedDiameter, Double(bounds.width), Double(bounds.height))
        guard resolvedDiameter > 0 else { return nil }
        let radius = resolvedDiameter / 2
        let minimumOriginX = Double(bounds.x)
        let minimumOriginY = Double(bounds.y)
        let maximumOriginX = Double(bounds.x + bounds.width) - resolvedDiameter
        let maximumOriginY = Double(bounds.y + bounds.height) - resolvedDiameter
        let resolvedOriginX = min(
            max((rawCenter.x - radius).rounded(), minimumOriginX),
            maximumOriginX
        )
        let resolvedOriginY = min(
            max((rawCenter.y - radius).rounded(), minimumOriginY),
            maximumOriginY
        )
        let resolvedCenter = ScreenshotPixelPoint(
            x: resolvedOriginX + radius,
            y: resolvedOriginY + radius
        )
        center = resolvedCenter
        diameter = resolvedDiameter
        lensRect = Self.lensRect(center: resolvedCenter, diameter: resolvedDiameter)
    }

    private static func lensRect(center: ScreenshotPixelPoint, diameter: Double) -> ScreenshotPixelRect {
        let left = Int((center.x - diameter / 2).rounded())
        let top = Int((center.y - diameter / 2).rounded())
        let resolvedDiameter = Int(diameter.rounded())
        return .init(
            x: left,
            y: top,
            width: resolvedDiameter,
            height: resolvedDiameter
        )
    }

    private static func normalized(_ rect: ScreenshotPixelRect) -> ScreenshotPixelRect {
        .init(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }
}

public enum ScreenshotLinkedAnnotationLayout {
    public static func noteRect(
        targetBounds rawTargetBounds: ScreenshotPixelRect,
        noteSize: CGSize,
        gap proposedGap: Double,
        constrainedTo rawBounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        let bounds = normalized(rawBounds)
        let target = normalized(rawTargetBounds)
        let width = min(max(1, Int(ceil(noteSize.width))), max(1, bounds.width))
        let height = min(max(1, Int(ceil(noteSize.height))), max(1, bounds.height))
        let gap = max(0, Int(ceil(proposedGap.isFinite ? proposedGap : 0)))
        let centerX = target.x + target.width / 2
        let centerY = target.y + target.height / 2
        let candidates = [
            ScreenshotPixelRect(
                x: target.x + target.width + gap,
                y: centerY - height / 2,
                width: width,
                height: height
            ),
            ScreenshotPixelRect(
                x: target.x - gap - width,
                y: centerY - height / 2,
                width: width,
                height: height
            ),
            ScreenshotPixelRect(
                x: centerX - width / 2,
                y: target.y + target.height + gap,
                width: width,
                height: height
            ),
            ScreenshotPixelRect(
                x: centerX - width / 2,
                y: target.y - gap - height,
                width: width,
                height: height
            ),
        ]

        let fullyVisible = candidates.enumerated().filter { contains($0.element, in: bounds) }
        if let best = fullyVisible.min(by: { lhs, rhs in
            let lhsDistance = edgeDistance(lhs.element, target)
            let rhsDistance = edgeDistance(rhs.element, target)
            if abs(lhsDistance - rhsDistance) > 0.001 { return lhsDistance < rhsDistance }
            return lhs.offset < rhs.offset
        }) {
            return best.element
        }

        let ranked = candidates.enumerated().map { index, candidate in
            let visibleArea = intersectionArea(candidate, bounds)
            let fitted = fit(candidate, in: bounds)
            let dx = fitted.x - candidate.x
            let dy = fitted.y - candidate.y
            return (index, visibleArea, dx * dx + dy * dy, fitted)
        }
        return ranked.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0 > rhs.0
        }?.3 ?? fit(candidates[0], in: bounds)
    }

    private static func normalized(_ rect: ScreenshotPixelRect) -> ScreenshotPixelRect {
        .init(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private static func contains(_ rect: ScreenshotPixelRect, in bounds: ScreenshotPixelRect) -> Bool {
        rect.x >= bounds.x
            && rect.y >= bounds.y
            && rect.x + rect.width <= bounds.x + bounds.width
            && rect.y + rect.height <= bounds.y + bounds.height
    }

    private static func fit(_ rect: ScreenshotPixelRect, in bounds: ScreenshotPixelRect) -> ScreenshotPixelRect {
        .init(
            x: min(max(rect.x, bounds.x), bounds.x + bounds.width - rect.width),
            y: min(max(rect.y, bounds.y), bounds.y + bounds.height - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    private static func intersectionArea(_ rect: ScreenshotPixelRect, _ bounds: ScreenshotPixelRect) -> Int {
        let width = max(0, min(rect.x + rect.width, bounds.x + bounds.width) - max(rect.x, bounds.x))
        let height = max(0, min(rect.y + rect.height, bounds.y + bounds.height) - max(rect.y, bounds.y))
        return width * height
    }

    private static func edgeDistance(_ lhs: ScreenshotPixelRect, _ rhs: ScreenshotPixelRect) -> Double {
        let dx = max(0, max(rhs.x - (lhs.x + lhs.width), lhs.x - (rhs.x + rhs.width)))
        let dy = max(0, max(rhs.y - (lhs.y + lhs.height), lhs.y - (rhs.y + rhs.height)))
        return hypot(Double(dx), Double(dy))
    }
}

public struct ScreenshotStepResolvedLayout: Equatable, Sendable {
    public static let defaultGap = 28.0
    public static let minimumGap = 8.0

    public let badgeCenter: ScreenshotPixelPoint
    public let badgeDiameter: Double
    public let badgeRect: ScreenshotPixelRect
    public let badgeTextRect: ScreenshotPixelRect
    public let badgeFontSize: Double
    public let noteRect: ScreenshotPixelRect?
    public let connector: ScreenshotLineEndpoints?
    public let connectorAttachment: ScreenshotStepConnectorAttachment?
    public let connectorControlPoint: ScreenshotPixelPoint?
    public let connectorBounds: ScreenshotPixelRect?
    public let connectorLineWidth: Double
    public let bounds: ScreenshotPixelRect

    public init?(element: ScreenshotElement) {
        guard case let .step(badgeCenter, rawNoteRect) = element.geometry,
              case let .step(appearance) = element.appearance.payload else { return nil }

        let badgeSize = max(16, appearance.badgeSize.isFinite ? appearance.badgeSize : 16)
        let badgeRect = Self.pixelRect(
            x: badgeCenter.x - badgeSize / 2,
            y: badgeCenter.y - badgeSize / 2,
            width: badgeSize,
            height: badgeSize
        )
        self.badgeCenter = badgeCenter
        badgeDiameter = badgeSize
        self.badgeRect = badgeRect
        badgeTextRect = ScreenshotPixelRect(
            x: Int(badgeCenter.x - badgeSize / 2),
            y: Int(badgeCenter.y - badgeSize / 2 + badgeSize * 0.12),
            width: Int(badgeSize),
            height: Int(badgeSize * 0.76)
        )
        badgeFontSize = badgeSize * 0.46
        connectorLineWidth = max(0.5, appearance.connector.width)

        guard let rawNoteRect else {
            noteRect = nil
            connector = nil
            connectorAttachment = nil
            connectorControlPoint = nil
            connectorBounds = nil
            bounds = badgeRect
            return
        }

        let noteRect = Self.normalized(rawNoteRect)
        self.noteRect = noteRect

        let noteAnchor = Self.nearestPoint(on: noteRect, to: badgeCenter)
        let dx = noteAnchor.x - badgeCenter.x
        let dy = noteAnchor.y - badgeCenter.y
        let distance = hypot(dx, dy)
        let direction = distance > 0
            ? ScreenshotPixelPoint(x: dx / distance, y: dy / distance)
            : ScreenshotPixelPoint(x: 1, y: 0)
        connectorAttachment = .init(
            badgeDirection: direction,
            notePosition: .init(
                x: (noteAnchor.x - Double(noteRect.x)) / Double(max(1, noteRect.width)),
                y: (noteAnchor.y - Double(noteRect.y)) / Double(max(1, noteRect.height))
            )
        )
        let badgeAnchor = ScreenshotPixelPoint(
            x: badgeCenter.x + direction.x * badgeSize / 2,
            y: badgeCenter.y + direction.y * badgeSize / 2
        )
        let connector = ScreenshotLineEndpoints(start: badgeAnchor, end: noteAnchor)
        self.connector = connector
        let control = ScreenshotGeometry.lineControlPoint(
            start: connector.start,
            end: connector.end,
            curvature: appearance.connector.curvature
        )
        connectorControlPoint = control
        let connectorBounds = Self.pixelRect(
            x: min(connector.start.x, control.x, connector.end.x) - connectorLineWidth,
            y: min(connector.start.y, control.y, connector.end.y) - connectorLineWidth,
            width: max(connector.start.x, control.x, connector.end.x)
                - min(connector.start.x, control.x, connector.end.x)
                + connectorLineWidth * 2,
            height: max(connector.start.y, control.y, connector.end.y)
                - min(connector.start.y, control.y, connector.end.y)
                + connectorLineWidth * 2
        )
        self.connectorBounds = connectorBounds
        bounds = Self.union(Self.union(badgeRect, noteRect), connectorBounds)
    }

    public func hitKind(
        at point: ScreenshotPixelPoint,
        tolerance proposedTolerance: Double
    ) -> ScreenshotObjectHitKind? {
        let tolerance = max(0, proposedTolerance)
        let badgeDistance = hypot(point.x - badgeCenter.x, point.y - badgeCenter.y)
        let badgeBoundaryDistance = max(0, badgeDistance - badgeDiameter / 2)
        let noteBoundaryDistance = noteRect.map { Self.distance(from: point, to: $0) }

        // An actual object interior must win over another object's enlarged
        // pointer tolerance. This keeps a zoomed-out note draggable even when
        // its leading edge is close to the badge handles.
        if badgeBoundaryDistance == 0 { return .stepBadge }
        if noteBoundaryDistance == 0 { return .stepNote }

        let badgeIsNear = badgeBoundaryDistance <= tolerance
        let noteIsNear = noteBoundaryDistance.map { $0 <= tolerance } ?? false
        if badgeIsNear || noteIsNear {
            if badgeIsNear, noteIsNear, let noteBoundaryDistance {
                return noteBoundaryDistance < badgeBoundaryDistance ? .stepNote : .stepBadge
            }
            return badgeIsNear ? .stepBadge : .stepNote
        }

        if let connector,
           let connectorControlPoint,
           Self.distance(
               from: point,
               toQuadraticFrom: connector.start,
               control: connectorControlPoint,
               to: connector.end
           ) <= tolerance + connectorLineWidth / 2 {
            return .stepConnector
        }
        return nil
    }

    public static func constrainedNoteRect(
        _ proposedNoteRect: ScreenshotPixelRect,
        badgeCenter: ScreenshotPixelPoint,
        badgeDiameter: Double,
        gap proposedGap: Double,
        constrainedTo sourceBounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        let gap = max(minimumGap, proposedGap.isFinite ? proposedGap : defaultGap)
        return resolveNoteRect(
            normalized(proposedNoteRect),
            fromBadgeCenteredAt: badgeCenter,
            radius: max(16, badgeDiameter.isFinite ? badgeDiameter : 16) / 2,
            gap: gap,
            constrainedTo: normalized(sourceBounds)
        )
    }

    public static func constrainedBadgeCenter(
        _ proposedBadgeCenter: ScreenshotPixelPoint,
        badgeDiameter: Double,
        noteRect: ScreenshotPixelRect?,
        gap proposedGap: Double,
        constrainedTo sourceBounds: ScreenshotPixelRect
    ) -> ScreenshotPixelPoint {
        let bounds = normalized(sourceBounds)
        let diameter = max(16, badgeDiameter.isFinite ? badgeDiameter : 16)
        let radius = diameter / 2
        let fitted = fit(
            proposedBadgeCenter,
            radius: radius,
            inside: bounds
        )
        guard let rawNoteRect = noteRect else { return fitted }
        let noteRect = normalized(rawNoteRect)
        let gap = max(minimumGap, proposedGap.isFinite ? proposedGap : defaultGap)
        guard edgeGap(from: fitted, radius: radius, to: noteRect) < gap else { return fitted }

        var candidates = [fitted]
        candidates.append(separate(
            fitted,
            from: noteRect,
            radius: radius,
            gap: gap
        ))
        let minimumX = Double(bounds.x) + radius
        let maximumX = Double(bounds.x + bounds.width) - radius
        let minimumY = Double(bounds.y) + radius
        let maximumY = Double(bounds.y + bounds.height) - radius
        candidates.append(contentsOf: [
            .init(x: minimumX, y: fitted.y),
            .init(x: maximumX, y: fitted.y),
            .init(x: fitted.x, y: minimumY),
            .init(x: fitted.x, y: maximumY),
            .init(x: minimumX, y: minimumY),
            .init(x: maximumX, y: minimumY),
            .init(x: minimumX, y: maximumY),
            .init(x: maximumX, y: maximumY),
        ])
        candidates = candidates.map { fit($0, radius: radius, inside: bounds) }

        func movement(_ candidate: ScreenshotPixelPoint) -> Double {
            let dx = candidate.x - fitted.x
            let dy = candidate.y - fitted.y
            return dx * dx + dy * dy
        }
        let meetingGap = candidates.filter { edgeGap(from: $0, radius: radius, to: noteRect) >= gap - 0.001 }
        if let closest = meetingGap.min(by: { movement($0) < movement($1) }) {
            return closest
        }
        return candidates.max {
            let lhsGap = edgeGap(from: $0, radius: radius, to: noteRect)
            let rhsGap = edgeGap(from: $1, radius: radius, to: noteRect)
            if abs(lhsGap - rhsGap) > 0.001 { return lhsGap < rhsGap }
            return movement($0) > movement($1)
        } ?? fitted
    }

    private static func resolveNoteRect(
        _ rect: ScreenshotPixelRect,
        fromBadgeCenteredAt center: ScreenshotPixelPoint,
        radius: Double,
        gap: Double,
        constrainedTo bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        let fitted = fit(rect, inside: bounds)
        guard edgeGap(from: center, radius: radius, to: fitted) < gap else { return fitted }

        let separated = separate(fitted, fromBadgeCenteredAt: center, radius: radius, gap: gap)
        let width = fitted.width
        let height = fitted.height
        let maximumX = bounds.x + bounds.width - width
        let maximumY = bounds.y + bounds.height - height
        let desiredCenterX = Double(fitted.x) + Double(width) / 2
        let desiredCenterY = Double(fitted.y) + Double(height) / 2
        let candidates = [
            fitted,
            fit(separated, inside: bounds),
            ScreenshotPixelRect(x: bounds.x, y: fitted.y, width: width, height: height),
            ScreenshotPixelRect(x: maximumX, y: fitted.y, width: width, height: height),
            ScreenshotPixelRect(x: fitted.x, y: bounds.y, width: width, height: height),
            ScreenshotPixelRect(x: fitted.x, y: maximumY, width: width, height: height),
            ScreenshotPixelRect(x: bounds.x, y: bounds.y, width: width, height: height),
            ScreenshotPixelRect(x: maximumX, y: bounds.y, width: width, height: height),
            ScreenshotPixelRect(x: bounds.x, y: maximumY, width: width, height: height),
            ScreenshotPixelRect(x: maximumX, y: maximumY, width: width, height: height),
        ].map { fit($0, inside: bounds) }

        func movement(_ candidate: ScreenshotPixelRect) -> Double {
            let dx = Double(candidate.x) + Double(candidate.width) / 2 - desiredCenterX
            let dy = Double(candidate.y) + Double(candidate.height) / 2 - desiredCenterY
            return dx * dx + dy * dy
        }
        let meetingGap = candidates.filter { edgeGap(from: center, radius: radius, to: $0) >= gap - 0.001 }
        if let closest = meetingGap.min(by: { movement($0) < movement($1) }) {
            return closest
        }
        return candidates.max {
            let lhsGap = edgeGap(from: center, radius: radius, to: $0)
            let rhsGap = edgeGap(from: center, radius: radius, to: $1)
            if abs(lhsGap - rhsGap) > 0.001 { return lhsGap < rhsGap }
            return movement($0) > movement($1)
        } ?? fitted
    }

    private static func separate(
        _ rect: ScreenshotPixelRect,
        fromBadgeCenteredAt center: ScreenshotPixelPoint,
        radius: Double,
        gap: Double
    ) -> ScreenshotPixelRect {
        let nearest = nearestPoint(on: rect, to: center)
        var dx = nearest.x - center.x
        var dy = nearest.y - center.y
        var distance = hypot(dx, dy)
        if distance == 0 {
            let rectCenter = ScreenshotPixelPoint(
                x: Double(rect.x) + Double(rect.width) / 2,
                y: Double(rect.y) + Double(rect.height) / 2
            )
            dx = rectCenter.x - center.x
            dy = rectCenter.y - center.y
            if abs(dx) >= abs(dy) {
                dx = dx >= 0 ? 1 : -1
                dy = 0
            } else {
                dx = 0
                dy = dy >= 0 ? 1 : -1
            }
            distance = 1
        }
        let shift = max(0, radius + gap - distance)
        let shiftX = dx / distance * shift
        let shiftY = dy / distance * shift
        return ScreenshotPixelRect(
            x: rect.x + Int(shiftX.rounded(.awayFromZero)),
            y: rect.y + Int(shiftY.rounded(.awayFromZero)),
            width: rect.width,
            height: rect.height
        )
    }

    private static func separate(
        _ center: ScreenshotPixelPoint,
        from rect: ScreenshotPixelRect,
        radius: Double,
        gap: Double
    ) -> ScreenshotPixelPoint {
        let nearest = nearestPoint(on: rect, to: center)
        var dx = center.x - nearest.x
        var dy = center.y - nearest.y
        var distance = hypot(dx, dy)
        if distance == 0 {
            let rectCenter = ScreenshotPixelPoint(
                x: Double(rect.x) + Double(rect.width) / 2,
                y: Double(rect.y) + Double(rect.height) / 2
            )
            dx = center.x - rectCenter.x
            dy = center.y - rectCenter.y
            if abs(dx) >= abs(dy) {
                dx = dx >= 0 ? 1 : -1
                dy = 0
            } else {
                dx = 0
                dy = dy >= 0 ? 1 : -1
            }
            distance = 1
        }
        let shift = max(0, radius + gap - distance)
        return ScreenshotPixelPoint(
            x: center.x + dx / distance * shift,
            y: center.y + dy / distance * shift
        )
    }

    private static func edgeGap(
        from center: ScreenshotPixelPoint,
        radius: Double,
        to rect: ScreenshotPixelRect
    ) -> Double {
        let nearest = nearestPoint(on: rect, to: center)
        return hypot(nearest.x - center.x, nearest.y - center.y) - radius
    }

    private static func fit(
        _ rect: ScreenshotPixelRect,
        inside bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return ScreenshotPixelRect(
            x: min(max(rect.x, bounds.x), bounds.x + bounds.width - width),
            y: min(max(rect.y, bounds.y), bounds.y + bounds.height - height),
            width: width,
            height: height
        )
    }

    private static func fit(
        _ point: ScreenshotPixelPoint,
        radius: Double,
        inside bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelPoint {
        let x = Double(bounds.width) < radius * 2
            ? Double(bounds.x) + Double(bounds.width) / 2
            : min(max(point.x, Double(bounds.x) + radius), Double(bounds.x + bounds.width) - radius)
        let y = Double(bounds.height) < radius * 2
            ? Double(bounds.y) + Double(bounds.height) / 2
            : min(max(point.y, Double(bounds.y) + radius), Double(bounds.y + bounds.height) - radius)
        return ScreenshotPixelPoint(x: x, y: y)
    }

    private static func normalized(_ rect: ScreenshotPixelRect) -> ScreenshotPixelRect {
        return ScreenshotPixelRect(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private static func nearestPoint(
        on rect: ScreenshotPixelRect,
        to point: ScreenshotPixelPoint
    ) -> ScreenshotPixelPoint {
        ScreenshotPixelPoint(
            x: min(max(point.x, Double(rect.x)), Double(rect.x + rect.width)),
            y: min(max(point.y, Double(rect.y)), Double(rect.y + rect.height))
        )
    }

    private static func pixelRect(x: Double, y: Double, width: Double, height: Double) -> ScreenshotPixelRect {
        let left = floor(x)
        let top = floor(y)
        let right = ceil(x + width)
        let bottom = ceil(y + height)
        return ScreenshotPixelRect(
            x: Int(left),
            y: Int(top),
            width: Int(right - left),
            height: Int(bottom - top)
        )
    }

    private static func union(_ lhs: ScreenshotPixelRect, _ rhs: ScreenshotPixelRect) -> ScreenshotPixelRect {
        let left = min(lhs.x, rhs.x)
        let top = min(lhs.y, rhs.y)
        let right = max(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = max(lhs.y + lhs.height, rhs.y + rhs.height)
        return ScreenshotPixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func distance(
        from point: ScreenshotPixelPoint,
        to rect: ScreenshotPixelRect
    ) -> Double {
        let nearest = nearestPoint(on: rect, to: point)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func distance(
        from point: ScreenshotPixelPoint,
        toSegmentFrom start: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(
            1,
            max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
        )
        let closest = ScreenshotPixelPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private static func distance(
        from point: ScreenshotPixelPoint,
        toQuadraticFrom start: ScreenshotPixelPoint,
        control: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint
    ) -> Double {
        let points = (0...24).map { index -> ScreenshotPixelPoint in
            let t = Double(index) / 24
            let inverse = 1 - t
            return ScreenshotPixelPoint(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
        return zip(points, points.dropFirst()).map {
            distance(from: point, toSegmentFrom: $0.0, to: $0.1)
        }.min() ?? .infinity
    }
}

public struct ScreenshotCalloutResolvedLayout: Equatable, Sendable {
    public let target: ScreenshotCalloutTarget
    public let targetRect: ScreenshotPixelRect?
    public let noteRect: ScreenshotPixelRect
    public let connector: ScreenshotLineEndpoints
    public let connectorAttachment: ScreenshotCalloutConnectorAttachment
    public let connectorControlPoint: ScreenshotPixelPoint
    public let connectorBounds: ScreenshotPixelRect
    public let bounds: ScreenshotPixelRect

    public init?(element: ScreenshotElement) {
        guard element.kind == .callout,
              case let .callout(appearance) = element.appearance.payload else { return nil }
        let resolvedTarget: ScreenshotCalloutTarget
        let rawNote: ScreenshotPixelRect
        switch element.geometry {
        case let .callout(body, pointer):
            resolvedTarget = .point(pointer)
            rawNote = body
        case let .calloutComposite(target, note):
            resolvedTarget = target
            rawNote = note
        default:
            return nil
        }

        target = resolvedTarget
        noteRect = Self.normalized(rawNote)
        let targetCenter: ScreenshotPixelPoint
        switch resolvedTarget {
        case let .point(point):
            targetRect = nil
            targetCenter = point
        case let .ellipse(rect):
            let rect = Self.normalized(rect)
            targetRect = rect
            targetCenter = .init(
                x: Double(rect.x) + Double(rect.width) / 2,
                y: Double(rect.y) + Double(rect.height) / 2
            )
        }

        let noteAnchor = Self.nearestPoint(on: noteRect, to: targetCenter)
        let targetDX = noteAnchor.x - targetCenter.x
        let targetDY = noteAnchor.y - targetCenter.y
        let targetDistance = hypot(targetDX, targetDY)
        let targetDirection = targetDistance > 0
            ? ScreenshotPixelPoint(x: targetDX / targetDistance, y: targetDY / targetDistance)
            : ScreenshotPixelPoint(x: 1, y: 0)
        connectorAttachment = .init(
            targetDirection: targetDirection,
            notePosition: .init(
                x: (noteAnchor.x - Double(noteRect.x)) / Double(max(1, noteRect.width)),
                y: (noteAnchor.y - Double(noteRect.y)) / Double(max(1, noteRect.height))
            )
        )
        let targetAnchor: ScreenshotPixelPoint
        switch resolvedTarget {
        case let .point(point):
            targetAnchor = point
        case .ellipse:
            guard let targetRect else { return nil }
            targetAnchor = Self.ellipseBoundary(
                rect: targetRect,
                direction: targetDirection
            )
        }
        connector = .init(start: noteAnchor, end: targetAnchor)
        connectorControlPoint = ScreenshotGeometry.lineControlPoint(
            start: noteAnchor,
            end: targetAnchor,
            curvature: appearance.connector.curvature
        )
        let lineWidth = max(0.5, appearance.connector.width)
        connectorBounds = Self.pixelRect(containing: [
            connector.start,
            connectorControlPoint,
            connector.end,
        ], outset: lineWidth)
        let targetBounds = targetRect ?? ScreenshotPixelRect(
            x: Int(targetAnchor.x.rounded()),
            y: Int(targetAnchor.y.rounded()),
            width: 1,
            height: 1
        )
        bounds = Self.union(Self.union(targetBounds, noteRect), connectorBounds)
    }

    public func hitKind(
        at point: ScreenshotPixelPoint,
        tolerance: Double
    ) -> ScreenshotObjectHitKind? {
        let tolerance = max(0, tolerance)
        if let targetRect,
           Self.hitEllipse(point, rect: targetRect, tolerance: tolerance) {
            return .calloutTarget
        }
        if Self.contains(point, rect: noteRect, outset: tolerance) {
            return .calloutNote
        }
        if Self.distance(
            from: point,
            toQuadraticFrom: connector.start,
            control: connectorControlPoint,
            to: connector.end
        ) <= tolerance + 2 {
            return .calloutConnector
        }
        if case let .point(targetPoint) = target,
           hypot(point.x - targetPoint.x, point.y - targetPoint.y) <= tolerance + 5 {
            return .calloutTarget
        }
        return nil
    }

    private static func normalized(_ rect: ScreenshotPixelRect) -> ScreenshotPixelRect {
        .init(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private static func nearestPoint(
        on rect: ScreenshotPixelRect,
        to point: ScreenshotPixelPoint
    ) -> ScreenshotPixelPoint {
        let left = Double(rect.x)
        let right = Double(rect.x + rect.width)
        let top = Double(rect.y)
        let bottom = Double(rect.y + rect.height)
        let clampedX = min(max(point.x, left), right)
        let clampedY = min(max(point.y, top), bottom)
        let candidates = [
            ScreenshotPixelPoint(x: left, y: clampedY),
            ScreenshotPixelPoint(x: right, y: clampedY),
            ScreenshotPixelPoint(x: clampedX, y: top),
            ScreenshotPixelPoint(x: clampedX, y: bottom),
        ]
        return candidates.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        } ?? .init(x: left, y: top)
    }

    private static func ellipseBoundary(
        rect: ScreenshotPixelRect,
        direction: ScreenshotPixelPoint
    ) -> ScreenshotPixelPoint {
        let center = ScreenshotPixelPoint(
            x: Double(rect.x) + Double(rect.width) / 2,
            y: Double(rect.y) + Double(rect.height) / 2
        )
        let radiusX = max(0.5, Double(rect.width) / 2)
        let radiusY = max(0.5, Double(rect.height) / 2)
        let dx = direction.x
        let dy = direction.y
        let denominator = sqrt(dx * dx / (radiusX * radiusX) + dy * dy / (radiusY * radiusY))
        guard denominator > 0 else { return .init(x: center.x + radiusX, y: center.y) }
        return .init(x: center.x + dx / denominator, y: center.y + dy / denominator)
    }

    private static func contains(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        outset: Double
    ) -> Bool {
        point.x >= Double(rect.x) - outset
            && point.x <= Double(rect.x + rect.width) + outset
            && point.y >= Double(rect.y) - outset
            && point.y <= Double(rect.y + rect.height) + outset
    }

    private static func hitEllipse(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        tolerance: Double
    ) -> Bool {
        let radiusX = max(0.5, Double(rect.width) / 2 + tolerance)
        let radiusY = max(0.5, Double(rect.height) / 2 + tolerance)
        let centerX = Double(rect.x) + Double(rect.width) / 2
        let centerY = Double(rect.y) + Double(rect.height) / 2
        let dx = (point.x - centerX) / radiusX
        let dy = (point.y - centerY) / radiusY
        return dx * dx + dy * dy <= 1
    }

    private static func distance(
        from point: ScreenshotPixelPoint,
        toQuadraticFrom start: ScreenshotPixelPoint,
        control: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint
    ) -> Double {
        let points = (0...24).map { index -> ScreenshotPixelPoint in
            let t = Double(index) / 24
            let inverse = 1 - t
            return .init(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
        return zip(points, points.dropFirst()).map { first, second in
            let dx = second.x - first.x
            let dy = second.y - first.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.x - first.x, point.y - first.y) }
            let t = min(1, max(0, ((point.x - first.x) * dx + (point.y - first.y) * dy) / lengthSquared))
            return hypot(point.x - (first.x + t * dx), point.y - (first.y + t * dy))
        }.min() ?? .infinity
    }

    private static func pixelRect(
        containing points: [ScreenshotPixelPoint],
        outset: Double
    ) -> ScreenshotPixelRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? minX
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? minY
        return .init(
            x: Int(floor(minX - outset)),
            y: Int(floor(minY - outset)),
            width: max(1, Int(ceil(maxX - minX + outset * 2))),
            height: max(1, Int(ceil(maxY - minY + outset * 2)))
        )
    }

    private static func union(_ lhs: ScreenshotPixelRect, _ rhs: ScreenshotPixelRect) -> ScreenshotPixelRect {
        let minX = min(lhs.x, rhs.x)
        let minY = min(lhs.y, rhs.y)
        let maxX = max(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = max(lhs.y + lhs.height, rhs.y + rhs.height)
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public enum ScreenshotGeometry {
    public static func bounds(of element: ScreenshotElement) -> ScreenshotPixelRect {
        switch element.geometry {
        case let .line(start, end):
            let control = lineControlPoint(
                start: start,
                end: end,
                curvature: element.appearance.curvature
            )
            return rect(containing: [start, control, end])
        case let .counter(center):
            guard case let .counter(value) = element.appearance.payload else {
                return bounds(of: element.geometry)
            }
            let size = max(16, value.size)
            return .init(
                x: Int((center.x - size / 2).rounded(.down)),
                y: Int((center.y - size / 2).rounded(.down)),
                width: Int(size.rounded(.up)),
                height: Int(size.rounded(.up))
            )
        case .step:
            return ScreenshotStepResolvedLayout(element: element)?.bounds ?? bounds(of: element.geometry)
        case .callout:
            return ScreenshotCalloutResolvedLayout(element: element)?.bounds ?? bounds(of: element.geometry)
        case .magnifier:
            return ScreenshotMagnifierResolvedLayout(element: element)?.lensRect ?? bounds(of: element.geometry)
        default:
            return bounds(of: element.geometry)
        }
    }

    public static func bounds(of geometry: ScreenshotElementGeometry) -> ScreenshotPixelRect {
        switch geometry {
        case let .line(start, end):
            return rect(containing: [start, end])
        case let .rect(rect):
            return normalized(rect)
        case let .path(points):
            return rect(containing: points)
        case let .callout(body, pointer):
            return rect(containing: [
                .init(x: Double(body.x), y: Double(body.y)),
                .init(x: Double(body.x + body.width), y: Double(body.y + body.height)),
                pointer,
            ])
        case let .calloutComposite(target, note):
            let targetBounds: ScreenshotPixelRect = switch target {
            case let .point(point):
                .init(x: Int(point.x.rounded()), y: Int(point.y.rounded()), width: 1, height: 1)
            case let .ellipse(rect):
                normalized(rect)
            }
            return union(normalized(note), targetBounds)
        case let .counter(center):
            return .init(x: Int(center.x.rounded()), y: Int(center.y.rounded()), width: 0, height: 0)
        case let .step(badgeCenter, note):
            let badge = ScreenshotPixelRect(
                x: Int(badgeCenter.x.rounded()),
                y: Int(badgeCenter.y.rounded()),
                width: 0,
                height: 0
            )
            return note.map { union(badge, normalized($0)) } ?? badge
        case let .magnifier(center):
            return .init(x: Int(center.x.rounded()), y: Int(center.y.rounded()), width: 0, height: 0)
        }
    }

    public static func lineEndpoints(of geometry: ScreenshotElementGeometry) -> ScreenshotLineEndpoints? {
        guard case let .line(start, end) = geometry else { return nil }
        return ScreenshotLineEndpoints(start: start, end: end)
    }

    public static func translate(
        _ geometry: ScreenshotElementGeometry,
        dx: Double,
        dy: Double
    ) -> ScreenshotElementGeometry {
        switch geometry {
        case let .line(start, end):
            return .line(start: offset(start, dx: dx, dy: dy), end: offset(end, dx: dx, dy: dy))
        case let .rect(rect):
            return .rect(.init(
                x: rect.x + Int(dx.rounded()),
                y: rect.y + Int(dy.rounded()),
                width: rect.width,
                height: rect.height
            ))
        case let .path(points):
            return .path(points.map { offset($0, dx: dx, dy: dy) })
        case let .callout(body, pointer):
            return .callout(
                body: .init(
                    x: body.x + Int(dx.rounded()),
                    y: body.y + Int(dy.rounded()),
                    width: body.width,
                    height: body.height
                ),
                pointer: offset(pointer, dx: dx, dy: dy)
            )
        case let .calloutComposite(target, note):
            let translatedTarget: ScreenshotCalloutTarget = switch target {
            case let .point(point):
                .point(offset(point, dx: dx, dy: dy))
            case let .ellipse(rect):
                .ellipse(.init(
                    x: rect.x + Int(dx.rounded()),
                    y: rect.y + Int(dy.rounded()),
                    width: rect.width,
                    height: rect.height
                ))
            }
            return .calloutComposite(
                target: translatedTarget,
                note: .init(
                    x: note.x + Int(dx.rounded()),
                    y: note.y + Int(dy.rounded()),
                    width: note.width,
                    height: note.height
                )
            )
        case let .counter(center):
            return .counter(center: offset(center, dx: dx, dy: dy))
        case let .step(badgeCenter, note):
            return .step(
                badgeCenter: offset(badgeCenter, dx: dx, dy: dy),
                note: note.map {
                    .init(
                        x: $0.x + Int(dx.rounded()),
                        y: $0.y + Int(dy.rounded()),
                        width: $0.width,
                        height: $0.height
                    )
                }
            )
        case let .magnifier(center):
            return .magnifier(center: offset(center, dx: dx, dy: dy))
        }
    }

    public static func translateWithinBounds(
        _ geometry: ScreenshotElementGeometry,
        dx: Double,
        dy: Double,
        bounds: ScreenshotPixelRect
    ) -> ScreenshotElementGeometry {
        let geometryBounds = self.bounds(of: geometry)
        let bounds = normalized(bounds)
        let minDX = Double(bounds.x - geometryBounds.x)
        let maxDX = Double(bounds.x + bounds.width - geometryBounds.x - geometryBounds.width)
        let minDY = Double(bounds.y - geometryBounds.y)
        let maxDY = Double(bounds.y + bounds.height - geometryBounds.y - geometryBounds.height)
        return translate(
            geometry,
            dx: min(max(dx, minDX), maxDX),
            dy: min(max(dy, minDY), maxDY)
        )
    }

    public static func translateWithinBounds(
        _ element: ScreenshotElement,
        dx: Double,
        dy: Double,
        bounds: ScreenshotPixelRect
    ) -> ScreenshotElementGeometry {
        let elementBounds = self.bounds(of: element)
        let bounds = normalized(bounds)
        let minDX = Double(bounds.x - elementBounds.x)
        let maxDX = Double(bounds.x + bounds.width - elementBounds.x - elementBounds.width)
        let minDY = Double(bounds.y - elementBounds.y)
        let maxDY = Double(bounds.y + bounds.height - elementBounds.y - elementBounds.height)
        return translate(
            element.geometry,
            dx: min(max(dx, minDX), maxDX),
            dy: min(max(dy, minDY), maxDY)
        )
    }

    public static func resize(
        _ rect: ScreenshotPixelRect,
        handle: ScreenshotResizeHandle,
        to point: ScreenshotPixelPoint,
        constrainedTo bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        resize(rect, handle: handle, to: clamp(point, to: bounds))
    }

    public static func resize(
        _ rect: ScreenshotPixelRect,
        handle: ScreenshotResizeHandle,
        to point: ScreenshotPixelPoint,
        constrainedTo bounds: ScreenshotPixelRect,
        aspectRatio: Double
    ) -> ScreenshotPixelRect {
        guard aspectRatio > 0 else {
            return resize(rect, handle: handle, to: point, constrainedTo: bounds)
        }
        let rect = normalized(rect)
        let bounds = normalized(bounds)
        let point = clamp(point, to: bounds)
        let isLeft = handle == .northWest || handle == .west || handle == .southWest
        let isTop = handle == .northWest || handle == .north || handle == .northEast
        let isHorizontalEdge = handle == .east || handle == .west
        let isVerticalEdge = handle == .north || handle == .south

        if isHorizontalEdge {
            let anchorX = Double(isLeft ? rect.x + rect.width : rect.x)
            let centerY = Double(rect.y) + Double(rect.height) / 2
            let maximumWidth = isLeft
                ? anchorX - Double(bounds.x)
                : Double(bounds.x + bounds.width) - anchorX
            let verticalRoom = 2 * min(
                centerY - Double(bounds.y),
                Double(bounds.y + bounds.height) - centerY
            )
            let width = max(0, min(abs(point.x - anchorX), maximumWidth, verticalRoom * aspectRatio))
            let height = width / aspectRatio
            return pixelRect(
                x: isLeft ? anchorX - width : anchorX,
                y: centerY - height / 2,
                width: width,
                height: height
            )
        }

        if isVerticalEdge {
            let anchorY = Double(isTop ? rect.y + rect.height : rect.y)
            let centerX = Double(rect.x) + Double(rect.width) / 2
            let maximumHeight = isTop
                ? anchorY - Double(bounds.y)
                : Double(bounds.y + bounds.height) - anchorY
            let horizontalRoom = 2 * min(
                centerX - Double(bounds.x),
                Double(bounds.x + bounds.width) - centerX
            )
            let height = max(0, min(abs(point.y - anchorY), maximumHeight, horizontalRoom / aspectRatio))
            let width = height * aspectRatio
            return pixelRect(
                x: centerX - width / 2,
                y: isTop ? anchorY - height : anchorY,
                width: width,
                height: height
            )
        }

        let anchorX = Double(isLeft ? rect.x + rect.width : rect.x)
        let anchorY = Double(isTop ? rect.y + rect.height : rect.y)
        return aspectRect(
            anchor: .init(x: anchorX, y: anchorY),
            movingPoint: point,
            aspectRatio: aspectRatio,
            bounds: bounds
        )
    }

    public static func rect(
        from start: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint,
        aspectRatio: Double,
        constrainedTo bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        guard aspectRatio > 0 else {
            return clamp(
                .init(
                    x: Int(min(start.x, end.x).rounded()),
                    y: Int(min(start.y, end.y).rounded()),
                    width: Int(abs(end.x - start.x).rounded()),
                    height: Int(abs(end.y - start.y).rounded())
                ),
                to: bounds
            )
        }
        return aspectRect(
            anchor: clamp(start, to: bounds),
            movingPoint: clamp(end, to: bounds),
            aspectRatio: aspectRatio,
            bounds: normalized(bounds)
        )
    }

    private static func aspectRect(
        anchor: ScreenshotPixelPoint,
        movingPoint: ScreenshotPixelPoint,
        aspectRatio: Double,
        bounds: ScreenshotPixelRect
    ) -> ScreenshotPixelRect {
        let movingLeft = movingPoint.x < anchor.x
        let movingTop = movingPoint.y < anchor.y
        let maximumWidth = movingLeft
            ? anchor.x - Double(bounds.x)
            : Double(bounds.x + bounds.width) - anchor.x
        let maximumHeight = movingTop
            ? anchor.y - Double(bounds.y)
            : Double(bounds.y + bounds.height) - anchor.y
        let rawWidth = abs(movingPoint.x - anchor.x)
        let rawHeight = abs(movingPoint.y - anchor.y)
        var width: Double
        var height: Double
        if rawHeight == 0 || rawWidth / max(rawHeight, 0.0001) >= aspectRatio {
            width = rawWidth
            height = width / aspectRatio
        } else {
            height = rawHeight
            width = height * aspectRatio
        }
        let scale = min(
            1,
            maximumWidth / max(width, 0.0001),
            maximumHeight / max(height, 0.0001)
        )
        width *= max(0, scale)
        height *= max(0, scale)
        return pixelRect(
            x: movingLeft ? anchor.x - width : anchor.x,
            y: movingTop ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    private static func pixelRect(x: Double, y: Double, width: Double, height: Double) -> ScreenshotPixelRect {
        ScreenshotPixelRect(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: max(0, Int(width.rounded())),
            height: max(0, Int(height.rounded()))
        )
    }

    public static func resize(
        _ rect: ScreenshotPixelRect,
        handle: ScreenshotResizeHandle,
        to point: ScreenshotPixelPoint
    ) -> ScreenshotPixelRect {
        let rect = normalized(rect)
        var left = rect.x
        var top = rect.y
        var right = rect.x + rect.width
        var bottom = rect.y + rect.height
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())

        switch handle {
        case .northWest: left = x; top = y
        case .north: top = y
        case .northEast: right = x; top = y
        case .east: right = x
        case .southEast: right = x; bottom = y
        case .south: bottom = y
        case .southWest: left = x; bottom = y
        case .west: left = x
        }

        return .init(
            x: min(left, right),
            y: min(top, bottom),
            width: abs(right - left),
            height: abs(bottom - top)
        )
    }

    public static func hitTest(
        _ point: ScreenshotPixelPoint,
        element: ScreenshotElement,
        tolerance: Double,
        constrainedTo sourceBounds: ScreenshotPixelRect? = nil
    ) -> Bool {
        let tolerance = max(0, tolerance)
        let strokeTolerance = tolerance + max(0.5, element.appearance.lineWidth) / 2
        switch (element.kind, element.geometry) {
        case let (.arrow, .line(start, end)), let (.line, .line(start, end)):
            let control = lineControlPoint(start: start, end: end, curvature: element.appearance.curvature)
            let pathPoints = quadraticPoints(start: start, control: control, end: end)
            if hitPath(point, points: pathPoints, tolerance: strokeTolerance) {
                return true
            }
            return hitLineEnding(
                point,
                ending: element.appearance.startEnding,
                tip: start,
                other: control,
                appearance: element.appearance,
                tolerance: tolerance
            ) || hitLineEnding(
                point,
                ending: element.appearance.endEnding,
                tip: end,
                other: control,
                appearance: element.appearance,
                tolerance: tolerance
            )
        case let (.freehand, .path(points)):
            return hitPath(point, points: points, tolerance: strokeTolerance)
        case let (.highlight, .path(points)) where element.appearance.highlightMode == .freehand:
            return hitPath(point, points: points, tolerance: strokeTolerance)
        case let (.rectangle, .rect(rect)):
            return hitRectangle(
                point,
                rect: rect,
                threshold: strokeTolerance,
                filled: (element.appearance.fillColor?.alpha ?? 0) * element.appearance.fillOpacity > 0
            )
        case let (.ellipse, .rect(rect)):
            return hitEllipse(
                point,
                rect: rect,
                threshold: strokeTolerance,
                filled: (element.appearance.fillColor?.alpha ?? 0) * element.appearance.fillOpacity > 0
            )
        case let (.highlight, .rect(rect)) where element.appearance.highlightMode == .rectangle:
            return pointInRect(point, rect: rect, outset: tolerance)
        case let (.text, .rect(rect)):
            return pointInRect(point, rect: rect, outset: tolerance)
        case let (.blur, .rect(rect)), let (.pixelate, .rect(rect)),
             let (.spotlight, .rect(rect)), let (.redact, .rect(rect)):
            return element.appearance.effectShape == .ellipse
                ? hitEllipse(point, rect: rect, threshold: tolerance, filled: true)
                : pointInRect(point, rect: rect, outset: tolerance)
        case let (.counter, .counter(center)):
            guard case let .counter(value) = element.appearance.payload else { return false }
            return hypot(point.x - center.x, point.y - center.y) <= value.size / 2 + tolerance
        case (.step, .step):
            return stepHitKind(at: point, element: element, tolerance: tolerance) != nil
        case (.callout, .callout), (.callout, .calloutComposite):
            return ScreenshotCalloutResolvedLayout(element: element)?.hitKind(
                at: point,
                tolerance: max(tolerance, strokeTolerance)
            ) != nil
        case (.magnifier, .magnifier):
            let lens = sourceBounds.flatMap {
                ScreenshotMagnifierResolvedLayout(element: element, constrainedTo: $0)?.lensRect
            } ?? bounds(of: element)
            return hitEllipse(
                point,
                rect: lens,
                threshold: tolerance,
                filled: true
            )
        default:
            return false
        }
    }

    public static func hitResults(
        at point: ScreenshotPixelPoint,
        elements: [ScreenshotElement],
        tolerance: Double,
        constrainedTo sourceBounds: ScreenshotPixelRect? = nil
    ) -> [ScreenshotObjectHitResult] {
        elements.enumerated().reversed().compactMap { index, element in
            guard hitTest(
                point,
                element: element,
                tolerance: tolerance,
                constrainedTo: sourceBounds
            ) else { return nil }
            let kind: ScreenshotObjectHitKind = switch element.geometry {
            case .line, .path: .stroke
            case .callout, .calloutComposite:
                ScreenshotCalloutResolvedLayout(element: element)?.hitKind(
                    at: point,
                    tolerance: tolerance
                ) ?? .body
            case .counter: .body
            case .step:
                stepHitKind(at: point, element: element, tolerance: tolerance) ?? .body
            case .magnifier: .body
            case .rect: .body
            }
            return ScreenshotObjectHitResult(elementID: element.id, kind: kind, zIndex: index)
        }
    }

    private static func stepHitKind(
        at point: ScreenshotPixelPoint,
        element: ScreenshotElement,
        tolerance: Double
    ) -> ScreenshotObjectHitKind? {
        ScreenshotStepResolvedLayout(element: element)?.hitKind(
            at: point,
            tolerance: tolerance
        )
    }

    public static func hitTestHandle(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        tolerance: Double
    ) -> ScreenshotResizeHandle? {
        let rect = normalized(rect)
        let left = Double(rect.x)
        let top = Double(rect.y)
        let right = Double(rect.x + rect.width)
        let bottom = Double(rect.y + rect.height)
        let middleX = (left + right) / 2
        let middleY = (top + bottom) / 2
        let handles: [(ScreenshotResizeHandle, ScreenshotPixelPoint)] = [
            (.northWest, .init(x: left, y: top)),
            (.northEast, .init(x: right, y: top)),
            (.southEast, .init(x: right, y: bottom)),
            (.southWest, .init(x: left, y: bottom)),
            (.north, .init(x: middleX, y: top)),
            (.east, .init(x: right, y: middleY)),
            (.south, .init(x: middleX, y: bottom)),
            (.west, .init(x: left, y: middleY)),
        ]
        return handles.first {
            hypot(point.x - $0.1.x, point.y - $0.1.y) <= max(0, tolerance)
        }?.0
    }

    public static func clamp(
        _ geometry: ScreenshotElementGeometry,
        to bounds: ScreenshotPixelRect
    ) -> ScreenshotElementGeometry {
        switch geometry {
        case let .line(start, end):
            return .line(start: clamp(start, to: bounds), end: clamp(end, to: bounds))
        case let .rect(rect):
            return .rect(clamp(rect, to: bounds))
        case let .path(points):
            return .path(points.map { clamp($0, to: bounds) })
        case let .callout(body, pointer):
            return .callout(body: clamp(body, to: bounds), pointer: clamp(pointer, to: bounds))
        case let .calloutComposite(target, note):
            let clampedTarget: ScreenshotCalloutTarget = switch target {
            case let .point(point): .point(clamp(point, to: bounds))
            case let .ellipse(rect): .ellipse(clamp(rect, to: bounds))
            }
            return .calloutComposite(target: clampedTarget, note: clamp(note, to: bounds))
        case let .counter(center):
            return .counter(center: clamp(center, to: bounds))
        case let .step(badgeCenter, note):
            return .step(
                badgeCenter: clamp(badgeCenter, to: bounds),
                note: note.map { clamp($0, to: bounds) }
            )
        case let .magnifier(center):
            return .magnifier(center: clamp(center, to: bounds))
        }
    }

    public static func clamp(_ rect: ScreenshotPixelRect, to bounds: ScreenshotPixelRect) -> ScreenshotPixelRect {
        let bounds = normalized(bounds)
        let rect = normalized(rect)
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return .init(
            x: min(max(rect.x, bounds.x), bounds.x + bounds.width - width),
            y: min(max(rect.y, bounds.y), bounds.y + bounds.height - height),
            width: width,
            height: height
        )
    }

    public static func clamp(_ point: ScreenshotPixelPoint, to bounds: ScreenshotPixelRect) -> ScreenshotPixelPoint {
        let normalizedBounds = normalized(bounds)
        return .init(
            x: min(max(point.x, Double(normalizedBounds.x)), Double(normalizedBounds.x + normalizedBounds.width)),
            y: min(max(point.y, Double(normalizedBounds.y)), Double(normalizedBounds.y + normalizedBounds.height))
        )
    }

    public static func intersects(_ geometry: ScreenshotElementGeometry, rect: ScreenshotPixelRect) -> Bool {
        let lhs = bounds(of: geometry)
        let rhs = normalized(rect)
        let lhsRight = lhs.x + max(1, lhs.width)
        let lhsBottom = lhs.y + max(1, lhs.height)
        return lhs.x <= rhs.x + rhs.width
            && lhsRight >= rhs.x
            && lhs.y <= rhs.y + rhs.height
            && lhsBottom >= rhs.y
    }

    public static func intersects(_ element: ScreenshotElement, rect: ScreenshotPixelRect) -> Bool {
        let lhs = bounds(of: element)
        let rhs = normalized(rect)
        let lhsRight = lhs.x + max(1, lhs.width)
        let lhsBottom = lhs.y + max(1, lhs.height)
        return lhs.x <= rhs.x + rhs.width
            && lhsRight >= rhs.x
            && lhs.y <= rhs.y + rhs.height
            && lhsBottom >= rhs.y
    }

    private static func normalized(_ rect: ScreenshotPixelRect) -> ScreenshotPixelRect {
        .init(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private static func union(_ lhs: ScreenshotPixelRect, _ rhs: ScreenshotPixelRect) -> ScreenshotPixelRect {
        let lhs = normalized(lhs)
        let rhs = normalized(rhs)
        let left = min(lhs.x, rhs.x)
        let top = min(lhs.y, rhs.y)
        let right = max(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = max(lhs.y + lhs.height, rhs.y + rhs.height)
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func rect(containing points: [ScreenshotPixelPoint]) -> ScreenshotPixelRect {
        guard let first = points.first else { return .init(x: 0, y: 0, width: 0, height: 0) }
        let minX = points.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = points.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = points.dropFirst().reduce(first.x) { max($0, $1.x) }
        let maxY = points.dropFirst().reduce(first.y) { max($0, $1.y) }
        return .init(
            x: Int(floor(minX)),
            y: Int(floor(minY)),
            width: Int(ceil(maxX) - floor(minX)),
            height: Int(ceil(maxY) - floor(minY))
        )
    }

    private static func offset(_ point: ScreenshotPixelPoint, dx: Double, dy: Double) -> ScreenshotPixelPoint {
        .init(x: point.x + dx, y: point.y + dy)
    }

    private static func hitPath(
        _ point: ScreenshotPixelPoint,
        points: [ScreenshotPixelPoint],
        tolerance: Double
    ) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 {
            return hypot(point.x - first.x, point.y - first.y) <= tolerance
        }
        return zip(points, points.dropFirst()).contains {
            distance(from: point, toSegmentFrom: $0.0, to: $0.1) <= tolerance
        }
    }

    private static func hitRectangle(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        threshold: Double,
        filled: Bool
    ) -> Bool {
        guard pointInRect(point, rect: rect, outset: threshold) else { return false }
        if filled { return true }
        let rect = normalized(rect)
        let innerWidth = Double(rect.width) - threshold * 2
        let innerHeight = Double(rect.height) - threshold * 2
        guard innerWidth > 0, innerHeight > 0 else { return true }
        return !pointInRect(point, rect: rect, outset: -threshold)
    }

    private static func hitEllipse(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        threshold: Double,
        filled: Bool
    ) -> Bool {
        let rect = normalized(rect)
        let centerX = Double(rect.x) + Double(rect.width) / 2
        let centerY = Double(rect.y) + Double(rect.height) / 2
        let radiusX = Double(rect.width) / 2
        let radiusY = Double(rect.height) / 2
        let outerX = radiusX + threshold
        let outerY = radiusY + threshold
        guard ellipseValue(point, centerX: centerX, centerY: centerY, radiusX: outerX, radiusY: outerY) <= 1 else {
            return false
        }
        if filled { return true }
        let innerX = radiusX - threshold
        let innerY = radiusY - threshold
        guard innerX > 0, innerY > 0 else { return true }
        return ellipseValue(point, centerX: centerX, centerY: centerY, radiusX: innerX, radiusY: innerY) >= 1
    }

    private static func ellipseValue(
        _ point: ScreenshotPixelPoint,
        centerX: Double,
        centerY: Double,
        radiusX: Double,
        radiusY: Double
    ) -> Double {
        guard radiusX > 0, radiusY > 0 else { return .infinity }
        let x = (point.x - centerX) / radiusX
        let y = (point.y - centerY) / radiusY
        return x * x + y * y
    }

    private static func pointInRect(
        _ point: ScreenshotPixelPoint,
        rect: ScreenshotPixelRect,
        outset: Double
    ) -> Bool {
        let rect = normalized(rect)
        return point.x >= Double(rect.x) - outset
            && point.x <= Double(rect.x + rect.width) + outset
            && point.y >= Double(rect.y) - outset
            && point.y <= Double(rect.y + rect.height) + outset
    }

    private static func hitLineEnding(
        _ point: ScreenshotPixelPoint,
        ending: ScreenshotLineEnding,
        tip: ScreenshotPixelPoint,
        other: ScreenshotPixelPoint,
        appearance: ScreenshotElementAppearance,
        tolerance: Double
    ) -> Bool {
        guard ending != .none else { return false }
        if ending == .circle {
            let radius = max(3, appearance.lineWidth * 1.25) + tolerance
            return hypot(point.x - tip.x, point.y - tip.y) <= radius
        }
        let angle = atan2(tip.y - other.y, tip.x - other.x)
        let length = max(8, appearance.lineWidth * 4 * appearance.arrowHeadSize)
        let spread = Double.pi / 7
        let first = ScreenshotPixelPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        )
        let second = ScreenshotPixelPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        )
        let threshold = tolerance + max(0.5, appearance.lineWidth) / 2
        if hitPath(point, points: [first, tip, second], tolerance: threshold) {
            return true
        }
        return ending == .filledArrow && pointInTriangle(point, first, tip, second)
    }

    private static func nearestPoint(on rect: ScreenshotPixelRect, to point: ScreenshotPixelPoint) -> ScreenshotPixelPoint {
        let rect = normalized(rect)
        return .init(
            x: min(max(point.x, Double(rect.x)), Double(rect.x + rect.width)),
            y: min(max(point.y, Double(rect.y)), Double(rect.y + rect.height))
        )
    }

    private static func pointInTriangle(
        _ point: ScreenshotPixelPoint,
        _ first: ScreenshotPixelPoint,
        _ second: ScreenshotPixelPoint,
        _ third: ScreenshotPixelPoint
    ) -> Bool {
        func sign(_ lhs: ScreenshotPixelPoint, _ a: ScreenshotPixelPoint, _ b: ScreenshotPixelPoint) -> Double {
            (lhs.x - b.x) * (a.y - b.y) - (a.x - b.x) * (lhs.y - b.y)
        }
        let firstSign = sign(point, first, second)
        let secondSign = sign(point, second, third)
        let thirdSign = sign(point, third, first)
        let hasNegative = firstSign < 0 || secondSign < 0 || thirdSign < 0
        let hasPositive = firstSign > 0 || secondSign > 0 || thirdSign > 0
        return !(hasNegative && hasPositive)
    }

    private static func distance(
        from point: ScreenshotPixelPoint,
        toSegmentFrom start: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, projection))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    public static func lineControlPoint(
        start: ScreenshotPixelPoint,
        end: ScreenshotPixelPoint,
        curvature: Double
    ) -> ScreenshotPixelPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return start }
        let offset = length * curvature * 0.5
        return .init(
            x: (start.x + end.x) / 2 - dy / length * offset,
            y: (start.y + end.y) / 2 + dx / length * offset
        )
    }

    public static func lineCurvature(
        start: ScreenshotPixelPoint,
        end: ScreenshotPixelPoint,
        control: ScreenshotPixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return 0 }
        let midpoint = ScreenshotPixelPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let normalX = -dy / length
        let normalY = dx / length
        let offset = (control.x - midpoint.x) * normalX + (control.y - midpoint.y) * normalY
        return min(2, max(-2, offset * 2 / length))
    }

    private static func quadraticPoints(
        start: ScreenshotPixelPoint,
        control: ScreenshotPixelPoint,
        end: ScreenshotPixelPoint
    ) -> [ScreenshotPixelPoint] {
        (0...16).map { index in
            let t = Double(index) / 16
            let inverse = 1 - t
            return .init(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
    }
}
