import AppKit
import BlocksScreenshotCore
import CoreText
import SwiftUI

enum ScreenshotCanvasGestureDisposition: Equatable {
    case handled
    case beginTextCreation
}

enum ScreenshotEditorAccessibilityTarget: Equatable {
    case crop
    case element(UUID)
    case lineStart(UUID)
    case lineEnd(UUID)
    case resizeHandle(UUID, ScreenshotResizeHandle)
    case stepComponent(UUID, ScreenshotStepComponent)
    case stepResizeHandle(UUID, ScreenshotStepComponent, ScreenshotResizeHandle)
    case calloutComponent(UUID, ScreenshotCalloutComponent)
    case calloutResizeHandle(UUID, ScreenshotCalloutComponent, ScreenshotResizeHandle)
    case magnifierResizeHandle(UUID, ScreenshotResizeHandle)
}

struct ScreenshotEditorAccessibilityItem: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let sourceRect: ScreenshotPixelRect
    let target: ScreenshotEditorAccessibilityTarget
}

struct ScreenshotEditorAccessibilityModel: Equatable {
    let items: [ScreenshotEditorAccessibilityItem]

    init(
        cropRect: ScreenshotPixelRect,
        elements: [ScreenshotElement],
        selectedElementID: UUID?,
        selectedStepComponent: ScreenshotStepComponent? = nil,
        selectedCalloutComponent: ScreenshotCalloutComponent? = nil,
        sourceBounds: ScreenshotPixelRect? = nil
    ) {
        var result = [ScreenshotEditorAccessibilityItem(
            id: "crop",
            label: L10n.string("screenshot.editor.accessibility.crop"),
            value: Self.value(for: cropRect),
            sourceRect: cropRect,
            target: .crop
        )]
        var selectedHandles: [ScreenshotEditorAccessibilityItem] = []
        for (index, element) in elements.enumerated() {
            // A tiled watermark covers the crop by design, so exposing it as a
            // canvas object would create one giant hit target. It is selected
            // and edited through the toolbar and status strip instead.
            guard element.kind != .watermark else { continue }
            let bounds = ScreenshotMagnifierResolvedLayout(
                element: element,
                constrainedTo: cropRect
            )?.lensRect ?? ScreenshotGeometry.bounds(of: element)
            let type = L10n.string("screenshot.editor.tool.\(element.kind.rawValue)")
            result.append(.init(
                id: "element-\(element.id.uuidString)",
                label: L10n.format("screenshot.editor.accessibility.element", index + 1, type),
                value: Self.value(for: bounds),
                sourceRect: bounds,
                target: .element(element.id)
            ))
            guard element.id == selectedElementID else { continue }
            switch element.geometry {
            case let .line(start, end):
                selectedHandles.append(Self.lineHandle(element.id, point: start, position: "lineStart", target: .lineStart(element.id)))
                selectedHandles.append(Self.lineHandle(element.id, point: end, position: "lineEnd", target: .lineEnd(element.id)))
            case let .rect(rect):
                for handle in ScreenshotResizeHandle.allCases {
                    let point = Self.point(for: handle, in: rect)
                    selectedHandles.append(Self.lineHandle(
                        element.id,
                        point: point,
                        position: handle.rawValue,
                        target: .resizeHandle(element.id, handle)
                    ))
                }
            case .callout, .calloutComposite:
                guard let layout = ScreenshotCalloutResolvedLayout(element: element) else { break }
                if let targetRect = layout.targetRect {
                    result.append(.init(
                        id: "callout-target-\(element.id.uuidString)",
                        label: L10n.string("screenshot.editor.accessibility.calloutTarget"),
                        value: Self.value(for: targetRect),
                        sourceRect: targetRect,
                        target: .calloutComponent(element.id, .target)
                    ))
                }
                result.append(.init(
                    id: "callout-connector-\(element.id.uuidString)",
                    label: L10n.string("screenshot.editor.accessibility.calloutConnector"),
                    value: Self.value(for: layout.connectorBounds),
                    sourceRect: layout.connectorBounds,
                    target: .calloutComponent(element.id, .connector)
                ))
                result.append(.init(
                    id: "callout-note-\(element.id.uuidString)",
                    label: L10n.string("screenshot.editor.accessibility.calloutNote"),
                    value: Self.value(for: layout.noteRect),
                    sourceRect: layout.noteRect,
                    target: .calloutComponent(element.id, .note)
                ))
                let component = selectedCalloutComponent
                    ?? (layout.targetRect == nil ? .connector : .target)
                let componentRect: ScreenshotPixelRect
                switch component {
                case .target:
                    componentRect = layout.targetRect ?? layout.connectorBounds
                case .connector:
                    componentRect = layout.connectorBounds
                case .note:
                    componentRect = layout.noteRect
                }
                if component == .connector {
                    selectedHandles.append(Self.lineHandle(
                        element.id,
                        point: layout.connectorControlPoint,
                        position: "curve",
                        componentID: component.rawValue,
                        componentLabel: L10n.string("screenshot.editor.accessibility.calloutConnector"),
                        target: .calloutComponent(element.id, .connector)
                    ))
                } else {
                    for handle in ScreenshotResizeHandle.allCases {
                        let point = Self.point(for: handle, in: componentRect)
                    selectedHandles.append(Self.lineHandle(
                        element.id,
                        point: point,
                        position: handle.rawValue,
                            componentID: component.rawValue,
                            componentLabel: component == .target
                                ? L10n.string("screenshot.editor.accessibility.calloutTarget")
                                : L10n.string("screenshot.editor.accessibility.calloutNote"),
                            target: .calloutResizeHandle(element.id, component, handle)
                    ))
                }
                }
            case .magnifier:
                let lens = ScreenshotMagnifierResolvedLayout(
                    element: element,
                    constrainedTo: cropRect
                )?.lensRect ?? ScreenshotGeometry.bounds(of: element)
                for handle in ScreenshotResizeHandle.allCases where handle.isCorner {
                    let point = Self.point(for: handle, in: lens)
                    selectedHandles.append(Self.lineHandle(
                        element.id,
                        point: point,
                        position: handle.rawValue,
                        componentID: "magnifier",
                        componentLabel: L10n.string("screenshot.editor.accessibility.magnifierLens"),
                        target: .magnifierResizeHandle(element.id, handle)
                    ))
                }
            case .step:
                guard let layout = ScreenshotStepResolvedLayout(element: element) else { break }
                result.append(.init(
                    id: "step-badge-\(element.id.uuidString)",
                    label: L10n.string("screenshot.editor.accessibility.stepBadge"),
                    value: Self.value(for: layout.badgeRect),
                    sourceRect: layout.badgeRect,
                    target: .stepComponent(element.id, .badge)
                ))
                if let connectorBounds = layout.connectorBounds {
                    result.append(.init(
                        id: "step-connector-\(element.id.uuidString)",
                        label: L10n.string("screenshot.editor.accessibility.stepConnector"),
                        value: Self.value(for: connectorBounds),
                        sourceRect: connectorBounds,
                        target: .stepComponent(element.id, .connector)
                    ))
                }
                if let note = layout.noteRect {
                    result.append(.init(
                        id: "step-note-\(element.id.uuidString)",
                        label: L10n.string("screenshot.editor.accessibility.stepNote"),
                        value: Self.value(for: note),
                        sourceRect: note,
                        target: .stepComponent(element.id, .note)
                    ))
                }
                let component = selectedStepComponent ?? .badge
                switch component {
                case .connector:
                    if let point = layout.connectorControlPoint {
                        selectedHandles.append(Self.lineHandle(
                            element.id,
                            point: point,
                            position: "curve",
                            componentID: component.rawValue,
                            componentLabel: L10n.string("screenshot.editor.accessibility.stepConnector"),
                            target: .stepComponent(element.id, .connector)
                        ))
                    }
                case .badge, .note:
                    let componentRect = component == .note
                        ? (layout.noteRect ?? layout.badgeRect)
                        : layout.badgeRect
                    for handle in ScreenshotResizeHandle.allCases where component == .note || handle.isCorner {
                        let point = Self.point(for: handle, in: componentRect)
                        selectedHandles.append(Self.lineHandle(
                            element.id,
                            point: point,
                            position: handle.rawValue,
                            componentID: component.rawValue,
                            componentLabel: L10n.string(
                                component == .badge
                                    ? "screenshot.editor.accessibility.stepBadge"
                                    : "screenshot.editor.accessibility.stepNote"
                            ),
                            target: .stepResizeHandle(element.id, component, handle)
                        ))
                    }
                }
            case .path, .counter:
                break
            }
        }
        result.append(contentsOf: selectedHandles)
        items = result
    }

    private static func lineHandle(
        _ elementID: UUID,
        point: ScreenshotPixelPoint,
        position: String,
        componentID: String? = nil,
        componentLabel: String? = nil,
        target: ScreenshotEditorAccessibilityTarget
    ) -> ScreenshotEditorAccessibilityItem {
        let rect = ScreenshotPixelRect(
            x: Int(point.x.rounded()),
            y: Int(point.y.rounded()),
            width: 1,
            height: 1
        )
        let handleLabel = L10n.string("screenshot.editor.accessibility.handle.\(position)")
        return .init(
            id: "handle-\(elementID.uuidString)-\(componentID.map { "\($0)-" } ?? "")\(position)",
            label: componentLabel.map {
                L10n.format("screenshot.editor.accessibility.componentHandle", $0, handleLabel)
            } ?? handleLabel,
            value: value(for: rect),
            sourceRect: rect,
            target: target
        )
    }

    private static func point(
        for handle: ScreenshotResizeHandle,
        in rect: ScreenshotPixelRect
    ) -> ScreenshotPixelPoint {
        let minX = Double(rect.x)
        let midX = Double(rect.x) + Double(rect.width) / 2
        let maxX = Double(rect.x + rect.width)
        let minY = Double(rect.y)
        let midY = Double(rect.y) + Double(rect.height) / 2
        let maxY = Double(rect.y + rect.height)
        return switch handle {
        case .northWest: .init(x: minX, y: minY)
        case .north: .init(x: midX, y: minY)
        case .northEast: .init(x: maxX, y: minY)
        case .east: .init(x: maxX, y: midY)
        case .southEast: .init(x: maxX, y: maxY)
        case .south: .init(x: midX, y: maxY)
        case .southWest: .init(x: minX, y: maxY)
        case .west: .init(x: minX, y: midY)
        }
    }

    private static func value(for rect: ScreenshotPixelRect) -> String {
        "x \(rect.x), y \(rect.y), \(rect.width) × \(rect.height)"
    }
}

struct ScreenshotInlineTextLayoutPolicy: Equatable {
    let widthTracksTextView: Bool
    let containerWidth: CGFloat

    static func make(
        sizing: ScreenshotTextBoxSizing,
        maximumViewWidth: CGFloat,
        fixedViewWidth: CGFloat,
        horizontalInset: CGFloat
    ) -> ScreenshotInlineTextLayoutPolicy {
        let availableWidth: CGFloat
        switch sizing {
        case .auto:
            availableWidth = maximumViewWidth
        case .fixedWidth, .fixedBox:
            availableWidth = fixedViewWidth
        }
        return ScreenshotInlineTextLayoutPolicy(
            widthTracksTextView: sizing != .auto,
            containerWidth: max(1, availableWidth - horizontalInset * 2)
        )
    }
}

struct ScreenshotInlineTextAttributes {
    let foregroundColor: NSColor
    let backgroundColor: NSColor
    let drawsBackground: Bool
    let attributes: [NSAttributedString.Key: Any]

    init(appearance: ScreenshotElementAppearance, sourceUnitsPerViewPoint: Double) {
        let layout = ScreenshotTextLayout(appearance: appearance)
        let metrics = layout.viewMetrics(sourceUnitsPerViewPoint: sourceUnitsPerViewPoint)
        foregroundColor = ScreenshotResolvedColor(
            appearance.strokeColor,
            opacity: appearance.opacity
        ).nsColor
        backgroundColor = appearance.textBackgroundColor.map {
            ScreenshotResolvedColor($0, opacity: appearance.opacity).nsColor
        } ?? .clear
        drawsBackground = layout.backgroundColor != nil

        let font = NSFont(name: layout.fontName, size: CGFloat(metrics.fontSize))
            ?? .systemFont(ofSize: CGFloat(metrics.fontSize), weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = layout.alignment.nsAlignment
        paragraphStyle.minimumLineHeight = CGFloat(metrics.lineHeight)
        paragraphStyle.maximumLineHeight = CGFloat(metrics.lineHeight)
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineBreakMode = .byWordWrapping

        var resolved: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .kern: CGFloat(metrics.characterSpacing),
            .paragraphStyle: paragraphStyle,
        ]
        if layout.strokeWidth != 0 {
            resolved[.strokeWidth] = CGFloat(layout.strokeWidth)
            resolved[.strokeColor] = foregroundColor
        }
        attributes = resolved
    }

    func mergingMarkedTextAttributes(
        _ existing: [NSAttributedString.Key: Any]?
    ) -> [NSAttributedString.Key: Any] {
        var result = existing ?? [:]
        for (key, value) in attributes {
            result[key] = value
        }
        return result
    }
}

enum ScreenshotInlineMarkedTextResolver {
    static func resolve(
        _ markedText: Any,
        applying attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let resolved: NSMutableAttributedString
        if let attributed = markedText as? NSAttributedString {
            resolved = NSMutableAttributedString(attributedString: attributed)
        } else {
            resolved = NSMutableAttributedString(string: String(describing: markedText))
        }
        guard resolved.length > 0 else { return resolved }
        resolved.addAttributes(attributes, range: NSRange(location: 0, length: resolved.length))
        return resolved
    }
}

struct ScreenshotCanvasSnapshot: Equatable {
    let imageIdentity: ObjectIdentifier
    let visibleSourceRect: ScreenshotPixelRect
    let cropRect: ScreenshotPixelRect
    let selectedTool: ScreenshotEditorTool
    let textStyle: ScreenshotElementAppearance
    let zoomScale: CGFloat
    let panOffset: CGSize
    let allowsViewportNavigation: Bool
    let prefersInitialFitWidth: Bool
    let selectedElement: ScreenshotElement?
    let selectedStepComponent: ScreenshotStepComponent?
    let selectedCalloutComponent: ScreenshotCalloutComponent?
    let sceneElements: [ScreenshotElement]
    let allowsObjectEditing: Bool
    let isInteractionEnabled: Bool
    let draftElement: ScreenshotElement?
    let draftCropRect: ScreenshotPixelRect?
    let manualOCRRegion: ScreenshotPixelRect?
    let showsCropOverlay: Bool
    let isRoundedOutput: Bool
}

enum ScreenshotCanvasInvalidationPolicy {
    enum Invalidation: Equatable {
        case none
        case full
        case sourceRect(CGRect)
    }

    static func invalidation(
        previous: ScreenshotCanvasSnapshot?,
        next: ScreenshotCanvasSnapshot
    ) -> Invalidation {
        guard let previous else { return .full }
        guard previous != next else { return .none }

        if previous.imageIdentity != next.imageIdentity
            || previous.visibleSourceRect != next.visibleSourceRect
            || previous.cropRect != next.cropRect
            || previous.zoomScale != next.zoomScale
            || previous.panOffset != next.panOffset
            || previous.allowsViewportNavigation != next.allowsViewportNavigation
            || previous.prefersInitialFitWidth != next.prefersInitialFitWidth
            || previous.draftCropRect != next.draftCropRect
            || previous.showsCropOverlay != next.showsCropOverlay
            || previous.isRoundedOutput != next.isRoundedOutput {
            return .full
        }

        let dirtyRects = changedElementBounds(previous: previous, next: next)
            + [
                previous.selectedElement.map { ScreenshotGeometry.bounds(of: $0).cgRect },
                next.selectedElement.map { ScreenshotGeometry.bounds(of: $0).cgRect },
                previous.draftElement.map { ScreenshotGeometry.bounds(of: $0).cgRect },
                next.draftElement.map { ScreenshotGeometry.bounds(of: $0).cgRect },
                previous.manualOCRRegion?.cgRect,
                next.manualOCRRegion?.cgRect,
            ].compactMap { $0 }
        let dirtyRect = dirtyRects.reduce(CGRect.null) { $0.union($1) }
        return dirtyRect.isNull ? .none : .sourceRect(dirtyRect)
    }

    static func shouldRedraw(
        previous: ScreenshotCanvasSnapshot?,
        next: ScreenshotCanvasSnapshot
    ) -> Bool {
        invalidation(previous: previous, next: next) != .none
    }

    private static func changedElementBounds(
        previous: ScreenshotCanvasSnapshot,
        next: ScreenshotCanvasSnapshot
    ) -> [CGRect] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.sceneElements.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: next.sceneElements.map { ($0.id, $0) })
        let changedIDs = Set(previousByID.keys).union(nextByID.keys).filter {
            previousByID[$0] != nextByID[$0]
        }
        return changedIDs.flatMap { id in
            [previousByID[id], nextByID[id]].compactMap { element in
                element.map { ScreenshotGeometry.bounds(of: $0).cgRect }
            }
        }
    }
}

enum ScreenshotTextDragPreviewGeometry {
    static func sourceRect(
        start: CGPoint,
        current: CGPoint,
        lineHeight: CGFloat,
        minimumDrag: CGFloat
    ) -> CGRect? {
        let width = abs(current.x - start.x)
        guard width >= minimumDrag else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: width,
            height: lineHeight
        )
    }
}

struct ScreenshotEditorCanvas: NSViewRepresentable {
    let image: NSImage
    let visibleSourceRect: ScreenshotPixelRect
    let cropRect: ScreenshotPixelRect
    let selectedTool: ScreenshotEditorTool
    let textStyle: ScreenshotElementAppearance
    let zoomScale: CGFloat
    let panOffset: CGSize
    let allowsViewportNavigation: Bool
    let prefersInitialFitWidth: Bool
    let selectedElement: ScreenshotElement?
    let selectedStepComponent: ScreenshotStepComponent?
    let selectedCalloutComponent: ScreenshotCalloutComponent?
    let sceneElements: [ScreenshotElement]
    let allowsObjectEditing: Bool
    let isInteractionEnabled: Bool
    let draftElement: ScreenshotElement?
    let draftCropRect: ScreenshotPixelRect?
    let manualOCRRegion: ScreenshotPixelRect?
    let showsCropOverlay: Bool
    let isRoundedOutput: Bool
    let onViewportChanged: (CGFloat, CGSize) -> Void
    let onBegin: (CGPoint, Double, NSEvent.ModifierFlags) -> ScreenshotCanvasGestureDisposition
    let onUpdate: (CGPoint, [CGPoint], NSEvent.ModifierFlags) -> Void
    let onEnd: (CGPoint, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSelectTool: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onNudge: (Double, Double) -> Void
    let onSelectElement: (UUID) -> Void
    let onSelectStepComponent: (UUID, ScreenshotStepComponent) -> Void
    let onCycleStepComponent: (Bool) -> Bool
    let onSelectCalloutComponent: (UUID, ScreenshotCalloutComponent) -> Void
    let onCycleCalloutComponent: (Bool) -> Bool
    let onRequestTextEdit: (UUID) -> Void
    let onTextEditingEnded: () -> Void
    let onAdjustAccessibilityTarget: (ScreenshotEditorAccessibilityTarget, Double, Double) -> Void
    let onSelectCrop: () -> Void
    let onResetCurvature: () -> Void
    let curvatureAnchorPulse: Int
    let reduceMotion: Bool
    let onTextCommit: (String, CGRect, UUID?, ScreenshotTextBoxSizing) -> Void
    let textCommitRequestID: Int
    let onTextCommitRequestHandled: () -> Void
    let inlineTextEditRequestID: Int
    let inlineTextEditElementID: UUID?
    let onFirstFrameRendered: () -> Void

    func makeNSView(context: Context) -> ScreenshotEditorCanvasView { ScreenshotEditorCanvasView() }

    func updateNSView(_ view: ScreenshotEditorCanvasView, context: Context) {
        view.onFirstFrameRendered = onFirstFrameRendered
        let snapshot = ScreenshotCanvasSnapshot(
            imageIdentity: ObjectIdentifier(image),
            visibleSourceRect: visibleSourceRect,
            cropRect: cropRect,
            selectedTool: selectedTool,
            textStyle: textStyle,
            zoomScale: zoomScale,
            panOffset: panOffset,
            allowsViewportNavigation: allowsViewportNavigation,
            prefersInitialFitWidth: prefersInitialFitWidth,
            selectedElement: selectedElement,
            selectedStepComponent: selectedStepComponent,
            selectedCalloutComponent: selectedCalloutComponent,
            sceneElements: sceneElements,
            allowsObjectEditing: allowsObjectEditing,
            isInteractionEnabled: isInteractionEnabled,
            draftElement: draftElement,
            draftCropRect: draftCropRect,
            manualOCRRegion: manualOCRRegion,
            showsCropOverlay: showsCropOverlay,
            isRoundedOutput: isRoundedOutput
        )
        let previousSnapshot = view.canvasSnapshot
        let snapshotChanged = previousSnapshot != snapshot
        let invalidation = ScreenshotCanvasInvalidationPolicy.invalidation(
            previous: previousSnapshot,
            next: snapshot
        )
        if snapshotChanged {
            view.apply(snapshot: snapshot, image: image)
        }
        view.onViewportChanged = onViewportChanged
        view.onBegin = onBegin
        view.onUpdate = onUpdate
        view.onEnd = onEnd
        view.onCancel = onCancel
        view.onDelete = onDelete
        view.onSelectTool = onSelectTool
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.onNudge = onNudge
        view.onSelectElement = onSelectElement
        view.onSelectStepComponent = onSelectStepComponent
        view.onCycleStepComponent = onCycleStepComponent
        view.onSelectCalloutComponent = onSelectCalloutComponent
        view.onCycleCalloutComponent = onCycleCalloutComponent
        view.onRequestTextEdit = onRequestTextEdit
        view.onTextEditingEnded = onTextEditingEnded
        view.onAdjustAccessibilityTarget = onAdjustAccessibilityTarget
        view.onSelectCrop = onSelectCrop
        view.onResetCurvature = onResetCurvature
        view.reduceMotion = reduceMotion
        if view.curvatureAnchorPulse != curvatureAnchorPulse {
            view.curvatureAnchorPulse = curvatureAnchorPulse
            view.pulseCurvatureAnchor()
        }
        view.onTextCommit = onTextCommit
        view.onTextCommitRequestHandled = onTextCommitRequestHandled
        if view.lastTextCommitRequestID != textCommitRequestID {
            view.lastTextCommitRequestID = textCommitRequestID
            view.commitInlineTextIfNeeded()
            DispatchQueue.main.async { [weak view] in
                view?.onTextCommitRequestHandled?()
            }
        }
        if view.lastInlineTextEditRequestID != inlineTextEditRequestID {
            view.lastInlineTextEditRequestID = inlineTextEditRequestID
            DispatchQueue.main.async { [weak view] in
                view?.beginInlineTextEditing(for: inlineTextEditElementID)
            }
        }
        if previousSnapshot?.textStyle != snapshot.textStyle {
            view.updateActiveTextStyle()
        }
        switch invalidation {
        case .none:
            break
        case .full:
            view.needsDisplay = true
        case let .sourceRect(sourceRect):
            view.invalidate(sourceRect: sourceRect)
        }
    }
}

final class ScreenshotEditorCanvasView: NSView, NSTextViewDelegate {
    fileprivate private(set) var canvasSnapshot: ScreenshotCanvasSnapshot?
    var image: NSImage?
    var visibleSourceRect = ScreenshotPixelRect(x: 0, y: 0, width: 1, height: 1)
    var cropRect = ScreenshotPixelRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { invalidateAccessibilityModel() }
    }
    var selectedTool: ScreenshotEditorTool = .select
    var textStyle = ScreenshotElementAppearance()
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var allowsViewportNavigation = true {
        didSet {
            guard !allowsViewportNavigation else { return }
            zoomScale = 1
            panOffset = .zero
        }
    }
    var prefersInitialFitWidth = false {
        didSet {
            if !prefersInitialFitWidth { didApplyInitialFitWidth = false }
        }
    }
    var selectedElement: ScreenshotElement? {
        didSet { invalidateAccessibilityModel() }
    }
    var selectedStepComponent: ScreenshotStepComponent? {
        didSet {
            invalidateAccessibilityModel()
            guard selectedStepComponent != oldValue, selectedStepComponent != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.focusSelectedStepComponentForAccessibility()
            }
        }
    }
    var selectedCalloutComponent: ScreenshotCalloutComponent? {
        didSet { invalidateAccessibilityModel() }
    }
    var sceneElements: [ScreenshotElement] = [] {
        didSet { invalidateAccessibilityModel() }
    }
    var allowsObjectEditing = true {
        didSet {
            guard allowsObjectEditing != oldValue else { return }
            if !allowsObjectEditing {
                updateHoveredElement(nil)
            }
        }
    }
    var isInteractionEnabled = true
    var draftElement: ScreenshotElement?
    var draftCropRect: ScreenshotPixelRect?
    var manualOCRRegion: ScreenshotPixelRect?
    var showsCropOverlay = false
    var isRoundedOutput = false
    var cropRectForDrawing: ScreenshotPixelRect { draftCropRect ?? cropRect }
    var onViewportChanged: ((CGFloat, CGSize) -> Void)?
    var onBegin: ((CGPoint, Double, NSEvent.ModifierFlags) -> ScreenshotCanvasGestureDisposition)?
    var onUpdate: ((CGPoint, [CGPoint], NSEvent.ModifierFlags) -> Void)?
    var onEnd: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectTool: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onNudge: ((Double, Double) -> Void)?
    var onSelectElement: ((UUID) -> Void)?
    var onSelectStepComponent: ((UUID, ScreenshotStepComponent) -> Void)?
    var onCycleStepComponent: ((Bool) -> Bool)?
    var onSelectCalloutComponent: ((UUID, ScreenshotCalloutComponent) -> Void)?
    var onCycleCalloutComponent: ((Bool) -> Bool)?
    var onRequestTextEdit: ((UUID) -> Void)?
    var onTextEditingEnded: (() -> Void)?
    var onAdjustAccessibilityTarget: ((ScreenshotEditorAccessibilityTarget, Double, Double) -> Void)?
    var onSelectCrop: (() -> Void)?
    var onResetCurvature: (() -> Void)?
    var onTextCommit: ((String, CGRect, UUID?, ScreenshotTextBoxSizing) -> Void)?
    var onTextCommitRequestHandled: (() -> Void)?
    var onFirstFrameRendered: (() -> Void)?
    var lastTextCommitRequestID = 0
    var lastInlineTextEditRequestID = 0
    var activeInlineTextContainerInset: NSSize? { textEditor?.textContainerInset }
    var activeInlineTextString: String? { textEditor?.string }
    var isInlineTextEditorFirstResponder: Bool {
        guard let textEditor else { return false }
        return window?.firstResponder === textEditor
    }
    var curvatureAnchorPulse = 0
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if reduceMotion {
                curvatureAnchorHighlightUntil = .distantPast
                curvatureAnchorPulseTask?.cancel()
                curvatureAnchorPulseTask = nil
            }
            needsDisplay = true
        }
    }

    private var dragStart: CGPoint?
    private var dragPoints: [CGPoint] = []
    private var textDragCurrent: CGPoint?
    private var isCreatingInlineText = false
    private var textEditor: ScreenshotInlineTextView?
    private let inlineTextFocusCoordinator = ScreenshotFocusRequestCoordinator()
    private var inlineTextFocusRequestID = 0
    private var editingTextElementID: UUID?
    private var editingTextSizing: ScreenshotTextBoxSizing = .auto
    private var hoveredElementID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    private var accessibilityElementCache: [String: NSAccessibilityElement] = [:]
    private var accessibilityFocusIndex = -1
    private var didApplyInitialFitWidth = false
    private var curvatureAnchorHighlightUntil = Date.distantPast
    private var curvatureAnchorPulseTask: Task<Void, Never>?
    private var didRequestInitialFocus = false
    private var didReportFirstFrame = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate func apply(snapshot: ScreenshotCanvasSnapshot, image: NSImage) {
        let previous = canvasSnapshot
        canvasSnapshot = snapshot
        if previous?.imageIdentity != snapshot.imageIdentity { self.image = image }
        if previous?.visibleSourceRect != snapshot.visibleSourceRect {
            visibleSourceRect = snapshot.visibleSourceRect
        }
        if previous?.cropRect != snapshot.cropRect { cropRect = snapshot.cropRect }
        if previous?.selectedTool != snapshot.selectedTool { selectedTool = snapshot.selectedTool }
        if previous?.textStyle != snapshot.textStyle { textStyle = snapshot.textStyle }
        if previous?.zoomScale != snapshot.zoomScale { zoomScale = snapshot.zoomScale }
        if previous?.panOffset != snapshot.panOffset { panOffset = snapshot.panOffset }
        if previous?.allowsViewportNavigation != snapshot.allowsViewportNavigation {
            allowsViewportNavigation = snapshot.allowsViewportNavigation
        }
        if previous?.prefersInitialFitWidth != snapshot.prefersInitialFitWidth {
            prefersInitialFitWidth = snapshot.prefersInitialFitWidth
        }
        if previous?.selectedElement != snapshot.selectedElement {
            selectedElement = snapshot.selectedElement
        }
        if previous?.selectedStepComponent != snapshot.selectedStepComponent {
            selectedStepComponent = snapshot.selectedStepComponent
        }
        if previous?.selectedCalloutComponent != snapshot.selectedCalloutComponent {
            selectedCalloutComponent = snapshot.selectedCalloutComponent
        }
        if previous?.sceneElements != snapshot.sceneElements { sceneElements = snapshot.sceneElements }
        if previous?.allowsObjectEditing != snapshot.allowsObjectEditing {
            allowsObjectEditing = snapshot.allowsObjectEditing
        }
        if previous?.isInteractionEnabled != snapshot.isInteractionEnabled {
            isInteractionEnabled = snapshot.isInteractionEnabled
        }
        if previous?.draftElement != snapshot.draftElement { draftElement = snapshot.draftElement }
        if previous?.draftCropRect != snapshot.draftCropRect {
            draftCropRect = snapshot.draftCropRect
        }
        if previous?.manualOCRRegion != snapshot.manualOCRRegion {
            manualOCRRegion = snapshot.manualOCRRegion
        }
        if previous?.showsCropOverlay != snapshot.showsCropOverlay {
            showsCropOverlay = snapshot.showsCropOverlay
        }
        if previous?.isRoundedOutput != snapshot.isRoundedOutput {
            isRoundedOutput = snapshot.isRoundedOutput
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        window.initialFirstResponder = self
    }

    override func draw(_ dirtyRect: NSRect) {
        drawEditorBackdrop(in: bounds)
        guard let image else { return }
        let imageRect = imageRect(for: image.size)
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        drawEmptyAnnotationPlaceholders()
        drawTextDragPreview()
        if let draftElement { drawDraft(draftElement, in: imageRect) }
        drawCrop(in: imageRect)
        drawManualOCRRegion()
        drawHoveredObject(in: imageRect)
        drawSelection(in: imageRect)
        reportFirstFrameIfNeeded()
    }

    private func reportFirstFrameIfNeeded() {
        guard !didReportFirstFrame,
              let callback = onFirstFrameRendered else { return }
        didReportFirstFrame = true
        DispatchQueue.main.async {
            callback()
        }
    }

    override func layout() {
        super.layout()
        applyInitialFitWidthIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard isInsideToolCursorRegion(local) else {
            updateHoveredElement(nil)
            NSCursor.arrow.set()
            return
        }
        guard allowsObjectEditing else {
            updateHoveredElement(nil)
            ScreenshotToolCursorProvider.cursor(for: selectedTool).set()
            return
        }
        let location = sourcePoint(from: local)
        let point = ScreenshotPixelPoint(x: location.x.rounded(), y: location.y.rounded())
        if let cropHandle = ScreenshotGeometry.hitTestHandle(
            point,
            rect: cropRectForDrawing,
            tolerance: max(8, sourceUnitsPerViewPoint * 11)
        ) {
            updateHoveredElement(nil)
            ScreenshotToolCursorProvider.cursor(for: cropHandle).set()
            return
        }
        let hit = ScreenshotGeometry.hitResults(
            at: point,
            elements: sceneElements,
            tolerance: max(4, sourceUnitsPerViewPoint * 5),
            constrainedTo: cropRectForDrawing
        ).first
        updateHoveredElement(hit?.elementID)
        guard let hovered = sceneElements.first(where: { $0.id == hit?.elementID }) else {
            ScreenshotToolCursorProvider.cursor(for: selectedTool).set()
            return
        }
        switch hovered.kind {
        case .text, .callout:
            NSCursor.iBeam.set()
        case .step:
            NSCursor.openHand.set()
        default:
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredElement(nil)
        NSCursor.arrow.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            updateHoveredElement(nil)
            NSCursor.arrow.set()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateHoveredElement(_ elementID: UUID?) {
        guard hoveredElementID != elementID else { return }
        let previousID = hoveredElementID
        hoveredElementID = elementID
        let dirtyRects = [previousID, elementID].compactMap { id -> CGRect? in
            guard let id,
                  let element = sceneElements.first(where: { $0.id == id }) else { return nil }
            return viewRect(from: ScreenshotGeometry.bounds(of: element).cgRect)
                .insetBy(dx: -5, dy: -5)
        }
        let dirtyRect = dirtyRects.reduce(CGRect.null) { $0.union($1) }
        guard !dirtyRect.isNull else { return }
        setNeedsDisplay(dirtyRect)
    }

    private func isInsideToolCursorRegion(_ point: CGPoint) -> Bool {
        guard let image else { return false }
        let sourceImageFrame = imageRect(for: image.size)
        guard sourceImageFrame.contains(point) else { return false }
        return viewRect(from: cropRectForDrawing.cgRect)
            .insetBy(dx: -11, dy: -11)
            .contains(point)
    }

    private func drawManualOCRRegion() {
        guard let manualOCRRegion else { return }
        let rect = viewRect(from: manualOCRRegion.cgRect).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let local = convert(event.locationInWindow, from: nil)
        let point = sourcePoint(from: local)
        if event.clickCount == 2,
           isCurvatureControlPoint(point) {
            window?.makeFirstResponder(self)
            onResetCurvature?()
            return
        }
        if event.clickCount == 2,
           allowsObjectEditing,
           let editable = editableTextElement(at: point) {
            onRequestTextEdit?(editable.id)
            return
        }
        dragStart = point
        dragPoints = [point]
        let disposition = onBegin?(point, sourceUnitsPerViewPoint, event.modifierFlags) ?? .handled
        isCreatingInlineText = selectedTool == .text && disposition == .beginTextCreation
        if isCreatingInlineText {
            textDragCurrent = point
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func editableTextElement(at point: CGPoint) -> ScreenshotElement? {
        let source = ScreenshotPixelPoint(x: point.x.rounded(), y: point.y.rounded())
        let hits = ScreenshotGeometry.hitResults(
            at: source,
            elements: sceneElements,
            tolerance: max(2, sourceUnitsPerViewPoint * 2),
            constrainedTo: cropRectForDrawing
        )
        return hits.lazy
            .compactMap { hit in self.sceneElements.first(where: { $0.id == hit.elementID }) }
            .first { element in
                if element.kind == .text { return true }
                if element.kind == .callout,
                   let note = ScreenshotCalloutResolvedLayout(element: element)?.noteRect {
                    return note.contains(source)
                }
                guard element.kind == .step,
                      let note = ScreenshotStepResolvedLayout(element: element)?.noteRect else { return false }
                return note.contains(source)
            }
    }

    private func isCurvatureControlPoint(_ point: CGPoint) -> Bool {
        guard let selectedElement,
              case let .line(start, end) = selectedElement.geometry else { return false }
        let control = ScreenshotGeometry.lineControlPoint(
            start: start,
            end: end,
            curvature: selectedElement.appearance.curvature
        )
        return hypot(point.x - control.x, point.y - control.y) <= max(11, sourceUnitsPerViewPoint * 11)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = sourcePoint(from: convert(event.locationInWindow, from: nil))
        if isCreatingInlineText {
            let previousPreviewRect = textDragPreviewViewRect(current: textDragCurrent)
            textDragCurrent = point
            invalidateTextDragPreview(previous: previousPreviewRect)
            return
        }
        dragPoints.append(point)
        onUpdate?(point, dragPoints, event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = sourcePoint(from: convert(event.locationInWindow, from: nil))
        if isCreatingInlineText {
            let previousPreviewRect = textDragPreviewViewRect(current: textDragCurrent)
            let minimumDrag = sourceUnitsPerViewPoint * 3
            let width = abs(point.x - start.x)
            let sizing: ScreenshotTextBoxSizing = width >= minimumDrag ? .fixedWidth : .auto
            let origin = CGPoint(x: min(start.x, point.x), y: min(start.y, point.y))
            let requestedWidth = sizing != .auto ? max(width, sourceUnitsPerViewPoint * 80) : nil
            beginTextEditing(
                at: origin,
                replacing: nil,
                requestedWidth: requestedWidth,
                sizing: sizing
            )
            dragStart = nil
            textDragCurrent = nil
            isCreatingInlineText = false
            dragPoints.removeAll()
            invalidateTextDragPreview(previous: previousPreviewRect)
            return
        }
        onEnd?(point, event.modifierFlags)
        dragStart = nil
        isCreatingInlineText = false
        dragPoints.removeAll()
    }

    override func magnify(with event: NSEvent) {
        applyMagnification(event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    func applyMagnification(_ magnification: CGFloat) {
        guard allowsViewportNavigation else { return }
        zoomScale = min(8, max(0.1, zoomScale * (1 + magnification)))
        panOffset = clampedPanOffset(panOffset)
        onViewportChanged?(zoomScale, panOffset)
        needsDisplay = true
    }

    func applyScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard allowsViewportNavigation else { return }
        panOffset.width -= deltaX
        panOffset.height += deltaY
        panOffset = clampedPanOffset(panOffset)
        onViewportChanged?(zoomScale, panOffset)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Text creation starts on mouse-up. AppKit can still deliver the first
        // key event to the mouse-down responder before the inline editor's
        // first-responder transition settles. Transfer that event instead of
        // dropping the user's first character. NSTextView remains responsible
        // for IME, undo, navigation, Escape, and commit semantics.
        if let textEditor,
           window?.firstResponder !== textEditor {
            textEditor.window?.makeFirstResponder(textEditor)
            textEditor.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, !flags.contains(.command) {
            let backward = flags.contains(.shift)
            let didCycle = onCycleStepComponent?(backward) == true
                || onCycleCalloutComponent?(backward) == true
            if !didCycle {
                moveAccessibilityFocus(backward: flags.contains(.shift))
            }
        } else if event.keyCode == 36 || event.keyCode == 76 {
            activateFocusedAccessibilityItem()
        } else if flags.contains(.command), event.keyCode == 6 {
            flags.contains(.shift) ? onRedo?() : onUndo?()
        } else if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 9 {
            onSelectTool?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else if [123, 124, 125, 126].contains(event.keyCode) {
            let amount = flags.contains(.shift) ? 10.0 : 1.0
            let delta: (Double, Double) = switch event.keyCode {
            case 123: (-amount, 0)
            case 124: (amount, 0)
            case 125: (0, amount)
            default: (0, -amount)
            }
            if let item = focusedAccessibilityItem {
                onAdjustAccessibilityTarget?(item.target, delta.0, delta.1)
                return
            }
            switch event.keyCode {
            case 123: onNudge?(-amount, 0)
            case 124: onNudge?(amount, 0)
            case 125: onNudge?(0, amount)
            default: onNudge?(0, -amount)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let items = accessibilityModel.items
        var nextCache: [String: NSAccessibilityElement] = [:]
        let sceneChildren = items.map { item -> NSAccessibilityElement in
            let element = accessibilityElementCache[item.id] ?? NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityIdentifier(item.id)
            element.setAccessibilityRole(item.target.isHandle ? .button : .group)
            element.setAccessibilityLabel(item.label)
            element.setAccessibilityValue(item.value)
            let localRect = viewRect(from: item.sourceRect.cgRect).insetBy(
                dx: item.target.isHandle ? -11 : 0,
                dy: item.target.isHandle ? -11 : 0
            )
            let windowRect = convert(localRect, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(windowRect) ?? .zero)
            element.setAccessibilityCustomActions(customActions(for: item))
            nextCache[item.id] = element
            return element
        }
        accessibilityElementCache = nextCache
        // The canvas provides synthetic accessibility children for committed
        // scene objects. While text is being edited, the real NSTextView must
        // remain in that tree as well; otherwise assistive input sees only the
        // canvas and cannot address the active editor.
        if let textEditor {
            return [textEditor] + sceneChildren
        }
        return sceneChildren
    }

    private var accessibilityModel: ScreenshotEditorAccessibilityModel {
        ScreenshotEditorAccessibilityModel(
            cropRect: cropRect,
            elements: sceneElements,
            selectedElementID: selectedElement?.id,
            selectedStepComponent: selectedStepComponent,
            selectedCalloutComponent: selectedCalloutComponent,
            sourceBounds: visibleSourceRect
        )
    }

    private var focusedAccessibilityItem: ScreenshotEditorAccessibilityItem? {
        let items = accessibilityModel.items
        guard items.indices.contains(accessibilityFocusIndex) else { return nil }
        return items[accessibilityFocusIndex]
    }

    private func invalidateAccessibilityModel() {
        let count = accessibilityModel.items.count
        if accessibilityFocusIndex >= count { accessibilityFocusIndex = max(-1, count - 1) }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func focusSelectedStepComponentForAccessibility() {
        guard let elementID = selectedElement?.id,
              let component = selectedStepComponent else { return }
        let items = accessibilityModel.items
        guard let index = items.firstIndex(where: {
            $0.target == .stepComponent(elementID, component)
        }) else { return }
        accessibilityFocusIndex = index
        _ = accessibilityChildren()
        guard let child = accessibilityElementCache[items[index].id] else { return }
        NSAccessibility.post(element: child, notification: .focusedUIElementChanged)
    }

    private func moveAccessibilityFocus(backward: Bool) {
        let items = accessibilityModel.items
        guard !items.isEmpty else {
            backward ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            return
        }
        let next = accessibilityFocusIndex + (backward ? -1 : 1)
        guard items.indices.contains(next) else {
            accessibilityFocusIndex = backward ? items.count : -1
            backward ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            return
        }
        accessibilityFocusIndex = next
        _ = accessibilityChildren()
        if let child = accessibilityElementCache[items[next].id] {
            NSAccessibility.post(element: child, notification: .focusedUIElementChanged)
        }
    }

    private func activateFocusedAccessibilityItem() {
        guard let item = focusedAccessibilityItem else { return }
        activate(item)
    }

    private func activate(_ item: ScreenshotEditorAccessibilityItem) {
        switch item.target {
        case .crop:
            onSelectCrop?()
        case let .element(id), let .lineStart(id), let .lineEnd(id), let .resizeHandle(id, _):
            onSelectElement?(id)
        case let .stepComponent(id, component), let .stepResizeHandle(id, component, _):
            onSelectStepComponent?(id, component)
        case let .calloutComponent(id, component), let .calloutResizeHandle(id, component, _):
            onSelectCalloutComponent?(id, component)
        case let .magnifierResizeHandle(id, _):
            onSelectElement?(id)
        }
    }

    private func customActions(
        for item: ScreenshotEditorAccessibilityItem
    ) -> [NSAccessibilityCustomAction] {
        var actions = [NSAccessibilityCustomAction(
            name: L10n.string("screenshot.editor.accessibility.select"),
            handler: { [weak self] in
                self?.activate(item)
                return self != nil
            }
        )]
        switch item.target {
        case let .element(id):
            actions.append(NSAccessibilityCustomAction(
                name: L10n.string("screenshot.editor.accessibility.delete"),
                handler: { [weak self] in
                    self?.onSelectElement?(id)
                    self?.onDelete?()
                    return self != nil
                }
            ))
            for (key, dx, dy) in accessibilityMoveActions {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string(key),
                    handler: { [weak self] in
                        self?.onAdjustAccessibilityTarget?(.element(id), dx, dy)
                        return self != nil
                    }
                ))
            }
            if sceneElements.contains(where: { $0.id == id && $0.kind == .text }) {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string("screenshot.editor.accessibility.editText"),
                    handler: { [weak self] in
                        guard let self else { return false }
                        self.onRequestTextEdit?(id)
                        return true
                    }
                ))
            }
        case .lineStart, .lineEnd, .resizeHandle, .stepResizeHandle, .calloutResizeHandle, .magnifierResizeHandle:
            for (key, dx, dy) in accessibilityMoveActions {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string(key),
                    handler: { [weak self] in
                        self?.onAdjustAccessibilityTarget?(item.target, dx, dy)
                        return self != nil
                    }
                ))
            }
        case let .stepComponent(id, component):
            for (key, dx, dy) in accessibilityMoveActions {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string(key),
                    handler: { [weak self] in
                        self?.onSelectStepComponent?(id, component)
                        self?.onAdjustAccessibilityTarget?(item.target, dx, dy)
                        return self != nil
                    }
                ))
            }
        case let .calloutComponent(id, component):
            for (key, dx, dy) in accessibilityMoveActions {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string(key),
                    handler: { [weak self] in
                        self?.onSelectCalloutComponent?(id, component)
                        self?.onAdjustAccessibilityTarget?(item.target, dx, dy)
                        return self != nil
                    }
                ))
            }
            if component == .note {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string("screenshot.editor.accessibility.editText"),
                    handler: { [weak self] in
                        guard let self else { return false }
                        self.onSelectCalloutComponent?(id, .note)
                        self.onRequestTextEdit?(id)
                        return true
                    }
                ))
            }
            if component == .note {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string("screenshot.editor.accessibility.editText"),
                    handler: { [weak self] in
                        guard let self else { return false }
                        self.onSelectStepComponent?(id, .note)
                        self.onRequestTextEdit?(id)
                        return true
                    }
                ))
            }
        case .crop:
            for (key, dx, dy) in accessibilityMoveActions {
                actions.append(NSAccessibilityCustomAction(
                    name: L10n.string(key),
                    handler: { [weak self] in
                        self?.onAdjustAccessibilityTarget?(.crop, dx, dy)
                        return self != nil
                    }
                ))
            }
        }
        return actions
    }

    private var accessibilityMoveActions: [(String, Double, Double)] {
        [
            ("screenshot.editor.accessibility.moveLeft", -1, 0),
            ("screenshot.editor.accessibility.moveRight", 1, 0),
            ("screenshot.editor.accessibility.moveUp", 0, -1),
            ("screenshot.editor.accessibility.moveDown", 0, 1),
        ]
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? ScreenshotInlineTextView === textEditor else { return }
        resizeActiveTextEditor()
    }

    func textDidEndEditing(_ notification: Notification) { commitInlineText() }

    private func beginTextEditing(
        at point: CGPoint,
        replacing element: ScreenshotElement?,
        requestedWidth: Double? = nil,
        sizing: ScreenshotTextBoxSizing? = nil
    ) {
        textEditor?.removeFromSuperview()
        let sourceRect: CGRect
        let resolvedSizing: ScreenshotTextBoxSizing
        if let element {
            switch element.geometry {
            case let .rect(rect):
                sourceRect = rect.cgRect
            case let .callout(body, _):
                sourceRect = body.cgRect
            case let .calloutComposite(_, note):
                sourceRect = note.cgRect
            case let .step(center, note):
                sourceRect = (ScreenshotStepResolvedLayout(element: element)?.noteRect
                    ?? note
                    ?? ScreenshotStepEditorLayout.noteRect(
                    badgeCenter: center,
                    appearance: element.appearance.stepAppearance,
                    sourceBounds: cropRectForDrawing
                )).cgRect
            default:
                return
            }
            editingTextElementID = element.id
            resolvedSizing = element.textBoxSizing ?? .auto
        } else {
            editingTextElementID = nil
            resolvedSizing = sizing ?? .auto
            let layout = ScreenshotTextLayout(appearance: textStyle)
            let sourceWidth = Double(visibleSourceRect.width)
            let sourceHeight = Double(visibleSourceRect.height)
            let constraint = min(
                max(requestedWidth ?? ScreenshotTextLayout.defaultMaximumAutoWidth, layout.padding * 2 + 1),
                sourceWidth
            )
            let measured = layout.measure("", sizing: resolvedSizing, constrainedTo: constraint)
            let width = min(measured.width, sourceWidth)
            let height = min(measured.height, sourceHeight)
            let minX = Double(visibleSourceRect.x)
            let minY = Double(visibleSourceRect.y)
            sourceRect = CGRect(
                x: min(max(point.x, minX), Double(visibleSourceRect.x + visibleSourceRect.width) - width),
                y: min(max(point.y, minY), Double(visibleSourceRect.y + visibleSourceRect.height) - height),
                width: width,
                height: height
            )
        }
        editingTextSizing = resolvedSizing
        let editor = ScreenshotInlineTextView(frame: viewRect(from: sourceRect))
        editor.string = element?.text ?? ""
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.commitInlineText() }
        editor.onCancel = { [weak self] in self?.cancelInlineText() }
        editor.onMarkedTextChange = { [weak self] in self?.resizeActiveTextEditor() }
        let elementStyle = element?.appearance ?? textStyle
        let style = ScreenshotSemanticTextStyle.inlineAppearance(
            from: elementStyle,
            kind: element?.kind ?? .text
        )
        editor.textContainer?.lineFragmentPadding = 0
        let layout = ScreenshotTextLayout(appearance: style)
        let viewPadding = CGFloat(layout.padding / max(sourceUnitsPerViewPoint, 0.001))
        editor.textContainerInset = NSSize(width: viewPadding, height: viewPadding)
        let maximumAutoSourceWidth = min(
            ScreenshotTextLayout.defaultMaximumAutoWidth,
            Double(visibleSourceRect.width)
        )
        let maximumViewWidth = CGFloat(maximumAutoSourceWidth / max(sourceUnitsPerViewPoint, 0.001))
        applyTextContainerPolicy(
            to: editor,
            maximumViewWidth: maximumViewWidth,
            horizontalInset: viewPadding
        )
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width, .height]
        applyTextStyle(style, to: editor)
        applyStepEditorChrome(element?.kind == .step ? elementStyle : nil, to: editor)
        addSubview(editor)
        textEditor = editor
        resizeActiveTextEditor()
        focusInlineTextEditor(editor)
    }

    /// AppKit may restore the mouse-down view as first responder after the
    /// current event finishes. The shared lifecycle coordinator performs one
    /// monotonic next-run-loop validation without a wall-clock retry.
    private func focusInlineTextEditor(_ editor: ScreenshotInlineTextView) {
        inlineTextFocusCoordinator.detach()
        inlineTextFocusRequestID &+= 1
        inlineTextFocusCoordinator.attach(editor)
        inlineTextFocusCoordinator.requestFocusAfterCurrentEvent(inlineTextFocusRequestID)
    }

    func beginInlineTextEditing(for elementID: UUID?) {
        guard let elementID,
              let element = sceneElements.first(where: { $0.id == elementID }) else { return }
        let bounds: CGRect
        if element.kind == .step {
            bounds = ScreenshotStepResolvedLayout(element: element)?.noteRect?.cgRect
                ?? ScreenshotGeometry.bounds(of: element).cgRect
        } else if element.kind == .callout {
            bounds = ScreenshotCalloutResolvedLayout(element: element)?.noteRect.cgRect
                ?? ScreenshotGeometry.bounds(of: element).cgRect
        } else {
            bounds = ScreenshotGeometry.bounds(of: element).cgRect
        }
        beginTextEditing(at: bounds.origin, replacing: element)
    }

    private func drawHoveredObject(in _: CGRect) {
        guard let hoveredElementID,
              hoveredElementID != selectedElement?.id,
              let element = sceneElements.first(where: { $0.id == hoveredElementID }) else { return }
        let rect = viewRect(from: ScreenshotGeometry.bounds(of: element).cgRect)
            .insetBy(dx: -2, dy: -2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        hoverColor(for: element.kind).setStroke()
        path.stroke()
    }

    private func hoverColor(for kind: ScreenshotElementKind) -> NSColor {
        switch kind {
        case .arrow, .line, .freehand: .systemOrange
        case .rectangle, .ellipse, .highlight, .spotlight: .systemYellow
        case .text, .callout, .counter, .step: .systemBlue
        case .blur, .pixelate, .redact: .systemPurple
        case .magnifier: .systemGreen
        case .watermark: .systemTeal
        }
    }

    func updateActiveTextStyle() {
        guard let textEditor else { return }
        let editingElement = editingTextElementID.flatMap { id in
            sceneElements.first(where: { $0.id == id })
        }
        let editingKind = editingElement?.kind ?? .text
        let isEditingStep = editingKind == .step
        let appearance = ScreenshotSemanticTextStyle.inlineAppearance(
            from: textStyle,
            kind: editingKind
        )
        applyTextStyle(appearance, to: textEditor)
        applyStepEditorChrome(isEditingStep ? textStyle : nil, to: textEditor)
        resizeActiveTextEditor()
    }

    private func applyStepEditorChrome(
        _ appearance: ScreenshotElementAppearance?,
        to editor: ScreenshotInlineTextView
    ) {
        editor.wantsLayer = true
        guard let appearance, case let .step(step) = appearance.payload else {
            editor.layer?.cornerRadius = 0
            editor.layer?.borderWidth = 0
            editor.layer?.masksToBounds = false
            return
        }
        let scale = max(sourceUnitsPerViewPoint, 0.001)
        editor.layer?.cornerRadius = CGFloat(step.noteCornerRadius / scale)
        editor.layer?.borderWidth = CGFloat(step.noteBorderWidth / scale)
        editor.layer?.borderColor = ScreenshotResolvedColor(
            step.noteBorderColor,
            opacity: step.opacity
        ).nsColor.cgColor
        editor.layer?.masksToBounds = true
    }

    private func applyTextStyle(_ appearance: ScreenshotElementAppearance, to editor: ScreenshotInlineTextView) {
        let resolved = ScreenshotInlineTextAttributes(
            appearance: appearance,
            sourceUnitsPerViewPoint: sourceUnitsPerViewPoint
        )
        editor.drawsBackground = resolved.drawsBackground
        editor.backgroundColor = resolved.backgroundColor
        let selectedRange = editor.selectedRange()
        let markedRange = editor.markedRange()
        let textRange = NSRange(location: 0, length: (editor.string as NSString).length)

        editor.textStorage?.beginEditing()
        if textRange.length > 0 {
            // Add only layout keys so IME underline and candidate state remain intact.
            editor.textStorage?.addAttributes(resolved.attributes, range: textRange)
        }
        editor.textStorage?.endEditing()
        editor.markedTextAttributes = resolved.mergingMarkedTextAttributes(editor.markedTextAttributes)
        editor.textColor = resolved.foregroundColor
        editor.insertionPointColor = resolved.foregroundColor
        editor.typingAttributes = resolved.attributes
        editor.resolvedMarkedTextAttributes = resolved.attributes
        let upperBound = textRange.location + textRange.length
        let restoredRange = NSRange(
            location: min(selectedRange.location, upperBound),
            length: min(selectedRange.length, upperBound - min(selectedRange.location, upperBound))
        )
        if markedRange.location == NSNotFound, selectedRange.location != NSNotFound {
            editor.setSelectedRange(restoredRange)
        }
    }

    private func commitInlineText() {
        guard let editor = textEditor else { return }
        inlineTextFocusCoordinator.detach()
        let sourceRect = sourceRect(from: editor.frame)
        let text = editor.string
        editor.removeFromSuperview()
        textEditor = nil
        onTextCommit?(text, sourceRect, editingTextElementID, editingTextSizing)
        editingTextElementID = nil
        onTextEditingEnded?()
    }

    func commitInlineTextIfNeeded() {
        guard textEditor != nil else { return }
        commitInlineText()
    }

    private func cancelInlineText() {
        inlineTextFocusCoordinator.detach()
        textEditor?.removeFromSuperview()
        textEditor = nil
        editingTextElementID = nil
        window?.makeFirstResponder(self)
        onTextEditingEnded?()
    }

    private func resizeActiveTextEditor() {
        guard let editor = textEditor else { return }
        let current = sourceRect(from: editor.frame)
        let editingKind = editingTextElementID.flatMap { id in
            sceneElements.first(where: { $0.id == id })
        }?.kind ?? .text
        let appearance = ScreenshotSemanticTextStyle.inlineAppearance(
            from: textStyle,
            kind: editingKind
        )
        let layout = ScreenshotTextLayout(appearance: appearance)
        let sourceWidth = Double(visibleSourceRect.width)
        let sourceHeight = Double(visibleSourceRect.height)
        let constraint = editingTextSizing == .auto
            ? min(ScreenshotTextLayout.defaultMaximumAutoWidth, sourceWidth)
            : min(max(current.width, layout.padding * 2 + 1), sourceWidth)
        let measured = layout.measure(editor.string, sizing: editingTextSizing, constrainedTo: constraint)
        let width = editingTextSizing == .fixedBox
            ? min(max(current.width, layout.padding * 2 + 1), sourceWidth)
            : min(measured.width, sourceWidth)
        let height = editingTextSizing == .fixedBox
            ? min(max(current.height, layout.lineHeight + layout.padding * 2), sourceHeight)
            : min(measured.height, sourceHeight)
        let minX = Double(visibleSourceRect.x)
        let minY = Double(visibleSourceRect.y)
        let next = CGRect(
            x: min(max(current.minX, minX), Double(visibleSourceRect.x + visibleSourceRect.width) - width),
            y: min(max(current.minY, minY), Double(visibleSourceRect.y + visibleSourceRect.height) - height),
            width: width,
            height: height
        )
        editor.frame = viewRect(from: next)
        let viewPadding = CGFloat(layout.padding / max(sourceUnitsPerViewPoint, 0.001))
        editor.textContainerInset = NSSize(width: viewPadding, height: viewPadding)
        let maximumViewWidth = CGFloat(constraint / max(sourceUnitsPerViewPoint, 0.001))
        applyTextContainerPolicy(
            to: editor,
            maximumViewWidth: maximumViewWidth,
            horizontalInset: viewPadding
        )
    }

    private func applyTextContainerPolicy(
        to editor: ScreenshotInlineTextView,
        maximumViewWidth: CGFloat,
        horizontalInset: CGFloat
    ) {
        let policy = ScreenshotInlineTextLayoutPolicy.make(
            sizing: editingTextSizing,
            maximumViewWidth: maximumViewWidth,
            fixedViewWidth: editor.bounds.width,
            horizontalInset: horizontalInset
        )
        editor.textContainer?.widthTracksTextView = policy.widthTracksTextView
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(
            width: policy.containerWidth,
            height: .greatestFiniteMagnitude
        )
    }

    private func imageRect(for imageSize: NSSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height) * zoomScale
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let clampedOffset = clampedPanOffset(panOffset, renderedSize: size)
        return CGRect(
            x: bounds.midX - size.width / 2 + clampedOffset.width,
            y: bounds.midY - size.height / 2 + clampedOffset.height,
            width: size.width,
            height: size.height
        )
    }

    private func applyInitialFitWidthIfNeeded() {
        guard prefersInitialFitWidth,
              !didApplyInitialFitWidth,
              bounds.width > 0,
              bounds.height > 0,
              let image,
              image.size.width > 0,
              image.size.height > 0 else { return }
        let baseScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        guard baseScale > 0 else { return }
        zoomScale = min(8, max(0.1, (bounds.width / image.size.width) / baseScale))
        let renderedHeight = image.size.height * baseScale * zoomScale
        panOffset = clampedPanOffset(CGSize(
            width: 0,
            height: max(0, (renderedHeight - bounds.height) / 2)
        ))
        didApplyInitialFitWidth = true
        onViewportChanged?(zoomScale, panOffset)
        needsDisplay = true
    }

    private func clampedPanOffset(_ proposed: CGSize, renderedSize: CGSize? = nil) -> CGSize {
        guard allowsViewportNavigation, let image else { return .zero }
        let size: CGSize
        if let renderedSize {
            size = renderedSize
        } else {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height) * zoomScale
            size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let horizontalLimit = max(0, (size.width - bounds.width) / 2)
        let verticalLimit = max(0, (size.height - bounds.height) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, proposed.width)),
            height: min(verticalLimit, max(-verticalLimit, proposed.height))
        )
    }

    var sourceUnitsPerViewPoint: Double {
        guard let image else { return 1 }
        let rect = imageRect(for: image.size)
        return max(
            Double(visibleSourceRect.width) / max(rect.width, 1),
            Double(visibleSourceRect.height) / max(rect.height, 1)
        )
    }

    private func sourcePoint(from local: CGPoint) -> CGPoint {
        guard let image else { return .zero }
        let rect = imageRect(for: image.size)
        let x = min(max(local.x, rect.minX), rect.maxX)
        let y = min(max(local.y, rect.minY), rect.maxY)
        return CGPoint(
            x: Double(visibleSourceRect.x) + (x - rect.minX) / max(rect.width, 1) * Double(visibleSourceRect.width),
            y: Double(visibleSourceRect.y) + (y - rect.minY) / max(rect.height, 1) * Double(visibleSourceRect.height)
        )
    }

    private func viewRect(from sourceRect: CGRect) -> CGRect {
        guard let image else { return .zero }
        let rect = imageRect(for: image.size)
        return CGRect(
            x: rect.minX + (sourceRect.minX - Double(visibleSourceRect.x)) / Double(max(visibleSourceRect.width, 1)) * rect.width,
            y: rect.minY + (sourceRect.minY - Double(visibleSourceRect.y)) / Double(max(visibleSourceRect.height, 1)) * rect.height,
            width: sourceRect.width / Double(max(visibleSourceRect.width, 1)) * rect.width,
            height: sourceRect.height / Double(max(visibleSourceRect.height, 1)) * rect.height
        )
    }

    fileprivate func invalidate(sourceRect: CGRect) {
        guard image != nil, !sourceRect.isNull, !sourceRect.isEmpty else { return }
        // Selection dashes, resize handles and connector control points extend
        // beyond the semantic element bounds. Keep the expansion in view
        // points so it remains visually stable across zoom and mixed DPI.
        setNeedsDisplay(viewRect(from: sourceRect).insetBy(dx: -16, dy: -16))
    }

    private func sourceRect(from viewRect: CGRect) -> CGRect {
        guard let image else { return .zero }
        let rect = imageRect(for: image.size)
        return CGRect(
            x: Double(visibleSourceRect.x) + (viewRect.minX - rect.minX) / max(rect.width, 1) * Double(visibleSourceRect.width),
            y: Double(visibleSourceRect.y) + (viewRect.minY - rect.minY) / max(rect.height, 1) * Double(visibleSourceRect.height),
            width: viewRect.width / max(rect.width, 1) * Double(visibleSourceRect.width),
            height: viewRect.height / max(rect.height, 1) * Double(visibleSourceRect.height)
        )
    }

    private func drawSelection(in imageRect: CGRect) {
        // Watermarks are document-wide backgrounds, not draggable canvas
        // objects. Their selected state belongs to the status/tool bars only.
        guard let selectedElement, selectedElement.kind != .watermark else { return }
        let bounds: CGRect
        if let layout = ScreenshotStepResolvedLayout(element: selectedElement) {
            bounds = switch selectedStepComponent ?? .badge {
            case .badge:
                layout.badgeRect.cgRect
            case .connector:
                (layout.connectorBounds ?? layout.badgeRect).cgRect
            case .note:
                (layout.noteRect ?? layout.badgeRect).cgRect
            }
        } else if let layout = ScreenshotCalloutResolvedLayout(element: selectedElement) {
            bounds = switch selectedCalloutComponent
                ?? (layout.targetRect == nil ? .connector : .target) {
            case .target:
                (layout.targetRect ?? layout.connectorBounds).cgRect
            case .connector:
                layout.connectorBounds.cgRect
            case .note:
                layout.noteRect.cgRect
            }
        } else if let magnifier = ScreenshotMagnifierResolvedLayout(
            element: selectedElement,
            constrainedTo: cropRectForDrawing
        ) {
            bounds = magnifier.lensRect.cgRect
        } else {
            bounds = ScreenshotGeometry.bounds(of: selectedElement).cgRect
        }
        let selection = viewRect(from: bounds)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: selection.insetBy(dx: -3, dy: -3))
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        drawHandles(for: selectedElement, selection: selection)
    }

    private func drawEmptyAnnotationPlaceholders() {
        for element in sceneElements {
            guard (element.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if element.kind == .callout {
                drawEmptyCalloutPlaceholder(
                    element,
                    drawsNote: element.id != editingTextElementID
                )
                continue
            }
            guard element.id != editingTextElementID,
                  element.kind == .step,
                  case let .step(appearance) = element.appearance.payload,
                  let layout = ScreenshotStepResolvedLayout(element: element),
                  let noteRect = layout.noteRect else { continue }

            if let connector = layout.connector,
               let control = layout.connectorControlPoint {
                let start = viewRect(from: CGRect(x: connector.start.x, y: connector.start.y, width: 0, height: 0)).origin
                let end = viewRect(from: CGRect(x: connector.end.x, y: connector.end.y, width: 0, height: 0)).origin
                let controlPoint = viewRect(from: CGRect(x: control.x, y: control.y, width: 0, height: 0)).origin
                let firstControl = CGPoint(
                    x: start.x + (controlPoint.x - start.x) * 2 / 3,
                    y: start.y + (controlPoint.y - start.y) * 2 / 3
                )
                let secondControl = CGPoint(
                    x: end.x + (controlPoint.x - end.x) * 2 / 3,
                    y: end.y + (controlPoint.y - end.y) * 2 / 3
                )
                let path = NSBezierPath()
                path.move(to: start)
                path.curve(to: end, controlPoint1: firstControl, controlPoint2: secondControl)
                path.lineWidth = CGFloat(max(1, appearance.connector.width / sourceUnitsPerViewPoint))
                path.lineCapStyle = .round
                if appearance.connector.pattern == .dashed {
                    path.setLineDash([6, 4], count: 2, phase: 0)
                }
                ScreenshotResolvedColor(
                    appearance.connector.color,
                    opacity: appearance.connector.opacity
                ).nsColor.setStroke()
                path.stroke()
            }

            let note = viewRect(from: noteRect.cgRect)
            let cornerRadius = CGFloat(appearance.note.backgroundCornerRadius / sourceUnitsPerViewPoint)
            let notePath = NSBezierPath(roundedRect: note, xRadius: cornerRadius, yRadius: cornerRadius)
            if let background = appearance.note.backgroundColor {
                ScreenshotResolvedColor(background, opacity: appearance.note.opacity).nsColor.setFill()
                notePath.fill()
            }
            if let border = appearance.note.backgroundBorderColor,
               appearance.note.backgroundBorderWidth > 0 {
                notePath.lineWidth = CGFloat(max(1, appearance.note.backgroundBorderWidth / sourceUnitsPerViewPoint))
                ScreenshotResolvedColor(border, opacity: appearance.note.opacity).nsColor.setStroke()
                notePath.stroke()
            }

            let padding = CGFloat(appearance.note.backgroundPadding / sourceUnitsPerViewPoint)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = switch appearance.note.alignment {
            case .leading: .left
            case .center: .center
            case .trailing: .right
            }
            paragraph.minimumLineHeight = CGFloat(appearance.note.fontSize * appearance.note.lineSpacing / sourceUnitsPerViewPoint)
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            let placeholder = L10n.string("screenshot.editor.text.placeholder") as NSString
            placeholder.draw(
                in: note.insetBy(dx: padding, dy: padding),
                withAttributes: [
                    .font: BlocksTypography.nsFont(
                        size: CGFloat(appearance.note.fontSize / sourceUnitsPerViewPoint),
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    private func drawEmptyCalloutPlaceholder(
        _ element: ScreenshotElement,
        drawsNote: Bool
    ) {
        var layoutElement = element
        guard case var .callout(appearance) = layoutElement.appearance.payload,
              let layout = ScreenshotCalloutResolvedLayout(element: element) else { return }
        if !drawsNote {
            appearance.note.backgroundColor = nil
            appearance.note.backgroundBorderWidth = 0
            layoutElement.appearance.payload = .callout(appearance)
        }
        drawDraftCallout(
            layoutElement,
            sourceScale: 1 / max(0.001, sourceUnitsPerViewPoint)
        )
        guard drawsNote else { return }

        let note = viewRect(from: layout.noteRect.cgRect)
        let padding = CGFloat(appearance.note.backgroundPadding / sourceUnitsPerViewPoint)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch appearance.note.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.minimumLineHeight = CGFloat(appearance.note.fontSize * appearance.note.lineSpacing / sourceUnitsPerViewPoint)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        let placeholder = L10n.string("screenshot.editor.text.placeholder") as NSString
        placeholder.draw(
            in: note.insetBy(dx: padding, dy: padding),
            withAttributes: [
                .font: BlocksTypography.nsFont(
                    size: CGFloat(appearance.note.fontSize / sourceUnitsPerViewPoint),
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawHandles(for element: ScreenshotElement, selection: CGRect) {
        let points: [CGPoint]
        var anchoredCurvePoint: CGPoint?
        switch element.geometry {
        case let .line(start, end):
            let control = ScreenshotGeometry.lineControlPoint(
                start: start,
                end: end,
                curvature: element.appearance.curvature
            )
            let controlPoint = viewRect(from: CGRect(x: control.x, y: control.y, width: 0, height: 0)).origin
            points = [viewRect(from: CGRect(x: start.x, y: start.y, width: 0, height: 0)).origin,
                      viewRect(from: CGRect(x: end.x, y: end.y, width: 0, height: 0)).origin,
                      controlPoint]
            if abs(element.appearance.curvature) < 0.000_001 {
                anchoredCurvePoint = controlPoint
            }
        case .callout, .calloutComposite:
            guard let layout = ScreenshotCalloutResolvedLayout(element: element) else {
                points = []
                break
            }
            switch selectedCalloutComponent ?? (layout.targetRect == nil ? .connector : .target) {
            case .target:
                if let targetRect = layout.targetRect {
                    points = resizeHandlePoints(for: viewRect(from: targetRect.cgRect))
                } else if case let .point(point) = layout.target {
                    points = [viewRect(from: CGRect(x: point.x, y: point.y, width: 0, height: 0)).origin]
                } else {
                    points = []
                }
            case .connector:
                points = [viewRect(from: CGRect(
                    x: layout.connectorControlPoint.x,
                    y: layout.connectorControlPoint.y,
                    width: 0,
                    height: 0
                )).origin]
            case .note:
                points = resizeHandlePoints(for: viewRect(from: layout.noteRect.cgRect))
            }
        case .magnifier:
            let lens = ScreenshotMagnifierResolvedLayout(
                element: element,
                constrainedTo: cropRectForDrawing
            )?.lensRect.cgRect ?? ScreenshotGeometry.bounds(of: element).cgRect
            points = cornerHandlePoints(for: viewRect(from: lens))
        case .counter:
            points = [CGPoint(x: selection.midX, y: selection.midY)]
        case .step:
            if selectedStepComponent == .connector,
               let control = ScreenshotStepResolvedLayout(element: element)?.connectorControlPoint {
                points = [viewRect(from: CGRect(x: control.x, y: control.y, width: 0, height: 0)).origin]
            } else if selectedStepComponent == .note {
                points = resizeHandlePoints(for: selection)
            } else {
                points = cornerHandlePoints(for: selection)
            }
        default:
            points = resizeHandlePoints(for: selection)
        }
        for point in points {
            NSColor.controlAccentColor.setFill()
            NSColor.white.setStroke()
            let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            handle.fill()
            handle.lineWidth = 1
            handle.stroke()
        }
        if let anchoredCurvePoint {
            let isHighlighted = Date() < curvatureAnchorHighlightUntil
            let pulsePolicy = ScreenshotCurvatureAnchorPulsePolicy(reduceMotion: reduceMotion)
            let diameter = pulsePolicy.diameter(isHighlighted: isHighlighted)
            let anchor = NSBezierPath(ovalIn: CGRect(
                x: anchoredCurvePoint.x - diameter / 2,
                y: anchoredCurvePoint.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            anchor.lineWidth = isHighlighted ? 2.5 : 1.5
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.95 : 0.62).setStroke()
            anchor.stroke()
        }
    }

    func pulseCurvatureAnchor() {
        curvatureAnchorPulseTask?.cancel()
        let policy = ScreenshotCurvatureAnchorPulsePolicy(reduceMotion: reduceMotion)
        curvatureAnchorHighlightUntil = Date().addingTimeInterval(policy.duration)
        needsDisplay = true
        guard policy.duration > 0 else { return }
        curvatureAnchorPulseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(policy.duration))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.curvatureAnchorPulseTask = nil
            self.needsDisplay = true
        }
    }

    private func resizeHandlePoints(for selection: CGRect) -> [CGPoint] {
        [
            CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY),
        ]
    }

    private func cornerHandlePoints(for selection: CGRect) -> [CGPoint] {
        [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.maxY),
            CGPoint(x: selection.minX, y: selection.maxY),
        ]
    }

    private func drawCrop(in imageRect: CGRect) {
        guard showsCropOverlay || draftCropRect != nil else { return }
        let crop = viewRect(from: cropRectForDrawing.cgRect)
        let outputRadius = isRoundedOutput
            ? ScreenshotOutputAppearance(isRounded: true).cornerRadius(
                for: .init(width: cropRectForDrawing.width, height: cropRectForDrawing.height)
            )
            : 0
        let viewRadius = CGFloat(outputRadius) / CGFloat(max(0.001, sourceUnitsPerViewPoint))
        let cropPath = outputRadius > 0
            ? NSBezierPath(roundedRect: crop, xRadius: viewRadius, yRadius: viewRadius)
            : NSBezierPath(rect: crop)
        NSColor.black.withAlphaComponent(0.48).setFill()
        let outside = NSBezierPath(rect: imageRect)
        outside.append(cropPath)
        outside.windingRule = .evenOdd
        outside.fill()
        NSColor.controlAccentColor.setStroke()
        cropPath.lineWidth = 2
        cropPath.stroke()
        drawCropHandles(crop)
    }

    private func drawCropHandles(_ crop: CGRect) {
        let points = [
            CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.midX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.midY),
            CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.midX, y: crop.maxY),
            CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.midY),
        ]
        for point in points {
            NSColor.controlAccentColor.setFill()
            NSColor.white.withAlphaComponent(0.92).setStroke()
            let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            handle.fill()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    private func drawDraft(_ element: ScreenshotElement, in imageRect: CGRect) {
        if element.kind == .text {
            drawDraftText(element)
            return
        }
        if element.kind == .watermark {
            return
        }
        let color = Self.resolvedDraftStrokeColor(for: element)
        color.setStroke()
        color.setFill()
        let sourceScale = imageRect.width / CGFloat(max(visibleSourceRect.width, 1))
        let width = max(1, CGFloat(element.appearance.lineWidth) * sourceScale)
        switch element.geometry {
        case let .line(start, end):
            let a = viewRect(from: CGRect(x: start.x, y: start.y, width: 0, height: 0)).origin
            let b = viewRect(from: CGRect(x: end.x, y: end.y, width: 0, height: 0)).origin
            let path = NSBezierPath()
            path.move(to: a)
            let control = lineControlPoint(start: a, end: b, curvature: element.appearance.curvature)
            path.curve(to: b, controlPoint1: control, controlPoint2: control)
            path.lineWidth = width
            if element.appearance.linePattern == .dashed { path.setLineDash([8, 6], count: 2, phase: 0) }
            path.stroke()
            drawLineEnding(element.appearance.startEnding, tip: a, other: control, width: width, color: color)
            drawLineEnding(element.appearance.endEnding, tip: b, other: control, width: width, color: color)
        case let .rect(rect):
            let target = viewRect(from: rect.cgRect)
            if [.blur, .pixelate, .spotlight, .redact].contains(element.kind) {
                color.withAlphaComponent(color.alphaComponent * 0.18).setFill()
                target.fill()
            } else if element.kind == .ellipse {
                let path = NSBezierPath(ovalIn: target)
                path.lineWidth = width
                if let fill = element.appearance.fillColor {
                    fill.nsColor.withAlphaComponent(fill.alpha * element.appearance.opacity).setFill()
                    path.fill()
                    color.setStroke()
                }
                path.stroke()
            } else {
                let path = NSBezierPath(roundedRect: target, xRadius: element.appearance.cornerRadius, yRadius: element.appearance.cornerRadius)
                path.lineWidth = width
                if element.kind == .highlight { color.setFill(); path.fill() }
                else {
                    if let fill = element.appearance.fillColor {
                        fill.nsColor.withAlphaComponent(fill.alpha * element.appearance.opacity).setFill()
                        path.fill()
                        color.setStroke()
                    }
                    path.stroke()
                }
            }
        case let .path(points):
            let smoothed = ScreenshotStrokeSmoothing.points(
                for: points,
                amount: element.appearance.smoothing
            )
            guard let first = smoothed.first else { return }
            let path = NSBezierPath()
            var current = viewRect(from: CGRect(x: first.x, y: first.y, width: 0, height: 0)).origin
            path.move(to: current)
            if element.appearance.smoothing > 0, smoothed.count > 2 {
                for index in 1..<(smoothed.count - 1) {
                    let point = smoothed[index]
                    let next = smoothed[index + 1]
                    let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
                    let control = viewRect(from: CGRect(x: point.x, y: point.y, width: 0, height: 0)).origin
                    let end = viewRect(from: CGRect(x: midpoint.x, y: midpoint.y, width: 0, height: 0)).origin
                    path.curve(
                        to: end,
                        controlPoint1: CGPoint(
                            x: current.x + (control.x - current.x) * 2 / 3,
                            y: current.y + (control.y - current.y) * 2 / 3
                        ),
                        controlPoint2: CGPoint(
                            x: end.x + (control.x - end.x) * 2 / 3,
                            y: end.y + (control.y - end.y) * 2 / 3
                        )
                    )
                    current = end
                }
                if let last = smoothed.last {
                    path.line(to: viewRect(from: CGRect(x: last.x, y: last.y, width: 0, height: 0)).origin)
                }
            } else {
                for point in smoothed.dropFirst() {
                    path.line(to: viewRect(from: CGRect(x: point.x, y: point.y, width: 0, height: 0)).origin)
                }
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case let .counter(center):
            let diameter = CGFloat(element.appearance.counterSize) * sourceScale
            let point = viewRect(from: CGRect(x: center.x, y: center.y, width: 0, height: 0)).origin
            let target = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            let path = element.appearance.counterShape == .circle
                ? NSBezierPath(ovalIn: target)
                : NSBezierPath(roundedRect: target, xRadius: diameter * 0.28, yRadius: diameter * 0.28)
            path.lineWidth = width
            ScreenshotResolvedColor(
                element.appearance.counterFillColor,
                opacity: element.appearance.opacity
            ).nsColor.setFill()
            path.fill()
            ScreenshotResolvedColor(
                element.appearance.strokeColor,
                opacity: element.appearance.opacity
            ).nsColor.setStroke()
            path.lineWidth = max(0, CGFloat(element.appearance.lineWidth) * sourceScale)
            path.stroke()
            let counterTextColor = ScreenshotResolvedColor(
                element.appearance.counterTextColor,
                opacity: element.appearance.opacity
            ).nsColor
            drawOpticallyCenteredBadgeText(
                element.text ?? "1",
                in: target,
                fontSize: max(1, diameter * 0.46),
                color: counterTextColor
            )
        case let .step(badgeCenter, note):
            let appearance = element.appearance.stepAppearance
            let layout = ScreenshotStepResolvedLayout(element: element)
            if let connector = layout?.connector,
               let sourceControl = layout?.connectorControlPoint {
                let start = viewRect(from: CGRect(
                    x: connector.start.x,
                    y: connector.start.y,
                    width: 0,
                    height: 0
                )).origin
                let end = viewRect(from: CGRect(
                    x: connector.end.x,
                    y: connector.end.y,
                    width: 0,
                    height: 0
                )).origin
                let control = viewRect(from: CGRect(
                    x: sourceControl.x,
                    y: sourceControl.y,
                    width: 0,
                    height: 0
                )).origin
                let firstControl = CGPoint(
                    x: start.x + (control.x - start.x) * 2 / 3,
                    y: start.y + (control.y - start.y) * 2 / 3
                )
                let secondControl = CGPoint(
                    x: end.x + (control.x - end.x) * 2 / 3,
                    y: end.y + (control.y - end.y) * 2 / 3
                )
                let connectorWidth = max(1, CGFloat(appearance.connector.width) * sourceScale)
                let connectorColor = ScreenshotResolvedColor(
                    appearance.connector.color,
                    opacity: appearance.connector.opacity
                ).nsColor
                let connectorPath = NSBezierPath()
                connectorPath.move(to: start)
                connectorPath.curve(
                    to: end,
                    controlPoint1: firstControl,
                    controlPoint2: secondControl
                )
                connectorPath.lineWidth = connectorWidth
                connectorPath.lineCapStyle = .round
                if appearance.connector.pattern == .dashed {
                    let unit = max(2, connectorWidth * 2)
                    connectorPath.setLineDash([unit, unit], count: 2, phase: 0)
                }
                connectorColor.setStroke()
                connectorPath.stroke()
                drawLineEnding(
                    appearance.connector.startEnding,
                    tip: start,
                    other: control,
                    width: connectorWidth,
                    color: connectorColor,
                    headScale: CGFloat(appearance.connector.arrowHeadSize)
                )
                drawLineEnding(
                    appearance.connector.endEnding,
                    tip: end,
                    other: control,
                    width: connectorWidth,
                    color: connectorColor,
                    headScale: CGFloat(appearance.connector.arrowHeadSize)
                )
            }
            let resolvedNote = layout?.noteRect ?? note
            if let resolvedNote {
                let noteTarget = viewRect(from: resolvedNote.cgRect)
                let noteRadius = min(
                    CGFloat(appearance.noteCornerRadius) * sourceScale,
                    min(noteTarget.width, noteTarget.height) / 2
                )
                let notePath = NSBezierPath(
                    roundedRect: noteTarget,
                    xRadius: noteRadius,
                    yRadius: noteRadius
                )
                ScreenshotResolvedColor(
                    appearance.noteBackgroundColor,
                    opacity: appearance.note.opacity
                ).nsColor.setFill()
                notePath.fill()
                ScreenshotResolvedColor(
                    appearance.noteBorderColor,
                    opacity: appearance.note.opacity
                ).nsColor.setStroke()
                notePath.lineWidth = max(0, CGFloat(appearance.noteBorderWidth) * sourceScale)
                notePath.stroke()
            }
            let sourceDiameter = layout?.badgeDiameter ?? appearance.badgeSize
            let diameter = CGFloat(sourceDiameter) * sourceScale
            let resolvedCenter = layout?.badgeCenter ?? badgeCenter
            let point = viewRect(from: CGRect(
                x: resolvedCenter.x,
                y: resolvedCenter.y,
                width: 0,
                height: 0
            )).origin
            let badge = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            let path = appearance.badge.shape == .circle
                ? NSBezierPath(ovalIn: badge)
                : NSBezierPath(
                    roundedRect: badge,
                    xRadius: diameter * 0.28,
                    yRadius: diameter * 0.28
                )
            ScreenshotResolvedColor(appearance.badgeFillColor, opacity: appearance.badge.opacity).nsColor.setFill()
            path.fill()
            ScreenshotResolvedColor(appearance.badgeBorderColor, opacity: appearance.badge.opacity).nsColor.setStroke()
            path.lineWidth = max(0, CGFloat(appearance.badgeBorderWidth) * sourceScale)
            path.stroke()
            drawOpticallyCenteredBadgeText(
                String(element.stepNumber ?? 1),
                in: badge,
                fontSize: CGFloat(layout?.badgeFontSize ?? sourceDiameter * 0.46) * sourceScale,
                color: ScreenshotResolvedColor(
                    appearance.badgeTextColor,
                    opacity: appearance.badge.opacity
                ).nsColor
            )
            if let resolvedNote {
                var resolvedElement = element
                resolvedElement.geometry = .step(badgeCenter: resolvedCenter, note: resolvedNote)
                drawDraftText(resolvedElement, drawsBackground: false)
            }
        case .callout, .calloutComposite:
            drawDraftCallout(element, sourceScale: sourceScale)
        case .magnifier:
            // Magnifier previews are rendered through the throttled Core pipeline so
            // creation, movement, resizing, and final export share one pixel path.
            break
        }
    }

    private func drawDraftCallout(_ element: ScreenshotElement, sourceScale: CGFloat) {
        guard let layout = ScreenshotCalloutResolvedLayout(element: element),
              case let .callout(appearance) = element.appearance.payload else { return }
        let connectorColor = ScreenshotResolvedColor(
            appearance.connector.color,
            opacity: appearance.connector.opacity
        ).nsColor
        let start = viewPoint(from: layout.connector.start)
        let end = viewPoint(from: layout.connector.end)
        let control = viewPoint(from: layout.connectorControlPoint)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(
            to: end,
            controlPoint1: CGPoint(
                x: start.x + (control.x - start.x) * 2 / 3,
                y: start.y + (control.y - start.y) * 2 / 3
            ),
            controlPoint2: CGPoint(
                x: end.x + (control.x - end.x) * 2 / 3,
                y: end.y + (control.y - end.y) * 2 / 3
            )
        )
        let connectorWidth = max(1, CGFloat(appearance.connector.width) * sourceScale)
        path.lineWidth = connectorWidth
        path.lineCapStyle = .round
        if appearance.connector.pattern == .dashed {
            let unit = max(2, connectorWidth * 2)
            path.setLineDash([unit, unit], count: 2, phase: 0)
        }
        connectorColor.setStroke()
        path.stroke()
        drawLineEnding(
            appearance.connector.startEnding,
            tip: start,
            other: control,
            width: connectorWidth,
            color: connectorColor,
            headScale: CGFloat(appearance.connector.arrowHeadSize)
        )
        drawLineEnding(
            appearance.connector.endEnding,
            tip: end,
            other: control,
            width: connectorWidth,
            color: connectorColor,
            headScale: CGFloat(appearance.connector.arrowHeadSize)
        )

        if let targetRect = layout.targetRect {
            let targetPath = NSBezierPath(ovalIn: viewRect(from: targetRect.cgRect))
            targetPath.lineWidth = max(1, CGFloat(appearance.target.strokeWidth) * sourceScale)
            if let fill = appearance.target.fillColor {
                ScreenshotResolvedColor(
                    fill,
                    opacity: appearance.target.opacity * appearance.target.fillOpacity
                ).nsColor.setFill()
                targetPath.fill()
            }
            ScreenshotResolvedColor(
                appearance.target.strokeColor,
                opacity: appearance.target.opacity
            ).nsColor.setStroke()
            targetPath.stroke()
        }

        let noteRect = viewRect(from: layout.noteRect.cgRect)
        let notePath = NSBezierPath(
            roundedRect: noteRect,
            xRadius: CGFloat(appearance.note.backgroundCornerRadius) * sourceScale,
            yRadius: CGFloat(appearance.note.backgroundCornerRadius) * sourceScale
        )
        if let background = appearance.note.backgroundColor {
            ScreenshotResolvedColor(background, opacity: appearance.note.opacity).nsColor.setFill()
            notePath.fill()
        }
        if let border = appearance.note.backgroundBorderColor,
           appearance.note.backgroundBorderWidth > 0 {
            notePath.lineWidth = max(1, CGFloat(appearance.note.backgroundBorderWidth) * sourceScale)
            ScreenshotResolvedColor(border, opacity: appearance.note.opacity).nsColor.setStroke()
            notePath.stroke()
        }
        if !(element.text ?? "").isEmpty {
            drawDraftText(element, drawsBackground: false)
        }
    }

    private func viewPoint(from point: ScreenshotPixelPoint) -> CGPoint {
        viewRect(from: CGRect(x: point.x, y: point.y, width: 0, height: 0)).origin
    }

    static func resolvedDraftStrokeColor(for element: ScreenshotElement) -> NSColor {
        ScreenshotResolvedColor(
            element.appearance.strokeColor,
            opacity: element.appearance.opacity
        ).nsColor
    }

    private func drawTextDragPreview() {
        guard selectedTool == .text,
              let start = dragStart,
              let current = textDragCurrent,
              let sourceRect = ScreenshotTextDragPreviewGeometry.sourceRect(
                start: start,
                current: current,
                lineHeight: ScreenshotTextLayout(appearance: textStyle).lineHeight,
                minimumDrag: sourceUnitsPerViewPoint * 3
              ) else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: viewRect(from: sourceRect))
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func textDragPreviewViewRect(current: CGPoint?) -> CGRect? {
        guard let start = dragStart,
              let current,
              let sourceRect = ScreenshotTextDragPreviewGeometry.sourceRect(
                start: start,
                current: current,
                lineHeight: ScreenshotTextLayout(appearance: textStyle).lineHeight,
                minimumDrag: sourceUnitsPerViewPoint * 3
              ) else { return nil }
        return viewRect(from: sourceRect).insetBy(dx: -3, dy: -3)
    }

    private func invalidateTextDragPreview(previous: CGRect?) {
        let next = textDragPreviewViewRect(current: textDragCurrent)
        let dirtyRect = [previous, next]
            .compactMap { $0 }
            .reduce(CGRect.null) { $0.union($1) }
        guard !dirtyRect.isNull else { return }
        setNeedsDisplay(dirtyRect)
    }

    private func lineControlPoint(start: CGPoint, end: CGPoint, curvature: Double) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return start }
        let offset = length * curvature * 0.5
        return CGPoint(
            x: (start.x + end.x) / 2 - dy / length * offset,
            y: (start.y + end.y) / 2 + dx / length * offset
        )
    }

    static func draftTextRect(for element: ScreenshotElement) -> ScreenshotPixelRect? {
        switch element.geometry {
        case let .rect(value):
            value
        case let .callout(body, _):
            body
        case let .calloutComposite(_, note):
            note
        case let .step(_, note):
            note
        default:
            nil
        }
    }

    private func drawDraftText(_ element: ScreenshotElement, drawsBackground: Bool = true) {
        guard let rect = Self.draftTextRect(for: element) else { return }
        guard let text = element.text,
              !text.isEmpty else { return }
        let target = viewRect(from: rect.cgRect)
        let textAppearance = ScreenshotSemanticTextStyle.inlineAppearance(
            from: element.appearance,
            kind: element.kind
        )
        let layout = ScreenshotTextLayout(appearance: textAppearance)
        let metrics = layout.viewMetrics(sourceUnitsPerViewPoint: sourceUnitsPerViewPoint)
        let padding = CGFloat(layout.padding / max(sourceUnitsPerViewPoint, 0.001))
        if drawsBackground,
           case let .text(appearance) = textAppearance.payload,
           layout.backgroundColor != nil || appearance.backgroundBorderColor != nil {
            let radius = min(
                CGFloat(max(0, appearance.backgroundCornerRadius)) / max(sourceUnitsPerViewPoint, 0.001),
                min(target.width, target.height) / 2
            )
            let backgroundPath = NSBezierPath(
                roundedRect: target,
                xRadius: radius,
                yRadius: radius
            )
            if let background = layout.backgroundColor {
                NSColor(cgColor: background)?.setFill()
                backgroundPath.fill()
            }
            if let border = appearance.backgroundBorderColor,
               appearance.backgroundBorderWidth > 0 {
                ScreenshotResolvedColor(border, opacity: appearance.opacity).nsColor.setStroke()
                backgroundPath.lineWidth = max(
                    0.5,
                    CGFloat(appearance.backgroundBorderWidth) / max(sourceUnitsPerViewPoint, 0.001)
                )
                backgroundPath.stroke()
            }
        } else if drawsBackground, let background = layout.backgroundColor {
            NSColor(cgColor: background)?.setFill()
            target.fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = layout.alignment.nsAlignment
        paragraph.minimumLineHeight = CGFloat(metrics.lineHeight)
        paragraph.maximumLineHeight = CGFloat(metrics.lineHeight)
        paragraph.lineBreakMode = .byWordWrapping
        let font = NSFont(name: layout.fontName, size: CGFloat(metrics.fontSize))
            ?? .systemFont(ofSize: CGFloat(metrics.fontSize))
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: ScreenshotResolvedColor(
                    textAppearance.strokeColor,
                    opacity: textAppearance.opacity
                ).nsColor,
                .kern: CGFloat(metrics.characterSpacing),
                .paragraphStyle: paragraph,
            ]
        )
        attributed.draw(
            with: target.insetBy(dx: padding, dy: padding),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func drawOpticallyCenteredBadgeText(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: NSColor
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = ScreenshotBadgeTextLayout(
            text: text,
            fontSize: Double(max(1, fontSize))
        )
        let line = layout.makeLine(color: color.cgColor)
        let baseline = layout.baselineOrigin(
            inTopLeftRect: rect,
            canvasHeight: Double(bounds.height)
        )
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = baseline
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawLineEnding(
        _ ending: ScreenshotLineEnding,
        tip: CGPoint,
        other: CGPoint,
        width: CGFloat,
        color: NSColor,
        headScale: CGFloat = 1
    ) {
        guard ending != .none else { return }
        if ending == .circle {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: tip.x - max(4, width * 1.8),
                y: tip.y - max(4, width * 1.8),
                width: max(8, width * 3.6),
                height: max(8, width * 3.6)
            )).fill()
            return
        }
        let angle = atan2(tip.y - other.y, tip.x - other.x)
        let length = max(9, width * 4) * max(0.5, headScale)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - length * cos(angle - .pi / 7), y: tip.y - length * sin(angle - .pi / 7)))
        if ending == .openArrow {
            path.move(to: tip)
            path.line(to: CGPoint(x: tip.x - length * cos(angle + .pi / 7), y: tip.y - length * sin(angle + .pi / 7)))
            path.lineWidth = max(1, width)
            color.setStroke()
            path.stroke()
        } else {
            path.line(to: CGPoint(x: tip.x - length * cos(angle + .pi / 7), y: tip.y - length * sin(angle + .pi / 7)))
            path.close()
            color.setFill()
            path.fill()
        }
    }

    private func drawEditorBackdrop(in rect: CGRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
    }
}

struct ScreenshotCurvatureAnchorPulsePolicy: Equatable {
    let duration: TimeInterval
    let allowsSpatialMotion: Bool

    init(reduceMotion: Bool) {
        let motion = BlocksMotionRole.hoverFocus.policy(reduceMotion: reduceMotion)
        duration = motion.duration
        allowsSpatialMotion = motion.allowsSpatialMotion
    }

    func diameter(isHighlighted: Bool) -> CGFloat {
        isHighlighted && allowsSpatialMotion ? 18 : 14
    }
}

private extension ScreenshotColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

private extension ScreenshotResolvedColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

private extension ScreenshotPixelRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func contains(_ point: ScreenshotPixelPoint, tolerance: Double = 0) -> Bool {
        point.x >= Double(x) - tolerance
            && point.x <= Double(x + width) + tolerance
            && point.y >= Double(y) - tolerance
            && point.y <= Double(y + height) + tolerance
    }
}

private extension ScreenshotResizeHandle {
    var isCorner: Bool {
        switch self {
        case .northWest, .northEast, .southEast, .southWest:
            true
        case .north, .east, .south, .west:
            false
        }
    }
}

private extension ScreenshotTextAlignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

private extension ScreenshotEditorAccessibilityTarget {
    var isHandle: Bool {
        switch self {
        case .lineStart, .lineEnd, .resizeHandle, .stepResizeHandle, .calloutResizeHandle,
             .magnifierResizeHandle:
            true
        case .crop, .element, .stepComponent, .calloutComponent:
            false
        }
    }
}
