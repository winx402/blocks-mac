import AppKit

typealias TranslationPanelEscapeHotKeyLifecycle = BlocksGlobalEscapeHotKeyLifecycle

@MainActor
protocol TranslationPanelKeyMonitorRegistering: AnyObject {
    func addLocalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    func addGlobalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> Void
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
private final class AppKitTranslationPanelKeyMonitorRegistrar:
    TranslationPanelKeyMonitorRegistering
{
    func addLocalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func addGlobalKeyDownMonitor(
        _ handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

struct TranslationPanelDismissalState: Equatable {
    let isVisible: Bool
    let isPinned: Bool
    let isSuspended: Bool
    let isSystemInteractionActive: Bool
    let isDirectInteractionActive: Bool

    var allowsImplicitDismissal: Bool {
        isVisible
            && !isPinned
            && !isSuspended
            && !isSystemInteractionActive
            && !isDirectInteractionActive
    }
}

/// Owns every implicit dismissal mechanism for one translation panel. The
/// presenter supplies state; this controller alone owns AppKit event monitors
/// and the temporary Carbon Escape registration.
@MainActor
final class TranslationPanelDismissalController {
    private let dismissMonitor = FloatingPanelDismissMonitor()
    private let onDismiss: @MainActor () -> Void
    private weak var panel: NSPanel?
    private var state = TranslationPanelDismissalState(
        isVisible: false,
        isPinned: false,
        isSuspended: false,
        isSystemInteractionActive: false,
        isDirectInteractionActive: false
    )
    private var isDismissMonitorActive = false
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var visibleSessionIdentifier: UInt = 0
    private var hasRequestedDismissalForVisibleSession = false
    private let escapeHotKeyLifecycle: TranslationPanelEscapeHotKeyLifecycle?
    private let keyMonitorRegistrar: TranslationPanelKeyMonitorRegistering
    private lazy var escapeHotKeyController =
        BlocksGlobalEscapeHotKeyController { [weak self] in
            self?.requestDismissIfAllowed()
        }

    init(
        onDismiss: @escaping @MainActor () -> Void,
        escapeHotKeyLifecycle: TranslationPanelEscapeHotKeyLifecycle? = nil,
        keyMonitorRegistrar: TranslationPanelKeyMonitorRegistering? = nil
    ) {
        self.onDismiss = onDismiss
        self.escapeHotKeyLifecycle = escapeHotKeyLifecycle
        self.keyMonitorRegistrar = keyMonitorRegistrar
            ?? AppKitTranslationPanelKeyMonitorRegistrar()
    }

    func attach(panel: NSPanel) {
        resetVisibleSessionDismissal()
        if self.panel != nil {
            stopAllMonitoring()
        }
        self.panel = panel
        applyState()
    }

    func update(_ state: TranslationPanelDismissalState) {
        guard self.state != state else { return }
        let wasVisible = self.state.isVisible
        self.state = state
        if !state.isVisible || (!wasVisible && state.isVisible) {
            resetVisibleSessionDismissal()
        }
        applyState()
    }

    func shutdown() {
        state = TranslationPanelDismissalState(
            isVisible: false,
            isPinned: false,
            isSuspended: true,
            isSystemInteractionActive: false,
            isDirectInteractionActive: false
        )
        resetVisibleSessionDismissal()
        stopAllMonitoring()
        panel = nil
    }

    static func isUnmodifiedEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else {
            return false
        }
        let actionModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        return actionModifiers.isEmpty
    }

    private func applyState() {
        guard state.allowsImplicitDismissal,
              let panel,
              panel.isVisible else {
            stopAllMonitoring()
            return
        }

        if !isDismissMonitorActive {
            dismissMonitor.start(panel: panel) { [weak self] in
                self?.requestDismissIfAllowed()
            }
            isDismissMonitorActive = true
        }

        if startEscapeHotKey() {
            stopFallbackEscapeMonitoring()
        } else {
            startFallbackEscapeMonitoring()
        }
    }

    func requestDismissIfAllowed() {
        requestDismissIfAllowed(for: visibleSessionIdentifier)
    }

    private func requestDismissIfAllowed(for sessionIdentifier: UInt) {
        guard sessionIdentifier == visibleSessionIdentifier,
              state.allowsImplicitDismissal,
              panel?.isVisible == true else {
            return
        }
        guard !hasRequestedDismissalForVisibleSession else { return }
        hasRequestedDismissalForVisibleSession = true
        onDismiss()
    }

    private func startEscapeHotKey() -> Bool {
        escapeHotKeyLifecycle?.start() ?? escapeHotKeyController.start()
    }

    private func startFallbackEscapeMonitoring() {
        guard localEscapeMonitor == nil,
              globalEscapeMonitor == nil else { return }
        let sessionIdentifier = visibleSessionIdentifier
        localEscapeMonitor = keyMonitorRegistrar.addLocalKeyDownMonitor {
            [weak self] event in
            guard Self.isUnmodifiedEscape(event) else { return event }
            Task { @MainActor [weak self] in
                self?.requestDismissIfAllowed(for: sessionIdentifier)
            }
            return event
        }
        globalEscapeMonitor = keyMonitorRegistrar.addGlobalKeyDownMonitor {
            [weak self] event in
            guard Self.isUnmodifiedEscape(event) else { return }
            Task { @MainActor [weak self] in
                self?.requestDismissIfAllowed(for: sessionIdentifier)
            }
        }
    }

    private func resetVisibleSessionDismissal() {
        visibleSessionIdentifier &+= 1
        hasRequestedDismissalForVisibleSession = false
    }

    private func stopFallbackEscapeMonitoring() {
        if let localEscapeMonitor {
            keyMonitorRegistrar.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        guard let globalEscapeMonitor else { return }
        keyMonitorRegistrar.removeMonitor(globalEscapeMonitor)
        self.globalEscapeMonitor = nil
    }

    private func stopAllMonitoring() {
        if isDismissMonitorActive {
            dismissMonitor.stop()
            isDismissMonitorActive = false
        }
        if let escapeHotKeyLifecycle {
            escapeHotKeyLifecycle.stop()
        } else {
            escapeHotKeyController.stop()
        }
        stopFallbackEscapeMonitoring()
    }
}
