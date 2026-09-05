import AppKit
import SwiftUI

final class ScrollingScreenshotHUDPanel: ScreenshotSelectionPanel {
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

struct ScrollingScreenshotHUDState: Equatable {
    enum Phase: Equatable {
        case ready
        case capturing
        case recovering
        case paused
        case possibleEnd(secondsRemaining: Int)
        case finalizing
    }

    var phase: Phase = .capturing
    var accumulatedWidth = 0
    var accumulatedHeight = 0
    var warning: String?
    var isCheckingResume = false
    var isRestarting = false
}

struct ScrollingScreenshotHUDPresentation: Equatable {
    let phaseIcon: String
    let phaseTitle: String
    let dimensionText: String
    let warningText: String?
    let commands: [ScreenshotScrollingCommand]
    let disabledCommands: Set<ScreenshotScrollingCommand>
    let loadingCommands: Set<ScreenshotScrollingCommand>
    let isPauseActionLoading: Bool

    enum ActionSlot: CaseIterable, Identifiable {
        case primary
        case secondary
        case finish
        case cancel

        var id: Self { self }
    }

    init(state: ScrollingScreenshotHUDState) {
        dimensionText = L10n.format(
            "screenshot.scrolling.dimensions",
            state.accumulatedWidth,
            state.accumulatedHeight
        )
        warningText = state.warning
        isPauseActionLoading = state.isCheckingResume
        loadingCommands = state.isRestarting ? [.restart] : (state.isCheckingResume ? [.resume] : [])
        switch state.phase {
        case .ready:
            phaseIcon = "rectangle.stack"
            phaseTitle = L10n.string("screenshot.scrolling.ready")
            commands = [.start, .reselect, .cancel]
            disabledCommands = []
        case .capturing:
            phaseIcon = "rectangle.stack"
            phaseTitle = L10n.string("screenshot.scrolling.capturing")
            commands = [.pause, .restart, .finish, .cancel]
            disabledCommands = []
        case .recovering:
            phaseIcon = "arrow.clockwise"
            phaseTitle = L10n.string("screenshot.scrolling.recovering.short")
            commands = [.restart, .finish, .cancel]
            disabledCommands = [.finish]
        case .paused:
            phaseIcon = "pause.circle"
            phaseTitle = L10n.string("screenshot.scrolling.paused")
            commands = [.resume, .restart, .finish, .cancel]
            disabledCommands = state.isCheckingResume ? [.resume, .restart, .finish] : [.finish]
        case let .possibleEnd(seconds):
            phaseIcon = "hourglass"
            phaseTitle = L10n.format("screenshot.scrolling.possibleEnd", seconds)
            commands = [.pause, .restart, .finish, .cancel]
            disabledCommands = []
        case .finalizing:
            phaseIcon = "gearshape.2"
            phaseTitle = L10n.string("screenshot.scrolling.finalizing")
            commands = [.pause, .restart, .finish, .cancel]
            disabledCommands = [.pause, .restart, .finish]
        }
    }

    var announcementText: String {
        if isPauseActionLoading {
            return L10n.string("screenshot.scrolling.resumeChecking")
        }
        guard let warningText, !warningText.isEmpty else { return phaseTitle }
        return "\(phaseTitle). \(warningText)"
    }

    func command(in slot: ActionSlot) -> ScreenshotScrollingCommand? {
        switch slot {
        case .primary:
            return commands.first(where: { [.start, .pause, .resume].contains($0) })
        case .secondary:
            return commands.first(where: { [.reselect, .restart].contains($0) })
        case .finish:
            return commands.contains(.finish) ? .finish : nil
        case .cancel:
            return commands.contains(.cancel) ? .cancel : nil
        }
    }
}

enum ScrollingScreenshotHUDFocusPolicy {
    struct Configuration: Equatable {
        let commands: [ScreenshotScrollingCommand]
        let disabledCommands: Set<ScreenshotScrollingCommand>

        init(
            presentation: ScrollingScreenshotHUDPresentation,
            disabledCommands: Set<ScreenshotScrollingCommand>
        ) {
            commands = presentation.commands
            self.disabledCommands = disabledCommands
        }
    }

    static func initialFocus(for configuration: Configuration) -> ScreenshotScrollingCommand? {
        configuration.commands.first(where: {
            !isDisabled($0, in: configuration) && $0.emphasis == .accent
        }) ?? configuration.commands.first(where: { !isDisabled($0, in: configuration) })
    }

    static func focusAfterConfigurationChange(
        currentFocus: ScreenshotScrollingCommand?,
        configuration: Configuration
    ) -> ScreenshotScrollingCommand? {
        guard let currentFocus else { return nil }
        guard configuration.commands.contains(currentFocus),
              !isDisabled(currentFocus, in: configuration) else {
            return initialFocus(for: configuration)
        }
        return currentFocus
    }

    private static func isDisabled(
        _ command: ScreenshotScrollingCommand,
        in configuration: Configuration
    ) -> Bool {
        configuration.disabledCommands.contains(command)
    }
}

enum ScrollingScreenshotHUDPlacement {
    static let screenInset: CGFloat = 8

    static func frame(
        proposedOrigin: CGPoint,
        visibleFrame: CGRect,
        preferredSize: CGSize = ScreenshotDesignTokens.hudSize
    ) -> CGRect {
        let size = CGSize(
            width: min(preferredSize.width, max(0, visibleFrame.width - screenInset * 2)),
            height: min(preferredSize.height, max(0, visibleFrame.height - screenInset * 2))
        )
        let lowerBound = CGPoint(
            x: visibleFrame.minX + screenInset,
            y: visibleFrame.minY + screenInset
        )
        let upperBound = CGPoint(
            x: visibleFrame.maxX - size.width - screenInset,
            y: visibleFrame.maxY - size.height - screenInset
        )
        return CGRect(
            origin: CGPoint(
                x: min(max(proposedOrigin.x, lowerBound.x), upperBound.x),
                y: min(max(proposedOrigin.y, lowerBound.y), upperBound.y)
            ),
            size: size
        )
    }
}

@MainActor
final class ScrollingScreenshotHUDAnnouncementScheduler {
    private let announce: @MainActor (String, NSAccessibilityPriorityLevel) -> Void
    private var lastAnnouncement: String?
    private var announcementTask: Task<Void, Never>?
    private var announcementTaskOwner: UUID?
    private var pendingAnnouncementText: String?

    init(
        announce: @escaping @MainActor (String, NSAccessibilityPriorityLevel) -> Void = {
            ScreenshotAccessibilityAnnouncer.announce($0, priority: $1)
        }
    ) {
        self.announce = announce
    }

    func reset() {
        cancelPendingAnnouncement()
        lastAnnouncement = nil
    }

    func waitUntilIdleForTesting() async {
        guard let announcementTask else { return }
        await announcementTask.value
    }

    func schedule(
        presentation: ScrollingScreenshotHUDPresentation,
        isCurrent: @escaping () -> Bool
    ) {
        let announcementText = presentation.announcementText
        guard announcementText != pendingAnnouncementText else { return }

        cancelPendingAnnouncement()
        guard announcementText != lastAnnouncement else { return }

        let owner = UUID()
        announcementTaskOwner = owner
        pendingAnnouncementText = announcementText
        announcementTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.announcementTaskOwner == owner {
                    self.announcementTask = nil
                    self.announcementTaskOwner = nil
                    self.pendingAnnouncementText = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.announcementTaskOwner == owner,
                  isCurrent() else { return }
            self.lastAnnouncement = announcementText
            self.announce(
                announcementText,
                presentation.warningText == nil ? .medium : .high
            )
        }
    }

    private func cancelPendingAnnouncement() {
        announcementTask?.cancel()
        announcementTask = nil
        announcementTaskOwner = nil
        pendingAnnouncementText = nil
    }
}

@MainActor
final class ScrollingScreenshotHUDController: NSObject, ObservableObject, NSWindowDelegate {
    static let requiresApplicationActivation = false

    @Published var state = ScrollingScreenshotHUDState() {
        didSet { scheduleAccessibilityAnnouncement() }
    }

    private var hudPanel: ScrollingScreenshotHUDPanel?
    private var borderPanels: [ScreenshotSelectionPanel] = []
    private var isClampingFrame = false
    private var commandHandler: (ScreenshotScrollingCommand) -> Void = { _ in }
    private let accessibilityAnnouncementScheduler = ScrollingScreenshotHUDAnnouncementScheduler()

    var windowNumber: Int? {
        guard let hudPanel, hudPanel.windowNumber > 0 else { return nil }
        return hudPanel.windowNumber
    }

    func showReady(
        selectionRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        isStartEnabled: Bool,
        onCommand: @escaping (ScreenshotScrollingCommand) -> Void
    ) {
        state = ScrollingScreenshotHUDState(
            phase: .ready,
            accumulatedWidth: max(0, pixelWidth),
            accumulatedHeight: max(0, pixelHeight)
        )
        var disabled: Set<ScreenshotScrollingCommand> = []
        if !isStartEnabled { disabled.insert(.start) }
        disabledReadyCommands = disabled
        commandHandler = onCommand
        presentIfNeeded(selectionRect: selectionRect)
    }

    func updateReadyStartEnabled(_ enabled: Bool) {
        guard state.phase == .ready else { return }
        disabledReadyCommands = enabled ? [] : [.start]
        objectWillChange.send()
    }

    func transitionToCapturing(
        selectionRect: CGRect,
        onCommand: @escaping (ScreenshotScrollingCommand) -> Void
    ) {
        commandHandler = onCommand
        disabledReadyCommands = []
        state.phase = .capturing
        if state.accumulatedWidth == 0 {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(selectionRect) }) ?? NSScreen.main
            state.accumulatedWidth = Int((selectionRect.width * (screen?.backingScaleFactor ?? 1)).rounded())
            state.accumulatedHeight = Int((selectionRect.height * (screen?.backingScaleFactor ?? 1)).rounded())
        }
        presentIfNeeded(selectionRect: selectionRect)
    }

    func perform(_ command: ScreenshotScrollingCommand) {
        guard !effectiveDisabledCommands.contains(command) else { return }
        commandHandler(command)
    }

    private(set) var disabledReadyCommands: Set<ScreenshotScrollingCommand> = []
    var effectiveDisabledCommands: Set<ScreenshotScrollingCommand> {
        var disabled = ScrollingScreenshotHUDPresentation(state: state).disabledCommands
            .union(disabledReadyCommands)
        if state.isRestarting {
            disabled.formUnion([.pause, .resume, .restart, .finish])
        }
        return disabled
    }

    private func presentIfNeeded(selectionRect: CGRect) {
        guard hudPanel == nil else { return }
        accessibilityAnnouncementScheduler.reset()
        showBorder(selectionRect: selectionRect)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(selectionRect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect
        let size = ScreenshotDesignTokens.hudSize
        var origin = CGPoint(x: selectionRect.midX - size.width / 2, y: selectionRect.minY - size.height - 10)
        if origin.y < visible.minY + ScrollingScreenshotHUDPlacement.screenInset {
            origin.y = selectionRect.maxY + 10
        }
        let panel = ScrollingScreenshotHUDPanel(
            contentRect: ScrollingScreenshotHUDPlacement.frame(
                proposedOrigin: origin,
                visibleFrame: visible,
                preferredSize: size
            )
        )
        panel.delegate = self
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow))) + 1
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.perform(.cancel) }
        panel.contentView = ScreenshotFirstMouseHostingView(
            rootView: ScrollingScreenshotHUDView(controller: self)
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
        hudPanel = panel
        scheduleAccessibilityAnnouncement()
    }

    func confirmDiscard() async -> Bool {
        guard let hudPanel else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("screenshot.scrolling.cancel.title")
        alert.informativeText = L10n.string("screenshot.scrolling.cancel.detail")
        alert.addButton(withTitle: L10n.string("screenshot.editor.discard"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: hudPanel) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isClampingFrame, let panel = notification.object as? NSWindow else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let frame = ScrollingScreenshotHUDPlacement.frame(
            proposedOrigin: panel.frame.origin,
            visibleFrame: visible,
            preferredSize: panel.frame.size
        )
        guard frame != panel.frame else { return }
        isClampingFrame = true
        panel.setFrame(frame, display: false)
        isClampingFrame = false
    }

    func dismiss() {
        accessibilityAnnouncementScheduler.reset()
        hudPanel?.delegate = nil
        hudPanel?.onEscape = nil
        hudPanel?.contentView = nil
        borderPanels.forEach {
            $0.delegate = nil
            $0.contentView = nil
        }
        commandHandler = { _ in }

        hudPanel?.close()
        borderPanels.forEach { $0.close() }

        hudPanel = nil
        borderPanels.removeAll()
    }

    private func scheduleAccessibilityAnnouncement() {
        let presentation = ScrollingScreenshotHUDPresentation(state: state)
        guard let panel = hudPanel else { return }
        accessibilityAnnouncementScheduler.schedule(presentation: presentation) { [weak self, weak panel] in
            guard let self, let panel, self.hudPanel === panel else { return false }
            return ScrollingScreenshotHUDPresentation(state: self.state).announcementText
                == presentation.announcementText
        }
    }

    private func showBorder(selectionRect: CGRect) {
        for screen in NSScreen.screens where screen.frame.intersects(selectionRect) {
            let intersection = screen.frame.intersection(selectionRect)
            let panel = ScreenshotSelectionPanel(contentRect: intersection)
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.ignoresMouseEvents = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.contentView = ScrollingScreenshotBorderView(frame: CGRect(origin: .zero, size: intersection.size))
            panel.orderFrontRegardless()
            borderPanels.append(panel)
        }
    }
}

struct ScrollingScreenshotHUDView: View {
    @ObservedObject var controller: ScrollingScreenshotHUDController
    @FocusState private var focusedAction: ScreenshotScrollingCommand?

    private var presentation: ScrollingScreenshotHUDPresentation {
        ScrollingScreenshotHUDPresentation(state: controller.state)
    }

    private var focusConfiguration: ScrollingScreenshotHUDFocusPolicy.Configuration {
        ScrollingScreenshotHUDFocusPolicy.Configuration(
            presentation: presentation,
            disabledCommands: controller.effectiveDisabledCommands
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = ScrollingScreenshotHUDLayout.metrics(
                for: geometry.size.width
            )

            HStack(spacing: 0) {
                if layout.showsVisualStatus {
                    ScrollingScreenshotStatusSummary(
                        phaseIcon: presentation.phaseIcon,
                        phaseTitle: presentation.phaseTitle,
                        dimensionText: presentation.dimensionText,
                        warningText: presentation.warningText,
                        layout: layout
                    )
                    .frame(width: layout.statusWidth, alignment: .leading)

                    Spacer(minLength: BlocksVisualTokens.Spacing.sm)
                }

                BlocksCompactControlGroup {
                    ForEach(ScrollingScreenshotHUDPresentation.ActionSlot.allCases) { slot in
                        if let command = presentation.command(in: slot) {
                            ScreenshotToolbarIconButton(
                                systemImage: command.systemImage,
                                label: command.label,
                                isEnabled: !controller.effectiveDisabledCommands.contains(command),
                                isLoading: presentation.loadingCommands.contains(command),
                                emphasis: command.emphasis,
                                action: { controller.perform(command) }
                            )
                            .focused($focusedAction, equals: command)
                        } else {
                            ScreenshotToolbarIconButton(
                                systemImage: "circle",
                                label: "",
                                isEnabled: false,
                                action: {}
                            )
                            .hidden()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            .padding(.horizontal, BlocksVisualTokens.Spacing.sm)
            .frame(width: geometry.size.width, height: ScreenshotDesignTokens.hudSize.height)
        }
        .frame(height: ScreenshotDesignTokens.hudSize.height)
        .blocksSurface(.hud, cornerRadius: BlocksVisualTokens.CornerRadius.section)
        .onAppear {
            focusedAction = ScrollingScreenshotHUDFocusPolicy.initialFocus(for: focusConfiguration)
        }
        .onChange(of: focusConfiguration) { _, nextConfiguration in
            focusedAction = ScrollingScreenshotHUDFocusPolicy.focusAfterConfigurationChange(
                currentFocus: focusedAction,
                configuration: nextConfiguration
            )
        }
        .blocksImmediateTooltipHost()
    }
}

enum ScrollingScreenshotHUDLayout {
    enum StatusMode {
        case full
        case compact
        case iconOnly
        case accessibilityOnly
    }

    struct Metrics {
        let statusMode: StatusMode
        let statusWidth: CGFloat

        var showsVisualStatus: Bool {
            statusMode != .accessibilityOnly
        }
    }

    private static let actionSlotCount = ScrollingScreenshotHUDPresentation.ActionSlot.allCases.count
    private static let statusIconWidth: CGFloat = 24
    private static let fullTitleWidth: CGFloat = 128
    private static let fullWarningWidth: CGFloat = 152

    static func metrics(for hudWidth: CGFloat) -> Metrics {
        let contentWidth = max(0, hudWidth - BlocksVisualTokens.Spacing.sm * 2)
        let actionWidth = CGFloat(actionSlotCount) * BlocksVisualTokens.Control.minimumHitTarget
            + CGFloat(actionSlotCount - 1) * BlocksVisualTokens.Spacing.xxs
            + BlocksVisualTokens.Spacing.xxs * 2
        let statusWidth = max(
            0,
            contentWidth - actionWidth - BlocksVisualTokens.Spacing.sm
        )
        let fullStatusWidth = statusIconWidth + fullTitleWidth + fullWarningWidth
        let compactStatusWidth = statusIconWidth + BlocksVisualTokens.Control.minimumHitTarget

        switch statusWidth {
        case fullStatusWidth...:
            return Metrics(statusMode: .full, statusWidth: fullStatusWidth)
        case compactStatusWidth...:
            return Metrics(statusMode: .compact, statusWidth: statusWidth)
        case statusIconWidth...:
            return Metrics(statusMode: .iconOnly, statusWidth: statusIconWidth)
        default:
            return Metrics(statusMode: .accessibilityOnly, statusWidth: 0)
        }
    }
}

private struct ScrollingScreenshotStatusSummary: View {
    let phaseIcon: String
    let phaseTitle: String
    let dimensionText: String
    let warningText: String?
    let layout: ScrollingScreenshotHUDLayout.Metrics

    var body: some View {
        Group {
            switch layout.statusMode {
            case .full:
                HStack(spacing: 0) {
                    phaseImage
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phaseTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(dimensionText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 128, alignment: .leading)

                    warningLabel
                        .frame(width: 152, alignment: .leading)
                }
            case .compact:
                HStack(spacing: BlocksVisualTokens.Spacing.xxs) {
                    phaseImage
                    Text(phaseTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if warningText != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            case .iconOnly:
                phaseImage
            case .accessibilityOnly:
                EmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("screenshot.scrolling.accessibility.status"))
        .accessibilityValue(accessibilityValue)
    }

    private var phaseImage: some View {
        Image(systemName: phaseIcon)
            .frame(width: 24)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var warningLabel: some View {
        if let warningText {
            Label(warningText, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else {
            Color.clear
        }
    }

    private var accessibilityValue: String {
        [phaseTitle, dimensionText, warningText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

final class ScreenshotFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ScrollingScreenshotBorderView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
