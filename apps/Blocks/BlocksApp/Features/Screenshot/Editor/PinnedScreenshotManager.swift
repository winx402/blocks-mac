import AppKit
import BlocksScreenshotCore

struct PinnedScreenshotPresentation {
    let image: NSImage
    let logicalSize: CGSize
    let outputPixelScale: CGFloat
    let preferredScreenFrame: CGRect
    let targetVisibleFrame: CGRect

    init(
        image: NSImage,
        logicalSize: CGSize,
        outputPixelScale: CGFloat,
        preferredScreenFrame: CGRect,
        targetVisibleFrame: CGRect
    ) {
        self.image = image
        self.logicalSize = CGSize(
            width: max(1, logicalSize.width),
            height: max(1, logicalSize.height)
        )
        self.outputPixelScale = max(0.01, outputPixelScale)
        let resolvedVisibleFrame = targetVisibleFrame.width > 0 && targetVisibleFrame.height > 0
            ? targetVisibleFrame
            : CGRect(x: 0, y: 0, width: 1280, height: 800)
        self.targetVisibleFrame = resolvedVisibleFrame
        let preferredOrigin = preferredScreenFrame.width > 0 && preferredScreenFrame.height > 0
            ? preferredScreenFrame.origin
            : CGPoint(
                x: resolvedVisibleFrame.midX - self.logicalSize.width / 2,
                y: resolvedVisibleFrame.midY - self.logicalSize.height / 2
            )
        self.preferredScreenFrame = CGRect(origin: preferredOrigin, size: self.logicalSize)
    }
}

enum PinnedScreenshotGeometry {
    struct ScreenFrame: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    static func outputPixelScale(
        initialCropRect: ScreenshotPixelRect,
        sourceRect: CGRect
    ) -> CGFloat {
        if sourceRect.width > 0 {
            return max(0.01, CGFloat(initialCropRect.width) / sourceRect.width)
        }
        if sourceRect.height > 0 {
            return max(0.01, CGFloat(initialCropRect.height) / sourceRect.height)
        }
        return 1
    }

    static func logicalSize(
        cropRect: ScreenshotPixelRect,
        outputPixelScale: CGFloat
    ) -> CGSize {
        let scale = max(0.01, outputPixelScale)
        return CGSize(
            width: CGFloat(cropRect.width) / scale,
            height: CGFloat(cropRect.height) / scale
        )
    }

    static func preferredScreenFrame(
        cropRect: ScreenshotPixelRect,
        sourceFrame: CGRect,
        outputPixelScale: CGFloat
    ) -> CGRect {
        let scale = max(0.01, outputPixelScale)
        let size = logicalSize(cropRect: cropRect, outputPixelScale: scale)
        return CGRect(
            x: sourceFrame.minX + CGFloat(cropRect.x) / scale,
            y: sourceFrame.maxY - CGFloat(cropRect.y + cropRect.height) / scale,
            width: size.width,
            height: size.height
        )
    }

    static func preferredLongScreenshotFrame(
        captureScreenRect: CGRect,
        logicalSize: CGSize
    ) -> CGRect {
        CGRect(
            x: captureScreenRect.minX,
            y: captureScreenRect.maxY - logicalSize.height,
            width: logicalSize.width,
            height: logicalSize.height
        )
    }

    static func targetVisibleFrame(
        for preferredFrame: CGRect,
        screens: [ScreenFrame],
        fallback: CGRect
    ) -> CGRect {
        guard !screens.isEmpty else { return fallback }
        let targetCenter = CGPoint(x: preferredFrame.midX, y: preferredFrame.midY)
        return screens.max { lhs, rhs in
            let lhsArea = intersectionArea(preferredFrame, lhs.frame)
            let rhsArea = intersectionArea(preferredFrame, rhs.frame)
            if abs(lhsArea - rhsArea) > 0.5 { return lhsArea < rhsArea }
            return squaredDistance(targetCenter, lhs.frame) > squaredDistance(targetCenter, rhs.frame)
        }?.visibleFrame ?? fallback
    }

    static func initialFrame(
        preferredFrame: CGRect,
        displaySize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let proposed = CGRect(
            x: preferredFrame.minX,
            y: preferredFrame.maxY - displaySize.height,
            width: displaySize.width,
            height: displaySize.height
        )
        return CGRect(
            x: min(max(proposed.minX, visibleFrame.minX), visibleFrame.maxX - proposed.width),
            y: min(max(proposed.minY, visibleFrame.minY), visibleFrame.maxY - proposed.height),
            width: proposed.width,
            height: proposed.height
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = point.x - min(max(point.x, rect.minX), rect.maxX)
        let dy = point.y - min(max(point.y, rect.minY), rect.maxY)
        return dx * dx + dy * dy
    }
}

struct PinnedScreenshotDisplayState: Equatable {
    // A long screenshot can legitimately require a scale below 25% to fit the
    // current display while preserving its full logical height.
    static let minimumZoom: CGFloat = 0.05
    static let maximumZoom: CGFloat = 4

    let sourceSize: CGSize
    private(set) var zoom: CGFloat
    private(set) var opacity: CGFloat = 1

    init(sourceSize: CGSize, visibleFrame: CGRect) {
        self.sourceSize = CGSize(
            width: max(1, sourceSize.width),
            height: max(1, sourceSize.height)
        )
        zoom = Self.initialZoom(sourceSize: self.sourceSize, visibleFrame: visibleFrame)
    }

    var displaySize: CGSize {
        CGSize(
            width: max(40, sourceSize.width * zoom),
            height: max(30, sourceSize.height * zoom)
        )
    }

    var percentage: Int {
        Int((zoom * 100).rounded())
    }

    mutating func setZoom(_ proposed: CGFloat) {
        zoom = min(Self.maximumZoom, max(Self.minimumZoom, proposed))
    }

    mutating func scale(by factor: CGFloat) {
        setZoom(zoom * factor)
    }

    mutating func setOpacity(_ proposed: CGFloat) {
        opacity = min(1, max(0.25, proposed))
    }

    func fitZoom(visibleFrame: CGRect) -> CGFloat {
        Self.fitZoom(sourceSize: sourceSize, visibleFrame: visibleFrame)
    }

    static func initialZoom(sourceSize: CGSize, visibleFrame: CGRect) -> CGFloat {
        min(1, fitZoom(sourceSize: sourceSize, visibleFrame: visibleFrame))
    }

    static func fitZoom(sourceSize: CGSize, visibleFrame: CGRect) -> CGFloat {
        let safeWidth = max(80, visibleFrame.width - 48)
        let safeHeight = max(50, visibleFrame.height - 72)
        return min(
            maximumZoom,
            max(
                minimumZoom,
                min(safeWidth / max(1, sourceSize.width), safeHeight / max(1, sourceSize.height))
            )
        )
    }
}

@MainActor
final class PinnedScreenshotManager {
    private var controllers: [UUID: PinnedScreenshotController] = [:]

    func present(_ presentation: PinnedScreenshotPresentation, ocrCoordinator: LocalOCRCoordinator) {
        let id = UUID()
        let controller = PinnedScreenshotController(
            id: id,
            presentation: presentation,
            ocrCoordinator: ocrCoordinator,
            onClose: { [weak self] id in self?.controllers.removeValue(forKey: id) }
        )
        controllers[id] = controller
        controller.show()
    }
}

private final class PinnedScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum PinnedScreenshotOCRPanelState {
    case result(String)
    case failure(String)
}

enum PinnedScreenshotSavePanelResult: Sendable {
    case cancel
    case ok(URL)
}

@MainActor
private final class PinnedScreenshotSavePanelCancellation {
    private weak var panel: NSSavePanel?
    private var didCancel = false

    init(panel: NSSavePanel) {
        self.panel = panel
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        panel?.cancelOperation(nil)
    }

    func finish() {
        panel = nil
    }
}

typealias PinnedScreenshotSavePanelPresenter = @MainActor (NSSavePanel, NSWindow) async -> PinnedScreenshotSavePanelResult
typealias PinnedScreenshotSaveWriter = @Sendable (CGImage, URL) throws -> Void

@MainActor
final class PinnedScreenshotController: NSObject, NSWindowDelegate {
    let id: UUID
    private let image: NSImage
    private let recognizeOCRText: (CGImage, LocalVisionOCRRequestToken) async throws -> String
    private let writePlainText: (String) async throws -> Void
    private let writeImage: (NSImage) async throws -> Void
    private let savePanelPresenter: PinnedScreenshotSavePanelPresenter
    private let saveWriter: PinnedScreenshotSaveWriter
    private let onClose: (UUID) -> Void
    private let panel: PinnedScreenshotPanel
    private let imageView: PinnedScreenshotView
    private let preferredVisibleFrame: CGRect
    private var displayState: PinnedScreenshotDisplayState
    private var ocrPanel: NSPanel?
    private var ocrTask: Task<Void, Never>?
    private var ocrRequestToken: LocalVisionOCRRequestToken?
    private var ocrGeneration: UInt64 = 0
    private var ocrCopyGeneration: UInt64 = 0
    private var ocrCopyTask: Task<Void, Never>?
    private var ocrCopyFeedbackTask: Task<Void, Never>?
    private var imageCopyGeneration: UInt64 = 0
    private var imageCopyObserverTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    private var activeSavePanel: NSSavePanel?
    private var activeSavePanelCancellation: PinnedScreenshotSavePanelCancellation?
    private var savePresentationTask: Task<Void, Never>?
    private weak var ocrTextView: NSTextView?
    private weak var ocrCopyButton: BlocksAppKitCompactButton?
    private weak var ocrCopyFeedbackLabel: NSTextField?
    private var didPrepareParentClose = false

    convenience init(
        id: UUID,
        presentation: PinnedScreenshotPresentation,
        ocrCoordinator: LocalOCRCoordinator,
        onClose: @escaping (UUID) -> Void
    ) {
        self.init(
            id: id,
            presentation: presentation,
            recognizeOCRText: { image, requestToken in
                try await ocrCoordinator.recognizeText(
                    in: image,
                    context: .pinnedImage,
                    requestToken: requestToken
                ).text
            },
            writePlainText: { text in
                _ = try await ClipboardPasteboardWriter().writePlainText(text)
            },
            writeImage: { image in
                try await ScreenshotPasteboardWriter().write(image)
            },
            onClose: onClose
        )
    }

    init(
        id: UUID,
        presentation: PinnedScreenshotPresentation,
        recognizeOCRText: @escaping (CGImage, LocalVisionOCRRequestToken) async throws -> String,
        writePlainText: @escaping (String) async throws -> Void,
        writeImage: @escaping (NSImage) async throws -> Void,
        savePanelPresenter: @escaping PinnedScreenshotSavePanelPresenter = { savePanel, owner in
            await withCheckedContinuation { continuation in
                savePanel.beginSheetModal(for: owner) { response in
                    guard response == .OK, let url = savePanel.url else {
                        continuation.resume(returning: .cancel)
                        return
                    }
                    continuation.resume(returning: .ok(url))
                }
            }
        },
        saveWriter: @escaping PinnedScreenshotSaveWriter = { cgImage, url in
            let data = try ScreenshotImageEncoder().pngData(cgImage)
            try ScreenshotSecureFileWriter().write(data, to: url)
        },
        onClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        image = presentation.image
        self.recognizeOCRText = recognizeOCRText
        self.writePlainText = writePlainText
        self.writeImage = writeImage
        self.savePanelPresenter = savePanelPresenter
        self.saveWriter = saveWriter
        self.onClose = onClose
        preferredVisibleFrame = presentation.targetVisibleFrame

        let initialState = PinnedScreenshotDisplayState(
            sourceSize: presentation.logicalSize,
            visibleFrame: presentation.targetVisibleFrame
        )
        displayState = initialState
        panel = PinnedScreenshotPanel(
            contentRect: NSRect(origin: .zero, size: initialState.displaySize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        imageView = PinnedScreenshotView(frame: NSRect(origin: .zero, size: initialState.displaySize))
        super.init()

        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true

        imageView.image = presentation.image
        imageView.controller = self
        imageView.update(percentage: initialState.percentage, opacity: initialState.opacity)
        panel.contentView = imageView
        panel.setContentSize(initialState.displaySize)
        panel.setFrame(PinnedScreenshotGeometry.initialFrame(
            preferredFrame: presentation.preferredScreenFrame,
            displaySize: initialState.displaySize,
            visibleFrame: presentation.targetVisibleFrame
        ), display: false)
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(imageView)
        imageView.revealToolbarForKeyboard()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === ocrPanel {
            // NSWindow installs its delegate in NotificationCenter. Clear it as
            // part of the child-window close transaction so a closed OCR panel
            // cannot keep this controller alive through the registrar.
            closingWindow.delegate = nil
            invalidateOCRCopySession()
            panel.removeChildWindow(closingWindow)
            ocrPanel = nil
            ocrTextView = nil
            ocrCopyButton = nil
            ocrCopyFeedbackLabel = nil
            return
        }
        guard closingWindow === panel else { return }
        prepareParentCloseIfNeeded()
    }

    private func prepareParentCloseIfNeeded() {
        guard !didPrepareParentClose else { return }
        didPrepareParentClose = true
        dismissOCRPanel()
        ocrRequestToken?.cancel()
        ocrTask?.cancel()
        ocrTask = nil
        imageCopyGeneration &+= 1
        imageCopyObserverTask?.cancel()
        imageCopyObserverTask = nil
        saveGeneration &+= 1
        cancelActiveSavePanel()
        // The explicit copy request is allowed to finish after its UI closes,
        // but the controller must not remain its owner. The task already owns
        // the writer closure and only keeps weak UI/controller references.
        ocrCopyTask = nil
        imageView.controller = nil
        panel.delegate = nil
        onClose(id)
    }

    func close() {
        prepareParentCloseIfNeeded()
        panel.close()
    }

    func scale(by delta: CGFloat) {
        setZoom(displayState.zoom * exp(delta * 0.018))
    }

    func zoomIn() {
        setZoom(displayState.zoom + 0.10)
    }

    func zoomOut() {
        setZoom(displayState.zoom - 0.10)
    }

    func resetZoom() {
        setZoom(1)
    }

    func fitToScreen() {
        setZoom(displayState.fitZoom(visibleFrame: currentVisibleFrame))
    }

    private func setZoom(_ zoom: CGFloat) {
        let previousZoom = displayState.zoom
        displayState.setZoom(zoom)
        guard abs(displayState.zoom - previousZoom) > 0.0001 else { return }
        let oldFrame = panel.frame
        let center = CGPoint(x: oldFrame.midX, y: oldFrame.midY)
        let size = displayState.displaySize
        let proposed = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(clampedFrame(proposed), display: true, animate: false)
        imageView.update(percentage: displayState.percentage, opacity: displayState.opacity)
    }

    func nudge(dx: CGFloat, dy: CGFloat, accelerated: Bool) {
        let amount: CGFloat = accelerated ? 10 : 1
        let next = panel.frame.offsetBy(dx: dx * amount, dy: dy * amount)
        panel.setFrame(clampedFrame(next), display: true, animate: false)
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(zoomMenuItem())
        menu.addItem(opacityMenuItem())
        menu.addItem(.separator())
        addItem(L10n.string("screenshot.pin.copy"), action: #selector(copyImage), to: menu)
        addItem(L10n.string("screenshot.pin.save"), action: #selector(saveImage), to: menu)
        addItem(L10n.string("screenshot.pin.ocr"), action: #selector(recognizeText), to: menu)
        menu.addItem(.separator())
        addItem(L10n.string("common.close"), action: #selector(closeFromMenu), to: menu)
        return menu
    }

    func presentZoomMenu(from view: NSView) {
        present(menu: makeZoomMenu(), from: view)
    }

    func presentOpacityMenu(from view: NSView) {
        present(menu: makeOpacityMenu(), from: view)
    }

    func presentMoreMenu(from view: NSView) {
        let menu = NSMenu()
        menu.addItem(zoomMenuItem())
        menu.addItem(opacityMenuItem())
        menu.addItem(.separator())
        addItem(L10n.string("screenshot.pin.ocr"), action: #selector(recognizeText), to: menu)
        addItem(L10n.string("screenshot.pin.copy"), action: #selector(copyImage), to: menu)
        addItem(L10n.string("screenshot.pin.save"), action: #selector(saveImage), to: menu)
        present(menu: menu, from: view)
    }

    private func present(menu: NSMenu, from view: NSView) {
        imageView.keepsControlsVisible = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        imageView.keepsControlsVisible = false
    }

    private func zoomMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: L10n.string("screenshot.editor.zoom"),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = makeZoomMenu()
        return item
    }

    private func makeZoomMenu() -> NSMenu {
        let menu = NSMenu()
        let fit = NSMenuItem(
            title: L10n.string("screenshot.pin.fit"),
            action: #selector(fitFromMenu),
            keyEquivalent: ""
        )
        fit.target = self
        menu.addItem(fit)
        menu.addItem(.separator())
        for percentage in [25, 50, 75, 100, 150, 200, 300, 400] {
            let item = NSMenuItem(
                title: "\(percentage)%",
                action: #selector(setZoomFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = percentage
            item.state = abs(displayState.zoom - CGFloat(percentage) / 100) < 0.005 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func opacityMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: L10n.string("screenshot.pin.opacity"),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = makeOpacityMenu()
        return item
    }

    private func makeOpacityMenu() -> NSMenu {
        let menu = NSMenu()
        for percentage in [100, 75, 50, 25] {
            let item = NSMenuItem(
                title: "\(percentage)%",
                action: #selector(setOpacityFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = percentage
            item.state = abs(displayState.opacity - CGFloat(percentage) / 100) < 0.005 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func fitFromMenu() { fitToScreen() }

    @objc private func setZoomFromMenu(_ sender: NSMenuItem) {
        guard let percentage = sender.representedObject as? Int else { return }
        setZoom(CGFloat(percentage) / 100)
    }

    @objc private func setOpacityFromMenu(_ sender: NSMenuItem) {
        guard let percentage = sender.representedObject as? Int else { return }
        displayState.setOpacity(CGFloat(percentage) / 100)
        imageView.update(percentage: displayState.percentage, opacity: displayState.opacity)
    }

    @objc private func closeFromMenu() { close() }

    @objc func copyImage() {
        guard imageCopyObserverTask == nil else { return }
        imageView.clearCopyFailureFeedback()
        imageCopyGeneration &+= 1
        let generation = imageCopyGeneration
        let image = image
        let writeImage = writeImage
        // The committed pasteboard write must outlive this pin, but the task
        // executing it cannot retain the pin's window graph while suspended.
        let writerTask = Task { () -> Result<Void, Error> in
            do {
                try await writeImage(image)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        imageCopyObserverTask = Task { @MainActor [weak self] in
            let result = await writerTask.value
            guard !Task.isCancelled else { return }
            self?.finishImageCopy(result, generation: generation)
        }
    }

    private func finishImageCopy(_ result: Result<Void, Error>, generation: UInt64) {
        guard imageCopyGeneration == generation else { return }
        imageCopyObserverTask = nil
        guard !didPrepareParentClose, panel.contentView === imageView else { return }
        switch result {
        case .success:
            imageView.clearCopyFailureFeedback()
            imageView.showTransientConfirmation(systemImage: "checkmark")
        case .failure:
            NSSound.beep()
            imageView.showTransientConfirmation(systemImage: "exclamationmark.triangle")
            imageView.showCopyFailureFeedback()
        }
    }

    @objc func saveImage() {
        guard !didPrepareParentClose, activeSavePanel == nil else { return }
        saveGeneration &+= 1
        let generation = saveGeneration
        imageView.clearSaveFailureFeedback()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "Blocks-Pinned-Screenshot.png"
        let cancellation = PinnedScreenshotSavePanelCancellation(panel: savePanel)
        activeSavePanel = savePanel
        activeSavePanelCancellation = cancellation
        let savePanelPresenter = savePanelPresenter
        let owner = panel
        savePresentationTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await savePanelPresenter(savePanel, owner)
            } onCancel: {
                Task { @MainActor in
                    cancellation.cancel()
                }
            }
            guard !Task.isCancelled else { return }
            self?.finishSavePanelPresentation(
                result,
                panel: savePanel,
                cancellation: cancellation,
                generation: generation
            )
        }
    }

    private func cancelActiveSavePanel() {
        let task = savePresentationTask
        let cancellation = activeSavePanelCancellation
        savePresentationTask = nil
        activeSavePanelCancellation = nil
        activeSavePanel = nil
        task?.cancel()
        cancellation?.cancel()
    }

    private func finishSavePanelPresentation(
        _ result: PinnedScreenshotSavePanelResult,
        panel: NSSavePanel,
        cancellation: PinnedScreenshotSavePanelCancellation,
        generation: UInt64
    ) {
        guard saveGeneration == generation,
              activeSavePanel === panel,
              activeSavePanelCancellation === cancellation else { return }
        savePresentationTask = nil
        activeSavePanelCancellation = nil
        activeSavePanel = nil
        cancellation.finish()
        guard !didPrepareParentClose,
              case let .ok(url) = result,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Once the user confirms the save panel, encoding and the atomic write
        // are committed independently from this pin's UI lifetime. Closing the
        // panel suppresses only its late feedback, not the requested file write.
        let saveWriter = saveWriter
        let saveWork = Task.detached(priority: .userInitiated) {
            try saveWriter(cgImage, url)
        }
        Task { @MainActor [weak self] in
            let result: Result<Void, Error>
            do {
                try await saveWork.value
                result = .success(())
            } catch {
                result = .failure(error)
            }
            guard let self,
                  self.saveGeneration == generation,
                  !self.didPrepareParentClose,
                  self.panel.contentView === self.imageView else { return }
            switch result {
            case .success:
                self.imageView.clearSaveFailureFeedback()
                self.imageView.showSaveTransientConfirmation(systemImage: "checkmark")
            case let .failure(error):
                let message = self.saveFailureMessage(for: error)
                self.imageView.showSaveFailureFeedback(message)
            }
        }
    }

    private func saveFailureMessage(for error: Error) -> String {
        [
            L10n.string("screenshot.result.saveFailed"),
            L10n.string("screenshot.result.saveFailedDetail"),
            L10n.string("screenshot.result.saveCancelledDetail"),
            error.localizedDescription,
            L10n.string("screenshot.result.saveAs"),
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @objc func recognizeText() {
        guard ocrTask == nil else { return }
        dismissOCRPanel()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSSound.beep()
            return
        }
        ocrGeneration &+= 1
        let generation = ocrGeneration
        let requestToken = LocalVisionOCRRequestToken()
        ocrRequestToken = requestToken
        imageView.setOCRInProgress(true)
        let recognizeOCRText = recognizeOCRText
        // Keep recognition independent of the pin's UI lifetime. The observer
        // below is the only task allowed to reference the controller.
        let recognitionTask = Task { () -> Result<String, Error> in
            do {
                return .success(try await recognizeOCRText(cgImage, requestToken))
            } catch {
                return .failure(error)
            }
        }
        ocrTask = Task { @MainActor [weak self] in
            let result = await recognitionTask.value
            guard !Task.isCancelled else { return }
            self?.finishOCRRecognition(result, generation: generation)
        }
    }

    private func finishOCRRecognition(_ result: Result<String, Error>, generation: UInt64) {
        guard ocrGeneration == generation else { return }
        ocrTask = nil
        ocrRequestToken = nil
        imageView.setOCRInProgress(false)
        guard !didPrepareParentClose, panel.contentView === imageView else { return }
        switch result {
        case let .success(text):
            showOCRPanel(.result(text))
        case let .failure(error):
            guard !(error is CancellationError) else { return }
            showOCRPanel(.failure(L10n.string("screenshot.pin.ocr.failed")))
        }
    }

    private var currentVisibleFrame: CGRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? preferredVisibleFrame
    }

    private func clampedFrame(_ proposed: CGRect) -> CGRect {
        let visibleFrame = currentVisibleFrame
        let minimumVisible: CGFloat = 40
        let minX = visibleFrame.minX - max(0, proposed.width - minimumVisible)
        let maxX = visibleFrame.maxX - minimumVisible
        let minY = visibleFrame.minY - max(0, proposed.height - minimumVisible)
        let maxY = visibleFrame.maxY - minimumVisible
        return CGRect(
            x: min(max(proposed.minX, minX), maxX),
            y: min(max(proposed.minY, minY), maxY),
            width: proposed.width,
            height: proposed.height
        )
    }

    @objc private func copyOCRText() {
        guard let text = ocrTextView?.string,
              let sourcePanel = ocrPanel,
              let sourceButton = ocrCopyButton,
              ocrCopyTask == nil else { return }
        ocrCopyFeedbackTask?.cancel()
        clearOCRCopyFeedback()
        ocrCopyGeneration &+= 1
        let generation = ocrCopyGeneration
        let writePlainText = writePlainText
        sourceButton.isEnabled = false
        // Keep the potentially long-running pasteboard write in a task whose
        // capture context cannot include this controller. The UI observer below
        // owns only a weak controller reference, so closing a pin never keeps
        // its entire window graph alive while the writer is suspended.
        let writerTask = Task { () -> Result<Void, Error> in
            do {
                try await writePlainText(text)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        ocrCopyTask = Task { @MainActor [weak self, weak sourcePanel, weak sourceButton] in
            let result = await writerTask.value
            guard !Task.isCancelled else { return }
            self?.finishOCRCopy(
                result: result,
                sourcePanel: sourcePanel,
                sourceButton: sourceButton,
                generation: generation
            )
        }
    }

    private func finishOCRCopy(
        result: Result<Void, Error>,
        sourcePanel: NSPanel?,
        sourceButton: BlocksAppKitCompactButton?,
        generation: UInt64
    ) {
        ocrCopyTask = nil
        ocrCopyButton?.isEnabled = true
        guard ocrCopyGeneration == generation,
              ocrPanel === sourcePanel,
              ocrCopyButton === sourceButton,
              let sourcePanel,
              let sourceButton else { return }
        sourceButton.isEnabled = true
        switch result {
        case .success:
            let message = L10n.string("screenshot.ocr.copied")
            showOCRCopyFeedback(message)
            showOCRCopyConfirmation(
                systemImage: "checkmark",
                button: sourceButton,
                sourcePanel: sourcePanel,
                generation: generation
            )
        case .failure:
            let message = [
                L10n.string("screenshot.result.copyFailed"),
                L10n.string("screenshot.ocr.retry"),
            ].filter { !$0.isEmpty }.joined(separator: " ")
            showOCRCopyFeedback(message)
            showOCRCopyConfirmation(
                systemImage: "exclamationmark.triangle",
                button: sourceButton,
                sourcePanel: sourcePanel,
                generation: generation
            )
        }
    }

    private func showOCRCopyFeedback(_ message: String) {
        guard let feedbackLabel = ocrCopyFeedbackLabel else { return }
        feedbackLabel.stringValue = message
        feedbackLabel.toolTip = message
        feedbackLabel.setAccessibilityLabel(message)
        feedbackLabel.setAccessibilityValue(message)
        ScreenshotAccessibilityAnnouncer.announce(message)
    }

    private func clearOCRCopyFeedback() {
        ocrCopyFeedbackLabel?.stringValue = ""
        ocrCopyFeedbackLabel?.toolTip = nil
        ocrCopyFeedbackLabel?.setAccessibilityLabel("")
        ocrCopyFeedbackLabel?.setAccessibilityValue("")
    }

    private func showOCRCopyConfirmation(
        systemImage: String,
        button: BlocksAppKitCompactButton,
        sourcePanel: NSPanel,
        generation: UInt64
    ) {
        guard ocrCopyGeneration == generation,
              ocrPanel === sourcePanel,
              ocrCopyButton === button else { return }
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        ocrCopyFeedbackTask?.cancel()
        ocrCopyFeedbackTask = Task { @MainActor [weak self, weak button, weak sourcePanel] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.ocrCopyGeneration == generation,
                  self.ocrPanel === sourcePanel,
                  self.ocrCopyButton === button,
                  let button else { return }
            button.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
            self.ocrCopyFeedbackTask = nil
        }
    }

    private func invalidateOCRCopySession() {
        ocrCopyGeneration &+= 1
        ocrCopyFeedbackTask?.cancel()
        ocrCopyFeedbackTask = nil
        clearOCRCopyFeedback()
    }

    private func dismissOCRPanel() {
        invalidateOCRCopySession()
        if let ocrPanel {
            panel.removeChildWindow(ocrPanel)
            ocrPanel.delegate = nil
            ocrPanel.close()
        }
        self.ocrPanel = nil
        ocrTextView = nil
        ocrCopyButton = nil
        ocrCopyFeedbackLabel = nil
    }

    private func showOCRPanel(_ state: PinnedScreenshotOCRPanelState) {
        dismissOCRPanel()
        let resultSize = NSSize(width: 320, height: 220)
        let screenFrame = currentVisibleFrame
        var resultOrigin = CGPoint(
            x: panel.frame.maxX + 10,
            y: panel.frame.midY - resultSize.height / 2
        )
        if resultOrigin.x + resultSize.width > screenFrame.maxX {
            resultOrigin.x = panel.frame.minX - resultSize.width - 10
        }
        resultOrigin.x = min(max(resultOrigin.x, screenFrame.minX), screenFrame.maxX - resultSize.width)
        resultOrigin.y = min(max(resultOrigin.y, screenFrame.minY), screenFrame.maxY - resultSize.height)
        let resultPanel = NSPanel(
            contentRect: NSRect(origin: resultOrigin, size: resultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        resultPanel.level = .floating
        resultPanel.animationBehavior = .none
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        resultPanel.title = L10n.string("screenshot.pin.ocr.result")
        resultPanel.delegate = self
        resultPanel.contentView = makeOCRPanelContent(state)
        ocrPanel = resultPanel
        panel.addChildWindow(resultPanel, ordered: .above)
        resultPanel.orderFrontRegardless()
    }

    private func makeOCRPanelContent(_ state: PinnedScreenshotOCRPanelState) -> NSView {
        let contentView = NSView()
        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = BlocksVisualTokens.Spacing.xs
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(actionBar)

        let feedbackLabel = NSTextField(labelWithString: "")
        feedbackLabel.lineBreakMode = .byTruncatingTail
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(feedbackLabel)

        let retryButton = makeOCRActionButton(
            symbol: "arrow.clockwise",
            label: L10n.string("screenshot.ocr.retry"),
            action: #selector(recognizeText)
        )

        switch state {
        case let .result(text):
            let copyButton = makeOCRActionButton(
                symbol: "doc.on.doc",
                label: L10n.string("screenshot.ocr.copy"),
                action: #selector(copyOCRText)
            )
            copyButton.isEnabled = ocrCopyTask == nil
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            let textView = NSTextView(frame: NSRect(origin: .zero, size: NSSize(width: 300, height: 174)))
            textView.string = text
            textView.isEditable = true
            textView.isSelectable = true
            textView.allowsUndo = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: 300,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 10, height: 10)
            scrollView.documentView = textView
            contentView.addSubview(scrollView)
            actionBar.addArrangedSubview(copyButton)
            actionBar.addArrangedSubview(retryButton)
            ocrTextView = textView
            ocrCopyButton = copyButton
            ocrCopyFeedbackLabel = feedbackLabel
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -4)
            ])
        case let .failure(message):
            let failureLabel = NSTextField(wrappingLabelWithString: message)
            failureLabel.alignment = .center
            failureLabel.lineBreakMode = .byWordWrapping
            failureLabel.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(failureLabel)
            actionBar.addArrangedSubview(retryButton)
            NSLayoutConstraint.activate([
                failureLabel.leadingAnchor.constraint(
                    greaterThanOrEqualTo: contentView.leadingAnchor,
                    constant: BlocksVisualTokens.Spacing.md
                ),
                failureLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: contentView.trailingAnchor,
                    constant: -BlocksVisualTokens.Spacing.md
                ),
                failureLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                failureLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                failureLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: actionBar.topAnchor,
                    constant: -BlocksVisualTokens.Spacing.xs
                )
            ])
        }

        NSLayoutConstraint.activate([
            feedbackLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: BlocksVisualTokens.Spacing.sm
            ),
            feedbackLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: actionBar.leadingAnchor,
                constant: -BlocksVisualTokens.Spacing.xs
            ),
            feedbackLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            actionBar.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -BlocksVisualTokens.Spacing.sm
            ),
            actionBar.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -BlocksVisualTokens.Spacing.sm
            )
        ])
        return contentView
    }

    private func makeOCRActionButton(
        symbol: String,
        label: String,
        action: Selector
    ) -> BlocksAppKitCompactButton {
        let button = BlocksAppKitCompactButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setBlocksSelected(false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
        return button
    }

    var testingOCRText: String? { ocrTextView?.string }

    var testingOCRTextIsEditable: Bool { ocrTextView?.isEditable == true }

    var testingOCRPanel: NSPanel? { ocrPanel }

    var testingPanelAnimationBehavior: NSWindow.AnimationBehavior { panel.animationBehavior }

    var testingPanel: NSPanel { panel }

    var testingHasActiveSavePanel: Bool { activeSavePanel != nil }

    var testingOCRCopyButtonImage: NSImage? { ocrCopyButton?.image }

    var testingOCRCopyFeedback: String? { ocrCopyFeedbackLabel?.stringValue }

    var testingOCRCopyTask: Task<Void, Never>? { ocrCopyTask }

    var testingImageCopyObserverTask: Task<Void, Never>? { imageCopyObserverTask }

    var testingImageCopyFailureFeedback: String? { imageView.testingCopyFailureFeedback }

    var testingImageCopyButtonAccessibilityValue: String? {
        imageView.testingCopyButtonAccessibilityValue
    }

    var testingSaveFailureFeedback: String? { imageView.testingSaveFailureFeedback }

    var testingSaveButtonAccessibilityValue: String? {
        imageView.testingSaveButtonAccessibilityValue
    }

    var testingHasActiveOCRTask: Bool { ocrTask != nil }

    var testingOCRTask: Task<Void, Never>? { ocrTask }

    func setTestingOCRText(_ text: String) {
        ocrTextView?.string = text
    }

    func startTestingOCR() {
        recognizeText()
    }

    func retryTestingOCR() {
        recognizeText()
    }

    func copyTestingOCRText() {
        copyOCRText()
    }

    func closeForTesting() {
        close()
    }

    func revealToolbarForKeyboardTesting() {
        imageView.revealToolbarForKeyboard()
    }

    var testingToolbarIsVisible: Bool { imageView.testingToolbarIsVisible }

    var testingToolbarMinimumHitSize: CGSize { imageView.testingToolbarMinimumHitSize }

    @discardableResult
    func sendTestingCanvasKeyDown(_ event: NSEvent) -> String? {
        panel.makeFirstResponder(imageView)
        imageView.keyDown(with: event)
        return (panel.firstResponder as? NSView)?.accessibilityLabel()
    }

    @discardableResult
    func sendTestingFocusedToolbarKeyDown(_ event: NSEvent) -> String? {
        guard let button = panel.firstResponder as? PinnedScreenshotToolbarButton else { return nil }
        button.keyDown(with: event)
        return (panel.firstResponder as? NSView)?.accessibilityLabel()
    }

    func setTestingOCRInProgress(_ inProgress: Bool) {
        imageView.setOCRInProgress(inProgress)
    }

    func waitForTestingOCRTask() async {
        let task = ocrTask
        await task?.value
    }
}

private final class PinnedScreenshotView: NSView {
    private enum FeedbackOwner {
        case copy
        case save
    }

    weak var controller: PinnedScreenshotController? {
        didSet { toolbar.controller = controller }
    }
    var image: NSImage? {
        get { contentImageView.image }
        set { contentImageView.image = newValue }
    }
    var keepsControlsVisible = false {
        didSet {
            if keepsControlsVisible {
                showControls()
            } else if !mouseInside {
                scheduleHideControls()
            }
        }
    }

    private let contentImageView = NSImageView()
    private let toolbar = PinnedScreenshotToolbarView()
    private let copyFeedbackSurface = BlocksAppKitGlassSurfaceView()
    private let copyFeedbackLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hideWorkItem: DispatchWorkItem?
    private var mouseInside = false
    private var controlsTargetVisible = false
    private var feedbackOwner: FeedbackOwner?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = BlocksVisualTokens.CornerRadius.control
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        contentImageView.imageScaling = .scaleProportionallyUpOrDown
        contentImageView.imageAlignment = .alignCenter
        contentImageView.wantsLayer = true
        addSubview(contentImageView)

        toolbar.alphaValue = 0
        toolbar.isHidden = true
        addSubview(toolbar)

        copyFeedbackSurface.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .hud,
            cornerRadius: BlocksVisualTokens.CornerRadius.control,
            drawsShadow: true
        )
        // This view is frame-laid-out below. Give its internal constraints a
        // valid initial width so AppKit does not synthesize a transient
        // zero-width autoresizing constraint before the first layout pass.
        copyFeedbackSurface.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
        copyFeedbackSurface.isHidden = true
        copyFeedbackSurface.addBlocksContentSubview(copyFeedbackLabel)
        copyFeedbackLabel.alignment = .center
        copyFeedbackLabel.lineBreakMode = .byTruncatingTail
        copyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            copyFeedbackLabel.leadingAnchor.constraint(
                equalTo: copyFeedbackSurface.leadingAnchor,
                constant: BlocksVisualTokens.Spacing.sm
            ),
            copyFeedbackLabel.trailingAnchor.constraint(
                equalTo: copyFeedbackSurface.trailingAnchor,
                constant: -BlocksVisualTokens.Spacing.sm
            ),
            copyFeedbackLabel.centerYAnchor.constraint(equalTo: copyFeedbackSurface.centerYAnchor),
        ])
        addSubview(copyFeedbackSurface)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hideWorkItem?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        contentImageView.frame = bounds
        let toolbarWidth = toolbar.prepare(forAvailableWidth: bounds.width)
        toolbar.frame = NSRect(
            x: max(BlocksVisualTokens.Spacing.sm, (bounds.width - toolbarWidth) / 2),
            y: BlocksVisualTokens.Spacing.sm,
            width: min(toolbarWidth, max(0, bounds.width - BlocksVisualTokens.Spacing.lg)),
            height: 42
        )
        copyFeedbackSurface.frame = NSRect(
            x: max(BlocksVisualTokens.Spacing.sm, (bounds.width - 260) / 2),
            y: toolbar.frame.maxY + BlocksVisualTokens.Spacing.xs,
            width: min(260, max(0, bounds.width - BlocksVisualTokens.Spacing.lg)),
            height: 32
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        showControls()
    }

    override func mouseMoved(with event: NSEvent) {
        mouseInside = true
        showControls()
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        if !keepsControlsVisible { scheduleHideControls() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scale(by: event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        controller?.scale(by: event.magnification * 60)
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            revealToolbarForKeyboard()
            let movesBackward = event.modifierFlags.contains(.shift)
            if toolbar.focusBoundaryControl(backward: movesBackward) { return }
        }
        let accelerated = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 24, 69: controller?.zoomIn()
        case 27, 78: controller?.zoomOut()
        case 29: controller?.resetZoom()
        case 123: controller?.nudge(dx: -1, dy: 0, accelerated: accelerated)
        case 124: controller?.nudge(dx: 1, dy: 0, accelerated: accelerated)
        case 125: controller?.nudge(dx: 0, dy: -1, accelerated: accelerated)
        case 126: controller?.nudge(dx: 0, dy: 1, accelerated: accelerated)
        case 53: controller?.close()
        default: super.keyDown(with: event)
        }
    }

    func update(percentage: Int, opacity: CGFloat) {
        contentImageView.alphaValue = opacity
        toolbar.update(percentage: percentage)
        needsLayout = true
    }

    func setOCRInProgress(_ inProgress: Bool) {
        toolbar.setOCRInProgress(inProgress)
        if inProgress { showControls() }
    }

    func showTransientConfirmation(systemImage: String) {
        toolbar.showTransientConfirmation(systemImage: systemImage)
        showControls()
    }

    func showSaveTransientConfirmation(systemImage: String) {
        toolbar.showSaveTransientConfirmation(systemImage: systemImage)
        showControls()
    }

    func showCopyFailureFeedback() {
        let message = [
            L10n.string("screenshot.result.copyFailed"),
            L10n.string("screenshot.ocr.retry"),
        ].filter { !$0.isEmpty }.joined(separator: " ")
        showFeedback(message, owner: .copy)
        toolbar.setCopyFeedback(message)
        showControls()
        ScreenshotAccessibilityAnnouncer.announce(message, priority: .high)
    }

    func clearCopyFailureFeedback() {
        guard feedbackOwner == .copy else { return }
        clearFeedback()
        toolbar.setCopyFeedback(nil)
    }

    func showSaveFailureFeedback(_ message: String) {
        showFeedback(message, owner: .save)
        toolbar.setSaveFeedback(message)
        showControls()
        ScreenshotAccessibilityAnnouncer.announce(message, priority: .high)
    }

    func clearSaveFailureFeedback() {
        guard feedbackOwner == .save else { return }
        clearFeedback()
        toolbar.setSaveFeedback(nil)
    }

    private func showFeedback(_ message: String, owner: FeedbackOwner) {
        feedbackOwner = owner
        copyFeedbackLabel.stringValue = message
        copyFeedbackLabel.toolTip = message
        copyFeedbackLabel.setAccessibilityLabel(message)
        copyFeedbackLabel.setAccessibilityValue(message)
        copyFeedbackSurface.isHidden = false
    }

    private func clearFeedback() {
        copyFeedbackSurface.isHidden = true
        copyFeedbackLabel.stringValue = ""
        copyFeedbackLabel.toolTip = nil
        copyFeedbackLabel.setAccessibilityLabel("")
        copyFeedbackLabel.setAccessibilityValue("")
        feedbackOwner = nil
    }

    private func showControls() {
        hideWorkItem?.cancel()
        guard !controlsTargetVisible || toolbar.isHidden else { return }
        controlsTargetVisible = true
        toolbar.isHidden = false
        BlocksAppKitMotion.animate(
            view: toolbar,
            alphaValue: 1,
            role: .hoverFocus
        ) {}
    }

    private func scheduleHideControls() {
        hideWorkItem?.cancel()
        guard controlsTargetVisible, !toolbar.isHidden else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.mouseInside,
                  !self.keepsControlsVisible,
                  !self.toolbarHasKeyboardFocus else { return }
            self.controlsTargetVisible = false
            BlocksAppKitMotion.animate(
                view: self.toolbar,
                alphaValue: 0,
                role: .hoverFocus
            ) { [weak self] in
                guard let self,
                      !self.controlsTargetVisible,
                      self.toolbar.alphaValue < 0.01 else { return }
                self.toolbar.isHidden = true
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private var toolbarHasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === toolbar || responder.isDescendant(of: toolbar)
    }

    func revealToolbarForKeyboard() {
        layoutSubtreeIfNeeded()
        toolbar.layoutSubtreeIfNeeded()
        showControls()
    }

    var testingToolbarIsVisible: Bool { !toolbar.isHidden }

    var testingToolbarMinimumHitSize: CGSize { toolbar.testingMinimumHitSize }

    var testingCopyFailureFeedback: String? {
        copyFeedbackSurface.isHidden ? nil : copyFeedbackLabel.stringValue
    }

    var testingCopyButtonAccessibilityValue: String? { toolbar.testingCopyButtonAccessibilityValue }

    var testingSaveButtonAccessibilityValue: String? { toolbar.testingSaveButtonAccessibilityValue }

    var testingSaveFailureFeedback: String? {
        feedbackOwner == .save && !copyFeedbackSurface.isHidden ? copyFeedbackLabel.stringValue : nil
    }
}

private final class PinnedScreenshotToolbarButton: BlocksAppKitCompactButton {
    weak var focusNavigationToolbar: PinnedScreenshotToolbarView?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            let movesBackward = event.modifierFlags.contains(.shift)
            if focusNavigationToolbar?.moveKeyboardFocus(from: self, backward: movesBackward) == true {
                return
            }
        case 53:
            focusNavigationToolbar?.closeFromKeyboard()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }
}

private final class PinnedScreenshotToolbarView: BlocksAppKitGlassSurfaceView {
    weak var controller: PinnedScreenshotController?

    private enum LayoutMode {
        case full
        case compact
        case minimal
    }

    private let zoomOutButton = PinnedScreenshotToolbarButton()
    private let zoomButton = PinnedScreenshotToolbarButton()
    private let zoomInButton = PinnedScreenshotToolbarButton()
    private let opacityButton = PinnedScreenshotToolbarButton()
    private let ocrButton = PinnedScreenshotToolbarButton()
    private let copyButton = PinnedScreenshotToolbarButton()
    private let saveButton = PinnedScreenshotToolbarButton()
    private let moreButton = PinnedScreenshotToolbarButton()
    private let closeButton = PinnedScreenshotToolbarButton()
    private var copyConfirmationResetWorkItem: DispatchWorkItem?
    private var saveConfirmationResetWorkItem: DispatchWorkItem?
    private var mode: LayoutMode = .full

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .panel,
            cornerRadius: BlocksVisualTokens.CornerRadius.control,
            drawsShadow: true
        )

        configure(zoomOutButton, symbol: "minus", label: L10n.string("screenshot.pin.zoomOut"), action: #selector(zoomOut))
        configure(zoomInButton, symbol: "plus", label: L10n.string("screenshot.pin.zoomIn"), action: #selector(zoomIn))
        configure(opacityButton, symbol: "circle.lefthalf.filled", label: L10n.string("screenshot.pin.opacity"), action: #selector(showOpacityMenu))
        configure(ocrButton, symbol: "text.viewfinder", label: L10n.string("screenshot.pin.ocr"), action: #selector(recognizeText))
        configure(copyButton, symbol: "doc.on.doc", label: L10n.string("screenshot.pin.copy"), action: #selector(copyImage))
        configure(saveButton, symbol: "square.and.arrow.down", label: L10n.string("screenshot.pin.save"), action: #selector(saveImage))
        configure(moreButton, symbol: "ellipsis", label: L10n.string("screenshot.editor.moreTools"), action: #selector(showMoreMenu))
        configure(closeButton, symbol: "xmark", label: L10n.string("common.close"), action: #selector(close))

        zoomButton.title = "100%"
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.isBordered = false
        zoomButton.target = self
        zoomButton.action = #selector(showZoomMenu)
        zoomButton.toolTip = L10n.string("screenshot.editor.zoom")
        zoomButton.setAccessibilityLabel(L10n.string("screenshot.editor.zoom"))
        zoomButton.setBlocksSelected(false)
        zoomButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        zoomButton.focusNavigationToolbar = self
        addBlocksContentSubview(zoomButton)
    }

    required init?(coder: NSCoder) { nil }

    func prepare(forAvailableWidth width: CGFloat) -> CGFloat {
        let nextMode: LayoutMode
        if width >= preferredWidth(for: .full) {
            nextMode = .full
        } else if width >= preferredWidth(for: .compact) {
            nextMode = .compact
        } else {
            nextMode = .minimal
        }
        if nextMode != mode {
            mode = nextMode
            needsLayout = true
        }
        return preferredWidth(for: nextMode)
    }

    func update(percentage: Int) {
        zoomButton.title = "\(percentage)%"
        zoomButton.setAccessibilityValue("\(percentage)%")
    }

    func setOCRInProgress(_ inProgress: Bool) {
        ocrButton.isEnabled = !inProgress
        ocrButton.image = NSImage(
            systemSymbolName: inProgress ? "hourglass" : "text.viewfinder",
            accessibilityDescription: nil
        )
        updateFocusLoop()
    }

    func showTransientConfirmation(systemImage: String) {
        copyConfirmationResetWorkItem?.cancel()
        copyButton.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        let item = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
        copyConfirmationResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func setCopyFeedback(_ message: String?) {
        copyButton.setAccessibilityValue(message ?? "")
        copyButton.setAccessibilityHelp(message)
    }

    func showSaveTransientConfirmation(systemImage: String) {
        saveConfirmationResetWorkItem?.cancel()
        saveButton.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        let item = DispatchWorkItem { [weak self] in
            self?.saveButton.image = NSImage(
                systemSymbolName: "square.and.arrow.down",
                accessibilityDescription: nil
            )
        }
        saveConfirmationResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func setSaveFeedback(_ message: String?) {
        saveConfirmationResetWorkItem?.cancel()
        saveButton.image = NSImage(
            systemSymbolName: message == nil ? "square.and.arrow.down" : "exclamationmark.triangle",
            accessibilityDescription: nil
        )
        saveButton.setAccessibilityValue(message ?? "")
        saveButton.setAccessibilityHelp(message)
    }

    override func layout() {
        super.layout()
        let visibleButtons = buttons(for: mode)
        let hiddenButtons = allButtons.filter { candidate in
            !visibleButtons.contains(where: { $0 === candidate })
        }
        hiddenButtons.forEach { $0.isHidden = true }
        visibleButtons.forEach { $0.isHidden = false }

        var x: CGFloat = 6
        for button in visibleButtons {
            let width: CGFloat = button === zoomButton ? 52 : 36
            button.frame = NSRect(x: x, y: 3, width: width, height: 36)
            x += width + 4
        }
        updateFocusLoop()
    }

    private var allButtons: [NSButton] {
        [zoomOutButton, zoomButton, zoomInButton, opacityButton, ocrButton, copyButton, saveButton, moreButton, closeButton]
    }

    private func buttons(for mode: LayoutMode) -> [NSButton] {
        switch mode {
        case .full:
            [zoomOutButton, zoomButton, zoomInButton, opacityButton, ocrButton, copyButton, saveButton, closeButton]
        case .compact:
            [zoomOutButton, zoomButton, zoomInButton, opacityButton, moreButton, closeButton]
        case .minimal:
            [moreButton, closeButton]
        }
    }

    private func preferredWidth(for mode: LayoutMode) -> CGFloat {
        let buttons = buttons(for: mode)
        let controlsWidth = buttons.reduce(CGFloat.zero) { partial, button in
            partial + (button === zoomButton ? 52 : 36)
        }
        return controlsWidth + CGFloat(max(0, buttons.count - 1)) * 4 + 12
    }

    private func configure(
        _ button: PinnedScreenshotToolbarButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setBlocksSelected(false)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.focusNavigationToolbar = self
        addBlocksContentSubview(button)
    }

    @discardableResult
    func focusFirstControl() -> Bool {
        focusBoundaryControl(backward: false)
    }

    @discardableResult
    func focusBoundaryControl(backward: Bool) -> Bool {
        let controls = focusableControls
        guard let control = backward ? controls.last : controls.first else { return false }
        return window?.makeFirstResponder(control) == true
    }

    var testingMinimumHitSize: CGSize {
        let controls = buttons(for: mode)
        let minimumWidth = controls.map(\.frame.width).min() ?? 0
        let minimumHeight = controls.map(\.frame.height).min() ?? 0
        return CGSize(width: minimumWidth, height: minimumHeight)
    }

    var testingCopyButtonAccessibilityValue: String? {
        copyButton.accessibilityValue() as? String
    }

    var testingSaveButtonAccessibilityValue: String? {
        saveButton.accessibilityValue() as? String
    }

    private var focusableControls: [PinnedScreenshotToolbarButton] {
        buttons(for: mode).compactMap { $0 as? PinnedScreenshotToolbarButton }
            .filter { !$0.isHidden && $0.isEnabled }
    }

    @discardableResult
    func moveKeyboardFocus(from control: PinnedScreenshotToolbarButton, backward: Bool) -> Bool {
        let controls = focusableControls
        guard !controls.isEmpty else { return false }
        let destination: PinnedScreenshotToolbarButton
        if let currentIndex = controls.firstIndex(where: { $0 === control }) {
            let offset = backward ? controls.count - 1 : 1
            destination = controls[(currentIndex + offset) % controls.count]
        } else {
            destination = backward ? controls[controls.count - 1] : controls[0]
        }
        return window?.makeFirstResponder(destination) == true
    }

    func closeFromKeyboard() {
        controller?.close()
    }

    private func updateFocusLoop() {
        allButtons.forEach {
            $0.nextKeyView = nil
        }
        let controls = focusableControls
        guard let first = controls.first else { return }
        for (control, next) in zip(controls, controls.dropFirst()) {
            control.nextKeyView = next
        }
        controls.last?.nextKeyView = first
    }

    @objc private func zoomOut() { controller?.zoomOut() }
    @objc private func zoomIn() { controller?.zoomIn() }
    @objc private func showZoomMenu() { controller?.presentZoomMenu(from: zoomButton) }
    @objc private func showOpacityMenu() { controller?.presentOpacityMenu(from: opacityButton) }
    @objc private func recognizeText() { controller?.recognizeText() }
    @objc private func copyImage() { controller?.copyImage() }
    @objc private func saveImage() { controller?.saveImage() }
    @objc private func showMoreMenu() { controller?.presentMoreMenu(from: moreButton) }
    @objc private func close() { controller?.close() }
}
