import AppKit
import Combine
import SwiftUI

enum BlocksNotificationLayout {
    static let defaultCardWidth: CGFloat = 300
    static let minimumCardWidth: CGFloat = 260
    static let maximumCardWidth: CGFloat = 360
    static let horizontalScreenInset: CGFloat = 12
    static let anchoredGap: CGFloat = 8

    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        let usableWidth = max(1, availableWidth - horizontalScreenInset * 2)
        return min(defaultCardWidth, usableWidth)
    }

    static func editorTopInset(
        avoiding frame: CGRect,
        defaultTop: CGFloat = 12,
        estimatedNotificationHeight: CGFloat = 104
    ) -> CGFloat {
        guard !frame.isNull,
              !frame.isEmpty,
              frame.minY < defaultTop + estimatedNotificationHeight else {
            return defaultTop
        }
        return frame.maxY + 6
    }

    static func screenFrame(
        size: CGSize,
        visibleFrame: CGRect,
        avoiding frames: [CGRect]
    ) -> CGRect {
        var result = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        for frame in frames where result.intersects(frame) {
            result.origin.y = min(result.origin.y, frame.minY - size.height - 6)
        }
        result.origin.x = min(
            max(result.origin.x, visibleFrame.minX + horizontalScreenInset),
            visibleFrame.maxX - size.width - horizontalScreenInset
        )
        result.origin.y = max(visibleFrame.minY + horizontalScreenInset, result.origin.y)
        return result
    }

    static func anchoredFrame(
        size requestedSize: CGSize,
        anchorFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        let safeFrame = visibleFrame.insetBy(
            dx: horizontalScreenInset,
            dy: horizontalScreenInset
        )
        guard !safeFrame.isNull,
              !safeFrame.isEmpty else {
            return nil
        }
        let availableWidth = safeFrame.width
        let availableHeight = safeFrame.height
        let size = CGSize(
            width: min(max(1, requestedSize.width), availableWidth),
            height: min(max(1, requestedSize.height), availableHeight)
        )
        let horizontalOrigin = min(
            max(
                anchorFrame.midX - size.width / 2,
                safeFrame.minX
            ),
            safeFrame.maxX - size.width
        )
        let aboveOrigin = anchorFrame.maxY + anchoredGap
        let belowOrigin =
            anchorFrame.minY - anchoredGap - size.height
        let maximumOrigin =
            safeFrame.maxY - size.height
        let minimumOrigin =
            safeFrame.minY

        let verticalCenteredOrigin = min(
            max(
                anchorFrame.midY - size.height / 2,
                minimumOrigin
            ),
            maximumOrigin
        )
        let rightOrigin = anchorFrame.maxX + anchoredGap
        let leftOrigin = anchorFrame.minX - anchoredGap - size.width
        let candidates = [
            CGPoint(x: horizontalOrigin, y: aboveOrigin),
            CGPoint(x: horizontalOrigin, y: belowOrigin),
            CGPoint(x: rightOrigin, y: verticalCenteredOrigin),
            CGPoint(x: leftOrigin, y: verticalCenteredOrigin),
        ]

        return candidates
            .map { CGRect(origin: $0, size: size) }
            .first { safeFrame.contains($0) && !$0.intersects(anchorFrame) }
    }
}

enum BlocksNotificationLevel: Int, CaseIterable {
    case info = 0
    case success = 1
    case warning = 2
    case error = 3

    var systemImage: String {
        switch self {
        case .info:
            "info.circle.fill"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info:
            .accentColor
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    var defaultDismissPolicy: BlocksNotificationDismissPolicy {
        switch self {
        case .success:
            .automatic(after: 2.5)
        case .info:
            .automatic(after: 4)
        case .warning, .error:
            .manual
        }
    }

    var isPersistent: Bool {
        switch self {
        case .warning, .error:
            true
        case .info, .success:
            false
        }
    }
}

enum BlocksNotificationDismissPolicy: Equatable {
    case automatic(after: TimeInterval)
    case manual
}

enum BlocksNotificationPresentationStyle: Equatable {
    case standard
    case compactConfirmation
}

struct BlocksNotificationAction {
    let title: String
    let accessibilityHint: String?
    let handler: @MainActor () -> Void

    init(
        title: String,
        accessibilityHint: String? = nil,
        handler: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.accessibilityHint = accessibilityHint
        self.handler = handler
    }
}

struct BlocksNotificationDescriptor: Identifiable {
    let id: UUID
    let level: BlocksNotificationLevel
    let title: String
    let detail: String?
    let showsIndeterminateProgress: Bool
    let dismissPolicy: BlocksNotificationDismissPolicy
    let deduplicationKey: String?
    let action: BlocksNotificationAction?
    let presentationStyle: BlocksNotificationPresentationStyle
    let systemImage: String?

    init(
        id: UUID = UUID(),
        level: BlocksNotificationLevel,
        title: String,
        detail: String? = nil,
        showsIndeterminateProgress: Bool = false,
        dismissPolicy: BlocksNotificationDismissPolicy? = nil,
        deduplicationKey: String? = nil,
        action: BlocksNotificationAction? = nil,
        presentationStyle: BlocksNotificationPresentationStyle = .standard,
        systemImage: String? = nil
    ) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.showsIndeterminateProgress = showsIndeterminateProgress
        self.dismissPolicy = action == nil
            ? (
                dismissPolicy
                    ?? (
                        presentationStyle == .compactConfirmation
                            ? .automatic(after: 2)
                            : level.defaultDismissPolicy
                    )
            )
            : .manual
        self.deduplicationKey = deduplicationKey
        self.action = action
        self.presentationStyle = presentationStyle
        self.systemImage = systemImage
    }
}

struct BlocksPresentedNotification: Identifiable {
    let id: UUID
    var descriptor: BlocksNotificationDescriptor
    var occurrenceCount: Int
    var latestPresentedAt: Date
}

@MainActor
final class BlocksNotificationPresentationState: ObservableObject {
    @Published private(set) var current: BlocksPresentedNotification?
    @Published private(set) var isAutoDismissPaused = false
    @Published private(set) var presentationRevision = 0

    private var autoDismissTask: Task<Void, Never>?
    private var autoDismissDeadline: Date?
    private var remainingAutoDismissDuration: TimeInterval?
    private var isHostVisible: Bool

    init(isHostVisible: Bool = true) {
        self.isHostVisible = isHostVisible
    }

    func present(_ descriptor: BlocksNotificationDescriptor, now: Date = Date()) {
        guard isHostVisible || descriptor.level.isPersistent else {
            return
        }

        if var current,
           let key = descriptor.deduplicationKey,
           key == current.descriptor.deduplicationKey {
            if descriptor.level.rawValue >= current.descriptor.level.rawValue {
                current.descriptor = descriptor
            }
            current.occurrenceCount += 1
            current.latestPresentedAt = now
            self.current = current
            scheduleAutomaticDismiss(for: current.descriptor.dismissPolicy)
            return
        }

        if let current,
           current.descriptor.level.isPersistent,
           descriptor.level.rawValue < current.descriptor.level.rawValue {
            return
        }

        cancelAutomaticDismiss()
        current = BlocksPresentedNotification(
            id: descriptor.id,
            descriptor: descriptor,
            occurrenceCount: 1,
            latestPresentedAt: now
        )
        presentationRevision &+= 1
        scheduleAutomaticDismiss(for: descriptor.dismissPolicy)
    }

    func dismiss() {
        cancelAutomaticDismiss()
        current = nil
        isAutoDismissPaused = false
        presentationRevision &+= 1
    }

    func dismiss(deduplicationKey: String) {
        guard current?.descriptor.deduplicationKey
            == deduplicationKey else {
            return
        }
        dismiss()
    }

    func setHostVisible(_ visible: Bool) {
        isHostVisible = visible
        guard !visible else {
            resumeAutomaticDismissIfNeeded()
            return
        }
        guard let current else {
            return
        }
        if current.descriptor.level.isPersistent {
            pauseAutomaticDismiss()
        } else {
            dismiss()
        }
    }

    func setAutoDismissPaused(_ paused: Bool) {
        guard paused != isAutoDismissPaused else {
            return
        }
        isAutoDismissPaused = paused
        if paused {
            pauseAutomaticDismiss()
        } else {
            resumeAutomaticDismissIfNeeded()
        }
    }

    func shutdown() {
        cancelAutomaticDismiss()
        current = nil
        isAutoDismissPaused = false
    }

    private func scheduleAutomaticDismiss(for policy: BlocksNotificationDismissPolicy) {
        cancelAutomaticDismiss()
        guard case let .automatic(after: duration) = policy,
              duration > 0,
              !isAutoDismissPaused,
              isHostVisible else {
            return
        }
        remainingAutoDismissDuration = duration
        startAutomaticDismiss(after: duration)
    }

    private func startAutomaticDismiss(after duration: TimeInterval) {
        autoDismissDeadline = Date().addingTimeInterval(duration)
        autoDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.dismiss()
        }
    }

    private func pauseAutomaticDismiss() {
        guard let deadline = autoDismissDeadline else {
            return
        }
        remainingAutoDismissDuration = max(0, deadline.timeIntervalSinceNow)
        autoDismissTask?.cancel()
        autoDismissTask = nil
        autoDismissDeadline = nil
    }

    private func resumeAutomaticDismissIfNeeded() {
        guard !isAutoDismissPaused,
              isHostVisible,
              current != nil,
              let duration = remainingAutoDismissDuration,
              duration > 0 else {
            return
        }
        startAutomaticDismiss(after: duration)
    }

    private func cancelAutomaticDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        autoDismissDeadline = nil
        remainingAutoDismissDuration = nil
    }
}

struct BlocksNotificationCard: View {
    @ObservedObject var state: BlocksNotificationPresentationState
    let presentation: BlocksPresentedNotification
    let preferredWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: FocusedControl?
    @State private var isHovered = false

    private enum FocusedControl: Hashable {
        case action
        case close
    }

    init(
        state: BlocksNotificationPresentationState,
        presentation: BlocksPresentedNotification,
        preferredWidth: CGFloat = 300
    ) {
        self.state = state
        self.presentation = presentation
        self.preferredWidth = min(
            BlocksNotificationLayout.maximumCardWidth,
            max(1, preferredWidth)
        )
    }

    var body: some View {
        notificationContent
            .contentShape(
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.section,
                    style: .continuous
                )
            )
            .onHover { hovered in
                isHovered = hovered
                updateAutoDismissPause()
            }
            .onChange(of: focusedControl) { _, _ in
                updateAutoDismissPause()
            }
            .onDisappear {
                state.setAutoDismissPaused(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity)
            )
    }

    @ViewBuilder
    private var notificationContent: some View {
        if presentation.descriptor.presentationStyle
            == .compactConfirmation {
            HStack(spacing: 7) {
                Image(
                    systemName:
                        presentation.descriptor.systemImage
                        ?? presentation.descriptor.level.systemImage
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(presentation.descriptor.level.color)

                Text(presentation.descriptor.title)
                    .blocksFont(size: 13, weight: .semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: preferredWidth, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .blocksSurface(
                .hud,
                cornerRadius: BlocksVisualTokens.CornerRadius.section
            )
        } else {
            standardContent
        }
    }

    private var standardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(presentation.descriptor.level.color)
                .frame(width: 3)
                .padding(.vertical, 1)

            Group {
                if presentation.descriptor.showsIndeterminateProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(
                        systemName:
                            presentation.descriptor.systemImage
                            ?? presentation.descriptor.level.systemImage
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        presentation.descriptor.level.color
                    )
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(presentation.descriptor.title)
                        .blocksFont(size: 13, weight: .semibold)
                        .lineLimit(2)
                        .help(presentation.descriptor.title)

                    if presentation.occurrenceCount > 1 {
                        Text("×\(presentation.occurrenceCount)")
                            .blocksFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                L10n.format(
                                    "notification.occurrenceCount",
                                    Int64(presentation.occurrenceCount)
                                )
                            )
                    }
                }

                if let detail = presentation.descriptor.detail, !detail.isEmpty {
                    Text(detail)
                        .blocksFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .help(detail)
                }

                if let action = presentation.descriptor.action {
                    Button(action.title) {
                        action.handler()
                    }
                    .buttonStyle(.plain)
                    .blocksFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .focused($focusedControl, equals: .action)
                    .accessibilityHint(action.accessibilityHint ?? "")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focused($focusedControl, equals: .close)
            .help(L10n.string("common.close"))
            .accessibilityLabel(L10n.string("common.close"))
        }
        .padding(12)
        .frame(width: preferredWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .blocksSurface(
            .hud,
            cornerRadius: BlocksVisualTokens.CornerRadius.section
        )
    }

    private var accessibilitySummary: String {
        [presentation.descriptor.title, presentation.descriptor.detail]
            .compactMap { $0 }
            .joined(separator: "。")
    }

    private func updateAutoDismissPause() {
        state.setAutoDismissPaused(isHovered || focusedControl != nil)
    }
}

struct BlocksNotificationHost: View {
    @ObservedObject var state: BlocksNotificationPresentationState
    let preferredWidth: CGFloat

    init(
        state: BlocksNotificationPresentationState,
        preferredWidth: CGFloat = 300
    ) {
        self.state = state
        self.preferredWidth = preferredWidth
    }

    var body: some View {
        Group {
            if let presentation = state.current {
                BlocksNotificationCard(
                    state: state,
                    presentation: presentation,
                    preferredWidth: preferredWidth
                )
                .id(presentation.id)
            }
        }
        .blocksAnimation(.reveal, value: state.presentationRevision)
    }
}

@MainActor
protocol BlocksNotificationPanelPresenting: AnyObject {
    func present(
        _ descriptor: BlocksNotificationDescriptor,
        on screen: NSScreen?,
        avoiding frames: [CGRect]
    )
    func dismiss()
    func shutdown()
}

@MainActor
final class BlocksNotificationPanelPresenter: BlocksNotificationPanelPresenting {
    private let state = BlocksNotificationPresentationState()
    private let level: NSWindow.Level
    private var panel: NSPanel?
    private var currentObservation: AnyCancellable?

    init(level: NSWindow.Level = .floating) {
        self.level = level
        currentObservation = state.$current
            .sink { [weak self] current in
                guard current == nil else { return }
                self?.panel?.orderOut(nil)
            }
    }

    var panelForTesting: NSPanel? { panel }

    func present(
        _ descriptor: BlocksNotificationDescriptor,
        on screen: NSScreen?,
        avoiding frames: [CGRect] = []
    ) {
        let targetScreen = screen ?? NSScreen.main
        guard let targetScreen else {
            return
        }
        let width = BlocksNotificationLayout.cardWidth(
            availableWidth: targetScreen.visibleFrame.width
        )
        let panel = panel ?? makePanel(width: width)
        self.panel = panel
        state.setHostVisible(true)
        state.present(descriptor)
        guard let presented = state.current else { return }
        // Standard cards always contain a close button, even without a retry
        // action. Only a control-free compact confirmation is click-through.
        panel.ignoresMouseEvents = presented.descriptor.presentationStyle == .compactConfirmation
            && presented.descriptor.action == nil
        let contentView = makeContentView(width: width)
        contentView.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: max(1, contentView.fittingSize.height))
        panel.contentView = contentView
        panel.setFrame(
            BlocksNotificationLayout.screenFrame(
                size: size,
                visibleFrame: targetScreen.visibleFrame,
                avoiding: frames
            ),
            display: false
        )
        panel.orderFrontRegardless()
    }

    func dismiss() {
        state.dismiss()
        panel?.orderOut(nil)
    }

    func shutdown() {
        currentObservation?.cancel()
        currentObservation = nil
        state.shutdown()
        panel?.close()
        panel = nil
    }

    private func makePanel(width: CGFloat) -> NSPanel {
        let panel = BlocksNonactivatingNotificationPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        BlocksFloatingPanelWindowRole.passiveHUD.apply(to: panel)
        panel.level = level
        panel.contentView = makeContentView(width: width)
        return panel
    }

    private func makeContentView(width: CGFloat) -> NSView {
        NSHostingView(rootView:
            BlocksNotificationHost(
                state: state,
                preferredWidth: width
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .blocksDefaultFont()
        )
    }

}

/// Presents a shared notification card next to an existing window without
/// changing that window's content layout or responder chain.
@MainActor
final class BlocksAnchoredNotificationPanelPresenter {
    let state: BlocksNotificationPresentationState

    private weak var anchorWindow: NSWindow?
    private var panel: BlocksNonactivatingNotificationPanel?
    private var presentationObservation: AnyCancellable?
    private var parentCloseObservation: NSObjectProtocol?

    convenience init() {
        self.init(
            state: BlocksNotificationPresentationState()
        )
    }

    init(state: BlocksNotificationPresentationState) {
        self.state = state
        presentationObservation = state.$presentationRevision
            .sink { [weak self] _ in
                self?.synchronizePresentation()
            }
    }

    func attach(to window: NSWindow) {
        if anchorWindow !== window {
            detachFromAnchor()
            anchorWindow = window
            parentCloseObservation =
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.detach()
                    }
                }
        }
        synchronizePresentation()
    }

    func reposition() {
        guard state.current != nil else { return }
        positionPanel()
    }

    func detach() {
        detachFromAnchor()
        panel?.close()
        panel = nil
    }

    func shutdown() {
        state.shutdown()
        detach()
    }

    private func synchronizePresentation() {
        guard state.current != nil,
              let anchorWindow,
              anchorWindow.isVisible else {
            panel?.orderOut(nil)
            return
        }
        guard let layout = notificationLayout(for: anchorWindow) else {
            hidePanel()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = layout.contentView
        if panel.parent !== anchorWindow {
            panel.parent?.removeChildWindow(panel)
            anchorWindow.addChildWindow(panel, ordered: .above)
        }
        panel.setFrame(layout.frame, display: true)
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let anchorWindow,
              let panel,
              let layout = notificationLayout(for: anchorWindow) else {
            hidePanel()
            return
        }
        panel.contentView = layout.contentView
        panel.setFrame(layout.frame, display: true)
    }

    private func notificationLayout(for anchorWindow: NSWindow)
        -> (contentView: NSView, frame: CGRect)?
    {
        guard
              let screen =
                anchorWindow.screen
                    ?? NSScreen.screens.first(where: {
                        $0.frame.intersects(anchorWindow.frame)
                    })
                    ?? NSScreen.main else {
            return nil
        }
        let availableCardWidth = BlocksNotificationLayout.cardWidth(
            availableWidth: screen.visibleFrame.width
        )
        let contentView = makeContentView(
            preferredWidth: availableCardWidth
        )
        contentView.layoutSubtreeIfNeeded()
        let measuredSize =
            contentView.fittingSize
        let isCompact = state.current?.descriptor.presentationStyle
            == .compactConfirmation
        let size = CGSize(
            width:
                isCompact
                    ? min(
                        availableCardWidth,
                        min(260, max(120, measuredSize.width))
                    )
                    : min(
                        availableCardWidth,
                        max(
                            BlocksNotificationLayout.minimumCardWidth,
                            measuredSize.width
                        )
                    ),
            height: max(1, measuredSize.height)
        )
        guard let frame = BlocksNotificationLayout.anchoredFrame(
            size: size,
            anchorFrame: anchorWindow.frame,
            visibleFrame: screen.visibleFrame
        ) else {
            return nil
        }
        return (
            contentView: contentView,
            frame: frame
        )
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> BlocksNonactivatingNotificationPanel {
        let panel = BlocksNonactivatingNotificationPanel(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width:
                        BlocksNotificationLayout.defaultCardWidth,
                    height: 104
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        BlocksFloatingPanelWindowRole.passiveHUD.apply(to: panel)
        panel.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
        ]
        panel.contentView = makeContentView(
            preferredWidth: BlocksNotificationLayout.defaultCardWidth
        )
        return panel
    }

    private func makeContentView(preferredWidth: CGFloat) -> NSView {
        NSHostingView(
            rootView:
                BlocksNotificationHost(
                    state: state,
                    preferredWidth: preferredWidth
                )
                .fixedSize(horizontal: false, vertical: true)
                .blocksDefaultFont()
        )
    }

    private func detachFromAnchor() {
        if let parentCloseObservation {
            NotificationCenter.default.removeObserver(
                parentCloseObservation
            )
        }
        parentCloseObservation = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        anchorWindow = nil
    }

    // Internal testing accessor; test bundles may be compiled with Release settings.
    var panelForTesting: NSPanel? {
        panel
    }
}

final class BlocksNonactivatingNotificationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
