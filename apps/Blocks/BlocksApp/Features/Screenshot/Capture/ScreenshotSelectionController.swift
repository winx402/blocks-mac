import AppKit
import BlocksScreenshotCore
import os

enum ScreenshotSelectionResult {
    case window(UInt32)
    case region(CGRect)
    case display(UInt32)
    case allDisplays
    case scrollingRegion(CGRect, displayID: UInt32, sessionID: String)
    case screenRecordingPermissionMissing
    case inputMonitoringPermissionMissing
    case cancelled
    case timedOut
    case snapshotFailed
}

struct ScreenshotFrozenSelectionSnapshot {
    let images: [UInt32: CGImage]
    let candidates: [ScreenshotSelectionCandidate]
    let displayDescriptors: [ScreenshotDisplayDescriptor]
}

struct ScreenshotSelectionHandoffFrame {
    private let imagesByDisplayID: [UInt32: CGImage]

    init(context: ScreenshotEditingContext) {
        let image = context.sourceContext.compositeSource
        let sourceBounds = context.sourceContext.sourceBounds
        let sourceFrame = context.sourceFrame
        guard sourceFrame.width > 0, sourceFrame.height > 0 else {
            imagesByDisplayID = [:]
            return
        }
        let scaleX = CGFloat(sourceBounds.width) / sourceFrame.width
        let scaleY = CGFloat(sourceBounds.height) / sourceFrame.height
        let sourceRect = CGRect(
            x: CGFloat(sourceBounds.x),
            y: CGFloat(sourceBounds.y),
            width: CGFloat(sourceBounds.width),
            height: CGFloat(sourceBounds.height)
        )
        var slices: [UInt32: CGImage] = [:]
        for screen in context.screens {
            let rect = CGRect(
                x: CGFloat(sourceBounds.x)
                    + (screen.frame.minX - sourceFrame.minX) * scaleX,
                y: CGFloat(sourceBounds.y)
                    + (sourceFrame.maxY - screen.frame.maxY) * scaleY,
                width: screen.frame.width * scaleX,
                height: screen.frame.height * scaleY
            ).integral.intersection(sourceRect)
            guard rect.width > 0,
                  rect.height > 0,
                  let slice = image.cropping(to: rect) else { continue }
            slices[screen.displayID] = slice
        }
        imagesByDisplayID = slices
    }

    func image(for displayID: UInt32) -> CGImage? {
        imagesByDisplayID[displayID]
    }
}

struct ScreenshotSelectionCandidate {
    let id: UInt32
    let frame: CGRect
    let visibleHitRegions: [CGRect]
    let title: String

    init(
        id: UInt32,
        frame: CGRect,
        visibleHitRegions: [CGRect]? = nil,
        title: String
    ) {
        self.id = id
        self.frame = frame
        self.visibleHitRegions = visibleHitRegions ?? [frame]
        self.title = title
    }

    var coreValue: ScreenshotWindowCandidate {
        ScreenshotWindowCandidate(
            id: id,
            frame: frame.selectionRect,
            visibleHitRegions: visibleHitRegions.map(\.selectionRect)
        )
    }

    func containsVisibleHitPoint(_ point: CGPoint) -> Bool {
        visibleHitRegions.contains { $0.contains(point) }
    }
}

struct ScreenshotSelectionDisplay {
    let id: UInt32
    let frame: CGRect
    let title: String
    let backingScale: Double

    var coreValue: ScreenshotDisplayCandidate {
        ScreenshotDisplayCandidate(id: id, frame: frame.selectionRect)
    }
}

enum ScreenshotSelectionInvalidationPolicy {
    /// A stable hover only changes the magnifier/pointer presentation on the
    /// display the pointer left and the display it entered. State changes can
    /// alter a window, region, or all-display highlight and must invalidate all
    /// selection surfaces.
    static func displayIDsForPointerMove(
        previousPointer: CGPoint,
        currentPointer: CGPoint,
        stateChanged: Bool,
        displays: [ScreenshotSelectionDisplay]
    ) -> Set<UInt32>? {
        guard !stateChanged else { return nil }
        let ids = displays.compactMap { display -> UInt32? in
            display.frame.contains(previousPointer) || display.frame.contains(currentPointer)
                ? display.id
                : nil
        }
        return ids.isEmpty ? nil : Set(ids)
    }
}

struct ScreenshotSelectionParameters: Equatable {
    var constraint: ScreenshotRegionConstraint = .free
    var delaySeconds: Double = 0
    var showsCursor = false
    var freezesFrame = false
    var watermarkPresetID: UUID?
}

@MainActor
final class ScreenshotSelectionController {
    private static let performanceSignposter = OSSignposter(
        subsystem: "app.blocks.app",
        category: "ScreenshotPerformance"
    )
    private static let magnifierSize = CGSize(width: 96, height: 96)
    private let reducer = ScreenshotSelectionReducer()
    private let regionGeometry = ScreenshotRegionGeometry()
    private let capturePlanner = ScreenshotCapturePlanner()
    private let logger = Logger(subsystem: "app.blocks.app", category: "ScreenshotSelection")
    private let screenRecordingPermissionProvider: () -> Bool
    private let inputMonitoringPermissionProvider: () -> Bool
    private let scrollingHUD: ScrollingScreenshotHUDController
    private var state: ScreenshotSelectionState = .ready
    private var intentKind: ScreenshotCaptureIntentKind = .smart
    private var candidates: [ScreenshotSelectionCandidate] = []
    private var displays: [ScreenshotSelectionDisplay] = []
    private var frozenSnapshots: [UInt32: CGImage] = [:]
    private var frozenDisplayDescriptors: [ScreenshotDisplayDescriptor] = []
    private var handoffFrame: ScreenshotSelectionHandoffFrame?
    private var magnifierSnapshots: [UInt32: CGImage] = [:]
    private var frozenSnapshotProvider: ((Bool) async throws -> ScreenshotFrozenSelectionSnapshot)?
    private var magnifierSnapshotProvider: (() async throws -> [UInt32: CGImage])?
    private var parametersChanged: (ScreenshotSelectionParameters) -> Void = { _ in }
    private var customConstraints: [ScreenshotCustomConstraintPreset] = []
    private var watermarkPresets: [ScreenshotWatermarkPreset] = []
    private var saveCustomConstraint: (ScreenshotCustomConstraintPreset) -> Void = { _ in }
    private var deleteCustomConstraint: (UUID) -> Void = { _ in }
    private var frozenSnapshotTask: Task<Void, Never>?
    private var initialFrozenSnapshotTask: Task<Void, Never>?
    private var magnifierSnapshotTask: Task<Void, Never>?
    private var frozenSnapshotGeneration = 0
    private var isFrozenSnapshotReady = false
    private var pendingFrozenResult: ScreenshotSelectionResult?
    private var overlayWindows: [ScreenshotSelectionPanel] = []
    private var toolbarPanel: ScreenshotSelectionToolbarPanel?
    private var retainedSelectionSurfaceWindowIDs: Set<UInt32> = []
    private var keyMonitor: Any?
    private var initialFrozenLocalKeyMonitor: Any?
    private var initialFrozenGlobalKeyMonitor: Any?
    private var initialFrozenEscapeHotKey: BlocksGlobalEscapeHotKeyController?
    private var continuation: CheckedContinuation<ScreenshotSelectionResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// Every asynchronous setup callback must prove it still owns the current
    /// selection before it can create UI or mutate selection state.
    private var selectionGeneration = 0
    private var lastPointer = CGPoint.zero
    private var windowLocked = false
    private var scrollingMode = false
    private var scrollingPreparedRect: CGRect?
    private var scrollingSessionID: String?
    private var transfersScrollingHUD = false
    private var showsParameterToolbar = true
    private var selectionSessionID = ""
    private var selectionStartedAt: CFAbsoluteTime = 0
    private var selectionFinishedAt: CFAbsoluteTime?
    private(set) var parameters = ScreenshotSelectionParameters()
    private(set) var resultFrozenSnapshot: ScreenshotFrozenSelectionSnapshot?

    init(
        screenRecordingPermissionProvider: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        inputMonitoringPermissionProvider: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        scrollingHUD: ScrollingScreenshotHUDController? = nil
    ) {
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.inputMonitoringPermissionProvider = inputMonitoringPermissionProvider
        self.scrollingHUD = scrollingHUD ?? ScrollingScreenshotHUDController()
    }

    func applyDefaults(_ defaults: ScreenshotCaptureDefaults) {
        parameters = ScreenshotSelectionParameters(
            constraint: defaults.regionConstraint,
            delaySeconds: defaults.delaySeconds,
            showsCursor: defaults.showsCursor,
            freezesFrame: defaults.freezesFrame,
            watermarkPresetID: defaults.watermarkPresetID
        )
    }

    func cancel() {
        guard continuation != nil else {
            selectionGeneration &+= 1
            initialFrozenSnapshotTask?.cancel()
            initialFrozenSnapshotTask = nil
            clearInitialFrozenEscapeMonitoring()
            dismissSelectionSurfaces()
            return
        }
        finish(.cancelled)
    }

    func select(
        intent: ScreenshotCaptureIntent,
        candidates: [ScreenshotSelectionCandidate],
        displays: [ScreenshotSelectionDisplay],
        frozenSnapshotProvider: @escaping (Bool) async throws -> ScreenshotFrozenSelectionSnapshot,
        magnifierSnapshotProvider: @escaping () async throws -> [UInt32: CGImage],
        onParametersChanged: @escaping (ScreenshotSelectionParameters) -> Void,
        customConstraints: [ScreenshotCustomConstraintPreset] = [],
        watermarkPresets: [ScreenshotWatermarkPreset] = [],
        onSaveCustomConstraint: @escaping (ScreenshotCustomConstraintPreset) -> Void = { _ in },
        onDeleteCustomConstraint: @escaping (UUID) -> Void = { _ in },
        showsParameterToolbar: Bool = true,
        startsInScrollingMode: Bool = false,
        timeout: TimeInterval = 60
    ) async -> ScreenshotSelectionResult {
        guard continuation == nil else { return .cancelled }
        if startsInScrollingMode, !screenRecordingPermissionProvider() {
            return .screenRecordingPermissionMissing
        }
        if startsInScrollingMode, !inputMonitoringPermissionProvider() {
            return .inputMonitoringPermissionMissing
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            selectionGeneration &+= 1
            let generation = selectionGeneration
            initialFrozenSnapshotTask?.cancel()
            initialFrozenSnapshotTask = nil
            clearInitialFrozenEscapeMonitoring()
            dismissSelectionSurfaces()
            scrollingHUD.dismiss()
            transfersScrollingHUD = false
            intentKind = intent.kind
            self.candidates = candidates
            self.displays = displays
            retainedSelectionSurfaceWindowIDs.removeAll()
            frozenSnapshots.removeAll()
            frozenDisplayDescriptors.removeAll()
            handoffFrame = nil
            resultFrozenSnapshot = nil
            isFrozenSnapshotReady = false
            pendingFrozenResult = nil
            self.frozenSnapshotProvider = frozenSnapshotProvider
            self.magnifierSnapshotProvider = magnifierSnapshotProvider
            parametersChanged = onParametersChanged
            self.customConstraints = customConstraints
            self.watermarkPresets = watermarkPresets
            saveCustomConstraint = onSaveCustomConstraint
            deleteCustomConstraint = onDeleteCustomConstraint
            self.showsParameterToolbar = showsParameterToolbar
            state = initialState(for: intent)
            scrollingMode = startsInScrollingMode
            scrollingSessionID = startsInScrollingMode ? Self.makeScrollingSessionID() : nil
            scrollingPreparedRect = nil
            lastPointer = NSEvent.mouseLocation
            selectionSessionID = UUID().uuidString.lowercased()
            selectionStartedAt = CFAbsoluteTimeGetCurrent()
            selectionFinishedAt = nil
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled,
                      self?.selectionGeneration == generation else { return }
                self?.finish(.timedOut)
            }
            if parameters.freezesFrame {
                startInitialFrozenSnapshot(
                    generation: generation,
                    showsCursor: parameters.showsCursor,
                    provider: frozenSnapshotProvider
                )
            } else {
                showSelectionSurfaces()
                logSelectionReady()
            }
        }
    }

    func mouseMoved(globalPoint: CGPoint) {
        let previousPointer = lastPointer
        let previousState = state
        lastPointer = globalPoint
        guard !windowLocked else { return }
        if isDisplayMode {
            state = reducer.reduce(
                state: state,
                event: .displayHovered(display(at: globalPoint)?.coreValue)
            ).state
        } else if intentKind != .region, !scrollingMode {
            state = reducer.reduce(
                state: state,
                event: .pointerMoved(
                    point: globalPoint.selectionPoint,
                    windowCandidate: candidateCore(at: globalPoint)
                )
            ).state
        }
        redraw(displayIDs: ScreenshotSelectionInvalidationPolicy.displayIDsForPointerMove(
            previousPointer: previousPointer,
            currentPointer: globalPoint,
            stateChanged: previousState != state,
            displays: displays
        ))
    }

    private func startInitialFrozenSnapshot(
        generation: Int,
        showsCursor: Bool,
        provider: @escaping (Bool) async throws -> ScreenshotFrozenSelectionSnapshot
    ) {
        logger.info("stage=snapshot-start mode=frozen")
        guard installInitialFrozenEscapeMonitoring(for: generation) else {
            finish(.inputMonitoringPermissionMissing)
            return
        }
        initialFrozenSnapshotTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await provider(showsCursor)
                guard let self,
                      !Task.isCancelled,
                      self.selectionGeneration == generation,
                      self.continuation != nil else { return }
                self.initialFrozenSnapshotTask = nil
                self.frozenSnapshots = snapshot.images
                self.frozenDisplayDescriptors = snapshot.displayDescriptors
                self.candidates = snapshot.candidates
                self.refreshCurrentWindowPreview()
                self.isFrozenSnapshotReady = true
                self.logger.info(
                    "stage=snapshot-ready mode=frozen displayCount=\(snapshot.images.count)"
                )
                Self.performanceSignposter.emitEvent(
                    "SnapshotReady",
                    "mode=frozen displays=\(snapshot.images.count, privacy: .public)"
                )
                self.clearInitialFrozenEscapeMonitoring()
                self.showSelectionSurfaces()
                self.logSelectionReady()
            } catch is CancellationError {
                guard let self,
                      self.selectionGeneration == generation,
                      self.continuation != nil,
                      !Task.isCancelled else { return }
                self.initialFrozenSnapshotTask = nil
                self.finish(.cancelled)
            } catch {
                guard let self,
                      self.selectionGeneration == generation,
                      self.continuation != nil,
                      !Task.isCancelled else { return }
                self.initialFrozenSnapshotTask = nil
                self.logger.error("stage=snapshot-failed mode=frozen")
                self.finish(.snapshotFailed)
            }
        }
    }

    @discardableResult
    private func installInitialFrozenEscapeMonitoring(for generation: Int) -> Bool {
        clearInitialFrozenEscapeMonitoring()
        let escapeHotKey = BlocksGlobalEscapeHotKeyController { [weak self] in
            self?.requestInitialFrozenCancellation(for: generation)
        }
        if escapeHotKey.start() {
            initialFrozenEscapeHotKey = escapeHotKey
            return true
        }
        guard inputMonitoringPermissionProvider() else { return false }
        initialFrozenLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.requestInitialFrozenCancellation(for: generation)
            }
            return nil
        }
        initialFrozenGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.requestInitialFrozenCancellation(for: generation)
            }
        }
        return initialFrozenLocalKeyMonitor != nil || initialFrozenGlobalKeyMonitor != nil
    }

    private func requestInitialFrozenCancellation(for generation: Int) {
        guard selectionGeneration == generation, continuation != nil else { return }
        finish(.cancelled)
    }

    private func clearInitialFrozenEscapeMonitoring() {
        initialFrozenEscapeHotKey?.stop()
        initialFrozenEscapeHotKey = nil
        if let initialFrozenLocalKeyMonitor {
            NSEvent.removeMonitor(initialFrozenLocalKeyMonitor)
        }
        initialFrozenLocalKeyMonitor = nil
        if let initialFrozenGlobalKeyMonitor {
            NSEvent.removeMonitor(initialFrozenGlobalKeyMonitor)
        }
        initialFrozenGlobalKeyMonitor = nil
    }

    private func logSelectionReady() {
        logger.info(
            "stage=selection-ready mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "SelectionReady",
            "mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public)"
        )
    }

    func scrollingSelectionStatus() -> ScrollingScreenshotRuntimeSnapshot? {
        guard continuation != nil, scrollingMode, let scrollingSessionID else { return nil }
        let outputSize: ScreenshotPixelSize
        if let rect = scrollingPreparedRect {
            let scale = regionOutputScale(for: rect)
            outputSize = ScreenshotPixelSize(
                width: Int((rect.width * scale).rounded()),
                height: Int((rect.height * scale).rounded())
            )
        } else {
            outputSize = ScreenshotPixelSize(width: 0, height: 0)
        }
        return ScrollingScreenshotRuntimeSnapshot(
            sessionID: scrollingSessionID,
            state: .selecting,
            outputSize: outputSize,
            warning: nil
        )
    }

    func cancelScrollingSelection(sessionID: String, confirm: Bool) -> Bool {
        guard confirm,
              continuation != nil,
              scrollingMode,
              scrollingSessionID == sessionID else { return false }
        finish(.cancelled)
        return true
    }

    func mouseDown(globalPoint: CGPoint) {
        lastPointer = globalPoint
        guard !isDisplayMode else { return }
        guard scrollingPreparedRect == nil else { return }
        logger.debug(
            "stage=pointer-down x=\(globalPoint.x, privacy: .public) y=\(globalPoint.y, privacy: .public) frozen=\(self.parameters.freezesFrame, privacy: .public)"
        )
        if !windowLocked { mouseMoved(globalPoint: globalPoint) }
        state = reducer.reduce(
            state: state,
            event: .pointerDown(
                point: globalPoint.selectionPoint,
                windowCandidate: scrollingMode ? nil : candidateCore(at: globalPoint)
            )
        ).state
        redraw()
    }

    func mouseDragged(globalPoint: CGPoint) {
        lastPointer = globalPoint
        guard case let .pendingClick(start, _) = state else {
            if case .regionDrawing = state {
                state = reducer.reduce(
                    state: state,
                    event: .pointerDragged(current: globalPoint.selectionPoint, exceededThreshold: true)
                ).state
                redraw()
            }
            return
        }
        let exceeded = hypot(globalPoint.x - start.x, globalPoint.y - start.y) >= 3
        let previous = state
        state = reducer.reduce(
            state: state,
            event: .pointerDragged(current: globalPoint.selectionPoint, exceededThreshold: exceeded)
        ).state
        if previous != state, case .regionDrawing = state {
            logger.debug(
                "stage=drag-threshold x=\(globalPoint.x, privacy: .public) y=\(globalPoint.y, privacy: .public)"
            )
            toolbarPanel?.setRegionGestureActive(true)
            if !parameters.freezesFrame, magnifierSnapshots.isEmpty { refreshMagnifierSnapshots() }
        }
        redraw()
    }

    func mouseUp(globalPoint: CGPoint) {
        lastPointer = globalPoint
        let resolvedRegion = resolvedRegionForCurrentGesture()
        let transition = reducer.reduce(
            state: state,
            event: .pointerUp(
                point: globalPoint.selectionPoint,
                windowCandidate: scrollingMode ? nil : candidateCore(at: globalPoint),
                resolvedRegion: resolvedRegion?.selectionRect
            )
        )
        state = transition.state
        if let resolvedRegion {
            logger.debug(
                "stage=pointer-up kind=region x=\(resolvedRegion.minX, privacy: .public) y=\(resolvedRegion.minY, privacy: .public) width=\(resolvedRegion.width, privacy: .public) height=\(resolvedRegion.height, privacy: .public)"
            )
        } else {
            logger.debug(
                "stage=pointer-up kind=click x=\(globalPoint.x, privacy: .public) y=\(globalPoint.y, privacy: .public)"
            )
        }
        if transition.effects.isEmpty { toolbarPanel?.setRegionGestureActive(false) }
        handle(transition.effects)
        redraw()
    }

    func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            handle(reducer.reduce(
                state: state,
                event: .keyPressed(.escape, currentDisplay: nil)
            ).effects)
            return
        }
        if event.keyCode == 3 {
            let key: ScreenshotSelectionKey = event.modifierFlags.contains(.shift) ? .allDisplays : .displayMode
            let currentDisplay = key == .displayMode ? display(at: lastPointer)?.coreValue : nil
            let transition = reducer.reduce(
                state: state,
                event: .keyPressed(key, currentDisplay: currentDisplay)
            )
            state = transition.state
            windowLocked = false
            handle(transition.effects)
            redraw()
            return
        }
        if event.keyCode == 48 {
            cycleWindowCandidate(reverse: event.modifierFlags.contains(.shift))
            return
        }
        if event.keyCode == 49 {
            windowLocked.toggle()
            redraw()
        }
    }

    func draw(in view: ScreenshotSelectionCanvasView, dirtyRect _: CGRect) {
        if let display = displays.first(where: { $0.frame == view.window?.frame }) {
            if let snapshot = handoffFrame?.image(for: display.id) {
                NSImage(cgImage: snapshot, size: view.bounds.size).draw(
                    in: view.bounds,
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
            } else if parameters.freezesFrame,
                      let snapshot = frozenSnapshots[display.id] {
                NSImage(cgImage: snapshot, size: view.bounds.size).draw(
                    in: view.bounds,
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
            }
        }

        let localHighlight = highlightedGlobalRect.map(view.convertGlobalToLocal)
        let mask = NSBezierPath(rect: view.bounds)
        if let localHighlight { mask.appendRect(localHighlight) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        mask.fill()

        if let globalRect = highlightedGlobalRect, let localRect = localHighlight {
            NSColor.controlAccentColor.setStroke()
            if case let .windowPreview(candidate) = state {
                drawSolidSelectionBorder(in: view.convertGlobalToLocal(candidate.frame.cgRect))
            } else {
                drawSolidSelectionBorder(in: localRect)
            }
            if case .regionDrawing = state {
                drawDimensions(for: globalRect, near: localRect, in: view)
            } else if let title = highlightedTitle {
                drawBadge(title, at: CGPoint(x: localRect.minX + 8, y: localRect.maxY + 8), in: view)
            }
        }

        if case .regionDrawing = state { drawMagnifier(in: view) }
        drawHint(in: view)
    }

    private func initialState(for intent: ScreenshotCaptureIntent) -> ScreenshotSelectionState {
        switch intent.kind {
        case .display:
            if case let .displayID(id)? = intent.displayScope,
               let display = displays.first(where: { $0.id == id }) {
                return .displaySelection(display.coreValue)
            }
            return .displaySelection(nil)
        case .smart, .region, .window:
            return .ready
        }
    }

    private var isDisplayMode: Bool {
        if case .displaySelection = state { return true }
        return false
    }

    private var highlightedGlobalRect: CGRect? {
        if let scrollingPreparedRect { return scrollingPreparedRect }
        switch state {
        case let .windowPreview(candidate):
            return candidate.frame.cgRect
        case .regionDrawing:
            return resolvedRegionForCurrentGesture()
        case let .displaySelection(display?):
            return display.frame.cgRect
        default:
            return nil
        }
    }

    private var highlightedTitle: String? {
        switch state {
        case let .windowPreview(candidate): candidates.first(where: { $0.id == candidate.id })?.title
        case let .displaySelection(display?): displays.first(where: { $0.id == display.id })?.title
        default: nil
        }
    }

    private func candidate(at point: CGPoint) -> ScreenshotSelectionCandidate? {
        candidates.first { $0.containsVisibleHitPoint(point) }
    }

    private func candidateCore(at point: CGPoint) -> ScreenshotWindowCandidate? {
        if windowLocked, case let .windowPreview(candidate) = state { return candidate }
        return candidate(at: point)?.coreValue
    }

    private func display(at point: CGPoint) -> ScreenshotSelectionDisplay? {
        displays.first { $0.frame.contains(point) }
    }

    private func cycleWindowCandidate(reverse: Bool) {
        guard Self.canCycleWindowCandidate(in: state), !candidates.isEmpty else { return }
        let cycle = candidates.filter { $0.containsVisibleHitPoint(lastPointer) }
        guard !cycle.isEmpty else { return }
        let currentID: UInt32? = {
            if case let .windowPreview(candidate) = state { return candidate.id }
            return nil
        }()
        let currentIndex = cycle.firstIndex(where: { $0.id == currentID }) ?? (reverse ? 0 : -1)
        let nextIndex = (currentIndex + (reverse ? -1 : 1) + cycle.count) % cycle.count
        state = .windowPreview(cycle[nextIndex].coreValue)
        windowLocked = true
        redraw()
    }

    private func resolvedRegionForCurrentGesture() -> CGRect? {
        guard case let .regionDrawing(start, current) = state else { return nil }
        let raw = ScreenshotSelectionRect(from: start, to: current)
        guard !raw.isEmpty else { return nil }
        let verticalEdges = displays.flatMap { [Double($0.frame.minX), Double($0.frame.maxX)] }
            + candidates.flatMap { [Double($0.frame.minX), Double($0.frame.maxX)] }
        let horizontalEdges = displays.flatMap { [Double($0.frame.minY), Double($0.frame.maxY)] }
            + candidates.flatMap { [Double($0.frame.minY), Double($0.frame.maxY)] }
        let descriptors = displayDescriptors

        let snapped: ScreenshotSelectionRect
        switch parameters.constraint {
        case let .fixedPixels(width, height):
            guard let fixed = try? regionGeometry.resolveFixedPixelRegion(
                raw,
                width: width,
                height: height,
                displays: descriptors
            ) else { return nil }
            let proposed = regionGeometry.snapPreservingSize(
                fixed.rect,
                verticalEdges: verticalEdges,
                horizontalEdges: horizontalEdges,
                threshold: 6
            )
            let proposedScale = try? capturePlanner.outputScale(for: proposed, displays: descriptors)
            snapped = proposedScale == fixed.outputScale ? proposed : fixed.rect
        case .ratio:
            let constrained = regionGeometry.constrain(raw, to: parameters.constraint, outputScale: 1)
            snapped = regionGeometry.snapPreservingSize(
                constrained,
                verticalEdges: verticalEdges,
                horizontalEdges: horizontalEdges,
                threshold: 6
            )
        case .free:
            snapped = regionGeometry.snap(
                raw,
                verticalEdges: verticalEdges,
                horizontalEdges: horizontalEdges,
                threshold: 6
            )
        }
        let scale = regionOutputScale(for: snapped.cgRect)
        guard regionGeometry.meetsMinimumOutputSize(snapped, outputScale: scale) else { return nil }
        return snapped.cgRect.standardized
    }

    private func regionOutputScale(for rect: CGRect) -> Double {
        (try? capturePlanner.outputScale(for: rect.selectionRect, displays: displayDescriptors))
            ?? displays.map(\.backingScale).max()
            ?? 1
    }

    private var displayDescriptors: [ScreenshotDisplayDescriptor] {
        displays.map {
            ScreenshotDisplayDescriptor(
                id: $0.id,
                selectionFrame: $0.frame.selectionRect,
                backingScale: $0.backingScale
            )
        }
    }

    private func handleToolbarAction(_ action: ScreenshotSelectionToolbarAction) {
        switch action {
        case let .constraint(value): parameters.constraint = value
        case let .delay(value): parameters.delaySeconds = value
        case let .freeze(value):
            parameters.freezesFrame = value
            if value {
                magnifierSnapshotTask?.cancel()
                magnifierSnapshots.removeAll()
                refreshFrozenSnapshots()
            } else {
                cancelFrozenSnapshotRefresh(clearSnapshots: true)
            }
        case let .watermark(presetID):
            parameters.watermarkPresetID = presetID
        case let .scrollingMode(enabled):
            if enabled, !screenRecordingPermissionProvider() {
                finish(.screenRecordingPermissionMissing)
                return
            }
            if enabled, !inputMonitoringPermissionProvider() {
                finish(.inputMonitoringPermissionMissing)
                return
            }
            scrollingMode = enabled
            scrollingSessionID = enabled ? (scrollingSessionID ?? Self.makeScrollingSessionID()) : nil
            scrollingPreparedRect = nil
            scrollingHUD.dismiss()
            state = .ready
            windowLocked = false
            toolbarPanel?.update(phase: enabled ? .scrollingSelecting : .normal)
        case .scrollingStart:
            guard screenRecordingPermissionProvider() else {
                finish(.screenRecordingPermissionMissing)
                return
            }
            guard inputMonitoringPermissionProvider() else {
                finish(.inputMonitoringPermissionMissing)
                return
            }
            guard let rect = scrollingPreparedRect,
                  let display = displays.first(where: { $0.frame.contains(rect) }),
                  let scrollingSessionID else { return }
            finish(.scrollingRegion(rect, displayID: display.id, sessionID: scrollingSessionID))
            return
        case .scrollingReselect:
            scrollingPreparedRect = nil
            transfersScrollingHUD = false
            scrollingHUD.dismiss()
            state = .ready
            toolbarPanel?.orderFrontRegardless()
            toolbarPanel?.update(phase: .scrollingSelecting)
        case .scrollingCancel:
            scrollingHUD.dismiss()
            finish(.cancelled)
            return
        }
        parametersChanged(parameters)
        toolbarPanel?.update(parameters: parameters)
        redraw()
    }

    private func handle(_ effects: [ScreenshotSelectionEffect]) {
        for effect in effects {
            switch effect {
            case let .captureWindow(candidate): finish(.window(candidate.id))
            case let .captureRegion(rect):
                if scrollingMode {
                    let candidate = rect.cgRect.standardized
                    guard displays.contains(where: { $0.frame.contains(candidate) }) else {
                        state = .ready
                        scrollingPreparedRect = nil
                        redraw()
                        continue
                    }
                    scrollingPreparedRect = candidate
                    state = .ready
                    toolbarPanel?.setRegionGestureActive(false)
                    let outputScale = regionOutputScale(for: candidate)
                    toolbarPanel?.orderOut(nil)
                    scrollingHUD.showReady(
                        selectionRect: candidate,
                        pixelWidth: Int((candidate.width * outputScale).rounded()),
                        pixelHeight: Int((candidate.height * outputScale).rounded()),
                        isStartEnabled: screenRecordingPermissionProvider() && inputMonitoringPermissionProvider(),
                        onCommand: { [weak self] command in
                            switch command {
                            case .start: self?.handleToolbarAction(.scrollingStart)
                            case .reselect: self?.handleToolbarAction(.scrollingReselect)
                            case .cancel: self?.handleToolbarAction(.scrollingCancel)
                            case .pause, .resume, .restart, .finish: break
                            }
                        }
                    )
                } else {
                    finish(.region(rect.cgRect))
                }
            case let .captureDisplay(.displayID(id)): finish(.display(id))
            case .captureDisplay(.all): finish(.allDisplays)
            case .captureDisplay(.current):
                if let display = display(at: lastPointer) { finish(.display(display.id)) }
            case .cancel: finish(.cancelled)
            }
        }
    }

    private func showSelectionSurfaces() {
        clearInitialFrozenEscapeMonitoring()
        overlayWindows = NSScreen.screens.map { screen in
            let panel = ScreenshotSelectionPanel(contentRect: screen.frame)
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.alphaValue = 0
            let view = ScreenshotSelectionOverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                controller: self
            )
            panel.contentView = view
            return panel
        }
        if showsParameterToolbar {
            toolbarPanel = makeToolbar()
            toolbarPanel?.alphaValue = 0
        }
        let surfaces = overlayWindows + (toolbarPanel.map { [$0] } ?? [])
        surfaces.forEach {
            $0.contentView?.layoutSubtreeIfNeeded()
            $0.orderFrontRegardless()
            $0.displayIfNeeded()
        }
        overlayWindows.forEach { $0.alphaValue = 1 }
        if let toolbarPanel {
            BlocksAppKitMotion.animate(
                window: toolbarPanel,
                to: toolbarPanel.frame,
                alphaValue: 1,
                role: .hoverFocus
            ) {}
        }
        let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(lastPointer) }) ?? NSScreen.main
        if let panel = overlayWindows.first(where: { $0.frame == pointerScreen?.frame }) {
            panel.makeKey()
            if let overlay = panel.contentView as? ScreenshotSelectionOverlayView {
                panel.makeFirstResponder(overlay.eventView)
            }
        }
        let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - selectionStartedAt) * 1_000)
        logger.info(
            "stage=selection-surfaces-committed sessionID=\(self.selectionSessionID, privacy: .public) mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public) displayCount=\(self.overlayWindows.count, privacy: .public) elapsedMS=\(elapsedMS, privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "SelectionSurfacesCommitted",
            "sessionID=\(self.selectionSessionID, privacy: .public) mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public) displays=\(self.overlayWindows.count, privacy: .public)"
        )
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.continuation != nil else { return event }
            guard Self.shouldConsumeSelectionKeyEvent(keyCode: event.keyCode, from: event.window) else {
                return event
            }
            self.keyDown(with: event)
            return nil
        }
    }

    private func makeToolbar() -> ScreenshotSelectionToolbarPanel {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let toolbar = ScreenshotSelectionToolbarPanel(
            parameters: parameters,
            customConstraints: customConstraints,
            watermarkPresets: watermarkPresets,
            visibleFrames: visibleFrames,
            pointer: lastPointer,
            onSaveConstraint: saveCustomConstraint,
            onDeleteConstraint: deleteCustomConstraint,
            onAction: { [weak self] action in self?.handleToolbarAction(action) }
        )
        toolbar.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow))) + 1
        toolbar.update(phase: scrollingMode ? .scrollingSelecting : .normal)
        return toolbar
    }

    private func redraw(displayIDs: Set<UInt32>? = nil) {
        overlayWindows.forEach { panel in
            if let displayIDs {
                guard displays.contains(where: {
                    displayIDs.contains($0.id) && $0.frame == panel.frame
                }) else { return }
            }
            (panel.contentView as? ScreenshotSelectionOverlayView)?.canvasView.needsDisplay = true
        }
    }

    private func refreshFrozenSnapshots() {
        guard let frozenSnapshotProvider else { return }
        frozenSnapshotGeneration += 1
        let generation = frozenSnapshotGeneration
        let showsCursor = parameters.showsCursor
        isFrozenSnapshotReady = false
        frozenSnapshots.removeAll()
        frozenSnapshotTask?.cancel()
        frozenSnapshotTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await frozenSnapshotProvider(showsCursor)
                guard let self,
                      !Task.isCancelled,
                      self.parameters.freezesFrame,
                      self.frozenSnapshotGeneration == generation else { return }
                self.frozenSnapshots = snapshot.images
                self.frozenDisplayDescriptors = snapshot.displayDescriptors
                self.candidates = snapshot.candidates
                self.refreshCurrentWindowPreview()
                self.isFrozenSnapshotReady = true
                self.redraw()
                if let pending = self.pendingFrozenResult {
                    self.pendingFrozenResult = nil
                    self.finish(Self.validatedFrozenResult(pending, candidates: self.candidates))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(.snapshotFailed)
            }
        }
    }

    private func refreshMagnifierSnapshots() {
        guard magnifierSnapshotTask == nil, let magnifierSnapshotProvider else { return }
        magnifierSnapshotTask = Task { @MainActor [weak self] in
            defer { self?.magnifierSnapshotTask = nil }
            guard let snapshots = try? await magnifierSnapshotProvider(),
                  let self,
                  !Task.isCancelled else { return }
            self.magnifierSnapshots = snapshots
            self.redraw()
        }
    }

    private func refreshCurrentWindowPreview() {
        guard case let .windowPreview(current) = state else { return }
        guard let candidate = candidates.first(where: { $0.id == current.id }) else {
            state = .ready
            windowLocked = false
            if case let .window(id)? = pendingFrozenResult, id == current.id {
                pendingFrozenResult = nil
                finish(.snapshotFailed)
            }
            return
        }
        let refreshed = candidate.coreValue
        state = .windowPreview(refreshed)
        if case let .window(id)? = pendingFrozenResult, id == current.id {
            pendingFrozenResult = .window(id)
        }
    }

    private func cancelFrozenSnapshotRefresh(clearSnapshots: Bool) {
        frozenSnapshotGeneration += 1
        frozenSnapshotTask?.cancel()
        frozenSnapshotTask = nil
        if clearSnapshots { frozenSnapshots.removeAll() }
    }

    func consumeResultFrozenSnapshot() -> ScreenshotFrozenSelectionSnapshot? {
        defer { resultFrozenSnapshot = nil }
        return resultFrozenSnapshot
    }

    var selectionSurfaceWindowIDs: Set<UInt32> {
        let windows = overlayWindows + (toolbarPanel.map { [$0] } ?? [])
        let activeWindowIDs: Set<UInt32> = Set(windows.compactMap { window in
            guard window.windowNumber > 0 else { return nil }
            return UInt32(window.windowNumber)
        })
        let hudWindowIDs: Set<UInt32>
        if let number = scrollingHUD.windowNumber {
            hudWindowIDs = [UInt32(number)]
        } else {
            hudWindowIDs = []
        }
        return activeWindowIDs.union(retainedSelectionSurfaceWindowIDs).union(hudWindowIDs)
    }

    func clearRetainedSelectionSurfaceWindowIDs() {
        retainedSelectionSurfaceWindowIDs.removeAll()
        transfersScrollingHUD = false
    }

    func dismissSelectionSurfaces() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        if let toolbarPanel {
            BlocksAppKitMotion.cancelAnimations(on: toolbarPanel)
            toolbarPanel.orderOut(nil)
        }
        toolbarPanel = nil
        if !transfersScrollingHUD {
            scrollingHUD.dismiss()
        }
        releaseSelectionVisualResources()
    }

    func prepareHandoffFrame(from context: ScreenshotEditingContext, captureID: String) {
        handoffFrame = ScreenshotSelectionHandoffFrame(context: context)
        redraw()
        overlayWindows.forEach { $0.displayIfNeeded() }
        let reference = selectionFinishedAt ?? selectionStartedAt
        let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - reference) * 1_000)
        logger.info(
            "stage=handoff-frame-ready sessionID=\(self.selectionSessionID, privacy: .public) captureID=\(captureID, privacy: .public) mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public) displayCount=\(context.screens.count, privacy: .public) elapsedMS=\(elapsedMS, privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "HandoffFrameReady",
            "captureID=\(captureID, privacy: .public) mode=\(self.parameters.freezesFrame ? "frozen" : "live", privacy: .public) displays=\(context.screens.count, privacy: .public)"
        )
    }

    private func releaseSelectionVisualResources() {
        candidates.removeAll()
        displays.removeAll()
        frozenSnapshots.removeAll()
        frozenDisplayDescriptors.removeAll()
        magnifierSnapshots.removeAll()
        handoffFrame = nil
        resultFrozenSnapshot = nil
        selectionFinishedAt = nil
    }

    static func validatedFrozenResult(
        _ result: ScreenshotSelectionResult,
        candidates: [ScreenshotSelectionCandidate]
    ) -> ScreenshotSelectionResult {
        guard case let .window(id) = result else { return result }
        return candidates.contains(where: { $0.id == id }) ? result : .snapshotFailed
    }

    static func frozenWindowFrame(
        id: UInt32,
        candidates: [ScreenshotSelectionCandidate]
    ) -> CGRect? {
        candidates.first(where: { $0.id == id })?.frame
    }

    private func finish(_ result: ScreenshotSelectionResult) {
        guard let continuation else { return }
        if parameters.freezesFrame, result.requiresFrozenSnapshot, !isFrozenSnapshotReady {
            pendingFrozenResult = result
            return
        }
        self.continuation = nil
        selectionGeneration &+= 1
        scrollingSessionID = nil
        resultFrozenSnapshot = parameters.freezesFrame
            ? ScreenshotFrozenSelectionSnapshot(
                images: frozenSnapshots,
                candidates: candidates,
                displayDescriptors: frozenDisplayDescriptors
            )
            : nil
        cancelFrozenSnapshotRefresh(clearSnapshots: false)
        initialFrozenSnapshotTask?.cancel()
        initialFrozenSnapshotTask = nil
        clearInitialFrozenEscapeMonitoring()
        timeoutTask?.cancel()
        timeoutTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        retainedSelectionSurfaceWindowIDs = selectionSurfaceWindowIDs
        selectionFinishedAt = CFAbsoluteTimeGetCurrent()
        if case .scrollingRegion = result {
            transfersScrollingHUD = true
        } else {
            transfersScrollingHUD = false
            scrollingHUD.dismiss()
        }
        overlayWindows.forEach { $0.ignoresMouseEvents = true }
        toolbarPanel?.ignoresMouseEvents = true
        magnifierSnapshotTask?.cancel()
        magnifierSnapshotTask = nil
        magnifierSnapshots.removeAll()
        frozenSnapshotProvider = nil
        magnifierSnapshotProvider = nil
        parametersChanged = { _ in }
        showsParameterToolbar = true
        pendingFrozenResult = nil
        isFrozenSnapshotReady = false
        continuation.resume(returning: result)
    }

    private func drawDimensions(for globalRect: CGRect, near localRect: CGRect, in view: ScreenshotSelectionCanvasView) {
        let scale = regionOutputScale(for: globalRect)
        let text = L10n.format(
            "screenshot.selection.dimensions",
            Int(globalRect.minX),
            Int(globalRect.minY),
            Int((globalRect.width * scale).rounded()),
            Int((globalRect.height * scale).rounded())
        )
        drawBadge(text, at: CGPoint(x: localRect.minX, y: localRect.maxY + 8), in: view)
    }

    private func drawSolidSelectionBorder(in rect: CGRect) {
        let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawDashedCaptureBorder(in rect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.48).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        border.lineWidth = 1.5
        border.setLineDash([5, 4], count: 2, phase: 0)
        border.stroke()
    }

    static func shouldConsumeSelectionKeyEvent(keyCode: UInt16, from window: NSWindow?) -> Bool {
        guard window is ScreenshotSelectionPanel else { return false }
        guard !(window is ScrollingScreenshotHUDPanel) else { return false }
        guard window is ScreenshotSelectionToolbarPanel else { return true }
        return keyCode == 3 || keyCode == 53
    }

    static func canCycleWindowCandidate(in state: ScreenshotSelectionState) -> Bool {
        switch state {
        case .ready, .windowPreview:
            true
        case .pendingClick, .regionDrawing, .displaySelection, .capturing, .cancelled:
            false
        }
    }

    private static func makeScrollingSessionID() -> String {
        "scroll-\(UUID().uuidString.lowercased())"
    }

#if DEBUG
    var stateForTesting: ScreenshotSelectionState { state }
    var parameterToolbarVisibleForTesting: Bool { toolbarPanel?.isVisible == true }
    var selectionActiveForTesting: Bool { continuation != nil }

    func prepareForInputTesting(
        intent: ScreenshotCaptureIntentKind,
        candidates: [ScreenshotSelectionCandidate],
        displays: [ScreenshotSelectionDisplay]
    ) {
        intentKind = intent
        self.candidates = candidates
        self.displays = displays
        state = intent == .display ? .displaySelection(nil) : .ready
        windowLocked = false
    }
#endif

    private func drawHint(in view: ScreenshotSelectionCanvasView) {
        let key: String
        switch reducer.hintState(for: state, hasWindowCandidates: !candidates.isEmpty) {
        case .ready: key = "screenshot.selection.hint.ready"
        case .window: key = "screenshot.selection.hint.window"
        case .regionDrawing: key = "screenshot.selection.hint.regionDrawing"
        case .display: key = "screenshot.selection.hint.display"
        case .noCandidate: key = "screenshot.selection.hint.noCandidate"
        }
        drawBadge(L10n.string(key), at: CGPoint(x: view.bounds.midX - 180, y: 18), in: view)
    }

    private func drawMagnifier(in view: ScreenshotSelectionCanvasView) {
        let snapshots = parameters.freezesFrame ? frozenSnapshots : magnifierSnapshots
        guard let display = display(at: lastPointer),
              view.window?.frame.intersects(display.frame) == true,
              let snapshot = snapshots[display.id] else { return }
        let image = NSImage(cgImage: snapshot, size: display.frame.size)
        let localInDisplay = CGPoint(x: lastPointer.x - display.frame.minX, y: lastPointer.y - display.frame.minY)
        let source = CGRect(x: localInDisplay.x - 8, y: localInDisplay.y - 8, width: 16, height: 16)
            .intersection(CGRect(origin: .zero, size: display.frame.size))
        guard source.width > 0, source.height > 0 else { return }
        let pointer = view.convertGlobalToLocal(lastPointer)
        let size = Self.magnifierSize
        var origin = CGPoint(x: pointer.x + 18, y: pointer.y + 18)
        if origin.x + size.width > view.bounds.maxX - 12 { origin.x = pointer.x - size.width - 18 }
        if origin.y + size.height > view.bounds.maxY - 12 { origin.y = pointer.y - size.height - 18 }
        let destination = CGRect(origin: origin, size: size)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: destination.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: destination, from: source, operation: .copy, fraction: 1)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: destination, xRadius: 7, yRadius: 7)
        border.lineWidth = 2
        border.stroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: destination.midX, y: destination.minY))
        crosshair.line(to: CGPoint(x: destination.midX, y: destination.maxY))
        crosshair.move(to: CGPoint(x: destination.minX, y: destination.midY))
        crosshair.line(to: CGPoint(x: destination.maxX, y: destination.midY))
        crosshair.lineWidth = 1
        crosshair.stroke()
    }

    private func drawBadge(_ text: String, at point: CGPoint, in view: ScreenshotSelectionCanvasView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BlocksTypography.nsFont(size: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: max(12, min(point.x, view.bounds.maxX - size.width - 24)),
            y: max(12, min(point.y, view.bounds.maxY - size.height - 18))
        )
        let background = CGRect(x: origin.x - 8, y: origin.y - 5, width: size.width + 16, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: background, xRadius: 7, yRadius: 7).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}

private extension ScreenshotSelectionResult {
    var requiresFrozenSnapshot: Bool {
        switch self {
        case .window, .region, .display, .allDisplays: true
        case .scrollingRegion: false
        case .screenRecordingPermissionMissing,
             .inputMonitoringPermissionMissing,
             .cancelled,
             .timedOut,
             .snapshotFailed: false
        }
    }
}

private extension CGRect {
    var selectionRect: ScreenshotSelectionRect {
        ScreenshotSelectionRect(x: minX, y: minY, width: width, height: height)
    }
}

private extension CGPoint {
    var selectionPoint: ScreenshotSelectionPoint { ScreenshotSelectionPoint(x: x, y: y) }
}

private extension ScreenshotSelectionRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
