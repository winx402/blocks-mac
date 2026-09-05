import AppKit

@MainActor
final class ScreenshotCaptureCountdownController {
    private var panel: ScreenshotCaptureCountdownPanel?
    private var countdownTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    static func isCancelKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    func run(seconds: Double, targetRect: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        guard continuation == nil else { return false }

        let panel = ScreenshotCaptureCountdownPanel(contentRect: countdownFrame(near: targetRect))
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.onCancel = { [weak self] in self?.finish(completed: false) }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
        self.panel = panel

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                countdownTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    var remaining = max(1, Int(ceil(seconds)))
                    while remaining > 0 {
                        guard !Task.isCancelled else { return }
                        self.panel?.setRemaining(remaining)
                        do {
                            try await Task.sleep(for: .seconds(1))
                        } catch {
                            return
                        }
                        remaining -= 1
                    }
                    self.finish(completed: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(completed: false) }
        }
    }

    func cancel() {
        finish(completed: false)
    }

    private func countdownFrame(near targetRect: CGRect) -> CGRect {
        let size = CGSize(width: 76, height: 76)
        let targetPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(targetPoint) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? targetRect
        let proposed = CGRect(
            x: targetPoint.x - size.width / 2,
            y: targetPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return ScreenshotSelectionToolbarPlacement.clampedFrame(proposed, visibleFrames: [visibleFrame])
    }

    private func finish(completed: Bool) {
        guard let continuation else { return }
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
        dismissalTask?.cancel()
        guard completed else {
            self.continuation = nil
            continuation.resume(returning: false)
            return
        }
        // ScreenCaptureKit can observe a panel for a short time after orderOut.
        // Wait for WindowServer to retire the countdown surface before capturing.
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self, self.continuation != nil else { return }
            self.continuation = nil
            self.dismissalTask = nil
            continuation.resume(returning: true)
        }
    }
}

final class ScreenshotCaptureCountdownPanel: ScreenshotSelectionPanel {
    var onCancel: (() -> Void)?
    private let numberLabel = NSTextField(labelWithString: "")
    private var hasPostedInitialAccessibilityFocus = false

    override init(contentRect: CGRect) {
        super.init(contentRect: contentRect)
        hasShadow = true

        let surface = BlocksAppKitGlassSurfaceView(frame: CGRect(origin: .zero, size: contentRect.size))
        surface.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .hud,
            cornerRadius: contentRect.width / 2,
            drawsShadow: false
        )

        numberLabel.font = BlocksTypography.nsFont(size: 30, weight: .semibold)
        numberLabel.textColor = .labelColor
        numberLabel.alignment = .center
        numberLabel.setAccessibilityElement(true)
        numberLabel.setAccessibilityRole(.staticText)
        numberLabel.setAccessibilityLabel(L10n.string("screenshot.countdown.accessibility.label"))
        numberLabel.setAccessibilityHelp(L10n.string("screenshot.countdown.accessibility.help"))
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addBlocksContentSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: surface.blocksContentView.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: surface.blocksContentView.centerYAnchor),
        ])
        contentView = surface
    }

    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        if ScreenshotCaptureCountdownController.isCancelKeyCode(event.keyCode) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    func setRemaining(_ value: Int) {
        let announcement = L10n.format("screenshot.countdown.accessibility.value", value)
        numberLabel.stringValue = String(value)
        numberLabel.setAccessibilityValue(announcement)
        NSAccessibility.post(element: numberLabel, notification: .valueChanged)
        if !hasPostedInitialAccessibilityFocus {
            hasPostedInitialAccessibilityFocus = true
            ScreenshotAccessibilityAnnouncer.focus(numberLabel)
        }
        ScreenshotAccessibilityAnnouncer.announce(announcement, priority: .high)
    }
}
