import AppKit
import BlocksScreenshotCore
import Combine
import OSLog

enum ScreenshotStepComponent: String, Equatable {
    case badge
    case connector
    case note
}
enum ScreenshotCalloutComponent: String, Equatable {
    case target
    case connector
    case note
}

typealias ScreenshotEditorOutputImageProcessor = @Sendable (
    CGImage,
    ScreenshotPixelRect,
    ScreenshotPixelRect,
    ScreenshotOutputAppearance
) throws -> CGImage

@MainActor
final class ScreenshotEditorStore: ObservableObject {
    private static let textLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "screenshot-text-session"
    )
    private struct SelectionBaseKey: Equatable {
        let elementID: UUID
        let visibleRect: ScreenshotPixelRect
        let revision: ScreenshotSceneRevision
    }

    private struct OutputImageRequest: Sendable {
        let image: CGImage
        let imageRect: ScreenshotPixelRect
        let outputRect: ScreenshotPixelRect
        let appearance: ScreenshotOutputAppearance
        let revision: ScreenshotSceneRevision
    }

    let document: ScreenshotSceneDocument
    let preferencesStore: ScreenshotPreferencesStore
    let notificationState: BlocksNotificationPresentationState
    let prefersLongImageViewport: Bool
    let allowsDirectImageCopy: Bool
    let allowsCropMove: Bool

    @Published private(set) var activeToolbarItemID: ScreenshotToolbarItemID = .select
    @Published var moreToolsPresentation = ScreenshotMoreToolsPresentationState()
    @Published private(set) var moreToolsTriggerFocusRequestID: UUID?
    @Published private(set) var selectedTool: ScreenshotEditorTool = .select {
        didSet {
            guard selectedTool != oldValue else { return }
            loadStyleForCurrentContext()
        }
    }
    @Published var renderedImage: NSImage
    @Published private(set) var renderedVisibleRect: ScreenshotPixelRect
    @Published private(set) var renderState: ScreenshotEditorRenderState = .idle
    @Published private(set) var isPresentationTransitioning = false
    @Published var activeStyle: ScreenshotElementAppearance
    @Published var viewport = ScreenshotEditorViewportState()
    @Published private(set) var selectedElementID: UUID?
    @Published private(set) var selectedStepComponent: ScreenshotStepComponent? {
        didSet {
            if let selectedElementID, let selectedStepComponent {
                recentStepComponents[selectedElementID] = selectedStepComponent
            }
        }
    }
    @Published private(set) var selectedCalloutComponent: ScreenshotCalloutComponent? {
        didSet {
            if let selectedElementID, let selectedCalloutComponent {
                recentCalloutComponents[selectedElementID] = selectedCalloutComponent
            }
        }
    }
    @Published private(set) var draftElement: ScreenshotElement?
    @Published private(set) var draftCropRect: ScreenshotPixelRect?
    @Published private(set) var cropConstraint: ScreenshotRegionConstraint
    @Published private(set) var interactionBaseImage: NSImage?
    @Published private(set) var isCloseConfirmationPresented = false
    @Published private(set) var isOutputPending = false
    @Published private(set) var activeOutputCommand: ScreenshotEditorOutputCommand?
    @Published private(set) var curvatureAnchorPulse = 0
    @Published private(set) var inlineTextEditRequestID = 0
    @Published private(set) var inlineTextEditElementID: UUID?

    private(set) var renderSubmissionCount = 0
    private(set) var stylePersistenceCount = 0

    private let outputCoordinator: ScreenshotEditorOutputCoordinator
    private let outputImageProcessor: ScreenshotEditorOutputImageProcessor
    private let onComplete: (NSImage) -> Void
    private let onPinned: (PinnedScreenshotPresentation) -> Void
    private let onSaved: (NSImage) -> Void
    private let onRetake: () -> Void
    private let onClose: () -> Void
    private let onRequestClose: () -> Void
    private let onElementCommitted: @MainActor (ScreenshotElement) -> Void
    private let closesAfterSuccessfulSave: Bool
    private let pinnedOutputPixelScale: CGFloat
    private let pinnedSourceFrame: CGRect
    private let pinnedCaptureScreenRect: CGRect
    private let pinsLongScreenshotFromCaptureTopEdge: Bool
    private let presentationVisibleFrame: (CGRect) -> CGRect
    private var preferencesCancellable: AnyCancellable?
    private var manualOCRCancellable: AnyCancellable?
    private var interaction: ScreenshotEditorInteraction?
    private var styleInteractionElementID: UUID?
    private var deferredStyleElementID: UUID?
    private var styleEditingOriginalAppearance: ScreenshotElementAppearance?
    private var styleEditingOriginalPreset: ScreenshotToolPreset?
    private var isStyleEditing = false
    private var watermarkInteractionElementID: UUID?
    private var isWatermarkEditing = false
    private var implicitWatermarkCommitTask: Task<Void, Never>?
    private var isLoadingStyle = false
    private let renderPipeline = ScreenshotRenderPipeline()
    private let selectionBasePipeline = ScreenshotRenderPipeline(category: "screenshot-selection-base")
    private let textEditingBasePipeline = ScreenshotRenderPipeline(category: "screenshot-text-base")
    private let sourceImageStorage: NSImage
    private var pendingInlineTextEditElementID: UUID?
    private var selectionBaseImage: NSImage?
    private var selectionBaseVisibleRect: ScreenshotPixelRect?
    private var selectionBaseElementID: UUID?
    private var selectionBaseRevision: ScreenshotSceneRevision?
    private var pendingSelectionBaseKey: SelectionBaseKey?
    private var effectPreviewInFlight = false
    private var effectPreviewPending = false
    private var implicitStyleCommitTask: Task<Void, Never>?
    private var activeHandleTolerance = 11.0
    private let initialSnapshot: ScreenshotSceneSnapshot
    private var renderedRevision: ScreenshotSceneRevision?
    private var pendingOutputGate = ScreenshotPendingOutputGate()
    private var outputTask: Task<Void, Never>?
    private var outputGeneration = 0
    private var isShutdown = false
    private struct HostOutputWaiter {
        let id: UUID
        let continuation: CheckedContinuation<ScreenshotEditorOutputExecutionResult, Never>
    }
    private var hostOutputWaiter: HostOutputWaiter?
    private var pendingReplacementCompletion: ((NSImage?) -> Void)?
    private let manualOCRCoordinator: ScreenshotManualOCRCoordinator
    private var manualOCROutputTask: Task<Void, Never>?
    private var manualOCROutputGeneration = 0
    private var manualOCRStartPoint: ScreenshotPixelPoint?
    private var pendingManualOCRRegion: ScreenshotPixelRect?
    private var nextCounterNumber = 1
    private var recentStepComponents: [UUID: ScreenshotStepComponent] = [:]
    private var recentCalloutComponents: [UUID: ScreenshotCalloutComponent] = [:]
    private var overlapCycleIDs: [UUID] = []
    private var overlapCycleIndex = 0
    private var pendingObjectDrag: (
        elementID: UUID,
        start: ScreenshotPixelPoint,
        stepComponent: ScreenshotStepComponent?,
        calloutComponent: ScreenshotCalloutComponent?
    )?
    private var activeSourceUnitsPerViewPoint = 1.0
    private var curvatureGestureAnchor: ScreenshotCurvatureAnchor?
    private var curvaturePropertyAnchor: ScreenshotCurvatureAnchor?
    private let curvatureAnchorFeedback: () -> Void

    init(
        capture: ScreenshotCapture,
        preferencesStore: ScreenshotPreferencesStore,
        onComplete: @escaping (NSImage) -> Void,
        onPinned: ((PinnedScreenshotPresentation) -> Void)? = nil,
        onSaved: ((NSImage) -> Void)? = nil,
        onRetake: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onRequestClose: (() -> Void)? = nil,
        presentationWindow: @escaping () -> NSWindow? = { nil },
        outputCoordinator: ScreenshotEditorOutputCoordinator? = nil,
        outputSerializationGate: ScreenshotOutputSerialGate? = nil,
        outputImageProcessor: @escaping ScreenshotEditorOutputImageProcessor = {
            try ScreenshotOutputProcessor.process(
                image: $0,
                imageRect: $1,
                outputRect: $2,
                appearance: $3
            )
        },
        ocrCoordinator: LocalOCRCoordinator? = nil,
        ocrService: LocalVisionOCRService? = nil,
        onElementCommitted: @escaping @MainActor (ScreenshotElement) -> Void = { _ in },
        onOCRCompleted: @escaping ScreenshotManualOCRCoordinator.Completion = { _, _, _, _ in },
        curvatureAnchorFeedback: @escaping () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    ) throws {
        guard let editingContext = capture.editingContext,
              editingContext.supportsRangeExpansion || capture.defersOutputUntilEditorCompletion else {
            throw ScreenshotEditorError.editingContextUnavailable
        }
        guard capture.image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            throw ScreenshotEditorError.missingCGImage
        }
        let sourceContext = editingContext.sourceContext
        let initialCrop = editingContext.initialCropRect
        pinnedOutputPixelScale = PinnedScreenshotGeometry.outputPixelScale(
            initialCropRect: initialCrop,
            sourceRect: capture.sourceRect
        )
        pinnedSourceFrame = editingContext.sourceFrame
        pinnedCaptureScreenRect = capture.sourceRect
        pinsLongScreenshotFromCaptureTopEdge = capture.defersOutputUntilEditorCompletion
        presentationVisibleFrame = { preferredFrame in
            let fallback = presentationWindow()?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            return PinnedScreenshotGeometry.targetVisibleFrame(
                for: preferredFrame,
                screens: NSScreen.screens.map {
                    PinnedScreenshotGeometry.ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame)
                },
                fallback: fallback
            )
        }
        cropConstraint = editingContext.initialRegionConstraint
        let initialWatermarkElements: [ScreenshotElement]
        if let presetID = capture.watermarkPresetID,
           let preset = preferencesStore.preferences.watermarkPresets.first(where: { $0.id == presetID }) {
            initialWatermarkElements = [ScreenshotElement(
                kind: .watermark,
                geometry: .rect(initialCrop),
                watermark: ScreenshotWatermarkInstance(
                    presetID: preset.id,
                    name: preset.name,
                    style: preset.style
                )
            )]
        } else {
            initialWatermarkElements = []
        }
        document = ScreenshotSceneDocument(
            sourceContext: sourceContext,
            snapshot: ScreenshotSceneSnapshot(
                cropRect: initialCrop,
                elements: initialWatermarkElements
            )
        )
        initialSnapshot = document.snapshot
        self.preferencesStore = preferencesStore
        notificationState = BlocksNotificationPresentationState()
        self.curvatureAnchorFeedback = curvatureAnchorFeedback
        prefersLongImageViewport = capture.defersOutputUntilEditorCompletion
        allowsDirectImageCopy = !capture.defersOutputUntilEditorCompletion
        allowsCropMove = capture.kind == .region
            && editingContext.supportsRangeExpansion
            && !capture.defersOutputUntilEditorCompletion
        closesAfterSuccessfulSave = capture.defersOutputUntilEditorCompletion
        let resolvedOCRCoordinator = ocrCoordinator
            ?? LocalOCRCoordinator(service: ocrService ?? LocalVisionOCRService())
        manualOCRCoordinator = ScreenshotManualOCRCoordinator(
            onCompleted: onOCRCompleted
        ) { image in
            try await resolvedOCRCoordinator.recognizeText(
                in: image,
                context: .editorRegion
            ).text
        }
        self.outputCoordinator = outputCoordinator ?? ScreenshotEditorOutputCoordinator(
            preferencesStore: preferencesStore,
            presentationWindow: presentationWindow,
            serializationGate: outputSerializationGate ?? .init()
        )
        self.outputImageProcessor = outputImageProcessor
        activeStyle = preferencesStore.preferences.toolPresets[.select]?.appearance
            ?? ScreenshotElementAppearance.defaultValue(for: .select)
        let sourceImage = NSImage(
            cgImage: sourceContext.compositeSource,
            size: NSSize(
                width: sourceContext.compositeSource.width,
                height: sourceContext.compositeSource.height
            )
        )
        sourceImageStorage = sourceImage
        renderedImage = sourceImage
        renderedVisibleRect = sourceContext.sourceBounds
        self.onComplete = onComplete
        self.onPinned = onPinned ?? { onComplete($0.image) }
        self.onSaved = onSaved ?? onComplete
        self.onRetake = onRetake
        self.onClose = onClose
        self.onRequestClose = onRequestClose ?? onClose
        self.onElementCommitted = onElementCommitted
        if initialSnapshot.elements.isEmpty,
           initialSnapshot.cropRect == sourceContext.sourceBounds {
            renderedRevision = document.renderRevision
            renderState = .idle
        } else {
            refreshRender()
        }
        preferencesCancellable = preferencesStore.$preferences.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        manualOCRCancellable = manualOCRCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isDirty: Bool { document.snapshot != initialSnapshot }
    var cropAspectRatio: Double? { cropConstraint.aspectRatio }
    var cropConstraintTitle: String? {
        switch cropConstraint {
        case .free:
            return nil
        case let .ratio(width, height):
            return Self.formattedAspectRatio(width / height)
        case let .fixedPixels(width, height):
            return "\(width)×\(height)"
        }
    }
    var aspectOrientation: ScreenshotAspectOrientation {
        guard let ratio = cropAspectRatio else { return .landscape }
        return ratio >= 1 ? .landscape : .portrait
    }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var visibleQuickToolbarItems: [ScreenshotToolbarItemID] {
        preferencesStore.preferences.visibleQuickToolbarItemIDs
    }
    var visibleExtendedToolbarItems: [ScreenshotToolbarItemID] {
        preferencesStore.preferences.visibleExtendedToolbarItemIDs
    }
    var hiddenToolbarItems: [ScreenshotToolbarItemID] { preferencesStore.preferences.hiddenToolIDs }
    var watermarkPresets: [ScreenshotWatermarkPreset] { preferencesStore.preferences.watermarkPresets }
    var appliedWatermarkElements: [ScreenshotElement] {
        document.presentedSnapshot.elements.filter { $0.kind == .watermark }
    }
    var isRoundedOutput: Bool { document.presentedSnapshot.outputAppearance.isRounded }
    var pendingOutputCommand: ScreenshotEditorOutputCommand? { pendingOutputGate.pending }
    var currentOutputCommand: ScreenshotEditorOutputCommand? {
        activeOutputCommand ?? pendingOutputGate.pending
    }
    var selectedElement: ScreenshotElement? {
        guard let selectedElementID else { return nil }
        return document.presentedSnapshot.elements.first(where: { $0.id == selectedElementID })
    }
    var inspectorTool: ScreenshotEditorTool { selectedElement?.kind.tool ?? selectedTool }
    var cropRect: ScreenshotPixelRect { document.presentedSnapshot.cropRect }
    var pluginSceneSnapshot: ScreenshotSceneSnapshot { document.presentedSnapshot }
    var sourceBounds: ScreenshotPixelRect { document.sourceContext.sourceBounds }
    var sourceImage: NSImage { sourceImageStorage }
    var canvasImage: NSImage { renderedImage }
    var canvasVisibleRect: ScreenshotPixelRect { renderedVisibleRect }
    var canvasInputEnabled: Bool {
        !isPresentationTransitioning
            && !isCloseConfirmationPresented
            && !isOutputPending
            && !manualOCRCoordinator.state.isLocked
            && (interaction != nil || renderedVisibleRect == previewVisibleRect)
    }
    var manualOCRState: ScreenshotManualOCRState { manualOCRCoordinator.state }
    var manualOCRRegion: ScreenshotPixelRect? {
        switch manualOCRCoordinator.state {
        case let .selecting(region),
             let .recognizing(_, region, _),
             let .result(_, region, _, _),
             let .failed(_, region, _, _):
            region
        case .idle:
            nil
        }
    }

    func setPresentationTransitioning(_ transitioning: Bool) {
        isPresentationTransitioning = transitioning
    }

    func setCloseConfirmationPresented(_ presented: Bool) {
        isCloseConfirmationPresented = presented
    }

    func setFinalizingOutput(_ finalizing: Bool) {
        isOutputPending = finalizing
    }

    func setViewport(zoomScale: CGFloat, panOffset: CGSize) {
        viewport.zoomScale = min(8, max(0.1, zoomScale))
        viewport.panOffset = panOffset
    }

    func resetViewport() { viewport = ScreenshotEditorViewportState() }

    func selectTool(_ tool: ScreenshotEditorTool) {
        switch manualOCRCoordinator.state {
        case .selecting, .recognizing:
            cancelManualOCR()
        case .idle, .result, .failed:
            break
        }
        activeToolbarItemID = tool.toolbarItemID
        let previousPreviewRect = previewVisibleRect
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        pendingObjectDrag = nil
        invalidateSelectionBase()
        selectedTool = tool
        if previewVisibleRect != previousPreviewRect { refreshRender() }
    }

    func selectToolbarItem(_ item: ScreenshotToolbarItemID) {
        if let tool = item.editorTool {
            selectTool(tool)
            return
        }
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        cancelGesture()
        selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        invalidateSelectionBase()
        selectedTool = .select
        activeToolbarItemID = item
    }

    func selectElement(_ id: UUID) {
        guard let element = document.presentedSnapshot.elements.first(where: { $0.id == id }) else { return }
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        selectedElementID = id
        selectedStepComponent = element.kind == .step
            ? (recentStepComponents[id] ?? .badge)
            : nil
        selectedCalloutComponent = element.kind == .callout
            ? (recentCalloutComponents[id] ?? defaultCalloutComponent(for: element))
            : nil
        pendingObjectDrag = nil
        activeStyle = element.appearance
        prepareSelectionBase(for: id)
    }

    func selectStepComponent(_ id: UUID, component: ScreenshotStepComponent) {
        guard let element = document.presentedSnapshot.elements.first(where: {
            $0.id == id && $0.kind == .step
        }) else { return }
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        selectedElementID = id
        selectedStepComponent = component
        selectedCalloutComponent = nil
        pendingObjectDrag = nil
        activeStyle = element.appearance
        prepareSelectionBase(for: id)
    }

    func selectCalloutComponent(_ id: UUID, component: ScreenshotCalloutComponent) {
        guard let element = document.presentedSnapshot.elements.first(where: {
            $0.id == id && $0.kind == .callout
        }) else { return }
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        selectedElementID = id
        selectedStepComponent = nil
        selectedCalloutComponent = component
        pendingObjectDrag = nil
        activeStyle = element.appearance
        prepareSelectionBase(for: id)
    }

    @discardableResult
    func cycleSelectedStepComponent(backward: Bool) -> Bool {
        guard let selectedElement,
              selectedElement.kind == .step,
              let layout = ScreenshotStepResolvedLayout(element: selectedElement),
              layout.noteRect != nil else { return false }
        selectedStepComponent = switch (selectedStepComponent, backward) {
        case (.badge, false), (.none, false), (.note, true): .connector
        case (.connector, false): .note
        case (.note, false): .badge
        case (.badge, true), (.none, true): .note
        case (.connector, true): .badge
        }
        return true
    }

    @discardableResult
    func cycleSelectedCalloutComponent(backward: Bool) -> Bool {
        guard let selectedElement,
              selectedElement.kind == .callout,
              let layout = ScreenshotCalloutResolvedLayout(element: selectedElement) else { return false }
        let components: [ScreenshotCalloutComponent] = layout.targetRect == nil
            ? [.connector, .note]
            : [.target, .connector, .note]
        let current = selectedCalloutComponent ?? components[0]
        let currentIndex = components.firstIndex(of: current) ?? 0
        let offset = backward ? -1 : 1
        selectedCalloutComponent = components[(currentIndex + offset + components.count) % components.count]
        return true
    }

    func requestInlineTextEditing(_ elementID: UUID) {
        guard let element = document.presentedSnapshot.elements.first(where: {
            $0.id == elementID && [.text, .callout, .step].contains($0.kind)
        }) else { return }
        logTextElement(element, stage: "inline-edit-request")
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
        cancelGesture()
        selectedElementID = elementID
        selectedStepComponent = element.kind == .step ? .note : nil
        selectedCalloutComponent = element.kind == .callout ? .note : nil
        activeStyle = element.appearance
        pendingInlineTextEditElementID = elementID
        prepareSelectionBase(for: elementID)
        prepareTextEditingBase(for: elementID)
    }

    func endInlineTextEditing() {
        if let elementID = inlineTextEditElementID ?? pendingInlineTextEditElementID,
           let element = document.presentedSnapshot.elements.first(where: { $0.id == elementID }) {
            logTextElement(element, stage: "inline-edit-end")
        }
        textEditingBasePipeline.cancel()
        pendingInlineTextEditElementID = nil
        inlineTextEditElementID = nil
        interactionBaseImage = nil
    }

    func adjustAccessibilityTarget(
        _ target: ScreenshotEditorAccessibilityTarget,
        dx: Double,
        dy: Double
    ) {
        finishPropertyEditing()
        let elementID: UUID
        switch target {
        case .crop:
            guard allowsCropMove else { return }
            let allowed = sourceBounds
            let translated = ScreenshotGeometry.translateWithinBounds(
                .rect(cropRect),
                dx: dx,
                dy: dy,
                bounds: allowed
            )
            guard case let .rect(nextCrop) = translated else { return }
            _ = document.setCropRect(nextCrop)
            refreshRender()
            return
        case let .element(id),
             let .lineStart(id),
             let .lineEnd(id),
             let .resizeHandle(id, _),
             let .magnifierResizeHandle(id, _):
            elementID = id
        case let .stepComponent(id, component), let .stepResizeHandle(id, component, _):
            elementID = id
            selectStepComponent(id, component: component)
        case let .calloutComponent(id, component), let .calloutResizeHandle(id, component, _):
            elementID = id
            selectCalloutComponent(id, component: component)
        }
        if case .stepComponent = target {
            // Selection was established above with the requested subcomponent.
        } else if case .stepResizeHandle = target {
            // Selection was established above with the requested subcomponent.
        } else {
            selectElement(elementID)
        }
        guard let element = selectedElement else { return }
        _ = document.updateElement(id: elementID) { next in
            switch (target, element.geometry) {
            case (.element, _):
                next.geometry = translatedGeometry(of: element, dx: dx, dy: dy)
            case let (.lineStart, .line(start, end)):
                next.geometry = ScreenshotGeometry.clamp(
                    .line(start: .init(x: start.x + dx, y: start.y + dy), end: end),
                    to: sourceBounds
                )
            case let (.lineEnd, .line(start, end)):
                next.geometry = ScreenshotGeometry.clamp(
                    .line(start: start, end: .init(x: end.x + dx, y: end.y + dy)),
                    to: sourceBounds
                )
            case let (.resizeHandle(_, handle), .rect(rect)):
                let point = accessibilityHandlePoint(handle, in: rect)
                let destination = ScreenshotPixelPoint(x: point.x + dx, y: point.y + dy)
                let resized = ScreenshotGeometry.resize(
                    rect,
                    handle: handle,
                    to: destination,
                    constrainedTo: next.kind == .text ? cropRect : sourceBounds
                )
                if next.kind == .text {
                    next.textBoxSizing = .fixedBox
                    normalizeTextElement(&next, proposedRect: resized.cgRect)
                } else {
                    next.geometry = .rect(resized)
                }
            case let (.stepComponent(_, component), .step):
                next = translatingStepComponent(component, of: element, dx: dx, dy: dy)
            case let (.stepResizeHandle(_, .badge, handle), .step):
                guard let layout = ScreenshotStepResolvedLayout(element: element) else { return }
                let point = accessibilityHandlePoint(handle, in: layout.badgeRect)
                let resize = anchoredSquareResize(
                    layout.badgeRect,
                    handle: handle,
                    to: .init(x: point.x + dx, y: point.y + dy),
                    minimumDiameter: 18,
                    maximumDiameter: 160
                )
                var stepAppearance = next.appearance.stepAppearance
                stepAppearance.badgeSize = resize.diameter
                next.appearance.stepAppearance = stepAppearance
                let rawNote: ScreenshotPixelRect?
                if case let .step(_, note) = element.geometry {
                    rawNote = note
                } else {
                    return
                }
                let center = ScreenshotStepResolvedLayout.constrainedBadgeCenter(
                    resize.center,
                    badgeDiameter: resize.diameter,
                    noteRect: nil,
                    gap: stepAppearance.gap,
                    constrainedTo: cropRect
                )
                next.geometry = .step(badgeCenter: center, note: rawNote)
            case let (.stepResizeHandle(_, .note, handle), .step):
                guard let layout = ScreenshotStepResolvedLayout(element: element),
                      let note = layout.noteRect else { return }
                let point = accessibilityHandlePoint(handle, in: note)
                let resized = ScreenshotGeometry.resize(
                    note,
                    handle: handle,
                    to: .init(x: point.x + dx, y: point.y + dy),
                    constrainedTo: cropRect
                )
                next = resizedStepNote(element, to: resized, handle: handle)
            case let (.calloutComponent(_, component), .calloutComposite):
                next = translatingCalloutComponent(component, of: element, dx: dx, dy: dy)
            case let (.calloutResizeHandle(_, .target, handle), .calloutComposite):
                guard let targetRect = ScreenshotCalloutResolvedLayout(element: element)?.targetRect else { return }
                let handlePoint = accessibilityHandlePoint(handle, in: targetRect)
                next = resizedCalloutTarget(element, handle: handle, to: .init(
                    x: handlePoint.x + dx,
                    y: handlePoint.y + dy
                ))
            case let (.calloutResizeHandle(_, .note, handle), .calloutComposite):
                guard let noteRect = ScreenshotCalloutResolvedLayout(element: element)?.noteRect else { return }
                let handlePoint = accessibilityHandlePoint(handle, in: noteRect)
                next = resizedCalloutNote(element, handle: handle, to: .init(
                    x: handlePoint.x + dx,
                    y: handlePoint.y + dy
                ))
            case let (.magnifierResizeHandle(_, handle), .magnifier):
                let lens = magnifierLensRect(for: element)
                let point = accessibilityHandlePoint(handle, in: lens)
                let resize = anchoredSquareResize(
                    lens,
                    handle: handle,
                    to: .init(x: point.x + dx, y: point.y + dy),
                    minimumDiameter: ScreenshotMagnifierMetrics.minimumDiameter,
                    maximumDiameter: ScreenshotMagnifierMetrics.maximumDiameter,
                    constrainedTo: cropRect
                )
                next.appearance.magnifierDiameter = resize.diameter
                next.geometry = .magnifier(center: resize.center)
            default:
                break
            }
        }
        if let updated = document.presentedSnapshot.elements.first(where: { $0.id == elementID }) {
            activeStyle = updated.appearance
        }
        refreshRender()
    }

    func handleEscape() {
        if moreToolsPresentation.isPresented {
            var presentation = moreToolsPresentation
            presentation.handle(.escape)
            moreToolsPresentation = presentation
            requestMoreToolsTriggerFocus()
            return
        }
        onRequestClose()
    }

    func requestMoreToolsTriggerFocus() {
        moreToolsTriggerFocusRequestID = UUID()
    }

    func recordRecentColor(_ color: ScreenshotColor) {
        preferencesStore.recordRecentColor(color)
    }

    func toggleRoundedOutput() {
        let next = ScreenshotOutputAppearance(isRounded: !document.snapshot.outputAppearance.isRounded)
        guard document.setOutputAppearance(next) else { return }
        // The editable source preview remains rectangular. The canvas draws the
        // crop-corner preview, while final copy/save/history share the Core mask.
        reuseRenderedPreviewForCropRevision()
    }

    @discardableResult
    func applyWatermark(
        _ preset: ScreenshotWatermarkPreset,
        replacing elementID: UUID? = nil
    ) -> UUID? {
        if isWatermarkEditing { endWatermarkEditing() }
        let text = preset.style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            presentNotification(
                level: .warning,
                title: L10n.string("screenshot.watermark.error.emptyContent"),
                deduplicationKey: "screenshot.watermark.empty"
            )
            return nil
        }
        var normalized = preset
        normalized.style.text = text
        return applyPreparedWatermark(normalized, replacing: elementID)
    }

    @discardableResult
    func applyWatermarkAsync(
        _ preset: ScreenshotWatermarkPreset,
        replacing elementID: UUID? = nil
    ) async -> UUID? {
        guard !Task.isCancelled else { return nil }
        return applyWatermark(preset, replacing: elementID)
    }

    private func applyPreparedWatermark(
        _ preset: ScreenshotWatermarkPreset,
        replacing elementID: UUID?
    ) -> UUID? {
        let instance = ScreenshotWatermarkInstance(
            presetID: preset.id,
            name: preset.name,
            style: preset.style
        )

        let resolvedID: UUID
        if let elementID {
            let currentCrop = document.presentedSnapshot.cropRect
            guard document.updateElement(id: elementID, { element in
                guard element.kind == .watermark else { return }
                element.watermark = instance
                element.geometry = .rect(currentCrop)
            }) else { return nil }
            resolvedID = elementID
        } else {
            let element = ScreenshotElement(
                kind: .watermark,
                geometry: .rect(cropRect),
                watermark: instance
            )
            guard document.add(element) else { return nil }
            resolvedID = element.id
        }
        selectedElementID = resolvedID
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        activeToolbarItemID = .watermark
        selectedTool = .watermark
        invalidateSelectionBase()
        refreshRender()
        return resolvedID
    }

    func watermarkDraft(for elementID: UUID) -> ScreenshotWatermarkPreset? {
        guard let element = document.presentedSnapshot.elements.first(where: {
            $0.id == elementID && $0.kind == .watermark
        }), let instance = element.watermark else { return nil }
        return ScreenshotWatermarkPreset(
            id: instance.presetID ?? UUID(),
            name: instance.name,
            style: instance.style
        )
    }

    func selectOrCreateWatermark() {
        if let existing = document.presentedSnapshot.elements.last(where: { $0.kind == .watermark }) {
            selectElement(existing.id)
            activeToolbarItemID = .watermark
            selectedTool = .watermark
            return
        }
        let preferences = preferencesStore.preferences
        let preset = preferences.captureDefaults.watermarkPresetID.flatMap { id in
            preferences.watermarkPresets.first(where: { $0.id == id })
        } ?? ScreenshotWatermarkPreset(
            name: L10n.string("screenshot.watermark.defaultName"),
            style: ScreenshotWatermarkStyle(text: L10n.string("screenshot.watermark.defaultText"))
        )
        _ = applyWatermark(preset)
    }

    var selectedWatermark: ScreenshotWatermarkInstance? {
        guard selectedElement?.kind == .watermark else { return nil }
        return selectedElement?.watermark
    }

    func beginWatermarkEditing() {
        implicitWatermarkCommitTask?.cancel()
        implicitWatermarkCommitTask = nil
        guard !isWatermarkEditing,
              let id = selectedElementID,
              selectedElement?.kind == .watermark else { return }
        if isStyleEditing { endStyleEditing() }
        guard interaction == nil, document.beginInteraction() else { return }
        isWatermarkEditing = true
        watermarkInteractionElementID = id
    }

    func updateSelectedWatermark(_ mutation: (inout ScreenshotWatermarkStyle) -> Void) {
        let usesImplicitTransaction = !isWatermarkEditing
        if usesImplicitTransaction { beginWatermarkEditing() }
        guard let id = selectedElementID,
              watermarkInteractionElementID == id,
              document.updateInteraction({ snapshot in
                  guard let index = snapshot.elements.firstIndex(where: { $0.id == id }) else { return }
                  var element = snapshot.elements[index]
                  guard var watermark = element.watermark else { return }
                  var style = watermark.style
                  mutation(&style)
                  watermark.style = ScreenshotWatermarkStyle(
                      text: style.text,
                      color: style.color,
                      weight: style.weight,
                      fontSizeFraction: style.fontSizeFraction,
                      density: style.density,
                      angleDegrees: style.angleDegrees,
                      opacity: style.opacity
                  )
                  element.watermark = watermark
                  snapshot.elements[index] = element
              }) else { return }
        invalidateSelectionBase()
        refreshRender()
        if usesImplicitTransaction { scheduleImplicitWatermarkCommit() }
    }

    func endWatermarkEditing() {
        implicitWatermarkCommitTask?.cancel()
        implicitWatermarkCommitTask = nil
        guard isWatermarkEditing else { return }
        isWatermarkEditing = false
        watermarkInteractionElementID = nil
        _ = document.commitInteraction()
        invalidateSelectionBase()
        refreshRender()
    }

    func cancelWatermarkEditing() {
        implicitWatermarkCommitTask?.cancel()
        implicitWatermarkCommitTask = nil
        guard isWatermarkEditing else { return }
        isWatermarkEditing = false
        watermarkInteractionElementID = nil
        _ = document.cancelInteraction()
        invalidateSelectionBase()
        refreshRender()
    }

    private func scheduleImplicitWatermarkCommit() {
        implicitWatermarkCommitTask?.cancel()
        implicitWatermarkCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.endWatermarkEditing()
        }
    }

    func saveSelectedWatermarkPreset(name: String) -> Bool {
        guard let watermark = selectedWatermark else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        let preset = ScreenshotWatermarkPreset(
            id: watermark.presetID ?? UUID(),
            name: trimmedName,
            style: watermark.style
        )
        preferencesStore.saveWatermarkPreset(preset)
        if let id = selectedElementID {
            _ = document.updateElement(id: id) { element in
                element.watermark?.presetID = preset.id
                element.watermark?.name = preset.name
            }
        }
        return true
    }

    func applyAspectSelection(_ selection: ScreenshotAspectSelection) {
        let resolved = selection.resolvedConstraint
        cropConstraint = resolved
        let current = cropRect
        let bounds = sourceBounds
        let target: (width: Double, height: Double)
        switch resolved {
        case .free:
            return
        case let .ratio(width, height):
            let ratio = width / height
            let area = max(4, Double(current.width * current.height))
            let proposedWidth = sqrt(area * ratio)
            target = (proposedWidth, proposedWidth / ratio)
        case let .fixedPixels(width, height):
            target = (Double(width), Double(height))
        }
        let scale = min(
            1,
            Double(bounds.width) / max(1, target.width),
            Double(bounds.height) / max(1, target.height)
        )
        let width = target.width * scale
        let height = target.height * scale
        let centerX = Double(current.x) + Double(current.width) / 2
        let centerY = Double(current.y) + Double(current.height) / 2
        let proposed = ScreenshotPixelRect(
            x: Int((centerX - width / 2).rounded()),
            y: Int((centerY - height / 2).rounded()),
            width: max(2, Int(width.rounded())),
            height: max(2, Int(height.rounded()))
        )
        let next = ScreenshotGeometry.clamp(proposed, to: bounds)
        guard document.setCropRect(next) else { return }
        refreshPreviewAfterCropRevision()
    }

    func clearCropConstraint() {
        guard cropConstraint != .free else { return }
        cropConstraint = .free
    }

    @discardableResult
    func beginGesture(
        at point: CGPoint,
        sourceUnitsPerViewPoint: Double = 1,
        modifiers: NSEvent.ModifierFlags,
        allowsPersistentCropHandles: Bool = false
    ) -> ScreenshotCanvasGestureDisposition {
        guard interaction == nil else { return .handled }
        activeSourceUnitsPerViewPoint = max(1, sourceUnitsPerViewPoint)
        activeHandleTolerance = 11 * activeSourceUnitsPerViewPoint
        let sourcePoint = point.pixelPoint
        if activeToolbarItemID == .ocr {
            let clamped = clampedManualOCRPoint(sourcePoint)
            manualOCRStartPoint = clamped
            manualOCRCoordinator.beginSelection(at: clamped)
            return .handled
        }
        let forcesCreation = modifiers.contains(.option) && selectedTool != .select
        if !forcesCreation,
           beginSelectedElementHandleGestureIfNeeded(at: sourcePoint) {
            return .handled
        }
        // Selected object handles win over the persistent crop handles. Option-drag
        // bypasses both so a new object can still start at the crop boundary.
        let currentCrop = document.snapshot.cropRect
        if allowsPersistentCropHandles,
           !forcesCreation,
           let handle = ScreenshotGeometry.hitTestHandle(
               sourcePoint,
               rect: currentCrop,
               tolerance: handleTolerance
           ), document.beginInteraction() {
            interaction = .cropResize(original: currentCrop, handle: handle)
            interactionBaseImage = canvasImage
            draftCropRect = currentCrop
            return .handled
        }
        if !forcesCreation, beginSelectionGesture(at: sourcePoint, modifiers: modifiers) {
            return .handled
        }
        if selectedTool == .select,
           allowsCropMove,
           document.snapshot.cropRect.contains(sourcePoint),
           document.beginInteraction() {
            let crop = document.snapshot.cropRect
            interaction = .cropMove(original: crop, start: sourcePoint)
            interactionBaseImage = canvasImage
            draftCropRect = crop
            selectedElementID = nil
            selectedStepComponent = nil
            selectedCalloutComponent = nil
            invalidateSelectionBase()
            return .handled
        }
        if selectedTool == .select {
            selectedElementID = nil
            selectedStepComponent = nil
            selectedCalloutComponent = nil
            invalidateSelectionBase()
            return .handled
        }
        if selectedTool == .text { return .beginTextCreation }
        guard
              let element = makeElement(start: sourcePoint, current: sourcePoint, points: [sourcePoint], modifiers: modifiers),
              document.beginInteraction() else { return .handled }
        interaction = .creating(elementID: element.id, start: sourcePoint)
        interactionBaseImage = canvasImage
        selectedElementID = element.id
        selectedStepComponent = element.kind == .step ? .badge : nil
        selectedCalloutComponent = element.kind == .callout
            ? defaultCalloutComponent(for: element)
            : nil
        activeStyle = element.appearance
        _ = document.updateInteraction { $0.elements.append(element) }
        draftElement = element
        return .handled
    }

    func updateGesture(
        to point: CGPoint,
        points: [CGPoint],
        modifiers: NSEvent.ModifierFlags
    ) {
        let current = point.pixelPoint
        if activeToolbarItemID == .ocr, let start = manualOCRStartPoint {
            manualOCRCoordinator.updateSelection(
                from: start,
                to: clampedManualOCRPoint(current)
            )
            return
        }
        if interaction == nil { beginPendingObjectDragIfReady() }
        guard let interaction else { return }
        switch interaction {
        case let .creating(id, start):
            guard let next = makeElement(
                id: id,
                start: start,
                current: current,
                points: points.map(\.pixelPoint),
                modifiers: modifiers
            ) else { return }
            _ = document.updateInteraction { snapshot in
                guard let index = snapshot.elements.firstIndex(where: { $0.id == id }) else { return }
                snapshot.elements[index] = next
            }
            draftElement = next
            if next.kind == .magnifier {
                activeStyle = next.appearance
            }
        case let .moving(id, start, original):
            let dx = current.x - start.x
            let dy = current.y - start.y
            var next = original
            next.geometry = translatedGeometry(of: original, dx: dx, dy: dy)
            updateDraftElement(next, id: id)
        case let .movingStepComponent(id, start, original, component):
            let dx = current.x - start.x
            let dy = current.y - start.y
            let next = translatingStepComponent(component, of: original, dx: dx, dy: dy)
            if component == .connector { activeStyle = next.appearance }
            updateDraftElement(next, id: id)
        case let .movingCalloutComponent(id, start, original, component):
            let dx = current.x - start.x
            let dy = current.y - start.y
            let next = translatingCalloutComponent(component, of: original, dx: dx, dy: dy)
            if component == .connector { activeStyle = next.appearance }
            updateDraftElement(next, id: id)
        case let .resizing(id, original, handle):
            var next = original
            switch original.geometry {
            case let .rect(rect):
                let resized = ScreenshotGeometry.resize(
                    rect,
                    handle: handle,
                    to: current,
                    constrainedTo: next.kind == .text ? cropRect : sourceBounds
                )
                if next.kind == .text {
                    next.textBoxSizing = .fixedBox
                    normalizeTextElement(&next, proposedRect: resized.cgRect)
                } else {
                    next.geometry = .rect(resized)
                }
            case let .callout(body, pointer):
                let resized = ScreenshotGeometry.resize(
                    body,
                    handle: handle,
                    to: current,
                    constrainedTo: cropRect
                )
                next.textBoxSizing = .fixedBox
                next.geometry = .callout(body: resized, pointer: pointer)
                normalizeTextElement(&next, proposedRect: resized.cgRect)
            case let .calloutComposite(target, note):
                let resized = ScreenshotGeometry.resize(
                    note,
                    handle: handle,
                    to: current,
                    constrainedTo: cropRect
                )
                next.textBoxSizing = .fixedBox
                next.geometry = .calloutComposite(target: target, note: resized)
                normalizeTextElement(&next, proposedRect: resized.cgRect)
            default:
                return
            }
            updateDraftElement(next, id: id)
        case let .resizingStepBadge(id, original, handle):
            guard case let .step(_, rawNote) = original.geometry,
                  let layout = ScreenshotStepResolvedLayout(element: original) else { return }
            let resize = anchoredSquareResize(
                layout.badgeRect,
                handle: handle,
                to: current,
                minimumDiameter: 18,
                maximumDiameter: 160
            )
            var next = original
            var stepAppearance = next.appearance.stepAppearance
            stepAppearance.badgeSize = resize.diameter
            next.appearance.stepAppearance = stepAppearance
            next.geometry = .step(
                badgeCenter: ScreenshotStepResolvedLayout.constrainedBadgeCenter(
                    resize.center,
                    badgeDiameter: resize.diameter,
                    noteRect: nil,
                    gap: stepAppearance.gap,
                    constrainedTo: cropRect
                ),
                note: rawNote
            )
            activeStyle = next.appearance
            updateDraftElement(next, id: id)
        case let .resizingStepNote(id, original, handle):
            guard let layout = ScreenshotStepResolvedLayout(element: original),
                  let note = layout.noteRect else { return }
            let resized = ScreenshotGeometry.resize(
                note,
                handle: handle,
                to: current,
                constrainedTo: cropRect
            )
            let next = resizedStepNote(original, to: resized, handle: handle)
            updateDraftElement(next, id: id)
        case let .resizingCalloutTarget(id, original, handle):
            let next = resizedCalloutTarget(original, handle: handle, to: current)
            updateDraftElement(next, id: id)
        case let .resizingCalloutNote(id, original, handle):
            let next = resizedCalloutNote(original, handle: handle, to: current)
            updateDraftElement(next, id: id)
        case let .resizingMagnifier(id, original, handle):
            guard case .magnifier = original.geometry else { return }
            let lens = magnifierLensRect(for: original)
            let resize = anchoredSquareResize(
                lens,
                handle: handle,
                to: current,
                minimumDiameter: ScreenshotMagnifierMetrics.minimumDiameter,
                maximumDiameter: ScreenshotMagnifierMetrics.maximumDiameter,
                constrainedTo: cropRect
            )
            var next = original
            next.appearance.magnifierDiameter = resize.diameter
            next.geometry = .magnifier(center: resize.center)
            activeStyle = next.appearance
            updateDraftElement(next, id: id)
        case let .lineEndpoint(id, original, editsStart):
            guard case let .line(start, end) = original.geometry else { return }
            var next = original
            next.geometry = editsStart
                ? .line(start: current, end: end)
                : .line(start: start, end: current)
            next.geometry = ScreenshotGeometry.clamp(next.geometry, to: sourceBounds)
            updateDraftElement(next, id: id)
        case let .lineCurve(id, original):
            guard case let .line(start, end) = original.geometry else { return }
            var next = original
            let proposed = ScreenshotGeometry.lineCurvature(
                start: start,
                end: end,
                control: current
            )
            if var anchor = curvatureGestureAnchor {
                let resolution = anchor.resolve(
                    proposed,
                    bypassesAnchor: modifiers.contains(.option)
                )
                curvatureGestureAnchor = anchor
                next.appearance.curvature = resolution.value
                if resolution.didEnterAnchor { provideCurvatureAnchorFeedback() }
            } else {
                next.appearance.curvature = proposed
            }
            activeStyle = next.appearance
            updateDraftElement(next, id: id)
        case let .calloutPointer(id, original):
            guard let layout = ScreenshotCalloutResolvedLayout(element: original) else { return }
            var next = original
            next.geometry = .calloutComposite(
                target: .point(ScreenshotGeometry.clamp(current, to: sourceBounds)),
                note: layout.noteRect
            )
            updateDraftElement(next, id: id)
        case let .calloutCurve(id, original):
            guard let layout = ScreenshotCalloutResolvedLayout(element: original),
                  case var .callout(appearance) = original.appearance.payload else { return }
            var next = original
            appearance.connector.curvature = ScreenshotGeometry.lineCurvature(
                start: layout.connector.start,
                end: layout.connector.end,
                control: current
            )
            next.appearance.payload = .callout(appearance)
            activeStyle = next.appearance
            updateDraftElement(next, id: id)
        case let .cropCreate(start):
            if let aspectRatio = cropAspectRatio {
                updateDraftCrop(ScreenshotGeometry.rect(
                    from: start,
                    to: current,
                    aspectRatio: aspectRatio,
                    constrainedTo: sourceBounds
                ))
            } else {
                updateDraftCrop(rectFrom(start, current, modifiers: modifiers))
            }
        case let .cropResize(original, handle):
            let allowed = sourceBounds
            if let aspectRatio = cropAspectRatio {
                updateDraftCrop(ScreenshotGeometry.resize(
                    original,
                    handle: handle,
                    to: current,
                    constrainedTo: allowed,
                    aspectRatio: aspectRatio
                ))
            } else {
                updateDraftCrop(ScreenshotGeometry.resize(
                    original,
                    handle: handle,
                    to: current,
                    constrainedTo: allowed
                ))
            }
        case let .cropMove(original, start):
            let translated = ScreenshotGeometry.translateWithinBounds(
                .rect(original),
                dx: current.x - start.x,
                dy: current.y - start.y,
                bounds: sourceBounds
            )
            guard case let .rect(next) = translated else { return }
            updateDraftCrop(next)
        }
        if let draftElement, draftElement.requiresThrottledEffectPreview {
            scheduleEffectPreview()
        }
    }

    func endGesture(at _: CGPoint, modifiers _: NSEvent.ModifierFlags) {
        defer { pendingObjectDrag = nil }
        if activeToolbarItemID == .ocr, manualOCRStartPoint != nil {
            manualOCRStartPoint = nil
            guard case let .selecting(selection) = manualOCRCoordinator.state else {
                manualOCRCoordinator.cancel()
                return
            }
            // A click is an intentional full-crop OCR request. Requiring a 2×2
            // drag made the tool appear broken because a normal click silently
            // cancelled the operation. Keep drag-to-recognize for deliberate
            // regions, but use a view-space threshold so zoom does not change the
            // interaction contract.
            let minimumDrag = max(2, Int(ceil(3 * activeSourceUnitsPerViewPoint)))
            let region = if selection.width < minimumDrag || selection.height < minimumDrag {
                cropRect
            } else {
                selection
            }
            requestManualOCR(region: region)
            return
        }
        guard let interaction else { return }
        let updatesToolPreset: Bool = switch interaction {
        case .lineCurve,
             .calloutCurve,
             .movingStepComponent(_, _, _, .connector),
             .movingCalloutComponent(_, _, _, .connector): true
        default: false
        }
        let createsCounter: Bool = if case .creating = interaction { draftElement?.kind == .counter } else { false }
        let createsStep: Bool = if case .creating = interaction { draftElement?.kind == .step } else { false }
        let createsCallout: Bool = if case .creating = interaction { draftElement?.kind == .callout } else { false }
        let wasCropInteraction = draftCropRect != nil
        let shouldCommit: Bool
        if let draftCropRect {
            shouldCommit = draftCropRect.width >= 2 && draftCropRect.height >= 2
        } else if let draftElement {
            let bounds = ScreenshotGeometry.bounds(of: draftElement)
            shouldCommit = bounds.width >= 1 || bounds.height >= 1 || draftElement.kind == .freehand
        } else {
            shouldCommit = true
        }
        let committedElement: ScreenshotElement? = if case .creating = interaction {
            draftElement
        } else {
            nil
        }
        if shouldCommit {
            _ = document.commitInteraction()
            if let committedElement {
                onElementCommitted(committedElement)
            }
            if createsCounter {
                nextCounterNumber += 1
            }
        } else {
            _ = document.cancelInteraction()
        }
        if let draftElement, draftElement.kind == .text {
            logTextElement(
                draftElement,
                stage: shouldCommit ? "gesture-commit" : "gesture-discard"
            )
        }
        clearInteraction()
        if wasCropInteraction {
            refreshPreviewAfterCropRevision()
        } else {
            refreshRender()
        }
        if let selectedElementID { prepareSelectionBase(for: selectedElementID) }
        if updatesToolPreset { persistActiveStyle() }
        curvatureGestureAnchor = nil
        if (createsStep || createsCallout), shouldCommit {
            if let selectedElementID { requestInlineTextEditing(selectedElementID) }
        }
    }

    func cancelGesture() {
        pendingObjectDrag = nil
        if manualOCRStartPoint != nil {
            manualOCRStartPoint = nil
            manualOCRCoordinator.cancel()
            return
        }
        guard interaction != nil else { return }
        let wasCropInteraction = draftCropRect != nil
        _ = document.cancelInteraction()
        clearInteraction()
        curvatureGestureAnchor = nil
        if wasCropInteraction {
            refreshPreviewAfterCropRevision()
        } else {
            refreshRender()
        }
    }

    func applyText(
        _ text: String,
        in rect: CGRect,
        replacing elementID: UUID? = nil,
        sizing: ScreenshotTextBoxSizing = .auto
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let elementID,
               let element = document.presentedSnapshot.elements.first(where: { $0.id == elementID }),
               element.kind == .step {
                _ = document.updateElement(id: elementID) { next in
                    next.text = nil
                    if case let .step(center, _) = next.geometry {
                        next.geometry = .step(badgeCenter: center, note: rect.pixelRect)
                        normalizeTextElement(&next, proposedRect: rect)
                    }
                }
                selectedStepComponent = .note
                refreshRender()
            } else if let elementID,
                      let element = document.presentedSnapshot.elements.first(where: { $0.id == elementID }),
                      element.kind == .callout {
                _ = document.updateElement(id: elementID) { next in
                    next.text = nil
                    if case let .calloutComposite(target, _) = next.geometry {
                        next.geometry = .calloutComposite(target: target, note: rect.pixelRect)
                    } else if case let .callout(_, pointer) = next.geometry {
                        next.geometry = .calloutComposite(target: .point(pointer), note: rect.pixelRect)
                    }
                }
                selectedCalloutComponent = .note
                refreshRender()
            } else if let elementID, document.removeElement(id: elementID) {
                selectedElementID = nil
                selectedStepComponent = nil
                selectedCalloutComponent = nil
                invalidateSelectionBase()
                refreshRender()
            }
            return
        }
        if let elementID {
            _ = document.updateElement(id: elementID) {
                $0.text = text
                $0.textBoxSizing = sizing
                if $0.kind == .step, case let .step(center, _) = $0.geometry {
                    $0.geometry = .step(badgeCenter: center, note: rect.pixelRect)
                    normalizeTextElement(&$0, proposedRect: rect)
                } else {
                    normalizeTextElement(&$0, proposedRect: rect)
                }
            }
            selectedElementID = elementID
            selectedStepComponent = document.snapshot.elements.first(where: { $0.id == elementID })?.kind == .step
                ? .note
                : nil
            selectedCalloutComponent = document.snapshot.elements.first(where: { $0.id == elementID })?.kind == .callout
                ? .note
                : nil
        } else {
            let element = ScreenshotElement(
                kind: .text,
                geometry: .rect(rect.pixelRect),
                text: text,
                textBoxSizing: sizing,
                appearance: activeStyle
            )
            var normalized = element
            normalizeTextElement(&normalized, proposedRect: rect)
            _ = document.add(normalized)
            selectedElementID = normalized.id
            selectedStepComponent = nil
            selectedCalloutComponent = nil
        }
        if let selectedElement, selectedElement.kind == .text {
            logTextElement(selectedElement, stage: elementID == nil ? "text-create" : "text-commit")
        }
        refreshRender()
    }

    @discardableResult
    func addPluginText(_ text: String, rect: CGRect?) -> UUID? {
        let crop = cropRect
        let resolvedRect = rect ?? CGRect(
            x: Double(crop.x) + Double(crop.width) * 0.2,
            y: Double(crop.y) + Double(crop.height) * 0.2,
            width: max(120, Double(crop.width) * 0.4),
            height: 56
        )
        applyText(text, in: resolvedRect, sizing: .fixedBox)
        return selectedElementID
    }

    func updatePluginText(id: UUID, text: String) -> Bool {
        guard let element = document.presentedSnapshot.elements.first(where: {
            $0.id == id && [.text, .step, .callout].contains($0.kind)
        }) else { return false }
        let rect: CGRect = switch element.geometry {
        case let .rect(value): value.cgRect
        case let .step(_, note): note?.cgRect ?? cropRect.cgRect
        case let .calloutComposite(_, note): note.cgRect
        case let .callout(body, _): body.cgRect
        default: cropRect.cgRect
        }
        applyText(
            text,
            in: rect,
            replacing: id,
            sizing: element.textBoxSizing ?? .fixedBox
        )
        return true
    }

    func deletePluginElement(id: UUID) -> Bool {
        guard document.presentedSnapshot.elements.contains(where: { $0.id == id }) else {
            return false
        }
        selectElement(id)
        deleteSelection()
        return true
    }

    func updateSelectedStepNumber(_ requestedNumber: Int) {
        guard let selectedElementID,
              let transaction = ScreenshotStepNumbering.transaction(
                  moving: selectedElementID,
                  to: requestedNumber,
                  in: document.snapshot.elements
              ), !transaction.changes.isEmpty,
              document.beginInteraction() else { return }
        _ = document.updateInteraction { snapshot in
            snapshot.elements = transaction.applying(to: snapshot.elements)
        }
        _ = document.commitInteraction()
        refreshRender()
    }

    func updateSelectedStyle(
        _ appearance: ScreenshotElementAppearance,
        commitsImmediately: Bool = false
    ) {
        let usesImplicitTransaction = !isStyleEditing || implicitStyleCommitTask != nil
        if !isStyleEditing { beginStyleEditing() }
        activeStyle = appearance
        guard let selectedElementID else {
            if commitsImmediately {
                endStyleEditing()
            } else if usesImplicitTransaction {
                scheduleImplicitStyleCommit()
            }
            return
        }
        if deferredStyleElementID != selectedElementID {
            if styleInteractionElementID == selectedElementID {
                _ = document.updateInteraction { snapshot in
                    guard let index = snapshot.elements.firstIndex(where: { $0.id == selectedElementID }) else { return }
                    snapshot.elements[index].appearance = appearance
                    normalizeTextElement(&snapshot.elements[index])
                    normalizeAppearanceGeometry(&snapshot.elements[index])
                }
                draftElement = document.presentedSnapshot.elements.first(where: { $0.id == selectedElementID })
                if interactionBaseImage == nil {
                    interactionBaseImage = draftElement?.requiresThrottledEffectPreview == true
                        ? canvasImage
                        : selectionBaseImage
                }
                if draftElement?.requiresThrottledEffectPreview == true {
                    scheduleEffectPreview()
                }
            } else {
                _ = document.updateElement(id: selectedElementID) {
                    $0.appearance = appearance
                    normalizeTextElement(&$0)
                    normalizeAppearanceGeometry(&$0)
                }
                refreshRender()
            }
        }
        if commitsImmediately {
            endStyleEditing()
        } else if usesImplicitTransaction {
            scheduleImplicitStyleCommit()
        }
    }

    func beginStyleEditing() {
        implicitStyleCommitTask?.cancel()
        implicitStyleCommitTask = nil
        guard !isStyleEditing else { return }
        isStyleEditing = true
        styleEditingOriginalAppearance = activeStyle
        styleEditingOriginalPreset = preferencesStore.preferences.toolPresets[inspectorTool]
        guard let selectedElementID else { return }
        guard interaction == nil,
              selectionBaseElementID == selectedElementID,
              selectionBaseVisibleRect == renderedVisibleRect,
              selectionBaseImage != nil,
              document.beginInteraction() else {
            deferredStyleElementID = selectedElementID
            prepareSelectionBase(for: selectedElementID)
            return
        }
        styleInteractionElementID = selectedElementID
        interactionBaseImage = selectedElement?.requiresThrottledEffectPreview == true
            ? canvasImage
            : selectionBaseImage
        draftElement = selectedElement
    }

    func beginCurvatureEditing() {
        curvaturePropertyAnchor = ScreenshotCurvatureAnchor(
            initialValue: activeStyle.curvature,
            enterThreshold: 0.06,
            exitThreshold: 0.09
        )
        beginStyleEditing()
    }

    func updateCurvature(_ proposed: Double, bypassesAnchor: Bool = false) {
        if curvaturePropertyAnchor == nil {
            curvaturePropertyAnchor = ScreenshotCurvatureAnchor(
                initialValue: activeStyle.curvature,
                enterThreshold: 0.06,
                exitThreshold: 0.09
            )
            beginStyleEditing()
        }
        guard var anchor = curvaturePropertyAnchor else { return }
        let resolution = anchor.resolve(proposed, bypassesAnchor: bypassesAnchor)
        curvaturePropertyAnchor = anchor
        var next = activeStyle
        next.curvature = resolution.value
        updateSelectedStyle(next)
        if resolution.didEnterAnchor { provideCurvatureAnchorFeedback() }
    }

    func endCurvatureEditing() {
        curvaturePropertyAnchor = nil
        endStyleEditing()
    }

    func resetCurvature() {
        let shouldProvideFeedback = activeStyle.curvature != 0
        beginStyleEditing()
        var next = activeStyle
        next.curvature = 0
        updateSelectedStyle(next, commitsImmediately: true)
        curvaturePropertyAnchor = nil
        if shouldProvideFeedback { provideCurvatureAnchorFeedback() }
    }

    func endStyleEditing() {
        finishStyleEditing(refreshesRender: true)
    }

    func cancelStyleEditing() {
        guard isStyleEditing else { return }
        implicitStyleCommitTask?.cancel()
        implicitStyleCommitTask = nil
        let hadDocumentInteraction = styleInteractionElementID != nil
        if hadDocumentInteraction {
            _ = document.cancelInteraction()
        }
        if let original = styleEditingOriginalAppearance {
            activeStyle = original
        }
        let tool = inspectorTool
        preferencesStore.update {
            if let originalPreset = styleEditingOriginalPreset {
                $0.toolPresets[tool] = originalPreset
            } else {
                $0.toolPresets.removeValue(forKey: tool)
            }
        }
        isStyleEditing = false
        styleInteractionElementID = nil
        deferredStyleElementID = nil
        styleEditingOriginalAppearance = nil
        styleEditingOriginalPreset = nil
        draftElement = nil
        interactionBaseImage = nil
        effectPreviewPending = false
        effectPreviewInFlight = false
        if hadDocumentInteraction {
            // Invalidate any completed or in-flight effect preview before a
            // later editing session can observe it as its interaction base.
            renderPipeline.cancel()
            refreshRender()
        }
    }

    private func finishStyleEditing(refreshesRender: Bool) {
        guard isStyleEditing else { return }
        implicitStyleCommitTask?.cancel()
        implicitStyleCommitTask = nil
        isStyleEditing = false
        let editedElement = styleInteractionElementID
        if editedElement != nil { _ = document.commitInteraction() }
        let deferredElement = deferredStyleElementID
        if let deferredElement {
            _ = document.updateElement(id: deferredElement) {
                $0.appearance = activeStyle
                normalizeTextElement(&$0)
                normalizeAppearanceGeometry(&$0)
            }
        }
        styleInteractionElementID = nil
        deferredStyleElementID = nil
        styleEditingOriginalAppearance = nil
        styleEditingOriginalPreset = nil
        draftElement = nil
        interactionBaseImage = nil
        persistActiveStyle()
        if refreshesRender && (editedElement != nil || deferredElement != nil) { refreshRender() }
    }

    func nudgeSelection(dx: Double, dy: Double) {
        finishPropertyEditing()
        guard let selectedElementID, let selectedElement else { return }
        _ = document.updateElement(id: selectedElementID) { next in
            if selectedElement.kind == .step,
               let component = selectedStepComponent {
                next = self.translatingStepComponent(
                    component,
                    of: selectedElement,
                    dx: dx,
                    dy: dy
                )
            } else if selectedElement.kind == .callout,
                      let component = selectedCalloutComponent {
                next = self.translatingCalloutComponent(
                    component,
                    of: selectedElement,
                    dx: dx,
                    dy: dy
                )
            } else {
                next.geometry = translatedGeometry(of: selectedElement, dx: dx, dy: dy)
            }
        }
        refreshRender()
    }

    private func normalizeTextElement(_ element: inout ScreenshotElement, proposedRect: CGRect? = nil) {
        if element.kind == .step,
           let text = element.text,
           !text.isEmpty,
           case let .step(center, currentNote) = element.geometry {
            let base = proposedRect ?? currentNote?.cgRect ?? ScreenshotStepEditorLayout.noteRect(
                badgeCenter: center,
                appearance: element.appearance.stepAppearance,
                sourceBounds: cropRect
            ).cgRect
            let textAppearance = ScreenshotStepEditorLayout.inlineTextAppearance(from: element.appearance)
            let layout = ScreenshotTextLayout(appearance: textAppearance)
            let width = min(max(base.width, 80), Double(cropRect.width))
            let measured = layout.measure(text, sizing: .fixedWidth, constrainedTo: width)
            let height = element.textBoxSizing == .fixedWidth
                ? max(base.height, measured.height)
                : measured.height
            let proposed = ScreenshotPixelRect(
                x: Int(base.minX.rounded()),
                y: Int(base.minY.rounded()),
                width: max(1, Int(width.rounded())),
                height: max(1, Int(height.rounded(.up)))
            )
            element.geometry = .step(
                badgeCenter: center,
                note: ScreenshotStepResolvedLayout.constrainedNoteRect(
                    proposed,
                    badgeCenter: center,
                    badgeDiameter: element.appearance.stepAppearance.badgeSize,
                    gap: element.appearance.stepAppearance.gap,
                    constrainedTo: cropRect
                )
            )
            return
        }
        guard [.text, .callout].contains(element.kind),
              let text = element.text else { return }
        let existing: ScreenshotPixelRect
        switch element.geometry {
        case let .rect(rect):
            existing = rect
        case let .callout(body, _):
            existing = body
        case let .calloutComposite(_, note):
            existing = note
        default:
            return
        }
        let base = proposedRect ?? existing.cgRect
        let sizing = element.textBoxSizing ?? .auto
        let textAppearance = ScreenshotSemanticTextStyle.inlineAppearance(
            from: element.appearance,
            kind: element.kind
        )
        let layout = ScreenshotTextLayout(appearance: textAppearance)
        let minimumWidth = layout.padding * 2 + 1
        let constraintBounds = element.kind == .text || element.kind == .callout
            ? cropRect
            : sourceBounds
        let sourceWidth = Double(constraintBounds.width)
        let sourceHeight = Double(constraintBounds.height)
        let constraint = sizing == .auto
            ? min(ScreenshotTextLayout.defaultMaximumAutoWidth, sourceWidth)
            : min(max(base.width, minimumWidth), sourceWidth)
        let minimumHeight = layout.lineHeight + layout.padding * 2
        let width: Double
        let height: Double
        if sizing == .fixedBox {
            width = min(max(base.width, minimumWidth), sourceWidth)
            height = min(max(base.height, minimumHeight), sourceHeight)
        } else {
            let measured = layout.measure(
                text,
                sizing: sizing,
                constrainedTo: constraint
            )
            width = min(max(measured.width, minimumWidth), sourceWidth)
            height = min(max(measured.height, minimumHeight), sourceHeight)
        }
        let minX = Double(constraintBounds.x)
        let minY = Double(constraintBounds.y)
        let maxX = Double(constraintBounds.x + constraintBounds.width) - width
        let maxY = Double(constraintBounds.y + constraintBounds.height) - height
        let nextRect = CGRect(
            x: min(max(base.minX, minX), maxX),
            y: min(max(base.minY, minY), maxY),
            width: width,
            height: height
        ).pixelRect
        if case let .callout(_, pointer) = element.geometry {
            element.geometry = .calloutComposite(target: .point(pointer), note: nextRect)
        } else if case let .calloutComposite(target, _) = element.geometry {
            element.geometry = .calloutComposite(target: target, note: nextRect)
        } else {
            element.geometry = .rect(nextRect)
        }
    }

    private func normalizeAppearanceGeometry(_ element: inout ScreenshotElement) {
        switch element.geometry {
        case let .magnifier(center):
            let magnifierBounds = cropRect
            let availableDiameter = Double(min(magnifierBounds.width, magnifierBounds.height))
            let diameter = min(
                ScreenshotMagnifierMetrics.maximumDiameter,
                max(
                    min(ScreenshotMagnifierMetrics.minimumDiameter, availableDiameter),
                    min(element.appearance.magnifierDiameter, availableDiameter)
                )
            )
            element.appearance.magnifierDiameter = diameter
            element.geometry = .magnifier(center: clampedCircularCenter(center, diameter: diameter))
        case let .step(center, note):
            let stepAppearance = element.appearance.stepAppearance
            let constrainedCenter = ScreenshotStepResolvedLayout.constrainedBadgeCenter(
                center,
                badgeDiameter: stepAppearance.badgeSize,
                noteRect: note,
                gap: stepAppearance.gap,
                constrainedTo: cropRect
            )
            element.geometry = .step(badgeCenter: constrainedCenter, note: note)
        default:
            break
        }
    }

    func deleteSelection() {
        guard let selectedElementID else { return }
        let nextElementID = ScreenshotEditorSelectionModel.nextElementID(
            afterDeleting: selectedElementID,
            from: ScreenshotEditorSelectionModel.visibleElements(in: document.presentedSnapshot)
        )
        deleteElement(selectedElementID, selecting: nextElementID)
    }

    func deleteElement(_ elementID: UUID, selecting nextElementID: UUID?) {
        finishPropertyEditing()
        guard document.removeElement(id: elementID) else { return }
        recentStepComponents.removeValue(forKey: elementID)
        recentCalloutComponents.removeValue(forKey: elementID)
        self.selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        pendingObjectDrag = nil
        if let nextElementID,
           document.presentedSnapshot.elements.contains(where: { $0.id == nextElementID }) {
            selectElement(nextElementID)
        } else {
            invalidateSelectionBase()
        }
        refreshRender()
    }

    func duplicateSelection() {
        finishPropertyEditing()
        guard let selectedElementID,
              let duplicate = document.duplicateElement(id: selectedElementID) else { return }
        self.selectedElementID = duplicate.id
        selectedStepComponent = duplicate.kind == .step ? .badge : nil
        selectedCalloutComponent = duplicate.kind == .callout
            ? defaultCalloutComponent(for: duplicate)
            : nil
        activeStyle = duplicate.appearance
        invalidateSelectionBase()
        refreshRender()
        prepareSelectionBase(for: duplicate.id)
    }

    func splitSelectedStep() {
        finishPropertyEditing()
        guard let step = selectedElement,
              step.kind == .step,
              let layout = ScreenshotStepResolvedLayout(element: step),
              let noteRect = layout.noteRect,
              let connector = layout.connector else { return }
        let appearance = step.appearance.stepAppearance
        let connectorElement = ScreenshotElement(
            kind: .arrow,
            geometry: .line(start: connector.start, end: connector.end),
            appearance: .line(appearance.connector)
        )
        let noteElement = ScreenshotElement(
            kind: .text,
            geometry: .rect(noteRect),
            text: step.text,
            textBoxSizing: step.textBoxSizing ?? .fixedWidth,
            appearance: .text(appearance.note)
        )
        let badgeElement = ScreenshotElement(
            kind: .counter,
            geometry: .counter(center: layout.badgeCenter),
            text: String(step.stepNumber ?? 1),
            appearance: .counter(appearance.badge)
        )
        let selectedReplacement = switch selectedStepComponent ?? .badge {
        case .badge: badgeElement
        case .connector: connectorElement
        case .note: noteElement
        }
        guard document.replaceElement(
            id: step.id,
            with: [connectorElement, noteElement, badgeElement]
        ) else { return }
        selectedElementID = selectedReplacement.id
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        activeStyle = selectedReplacement.appearance
        invalidateSelectionBase()
        refreshRender()
        prepareSelectionBase(for: selectedReplacement.id)
    }

    func moveSelectionForward() {
        finishPropertyEditing()
        guard let selectedElementID, document.moveElementForward(id: selectedElementID) else { return }
        invalidateSelectionBase()
        refreshRender()
        prepareSelectionBase(for: selectedElementID)
    }

    func moveSelectionBackward() {
        finishPropertyEditing()
        guard let selectedElementID, document.moveElementBackward(id: selectedElementID) else { return }
        invalidateSelectionBase()
        refreshRender()
        prepareSelectionBase(for: selectedElementID)
    }

    func undo() {
        finishPropertyEditing()
        cancelGesture()
        guard document.undo() else { return }
        selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        invalidateSelectionBase()
        refreshRender()
    }

    func redo() {
        finishPropertyEditing()
        cancelGesture()
        guard document.redo() else { return }
        selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        invalidateSelectionBase()
        refreshRender()
    }

    @discardableResult
    func copyCurrent() -> ScreenshotEditorOutputAdmission {
        performOrQueue(.copy)
    }

    func copyCurrentAwaitingCompletion() async -> ScreenshotEditorOutputExecutionResult {
        await performHostOutputAwaitingCompletion(.copy)
    }

    func saveCurrentAwaitingCompletion() async -> ScreenshotEditorOutputExecutionResult {
        await performHostOutputAwaitingCompletion(.save)
    }

    private func performHostOutputAwaitingCompletion(
        _ command: ScreenshotEditorOutputCommand
    ) async -> ScreenshotEditorOutputExecutionResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard hostOutputWaiter == nil else {
                    continuation.resume(returning: .rejected(.busy))
                    return
                }
                let admission = performOrQueue(command)
                guard admission.isAccepted else {
                    continuation.resume(returning: .rejected(admission))
                    return
                }
                hostOutputWaiter = HostOutputWaiter(
                    id: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelHostOutput(waiterID: waiterID)
            }
        }
    }

    @discardableResult
    func pinCurrent() -> ScreenshotEditorOutputAdmission {
        performOrQueue(.pin)
    }

    @discardableResult
    func saveAs() -> ScreenshotEditorOutputAdmission {
        performOrQueue(.save)
    }

    @discardableResult
    func complete() -> ScreenshotEditorOutputAdmission {
        performOrQueue(.complete)
    }

    func completeForReplacement() async -> NSImage? {
        await withCheckedContinuation { continuation in
            requestReplacementOutput { image in
                continuation.resume(returning: image)
            }
        }
    }

    func prepareFinalizedImageForHostAction() async -> ScreenshotEditorCompletionPreparation {
        guard !isCloseConfirmationPresented else {
            return .rejected(.closeConfirmation)
        }
        guard !isOutputPending,
              pendingReplacementCompletion == nil,
              pendingOutputGate.pending == nil else {
            return .rejected(.busy)
        }
        guard !Task.isCancelled else { return .cancelled }

        let image = await withTaskCancellationHandler {
            await completeForReplacement()
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelBackgroundWork()
            }
        }
        if Task.isCancelled || isShutdown { return .cancelled }
        guard let image else { return .failed }
        return .prepared(image)
    }

    func pinnedPresentationForHostAction(
        image: NSImage
    ) -> PinnedScreenshotPresentation {
        pinnedPresentation(image: image)
    }

    func retake() { onRetake() }

    func close() { onRequestClose() }

    func shutdown() {
        isShutdown = true
        finishStyleEditing(refreshesRender: false)
        if isWatermarkEditing { endWatermarkEditing() }
        cancelBackgroundWork()
        notificationState.shutdown()
    }

    func cancelActiveOutputForHostAction() {
        cancelOutputTask()
        pendingOutputGate.clear()
    }

    func updateManualOCRText(_ text: String) {
        manualOCRCoordinator.updateResultText(text)
    }

    func copyManualOCRText() {
        guard allowsDirectImageCopy else { return }
        guard case let .result(_, _, _, text) = manualOCRCoordinator.state else { return }
        let writer = ClipboardPasteboardWriter()
        Task { @MainActor [weak self] in
            await self?.copyManualOCRText(text, writer: writer)
        }
    }

    func copyManualOCRText(
        pasteboard: any ClipboardPasteboardWriting,
        changeSuppressor: ClipboardPasteboardChangeSuppressor
    ) async {
        guard allowsDirectImageCopy else { return }
        guard case let .result(_, _, _, text) = manualOCRCoordinator.state else { return }
        let writer = ClipboardPasteboardWriter(
            pasteboard: pasteboard,
            changeSuppressor: changeSuppressor
        )
        await copyManualOCRText(text, writer: writer)
    }

    private func copyManualOCRText(
        _ text: String,
        writer: ClipboardPasteboardWriter
    ) async {
        do {
            _ = try await writer.writePlainText(text)
            presentNotification(
                level: .success,
                title: L10n.string("screenshot.ocr.copied"),
                deduplicationKey: "screenshot.ocr.copy.succeeded"
            )
        } catch {
            presentNotification(
                level: .error,
                title: L10n.string("screenshot.result.copyFailed"),
                detail: error.localizedDescription,
                deduplicationKey: "screenshot.ocr.copy.failed"
            )
        }
    }

    func closeManualOCRResult() {
        manualOCRCoordinator.closeResult()
    }

    func cancelManualOCR() {
        cancelManualOCROutputPreparation()
        manualOCRStartPoint = nil
        manualOCRCoordinator.cancel()
    }

    func retryManualOCR() {
        guard case let .failed(_, region, _, _) = manualOCRCoordinator.state else { return }
        requestManualOCR(region: region)
    }

    @discardableResult
    private func beginSelectionGesture(
        at point: ScreenshotPixelPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        finishPropertyEditing()
        let tolerance = handleTolerance
        let hits = ScreenshotGeometry.hitResults(
            at: point,
            elements: document.presentedSnapshot.elements,
            tolerance: tolerance,
            constrainedTo: cropRect
        )
        guard !hits.isEmpty else {
            overlapCycleIDs = []
            overlapCycleIndex = 0
            return false
        }
        let hitID: UUID
        if modifiers.contains(.command) {
            let ids = hits.map(\.elementID)
            if ids != overlapCycleIDs {
                overlapCycleIDs = ids
                overlapCycleIndex = 0
            } else {
                overlapCycleIndex = (overlapCycleIndex + 1) % ids.count
            }
            hitID = ids[overlapCycleIndex]
        } else {
            overlapCycleIDs = []
            overlapCycleIndex = 0
            hitID = hits[0].elementID
        }
        guard let hit = document.presentedSnapshot.elements.first(where: { $0.id == hitID }) else {
            return false
        }
        let stepComponent = hit.kind == .step ? stepComponent(at: point, in: hit) : nil
        let calloutComponent = hit.kind == .callout ? calloutComponent(at: point, in: hit) : nil
        guard selectedElementID == hit.id else {
            selectedElementID = hit.id
            selectedStepComponent = stepComponent
            selectedCalloutComponent = calloutComponent
            activeStyle = hit.appearance
            prepareSelectionBase(for: hit.id)
            if !modifiers.contains(.command) {
                pendingObjectDrag = (hit.id, point, stepComponent, calloutComponent)
                beginPendingObjectDragIfReady()
            }
            return true
        }
        if modifiers.contains(.command) {
            activeStyle = hit.appearance
            return true
        }
        selectedElementID = hit.id
        selectedStepComponent = stepComponent
        selectedCalloutComponent = calloutComponent
        activeStyle = hit.appearance
        let nextInteraction: ScreenshotEditorInteraction
        if let stepComponent {
            nextInteraction = .movingStepComponent(
                id: hit.id,
                start: point,
                original: hit,
                component: stepComponent
            )
        } else if let calloutComponent {
            nextInteraction = .movingCalloutComponent(
                id: hit.id,
                start: point,
                original: hit,
                component: calloutComponent
            )
        } else {
            nextInteraction = .moving(id: hit.id, start: point, original: hit)
        }
        beginEditing(hit, interaction: nextInteraction)
        return true
    }

    private func beginPendingObjectDragIfReady() {
        guard interaction == nil,
              let pendingObjectDrag,
              let element = document.presentedSnapshot.elements.first(where: { $0.id == pendingObjectDrag.elementID }) else {
            return
        }
        let nextInteraction: ScreenshotEditorInteraction
        if let component = pendingObjectDrag.stepComponent {
            nextInteraction = .movingStepComponent(
                id: element.id,
                start: pendingObjectDrag.start,
                original: element,
                component: component
            )
        } else if let component = pendingObjectDrag.calloutComponent {
            nextInteraction = .movingCalloutComponent(
                id: element.id,
                start: pendingObjectDrag.start,
                original: element,
                component: component
            )
        } else {
            nextInteraction = .moving(
                id: element.id,
                start: pendingObjectDrag.start,
                original: element
            )
        }
        beginEditing(element, interaction: nextInteraction)
        if interaction != nil { self.pendingObjectDrag = nil }
    }

    private func beginSelectedElementHandleGestureIfNeeded(at point: ScreenshotPixelPoint) -> Bool {
        guard let selected = selectedElement else { return false }
        let tolerance = handleTolerance
        if case let .line(start, end) = selected.geometry {
            if point.distance(to: start) <= tolerance {
                beginEditing(
                    selected,
                    interaction: .lineEndpoint(id: selected.id, original: selected, editsStart: true)
                )
                return interaction != nil
            }
            if point.distance(to: end) <= tolerance {
                beginEditing(
                    selected,
                    interaction: .lineEndpoint(id: selected.id, original: selected, editsStart: false)
                )
                return interaction != nil
            }
            let control = ScreenshotGeometry.lineControlPoint(
                start: start,
                end: end,
                curvature: selected.appearance.curvature
            )
            if point.distance(to: control) <= tolerance {
                let lineLength = max(1, hypot(end.x - start.x, end.y - start.y))
                curvatureGestureAnchor = ScreenshotCurvatureAnchor(
                    initialValue: selected.appearance.curvature,
                    enterThreshold: min(1, 16 * activeSourceUnitsPerViewPoint / lineLength),
                    exitThreshold: min(1, 24 * activeSourceUnitsPerViewPoint / lineLength)
                )
                beginEditing(
                    selected,
                    interaction: .lineCurve(id: selected.id, original: selected)
                )
                return interaction != nil
            }
        }
        if case let .rect(rect) = selected.geometry,
           let handle = ScreenshotGeometry.hitTestHandle(point, rect: rect, tolerance: tolerance) {
            beginEditing(
                selected,
                interaction: .resizing(id: selected.id, original: selected, handle: handle)
            )
            return interaction != nil
        }
        if selected.kind == .callout,
           let layout = ScreenshotCalloutResolvedLayout(element: selected) {
            let selectedComponent = selectedCalloutComponent ?? defaultCalloutComponent(for: selected)
            let actualComponent: ScreenshotCalloutComponent? = switch layout.hitKind(
                at: point,
                tolerance: 0
            ) {
            case .calloutTarget: .target
            case .calloutConnector: .connector
            case .calloutNote: .note
            default: nil
            }
            if let actualComponent, actualComponent != selectedComponent { return false }
            switch selectedComponent {
            case .target:
                if let targetRect = layout.targetRect,
                   let handle = ScreenshotGeometry.hitTestHandle(
                       point,
                       rect: targetRect,
                       tolerance: tolerance
                   ) {
                    beginEditing(
                        selected,
                        interaction: .resizingCalloutTarget(
                            id: selected.id,
                            original: selected,
                            handle: handle
                        )
                    )
                    return interaction != nil
                }
                if case let .point(targetPoint) = layout.target,
                   point.distance(to: targetPoint) <= tolerance {
                    beginEditing(
                        selected,
                        interaction: .calloutPointer(id: selected.id, original: selected)
                    )
                    return interaction != nil
                }
            case .connector:
                if point.distance(to: layout.connectorControlPoint) <= tolerance {
                    beginEditing(
                        selected,
                        interaction: .calloutCurve(id: selected.id, original: selected)
                    )
                    return interaction != nil
                }
            case .note:
                if let handle = ScreenshotGeometry.hitTestHandle(
                    point,
                    rect: layout.noteRect,
                    tolerance: tolerance
                ) {
                    beginEditing(
                        selected,
                        interaction: .resizingCalloutNote(
                            id: selected.id,
                            original: selected,
                            handle: handle
                        )
                    )
                    return interaction != nil
                }
            }
        }
        if case .magnifier = selected.geometry {
            let lens = magnifierLensRect(for: selected)
            if let handle = ScreenshotGeometry.hitTestHandle(point, rect: lens, tolerance: tolerance),
               handle.isCorner {
                beginEditing(
                    selected,
                    interaction: .resizingMagnifier(id: selected.id, original: selected, handle: handle)
                )
                return interaction != nil
            }
        }
        if case .step = selected.geometry,
           let layout = ScreenshotStepResolvedLayout(element: selected) {
            let selectedComponent = selectedStepComponent ?? .badge
            let actualComponent: ScreenshotStepComponent? = switch layout.hitKind(
                at: point,
                tolerance: 0
            ) {
            case .stepBadge: .badge
            case .stepConnector: .connector
            case .stepNote: .note
            default: nil
            }
            // A zoom-scaled resize tolerance must never steal a direct hit on
            // the other step subtarget.
            if let actualComponent, actualComponent != selectedComponent { return false }
            switch selectedComponent {
            case .badge:
                if let handle = ScreenshotGeometry.hitTestHandle(
                    point,
                    rect: layout.badgeRect,
                    tolerance: tolerance
                ), handle.isCorner {
                    beginEditing(
                        selected,
                        interaction: .resizingStepBadge(id: selected.id, original: selected, handle: handle)
                    )
                    return interaction != nil
                }
            case .connector:
                return false
            case .note:
                if let note = layout.noteRect,
                   let handle = ScreenshotGeometry.hitTestHandle(point, rect: note, tolerance: tolerance) {
                    beginEditing(
                        selected,
                        interaction: .resizingStepNote(id: selected.id, original: selected, handle: handle)
                    )
                    return interaction != nil
                }
            }
        }
        return false
    }

    private func beginEditing(_ element: ScreenshotElement, interaction: ScreenshotEditorInteraction) {
        let hasPreparedBase = selectionBaseElementID == element.id
            && selectionBaseVisibleRect == renderedVisibleRect
            && selectionBaseImage != nil
        if !hasPreparedBase {
            prepareSelectionBase(for: element.id)
        }
        guard document.beginInteraction() else { return }
        self.interaction = interaction
        interactionBaseImage = element.requiresThrottledEffectPreview
            ? canvasImage
            : (selectionBaseImage ?? canvasImage)
        draftElement = element
        Self.textLogger.debug(
            "gesture-begin element=\(element.id.uuidString, privacy: .public) kind=\(element.kind.rawValue, privacy: .public) baseReady=\(hasPreparedBase, privacy: .public) revision=\(self.document.renderRevision.rawValue, privacy: .public)"
        )
    }

    private func logTextElement(_ element: ScreenshotElement, stage: String) {
        let bounds = ScreenshotGeometry.bounds(of: element)
        let color = element.appearance.strokeColor
        let sizing = element.textBoxSizing?.rawValue ?? "unset"
        Self.textLogger.debug(
            "stage=\(stage, privacy: .public) element=\(element.id.uuidString, privacy: .public) sizing=\(sizing, privacy: .public) bounds=\(bounds.x)x\(bounds.y)x\(bounds.width)x\(bounds.height) color=\(color.red)x\(color.green)x\(color.blue)x\(color.alpha) opacity=\(element.appearance.opacity)"
        )
    }

    private func updateDraftElement(_ element: ScreenshotElement, id: UUID) {
        _ = document.updateInteraction { snapshot in
            guard let index = snapshot.elements.firstIndex(where: { $0.id == id }) else { return }
            snapshot.elements[index] = element
        }
        draftElement = element
    }

    private func updateDraftCrop(_ proposed: ScreenshotPixelRect) {
        let allowed = sourceBounds
        let clamped = ScreenshotGeometry.clamp(proposed, to: allowed)
        _ = document.updateInteraction { $0.cropRect = clamped }
        draftCropRect = clamped
        if containsMagnifier { scheduleEffectPreview() }
    }

    private static func formattedAspectRatio(_ ratio: Double) -> String {
        let presets: [(Double, String)] = [(16.0 / 9.0, "16:9"), (4.0 / 3.0, "4:3"), (1, "1:1")]
        if let preset = presets.first(where: { abs($0.0 - ratio) < 0.001 }) {
            return preset.1
        }
        return String(format: "%.2f:1", ratio)
    }

    private func beginCropEdgeGestureIfNeeded(at sourcePoint: ScreenshotPixelPoint) -> Bool {
        let current = document.snapshot.cropRect
        guard let handle = cropResizeHandle(at: sourcePoint, in: current, tolerance: handleTolerance),
              document.beginInteraction() else { return false }
        interaction = .cropResize(original: current, handle: handle)
        interactionBaseImage = canvasImage
        draftCropRect = current
        selectedElementID = nil
        selectedStepComponent = nil
        selectedCalloutComponent = nil
        invalidateSelectionBase()
        return true
    }

    private func cropResizeHandle(
        at point: ScreenshotPixelPoint,
        in rect: ScreenshotPixelRect,
        tolerance: Double
    ) -> ScreenshotResizeHandle? {
        if let handle = ScreenshotGeometry.hitTestHandle(point, rect: rect, tolerance: tolerance) {
            return handle
        }

        let minX = Double(rect.x)
        let maxX = Double(rect.x + rect.width)
        let minY = Double(rect.y)
        let maxY = Double(rect.y + rect.height)
        let withinHorizontal = point.x >= minX - tolerance && point.x <= maxX + tolerance
        let withinVertical = point.y >= minY - tolerance && point.y <= maxY + tolerance
        guard withinHorizontal, withinVertical else { return nil }

        let nearLeft = abs(point.x - minX) <= tolerance
        let nearRight = abs(point.x - maxX) <= tolerance
        let nearTop = abs(point.y - minY) <= tolerance
        let nearBottom = abs(point.y - maxY) <= tolerance

        if nearLeft && nearTop { return .northWest }
        if nearRight && nearTop { return .northEast }
        if nearRight && nearBottom { return .southEast }
        if nearLeft && nearBottom { return .southWest }
        if nearTop { return .north }
        if nearRight { return .east }
        if nearBottom { return .south }
        if nearLeft { return .west }
        return nil
    }

    private func makeElement(
        id: UUID = UUID(),
        start: ScreenshotPixelPoint,
        current: ScreenshotPixelPoint,
        points: [ScreenshotPixelPoint],
        modifiers: NSEvent.ModifierFlags
    ) -> ScreenshotElement? {
        let style = activeStyle
        switch selectedTool {
        case .arrow, .line:
            let end = modifiers.contains(.shift) ? constrainedLineEnd(start: start, end: current) : current
            return ScreenshotElement(
                id: id,
                kind: .arrow,
                geometry: .line(start: start, end: end),
                appearance: style
            )
        case .rectangle, .ellipse, .blur, .pixelate, .spotlight, .redact:
            let rect = rectFrom(start, current, modifiers: modifiers)
            let kind: ScreenshotElementKind = switch selectedTool {
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .blur: .blur
            case .pixelate: .pixelate
            case .spotlight: .spotlight
            default: .redact
            }
            return ScreenshotElement(id: id, kind: kind, geometry: .rect(rect), appearance: style)
        case .freehand:
            return ScreenshotElement(id: id, kind: .freehand, geometry: .path(points), appearance: style)
        case .highlight:
            return style.highlightMode == .freehand
                ? ScreenshotElement(id: id, kind: .highlight, geometry: .path(points), appearance: style)
                : ScreenshotElement(id: id, kind: .highlight, geometry: .rect(rectFrom(start, current, modifiers: modifiers)), appearance: style)
        case .counter:
            return ScreenshotElement(
                id: id,
                kind: .counter,
                geometry: .counter(center: current),
                text: String(nextCounterNumber),
                appearance: style
            )
        case .step:
            let note = ScreenshotStepEditorLayout.noteRect(
                badgeCenter: current,
                appearance: style.stepAppearance,
                sourceBounds: cropRect
            )
            return ScreenshotElement(
                id: id,
                kind: .step,
                geometry: .step(badgeCenter: current, note: note),
                text: nil,
                textBoxSizing: .fixedWidth,
                stepNumber: ScreenshotStepNumbering.nextNumber(in: document.presentedSnapshot.elements),
                appearance: style
            )
        case .callout:
            let calloutStyle = style
            let dragDistance = hypot(current.x - start.x, current.y - start.y)
            let target: ScreenshotCalloutTarget
            let targetBounds: ScreenshotPixelRect
            if dragDistance < 4 {
                target = .point(start)
                targetBounds = .init(
                    x: Int(start.x.rounded()),
                    y: Int(start.y.rounded()),
                    width: 1,
                    height: 1
                )
            } else {
                let rect = rectFrom(start, current, modifiers: modifiers)
                target = .ellipse(rect)
                targetBounds = rect
            }
            let note = calloutNoteRect(
                targetBounds: targetBounds,
                appearance: style
            )
            return ScreenshotElement(
                id: id,
                kind: .callout,
                geometry: .calloutComposite(target: target, note: note),
                text: "",
                textBoxSizing: .fixedWidth,
                appearance: calloutStyle
            )
        case .magnifier:
            let dx = current.x - start.x
            let dy = current.y - start.y
            let dragDiameter = max(abs(dx), abs(dy))
            let magnifierBounds = cropRect
            let availableDiameter = Double(min(magnifierBounds.width, magnifierBounds.height))
            let usesDefaultDiameter = dragDiameter < 4
            let proposedDiameter = usesDefaultDiameter
                ? ScreenshotMagnifierMetrics.defaultDiameter
                : dragDiameter
            let diameter = min(
                ScreenshotMagnifierMetrics.maximumDiameter,
                max(
                    min(ScreenshotMagnifierMetrics.minimumDiameter, availableDiameter),
                    min(proposedDiameter, availableDiameter)
                )
            )
            let proposedCenter = usesDefaultDiameter
                ? start
                : ScreenshotPixelPoint(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
            var appearance = style
            appearance.magnifierDiameter = diameter
            return ScreenshotElement(
                id: id,
                kind: .magnifier,
                geometry: .magnifier(center: clampedCircularCenter(proposedCenter, diameter: diameter)),
                appearance: appearance
            )
        case .select, .text, .watermark:
            return nil
        }
    }

    private func rectFrom(
        _ start: ScreenshotPixelPoint,
        _ end: ScreenshotPixelPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> ScreenshotPixelRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if modifiers.contains(.shift) {
            let size = max(abs(dx), abs(dy))
            dx = dx < 0 ? -size : size
            dy = dy < 0 ? -size : size
        }
        let rect: ScreenshotPixelRect
        if modifiers.contains(.option) {
            rect = ScreenshotPixelRect(
                x: Int((start.x - abs(dx)).rounded()),
                y: Int((start.y - abs(dy)).rounded()),
                width: Int((abs(dx) * 2).rounded()),
                height: Int((abs(dy) * 2).rounded())
            )
        } else {
            rect = ScreenshotPixelRect(
                x: Int(min(start.x, start.x + dx).rounded()),
                y: Int(min(start.y, start.y + dy).rounded()),
                width: Int(abs(dx).rounded()),
                height: Int(abs(dy).rounded())
            )
        }
        return ScreenshotGeometry.clamp(rect, to: sourceBounds)
    }

    private func calloutNoteRect(
        targetBounds: ScreenshotPixelRect,
        appearance: ScreenshotElementAppearance
    ) -> ScreenshotPixelRect {
        let callout = if case let .callout(value) = appearance.payload {
            value
        } else {
            ScreenshotCalloutAppearance()
        }
        let width = min(180, max(80, cropRect.width - 16))
        let textLayout = ScreenshotTextLayout(appearance: .text(callout.note))
        let measured = textLayout.measure(
            L10n.string("screenshot.editor.text.placeholder"),
            sizing: .fixedWidth,
            constrainedTo: Double(width)
        )
        let height = min(max(44, Int(ceil(measured.height))), max(44, cropRect.height))
        return ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: targetBounds,
            noteSize: CGSize(width: width, height: height),
            gap: 64,
            constrainedTo: cropRect
        )
    }

    private func stepComponent(
        at point: ScreenshotPixelPoint,
        in element: ScreenshotElement
    ) -> ScreenshotStepComponent? {
        guard let layout = ScreenshotStepResolvedLayout(element: element) else { return nil }
        switch layout.hitKind(at: point, tolerance: handleTolerance) {
        case .stepBadge:
            return .badge
        case .stepNote:
            return .note
        case .stepConnector:
            return .connector
        default:
            return nil
        }
    }

    private func defaultCalloutComponent(for element: ScreenshotElement) -> ScreenshotCalloutComponent {
        ScreenshotCalloutResolvedLayout(element: element)?.targetRect == nil ? .connector : .target
    }

    private func calloutComponent(
        at point: ScreenshotPixelPoint,
        in element: ScreenshotElement
    ) -> ScreenshotCalloutComponent? {
        guard let layout = ScreenshotCalloutResolvedLayout(element: element) else { return nil }
        switch layout.hitKind(at: point, tolerance: handleTolerance) {
        case .calloutTarget:
            return .target
        case .calloutNote:
            return .note
        case .calloutConnector:
            return .connector
        default:
            return nil
        }
    }

    private func translatingCalloutComponent(
        _ component: ScreenshotCalloutComponent,
        of element: ScreenshotElement,
        dx: Double,
        dy: Double
    ) -> ScreenshotElement {
        guard let layout = ScreenshotCalloutResolvedLayout(element: element) else { return element }
        var next = element
        switch component {
        case .target:
            let target: ScreenshotCalloutTarget = switch layout.target {
            case let .point(point):
                .point(ScreenshotGeometry.clamp(
                    .init(x: point.x + dx, y: point.y + dy),
                    to: cropRect
                ))
            case let .ellipse(rect):
                .ellipse(ScreenshotGeometry.clamp(
                    .init(
                        x: rect.x + Int(dx.rounded()),
                        y: rect.y + Int(dy.rounded()),
                        width: rect.width,
                        height: rect.height
                    ),
                    to: cropRect
                ))
            }
            next.geometry = .calloutComposite(target: target, note: layout.noteRect)
        case .note:
            let note = ScreenshotGeometry.clamp(
                .init(
                    x: layout.noteRect.x + Int(dx.rounded()),
                    y: layout.noteRect.y + Int(dy.rounded()),
                    width: layout.noteRect.width,
                    height: layout.noteRect.height
                ),
                to: cropRect
            )
            next.geometry = .calloutComposite(target: layout.target, note: note)
        case .connector:
            let proposedControl = ScreenshotPixelPoint(
                x: layout.connectorControlPoint.x + dx,
                y: layout.connectorControlPoint.y + dy
            )
            if case var .callout(appearance) = next.appearance.payload {
                appearance.connector.curvature = ScreenshotGeometry.lineCurvature(
                    start: layout.connector.start,
                    end: layout.connector.end,
                    control: proposedControl
                )
                next.appearance.payload = .callout(appearance)
            }
        }
        return next
    }

    private func resizedCalloutTarget(
        _ element: ScreenshotElement,
        handle: ScreenshotResizeHandle,
        to point: ScreenshotPixelPoint
    ) -> ScreenshotElement {
        guard let layout = ScreenshotCalloutResolvedLayout(element: element),
              let targetRect = layout.targetRect else { return element }
        let resized = ScreenshotGeometry.resize(
            targetRect,
            handle: handle,
            to: point,
            constrainedTo: cropRect
        )
        var next = element
        next.geometry = .calloutComposite(target: .ellipse(resized), note: layout.noteRect)
        return next
    }

    private func resizedCalloutNote(
        _ element: ScreenshotElement,
        handle: ScreenshotResizeHandle,
        to point: ScreenshotPixelPoint
    ) -> ScreenshotElement {
        guard let layout = ScreenshotCalloutResolvedLayout(element: element) else { return element }
        let resized = ScreenshotGeometry.resize(
            layout.noteRect,
            handle: handle,
            to: point,
            constrainedTo: cropRect
        )
        var next = element
        next.textBoxSizing = .fixedBox
        next.geometry = .calloutComposite(target: layout.target, note: resized)
        normalizeTextElement(&next, proposedRect: resized.cgRect)
        return next
    }

    private func translatingStepComponent(
        _ component: ScreenshotStepComponent,
        of element: ScreenshotElement,
        dx: Double,
        dy: Double
    ) -> ScreenshotElement {
        guard case let .step(badgeCenter, rawNote) = element.geometry else { return element }
        let layout = ScreenshotStepResolvedLayout(element: element)
        let appearance = element.appearance.stepAppearance
        var next = element
        switch component {
        case .badge:
            let proposed = ScreenshotPixelPoint(x: badgeCenter.x + dx, y: badgeCenter.y + dy)
            let center = ScreenshotStepResolvedLayout.constrainedBadgeCenter(
                proposed,
                badgeDiameter: appearance.badgeSize,
                noteRect: rawNote,
                gap: appearance.gap,
                constrainedTo: cropRect
            )
            next.geometry = .step(badgeCenter: center, note: rawNote)
        case .note:
            guard let rawNote else { return element }
            let proposed = ScreenshotPixelRect(
                x: rawNote.x + Int(dx.rounded()),
                y: rawNote.y + Int(dy.rounded()),
                width: rawNote.width,
                height: rawNote.height
            )
            let note = ScreenshotStepResolvedLayout.constrainedNoteRect(
                proposed,
                badgeCenter: badgeCenter,
                badgeDiameter: appearance.badgeSize,
                gap: appearance.gap,
                constrainedTo: cropRect
            )
            next.geometry = .step(badgeCenter: badgeCenter, note: note)
        case .connector:
            guard let layout,
                  let connector = layout.connector,
                  let control = layout.connectorControlPoint else { return element }
            var stepAppearance = appearance
            stepAppearance.connector.curvature = ScreenshotGeometry.lineCurvature(
                start: connector.start,
                end: connector.end,
                control: .init(x: control.x + dx, y: control.y + dy)
            )
            next.appearance.stepAppearance = stepAppearance
        }
        return next
    }

    private func resolvingStepLayout(_ element: ScreenshotElement) -> ScreenshotElement {
        guard case let .step(badgeCenter, rawNote) = element.geometry,
              let rawNote else { return element }
        let appearance = element.appearance.stepAppearance
        var next = element
        next.geometry = .step(
            badgeCenter: badgeCenter,
            note: ScreenshotStepResolvedLayout.constrainedNoteRect(
                rawNote,
                badgeCenter: badgeCenter,
                badgeDiameter: appearance.badgeSize,
                gap: appearance.gap,
                constrainedTo: cropRect
            )
        )
        return next
    }

    private func resizedStepNote(
        _ element: ScreenshotElement,
        to resized: ScreenshotPixelRect,
        handle: ScreenshotResizeHandle
    ) -> ScreenshotElement {
        guard case let .step(badgeCenter, _) = element.geometry else { return element }
        let base = resized.cgRect
        let textAppearance = ScreenshotStepEditorLayout.inlineTextAppearance(from: element.appearance)
        let layout = ScreenshotTextLayout(appearance: textAppearance)
        let width = min(max(base.width, 80), Double(cropRect.width))
        let measuredHeight = element.text.map {
            layout.measure($0, sizing: .fixedWidth, constrainedTo: width).height
        } ?? 0
        let height = min(max(1, max(base.height, measuredHeight)), Double(cropRect.height))
        let x = handle.resizesFromLeadingEdge ? base.maxX - width : base.minX
        let y = handle.resizesFromTopEdge ? base.maxY - height : base.minY
        let proposed = ScreenshotPixelRect(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: max(1, Int(width.rounded())),
            height: max(1, Int(height.rounded()))
        )
        var next = element
        let stepAppearance = next.appearance.stepAppearance
        next.textBoxSizing = .fixedWidth
        next.geometry = .step(
            badgeCenter: badgeCenter,
            note: ScreenshotStepResolvedLayout.constrainedNoteRect(
                proposed,
                badgeCenter: badgeCenter,
                badgeDiameter: stepAppearance.badgeSize,
                gap: stepAppearance.gap,
                constrainedTo: cropRect
            )
        )
        return next
    }

    private func clampedCircularCenter(
        _ proposed: ScreenshotPixelPoint,
        diameter: Double
    ) -> ScreenshotPixelPoint {
        let magnifierBounds = cropRect
        let resolvedDiameter = min(
            max(0, diameter),
            Double(magnifierBounds.width),
            Double(magnifierBounds.height)
        )
        let radius = resolvedDiameter / 2
        let minimumX = Double(magnifierBounds.x) + radius
        let maximumX = Double(magnifierBounds.x + magnifierBounds.width) - radius
        let minimumY = Double(magnifierBounds.y) + radius
        let maximumY = Double(magnifierBounds.y + magnifierBounds.height) - radius
        return ScreenshotPixelPoint(
            x: min(max(proposed.x, minimumX), max(minimumX, maximumX)),
            y: min(max(proposed.y, minimumY), max(minimumY, maximumY))
        )
    }

    private func magnifierLensRect(for element: ScreenshotElement) -> ScreenshotPixelRect {
        ScreenshotMagnifierResolvedLayout(
            element: element,
            constrainedTo: cropRect
        )?.lensRect ?? ScreenshotGeometry.bounds(of: element)
    }

    private func anchoredSquareResize(
        _ originalRect: ScreenshotPixelRect,
        handle: ScreenshotResizeHandle,
        to proposedPoint: ScreenshotPixelPoint,
        minimumDiameter: Double,
        maximumDiameter: Double,
        constrainedTo constraintBounds: ScreenshotPixelRect? = nil
    ) -> (rect: ScreenshotPixelRect, center: ScreenshotPixelPoint, diameter: Double) {
        let bounds = constraintBounds ?? sourceBounds
        let left = Double(min(originalRect.x, originalRect.x + originalRect.width))
        let top = Double(min(originalRect.y, originalRect.y + originalRect.height))
        let right = Double(max(originalRect.x, originalRect.x + originalRect.width))
        let bottom = Double(max(originalRect.y, originalRect.y + originalRect.height))
        let anchorX = handle.resizesFromLeadingEdge ? right : left
        let anchorY = handle.resizesFromTopEdge ? bottom : top
        let horizontalRoom = handle.resizesFromLeadingEdge
            ? anchorX - Double(bounds.x)
            : Double(bounds.x + bounds.width) - anchorX
        let verticalRoom = handle.resizesFromTopEdge
            ? anchorY - Double(bounds.y)
            : Double(bounds.y + bounds.height) - anchorY
        let supportedMaximum = max(0, min(maximumDiameter, horizontalRoom, verticalRoom))
        let supportedMinimum = min(max(0, minimumDiameter), supportedMaximum)
        let requested = max(abs(proposedPoint.x - anchorX), abs(proposedPoint.y - anchorY))
        let diameter = Double(Int(min(max(requested, supportedMinimum), supportedMaximum).rounded()))
        let x = handle.resizesFromLeadingEdge ? anchorX - diameter : anchorX
        let y = handle.resizesFromTopEdge ? anchorY - diameter : anchorY
        let rect = ScreenshotPixelRect(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: Int(diameter),
            height: Int(diameter)
        )
        return (
            rect,
            ScreenshotPixelPoint(x: x + diameter / 2, y: y + diameter / 2),
            diameter
        )
    }

    private func translatedGeometry(
        of element: ScreenshotElement,
        dx: Double,
        dy: Double
    ) -> ScreenshotElementGeometry {
        if case .magnifier = element.geometry,
           let layout = ScreenshotMagnifierResolvedLayout(
               element: element,
               constrainedTo: cropRect
           ) {
            return .magnifier(center: clampedCircularCenter(
                .init(x: layout.center.x + dx, y: layout.center.y + dy),
                diameter: layout.diameter
            ))
        }
        return ScreenshotGeometry.translateWithinBounds(
            element,
            dx: dx,
            dy: dy,
            bounds: sourceBounds
        )
    }

    private func constrainedLineEnd(start: ScreenshotPixelPoint, end: ScreenshotPixelPoint) -> ScreenshotPixelPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return ScreenshotPixelPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private var handleTolerance: Double { activeHandleTolerance }

    private func accessibilityHandlePoint(
        _ handle: ScreenshotResizeHandle,
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

    private func clearInteraction() {
        effectPreviewPending = false
        effectPreviewInFlight = false
        interaction = nil
        draftElement = nil
        draftCropRect = nil
        interactionBaseImage = nil
    }

    private func reuseRenderedPreviewForCropRevision() {
        manualOCRCoordinator.invalidate(for: document.renderRevision.rawValue)
        guard renderedVisibleRect == previewVisibleRect,
              renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            refreshRender()
            return
        }
        renderedRevision = document.renderRevision
        renderState = .idle
        performPendingOutputIfReady()
    }

    private func refreshPreviewAfterCropRevision() {
        if containsMagnifier {
            refreshRender()
        } else {
            reuseRenderedPreviewForCropRevision()
        }
    }

    private var containsMagnifier: Bool {
        document.presentedSnapshot.elements.contains(where: { $0.kind == .magnifier })
    }

    private func refreshRender(isEffectPreview: Bool = false) {
        if !isEffectPreview {
            effectPreviewPending = false
            effectPreviewInFlight = false
        }
        manualOCRCoordinator.invalidate(for: document.renderRevision.rawValue)
        let previewCrop = previewVisibleRect
        let request = ScreenshotSceneRenderRequest(
            revision: document.renderRevision,
            snapshot: ScreenshotSceneRenderSnapshot(
                cropRect: previewCrop,
                watermarkClipRect: document.presentedSnapshot.cropRect,
                elements: document.presentedSnapshot.elements,
                outputAppearance: .init()
            )
        )
        renderState = .rendering
        renderSubmissionCount += 1
        renderPipeline.submit(
            sourceContext: document.sourceContext,
            request: request,
            completion: { [weak self] result in
                guard let self else { return }
                guard self.document.renderRevision == result.revision else {
                    if isEffectPreview { self.completeEffectPreview(with: nil) }
                    return
                }
                self.renderedImage = result.image.nsImage
                if (self.draftElement?.requiresThrottledEffectPreview == true || self.draftCropRect != nil),
                   self.interaction != nil || self.styleInteractionElementID != nil {
                    self.interactionBaseImage = result.image.nsImage
                }
                self.renderedVisibleRect = previewCrop
                self.renderedRevision = result.revision
                self.renderState = .idle
                if let selectedElementID = self.selectedElementID {
                    self.prepareSelectionBase(for: selectedElementID)
                }
                self.performPendingOutputIfReady()
                self.performPendingManualOCRIfReady()
                // Submit a coalesced successor only after this accepted frame
                // has fully updated state. Otherwise the older completion can
                // overwrite the new request's `.rendering` state and base.
                if isEffectPreview {
                    self.completeEffectPreview(with: result.image.nsImage)
                }
            },
            failure: { [weak self] revision, message in
                guard let self else { return }
                guard self.document.renderRevision == revision else {
                    if isEffectPreview { self.completeEffectPreview(with: nil) }
                    return
                }
                self.pendingOutputGate.clear()
                let replacementCompletion = self.pendingReplacementCompletion
                self.pendingReplacementCompletion = nil
                self.isOutputPending = false
                self.renderState = .failed(message)
                self.presentNotification(
                    level: .error,
                    title: L10n.string("status.failed.title"),
                    detail: message,
                    deduplicationKey: "screenshot.render.failed"
                )
                replacementCompletion?(nil)
                if isEffectPreview {
                    self.completeEffectPreview(with: nil)
                }
            }
        )
    }

    private var previewVisibleRect: ScreenshotPixelRect {
        sourceBounds
    }

    private func requestManualOCR(region: ScreenshotPixelRect) {
        guard !manualOCRCoordinator.state.isLocked else { return }
        pendingManualOCRRegion = region
        if cachedOutputRequest() == nil {
            if renderState != .rendering { refreshRender() }
            return
        }
        performPendingManualOCRIfReady()
    }

    private func performPendingManualOCRIfReady() {
        guard let region = pendingManualOCRRegion,
              let request = cachedOutputRequest() else { return }
        guard let requestID = manualOCRCoordinator.prepareRecognition(
            region: region,
            revision: request.revision.rawValue
        ) else { return }
        pendingManualOCRRegion = nil
        manualOCROutputTask?.cancel()
        manualOCROutputGeneration &+= 1
        let generation = manualOCROutputGeneration
        let processor = outputImageProcessor
        manualOCROutputTask = Task { @MainActor [weak self] in
            let image = await Self.processOutput(request, using: processor)
            guard !Task.isCancelled,
                  let self,
                  self.manualOCROutputGeneration == generation else { return }
            self.manualOCROutputTask = nil
            guard self.document.renderRevision == request.revision else {
                self.manualOCRCoordinator.cancel()
                return
            }
            guard let image else {
                self.manualOCRCoordinator.cancel()
                self.presentNotification(
                    level: .error,
                    title: L10n.string("screenshot.render.failed"),
                    deduplicationKey: "screenshot.ocr.output.processing.failed"
                )
                return
            }
            self.performManualOCR(
                region: region,
                image: image,
                requestID: requestID
            )
        }
    }

    private func performManualOCR(
        region: ScreenshotPixelRect,
        image: CGImage,
        requestID: UUID
    ) {
        let crop = cropRect.cgRect
        let selected = region.cgRect.intersection(crop)
        guard !selected.isNull, selected.width >= 2, selected.height >= 2 else {
            manualOCRCoordinator.cancel()
            return
        }
        let local = CGRect(
            x: selected.minX - crop.minX,
            y: selected.minY - crop.minY,
            width: selected.width,
            height: selected.height
        ).integral
        guard let selectedImage = image.cropping(to: local) else {
            manualOCRCoordinator.cancel()
            presentNotification(
                level: .error,
                title: L10n.string("screenshot.ocr.failed"),
                deduplicationKey: "screenshot.ocr.selection.failed"
            )
            return
        }
        guard manualOCRCoordinator.recognizePrepared(
            image: selectedImage,
            requestID: requestID
        ) else {
            manualOCRCoordinator.cancel()
            return
        }
    }

    private func clampedManualOCRPoint(_ point: ScreenshotPixelPoint) -> ScreenshotPixelPoint {
        let crop = cropRect
        return ScreenshotPixelPoint(
            x: min(max(point.x, Double(crop.x)), Double(crop.x + crop.width)),
            y: min(max(point.y, Double(crop.y)), Double(crop.y + crop.height))
        )
    }

    private func scheduleEffectPreview() {
        effectPreviewPending = true
        submitPendingEffectPreviewIfNeeded()
    }

    private func submitPendingEffectPreviewIfNeeded() {
        guard effectPreviewPending,
              !effectPreviewInFlight,
              hasActiveEffectPreview else { return }
        effectPreviewPending = false
        effectPreviewInFlight = true
        refreshRender(isEffectPreview: true)
    }

    private func completeEffectPreview(with image: NSImage?) {
        let remainsActive = hasActiveEffectPreview
        if remainsActive, let image {
            interactionBaseImage = image
        }
        effectPreviewInFlight = false
        guard remainsActive else {
            effectPreviewPending = false
            return
        }
        submitPendingEffectPreviewIfNeeded()
    }

    private var hasActiveEffectPreview: Bool {
        (draftElement?.requiresThrottledEffectPreview == true
            || (draftCropRect != nil && containsMagnifier))
            && (interaction != nil || styleInteractionElementID != nil)
    }

    private func prepareSelectionBase(for elementID: UUID) {
        let visibleRect = renderedVisibleRect
        let elements = document.presentedSnapshot.elements
        let key = SelectionBaseKey(
            elementID: elementID,
            visibleRect: visibleRect,
            revision: document.renderRevision
        )
        guard elements.contains(where: { $0.id == elementID }) else {
            invalidateSelectionBase()
            return
        }
        if selectionBaseElementID == elementID,
           selectionBaseVisibleRect == visibleRect,
           selectionBaseRevision == key.revision,
           selectionBaseImage != nil {
            return
        }
        guard pendingSelectionBaseKey != key else { return }
        selectionBasePipeline.cancel()
        pendingSelectionBaseKey = key
        selectionBaseElementID = nil
        selectionBaseVisibleRect = nil
        selectionBaseRevision = nil
        selectionBaseImage = nil
        if elements.count == 1,
           let source = sourcePreviewImage(croppedTo: visibleRect) {
            selectionBaseElementID = elementID
            selectionBaseVisibleRect = visibleRect
            selectionBaseRevision = key.revision
            selectionBaseImage = source
            pendingSelectionBaseKey = nil
            return
        }
        let request = ScreenshotSceneRenderRequest(
            revision: document.renderRevision,
            snapshot: ScreenshotSceneRenderSnapshot(
                cropRect: visibleRect,
                watermarkClipRect: document.presentedSnapshot.cropRect,
                elements: elements.filter { $0.id != elementID },
                outputAppearance: .init()
            )
        )
        selectionBasePipeline.submit(
            sourceContext: document.sourceContext,
            request: request,
            completion: { [weak self] result in
                guard let self,
                      self.selectedElementID == elementID,
                      self.renderedVisibleRect == visibleRect,
                      self.pendingSelectionBaseKey == key else { return }
                self.selectionBaseElementID = elementID
                self.selectionBaseVisibleRect = visibleRect
                self.selectionBaseRevision = result.revision
                self.selectionBaseImage = result.image.nsImage
                self.pendingSelectionBaseKey = nil
                if self.interaction != nil, self.draftElement?.id == elementID {
                    self.interactionBaseImage = result.image.nsImage
                }
            },
            failure: { [weak self] revision, _ in
                guard let self,
                      self.pendingSelectionBaseKey == key,
                      revision == key.revision else { return }
                self.pendingSelectionBaseKey = nil
            }
        )
    }

    private func prepareTextEditingBase(for elementID: UUID) {
        let visibleRect = renderedVisibleRect
        let elements = document.presentedSnapshot.elements
        guard let editingElement = elements.first(where: { $0.id == elementID }) else { return }
        textEditingBasePipeline.cancel()

        if editingElement.kind == .text {
            if selectionBaseElementID == elementID,
               selectionBaseVisibleRect == visibleRect,
               selectionBaseRevision == document.renderRevision,
               let selectionBaseImage {
                completeTextEditingBase(selectionBaseImage, elementID: elementID, visibleRect: visibleRect)
                return
            }
            if elements.count == 1,
               let source = sourcePreviewImage(croppedTo: visibleRect) {
                completeTextEditingBase(source, elementID: elementID, visibleRect: visibleRect)
                return
            }
        }

        let previewElements = elements.compactMap { element -> ScreenshotElement? in
            guard element.id == elementID else { return element }
            return ScreenshotStepEditorLayout.editingBaseElement(from: element)
        }
        let request = ScreenshotSceneRenderRequest(
            revision: document.renderRevision,
            snapshot: ScreenshotSceneRenderSnapshot(
                cropRect: visibleRect,
                watermarkClipRect: document.presentedSnapshot.cropRect,
                elements: previewElements,
                outputAppearance: .init()
            )
        )
        textEditingBasePipeline.submit(
            sourceContext: document.sourceContext,
            request: request,
            completion: { [weak self] result in
                self?.completeTextEditingBase(
                    result.image.nsImage,
                    elementID: elementID,
                    visibleRect: visibleRect
                )
            }
        )
    }

    private func completeTextEditingBase(
        _ image: NSImage,
        elementID: UUID,
        visibleRect: ScreenshotPixelRect
    ) {
        guard pendingInlineTextEditElementID == elementID,
              selectedElementID == elementID,
              renderedVisibleRect == visibleRect else { return }
        interactionBaseImage = image
        inlineTextEditElementID = elementID
        pendingInlineTextEditElementID = nil
        inlineTextEditRequestID &+= 1
    }

    private func invalidateSelectionBase() {
        selectionBasePipeline.cancel()
        pendingSelectionBaseKey = nil
        selectionBaseElementID = nil
        selectionBaseVisibleRect = nil
        selectionBaseRevision = nil
        selectionBaseImage = nil
    }

    private func sourcePreviewImage(croppedTo rect: ScreenshotPixelRect) -> NSImage? {
        let localRect = CGRect(
            x: rect.x - sourceBounds.x,
            y: rect.y - sourceBounds.y,
            width: rect.width,
            height: rect.height
        )
        guard let image = document.sourceContext.compositeSource.cropping(to: localRect) else { return nil }
        return image.nsImage
    }

    private func cancelBackgroundWork() {
        cancelOutputTask()
        cancelManualOCROutputPreparation()
        manualOCRCoordinator.cancel()
        pendingOutputGate.clear()
        activeOutputCommand = nil
        let replacementCompletion = pendingReplacementCompletion
        pendingReplacementCompletion = nil
        isOutputPending = false
        renderPipeline.cancel()
        selectionBasePipeline.cancel()
        effectPreviewPending = false
        effectPreviewInFlight = false
        implicitStyleCommitTask?.cancel()
        implicitStyleCommitTask = nil
        replacementCompletion?(nil)
    }

    private func cancelManualOCROutputPreparation() {
        manualOCROutputGeneration &+= 1
        manualOCROutputTask?.cancel()
        manualOCROutputTask = nil
        pendingManualOCRRegion = nil
    }

    private func beginOutputTask(_ command: ScreenshotEditorOutputCommand?) -> Int {
        outputTask?.cancel()
        outputGeneration &+= 1
        isOutputPending = true
        activeOutputCommand = command
        return outputGeneration
    }

    private func cancelOutputTask() {
        outputGeneration &+= 1
        outputTask?.cancel()
        outputTask = nil
        activeOutputCommand = nil
        isOutputPending = false
        resolveHostOutput(.cancelled)
    }

    private func finishOutputTask(
        generation: Int,
        result: ScreenshotEditorOutputExecutionResult? = nil
    ) {
        guard outputGeneration == generation else { return }
        outputTask = nil
        activeOutputCommand = nil
        isOutputPending = false
        if let result { resolveHostOutput(result) }
    }

    private func cancelHostOutput(waiterID: UUID) {
        guard hostOutputWaiter?.id == waiterID else { return }
        cancelOutputTask()
        pendingOutputGate.clear()
    }

    private func resolveHostOutput(_ result: ScreenshotEditorOutputExecutionResult) {
        let waiter = hostOutputWaiter
        hostOutputWaiter = nil
        waiter?.continuation.resume(returning: result)
    }

    private func isCurrentOutputTask(_ generation: Int) -> Bool {
        outputGeneration == generation && !Task.isCancelled
    }

    private func loadStyleForCurrentContext() {
        isLoadingStyle = true
        if let selected = selectedElement {
            activeStyle = selected.appearance
        } else {
            activeStyle = preferencesStore.preferences.toolPresets[selectedTool]?.appearance
                ?? ScreenshotElementAppearance.defaultValue(for: selectedTool)
        }
        isLoadingStyle = false
    }

    private func persistActiveStyle() {
        guard !isLoadingStyle else { return }
        stylePersistenceCount += 1
        let tool = inspectorTool
        let presetAppearance = activeStyle
        preferencesStore.update {
            $0.toolPresets[tool] = ScreenshotToolPreset(tool: tool, appearance: presetAppearance)
        }
    }

    private func provideCurvatureAnchorFeedback() {
        curvatureAnchorPulse &+= 1
        curvatureAnchorFeedback()
    }

    private func scheduleImplicitStyleCommit() {
        implicitStyleCommitTask?.cancel()
        implicitStyleCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.endStyleEditing()
        }
    }

    private func finishPropertyEditing() {
        if isStyleEditing { endStyleEditing() }
        if isWatermarkEditing { endWatermarkEditing() }
    }

    private func performOrQueue(
        _ command: ScreenshotEditorOutputCommand
    ) -> ScreenshotEditorOutputAdmission {
        guard !isCloseConfirmationPresented else { return .closeConfirmation }
        guard !isOutputPending else { return .busy }
        guard command != .copy || allowsDirectImageCopy else {
            return .directCopyUnavailable
        }
        finishPropertyEditing()
        guard let request = cachedOutputRequest() else {
            guard pendingOutputGate.enqueue(command) else { return .busy }
            isOutputPending = true
            if renderState != .rendering { refreshRender() }
            return .accepted
        }
        perform(command, request: request)
        return .accepted
    }

    private func performPendingOutputIfReady() {
        if let completion = pendingReplacementCompletion,
           let request = cachedOutputRequest() {
            pendingReplacementCompletion = nil
            isOutputPending = false
            performReplacement(request, completion: completion)
            return
        }
        guard let command = pendingOutputGate.pending,
              let request = cachedOutputRequest() else { return }
        _ = pendingOutputGate.take()
        isOutputPending = false
        perform(command, request: request)
    }

    private func requestReplacementOutput(completion: @escaping (NSImage?) -> Void) {
        guard !isCloseConfirmationPresented,
              !isOutputPending,
              pendingReplacementCompletion == nil,
              pendingOutputGate.pending == nil else {
            completion(nil)
            return
        }
        finishPropertyEditing()
        if let request = cachedOutputRequest() {
            performReplacement(request, completion: completion)
            return
        }
        pendingReplacementCompletion = completion
        isOutputPending = true
        if renderState != .rendering { refreshRender() }
    }

    private func performReplacement(
        _ request: OutputImageRequest,
        completion: @escaping (NSImage?) -> Void
    ) {
        pendingReplacementCompletion = completion
        let generation = beginOutputTask(nil)
        let processor = outputImageProcessor
        outputTask = Task { @MainActor [weak self] in
            let image = await Self.processOutput(request, using: processor)
            guard !Task.isCancelled,
                  let self, self.isCurrentOutputTask(generation) else { return }
            let completion = self.pendingReplacementCompletion
            self.pendingReplacementCompletion = nil
            self.finishOutputTask(generation: generation)
            completion?(image?.nsImage)
        }
    }

    private func perform(_ command: ScreenshotEditorOutputCommand, request: OutputImageRequest) {
        let generation = beginOutputTask(command)
        let processor = outputImageProcessor
        outputTask = Task { @MainActor [weak self] in
            let image = await Self.processOutput(request, using: processor)
            guard !Task.isCancelled,
                  let self, self.isCurrentOutputTask(generation) else { return }
            guard let image else {
                self.finishOutputTask(generation: generation, result: .failed)
                self.presentNotification(
                    level: .error,
                    title: L10n.string("screenshot.render.failed"),
                    deduplicationKey: "screenshot.output.processing.failed"
                )
                return
            }
            self.perform(command, image: image, generation: generation)
        }
    }

    private func perform(
        _ command: ScreenshotEditorOutputCommand,
        image: CGImage,
        generation: Int
    ) {
        switch command {
        case .copy:
            outputTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.outputCoordinator.copy(image)
                    guard self.isCurrentOutputTask(generation) else {
                        self.finishOutputTask(generation: generation, result: .cancelled)
                        return
                    }
                    self.presentNotification(
                        level: .success,
                        title: L10n.string("screenshot.result.copySucceeded"),
                        deduplicationKey: "screenshot.copy.succeeded"
                    )
                    self.finishOutputTask(generation: generation, result: .succeeded)
                } catch {
                    guard self.isCurrentOutputTask(generation) else {
                        self.finishOutputTask(generation: generation, result: .cancelled)
                        return
                    }
                    self.presentNotification(
                        level: .error,
                        title: L10n.string("screenshot.result.copyFailed"),
                        detail: error.localizedDescription,
                        deduplicationKey: "screenshot.copy.failed"
                    )
                    self.finishOutputTask(
                        generation: generation,
                        result: error is CancellationError ? .cancelled : .failed
                    )
                }
            }
        case .save:
            outputTask = Task { @MainActor [weak self] in
                guard let self,
                      !self.isShutdown,
                      self.isCurrentOutputTask(generation) else { return }
                do {
                    guard let url = try await self.outputCoordinator.saveAs(image) else {
                        self.finishOutputTask(generation: generation, result: .cancelled)
                        return
                    }
                    guard self.isCurrentOutputTask(generation) else {
                        self.finishOutputTask(generation: generation, result: .cancelled)
                        return
                    }
                    self.presentNotification(
                        level: .success,
                        title: L10n.string("screenshot.result.saveSucceeded"),
                        detail: L10n.format(
                            "screenshot.result.saveSucceededDetail",
                            url.lastPathComponent
                        ),
                        deduplicationKey: "screenshot.save.succeeded"
                    )
                    self.finishOutputTask(generation: generation, result: .succeeded)
                    if self.closesAfterSuccessfulSave {
                        self.cancelBackgroundWork()
                        self.onSaved(image.nsImage)
                    }
                } catch {
                    guard self.isCurrentOutputTask(generation) else {
                        self.finishOutputTask(generation: generation, result: .cancelled)
                        return
                    }
                    self.presentNotification(
                        level: .error,
                        title: L10n.string("screenshot.result.saveFailed"),
                        detail: error.localizedDescription,
                        deduplicationKey: "screenshot.save.failed"
                    )
                    self.finishOutputTask(
                        generation: generation,
                        result: error is CancellationError ? .cancelled : .failed
                    )
                }
            }
        case .pin:
            cancelBackgroundWork()
            onPinned(pinnedPresentation(image: image.nsImage))
        case .complete:
            cancelBackgroundWork()
            onComplete(image.nsImage)
        }
    }

    private func pinnedPresentation(image: NSImage) -> PinnedScreenshotPresentation {
        let cropRect = document.snapshot.cropRect
        let logicalSize = PinnedScreenshotGeometry.logicalSize(
            cropRect: cropRect,
            outputPixelScale: pinnedOutputPixelScale
        )
        let preferredScreenFrame = pinsLongScreenshotFromCaptureTopEdge
            ? PinnedScreenshotGeometry.preferredLongScreenshotFrame(
                captureScreenRect: pinnedCaptureScreenRect,
                logicalSize: logicalSize
            )
            : PinnedScreenshotGeometry.preferredScreenFrame(
                cropRect: cropRect,
                sourceFrame: pinnedSourceFrame,
                outputPixelScale: pinnedOutputPixelScale
            )
        return PinnedScreenshotPresentation(
            image: image,
            logicalSize: logicalSize,
            outputPixelScale: pinnedOutputPixelScale,
            preferredScreenFrame: preferredScreenFrame,
            targetVisibleFrame: presentationVisibleFrame(preferredScreenFrame)
        )
    }

    private func presentNotification(
        level: BlocksNotificationLevel,
        title: String,
        detail: String? = nil,
        deduplicationKey: String
    ) {
        notificationState.present(BlocksNotificationDescriptor(
            level: level,
            title: title,
            detail: detail,
            deduplicationKey: deduplicationKey
        ))
    }

    private func cachedOutputRequest() -> OutputImageRequest? {
        guard renderedRevision == document.renderRevision,
              let image = renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let crop = document.snapshot.cropRect
        guard renderedVisibleRect.x <= crop.x,
              renderedVisibleRect.y <= crop.y,
              renderedVisibleRect.x + renderedVisibleRect.width >= crop.x + crop.width,
              renderedVisibleRect.y + renderedVisibleRect.height >= crop.y + crop.height else {
            return nil
        }
        return OutputImageRequest(
            image: image,
            imageRect: renderedVisibleRect,
            outputRect: crop,
            appearance: document.snapshot.outputAppearance,
            revision: document.renderRevision
        )
    }

    private static func processOutput(
        _ request: OutputImageRequest,
        using processor: @escaping ScreenshotEditorOutputImageProcessor
    ) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            try? processor(
                request.image,
                request.imageRect,
                request.outputRect,
                request.appearance
            )
        }.value
    }
}

enum ScreenshotEditorOutputCommand: Equatable {
    case copy
    case pin
    case save
    case complete
}

enum ScreenshotEditorOutputAdmission: Equatable {
    case accepted
    case busy
    case closeConfirmation
    case directCopyUnavailable

    var isAccepted: Bool { self == .accepted }

    var operationCode: String {
        switch self {
        case .accepted: "accepted"
        case .busy: "rejected_busy"
        case .closeConfirmation: "rejected_close_confirmation"
        case .directCopyUnavailable: "rejected_direct_copy_unavailable"
        }
    }
}

enum ScreenshotEditorOutputExecutionResult: Equatable {
    case succeeded
    case failed
    case cancelled
    case rejected(ScreenshotEditorOutputAdmission)
}

enum ScreenshotEditorCompletionPreparation {
    case prepared(NSImage)
    case failed
    case cancelled
    case rejected(ScreenshotEditorOutputAdmission)
}

struct ScreenshotPendingOutputGate {
    private(set) var pending: ScreenshotEditorOutputCommand?

    mutating func enqueue(_ command: ScreenshotEditorOutputCommand) -> Bool {
        guard pending == nil else { return false }
        pending = command
        return true
    }

    mutating func take() -> ScreenshotEditorOutputCommand? {
        defer { pending = nil }
        return pending
    }

    mutating func clear() {
        pending = nil
    }
}

private enum ScreenshotEditorInteraction {
    case creating(elementID: UUID, start: ScreenshotPixelPoint)
    case moving(id: UUID, start: ScreenshotPixelPoint, original: ScreenshotElement)
    case movingStepComponent(
        id: UUID,
        start: ScreenshotPixelPoint,
        original: ScreenshotElement,
        component: ScreenshotStepComponent
    )
    case movingCalloutComponent(
        id: UUID,
        start: ScreenshotPixelPoint,
        original: ScreenshotElement,
        component: ScreenshotCalloutComponent
    )
    case resizing(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case resizingStepBadge(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case resizingStepNote(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case resizingMagnifier(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case lineEndpoint(id: UUID, original: ScreenshotElement, editsStart: Bool)
    case lineCurve(id: UUID, original: ScreenshotElement)
    case calloutPointer(id: UUID, original: ScreenshotElement)
    case calloutCurve(id: UUID, original: ScreenshotElement)
    case resizingCalloutTarget(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case resizingCalloutNote(id: UUID, original: ScreenshotElement, handle: ScreenshotResizeHandle)
    case cropCreate(start: ScreenshotPixelPoint)
    case cropResize(original: ScreenshotPixelRect, handle: ScreenshotResizeHandle)
    case cropMove(original: ScreenshotPixelRect, start: ScreenshotPixelPoint)
}

struct ScreenshotEditorViewportState: Equatable {
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
}

enum ScreenshotEditorRenderState: Equatable {
    case idle
    case rendering
    case failed(String)
}

enum ScreenshotEditorError: LocalizedError, Equatable {
    case missingCGImage
    case editingContextUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCGImage:
            L10n.string("error.noCGImage")
        case .editingContextUnavailable:
            L10n.string("screenshot.editor.quickContextUnavailable")
        }
    }
}

private extension CGPoint {
    var pixelPoint: ScreenshotPixelPoint { .init(x: x.rounded(), y: y.rounded()) }
}

private extension CGRect {
    var pixelRect: ScreenshotPixelRect {
        .init(x: Int(minX.rounded()), y: Int(minY.rounded()), width: max(1, Int(width.rounded())), height: max(1, Int(height.rounded())))
    }
}

private extension ScreenshotPixelPoint {
    func distance(to other: ScreenshotPixelPoint) -> Double { hypot(x - other.x, y - other.y) }
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


private extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
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

    var resizesFromLeadingEdge: Bool {
        switch self {
        case .northWest, .west, .southWest:
            true
        case .north, .northEast, .east, .southEast, .south:
            false
        }
    }

    var resizesFromTopEdge: Bool {
        switch self {
        case .northWest, .north, .northEast:
            true
        case .east, .southEast, .south, .southWest, .west:
            false
        }
    }
}

private extension ScreenshotPixelPoint {
    func distanceToSegment(
        from start: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: start) }
        let projection = ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, projection))
        return hypot(x - (start.x + t * dx), y - (start.y + t * dy))
    }
}

private extension ScreenshotElement {
    var requiresThrottledEffectPreview: Bool {
        switch kind {
        case .blur, .pixelate, .magnifier:
            true
        case .redact:
            appearance.redactMode == .securePixelate
        default:
            false
        }
    }
}
