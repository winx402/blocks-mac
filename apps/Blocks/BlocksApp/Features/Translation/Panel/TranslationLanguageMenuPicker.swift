import AppKit
import OSLog
import SwiftUI

/// No source text, menu titles or selected languages are recorded here.
@MainActor
enum TranslationPanelInteractionDiagnostics {
    private static let logger = Logger(subsystem: "app.blocks.app", category: "TranslationPanelInteraction")

    static func record(_ phase: String, isActive: Bool) {
        let event = NSApp.currentEvent
        let type = event.map { Int($0.type.rawValue) } ?? -1
        let keyCode = event.flatMap {
            $0.type == .keyDown || $0.type == .keyUp ? Int($0.keyCode) : nil
        } ?? -1
        logger.debug("phase=\(phase, privacy: .public) active=\(isActive, privacy: .public) eventType=\(type, privacy: .public) keyCode=\(keyCode, privacy: .public)")
    }
}

struct TranslationLanguageMenuEntry: Equatable {
    let title: String
    /// Nil denotes a nonselectable section heading, not automatic detection.
    let value: String?
}

/// Protection spans the complete native tracking event, including the action
/// delivered as the menu closes. A newer menu or teardown invalidates releases
/// queued by an earlier tracking session.
@MainActor
final class TranslationLanguageMenuTracking {
    var onChange: (Bool) -> Void
    private(set) var isActive = false
    private(set) var isMenuOpen = false
    private var generation: UInt = 0
    private let scheduleRelease: (@escaping () -> Void) -> Void

    init(
        onChange: @escaping (Bool) -> Void,
        scheduleRelease: @escaping (@escaping () -> Void) -> Void = { release in
            // DispatchQueue.main can run inside NSMenu's nested tracking
            // loop. Default-mode work waits until native event tracking and
            // the closing Escape's responder-chain delivery have unwound.
            RunLoop.main.perform(inModes: [.default]) { release() }
        }
    ) {
        self.onChange = onChange
        self.scheduleRelease = scheduleRelease
    }

    func begin() {
        generation &+= 1
        guard !isActive else { return }
        isActive = true
        onChange(true)
        TranslationPanelInteractionDiagnostics.record("menu-protection-began", isActive: true)
    }

    func menuWillOpen() {
        isMenuOpen = true
        begin()
        TranslationPanelInteractionDiagnostics.record("native-menu-open", isActive: isActive)
    }

    func mouseInteractionDidReturn() {
        TranslationPanelInteractionDiagnostics.record("native-mouse-return", isActive: isActive)
        // NSPopUpButton may return while its native menu is still showing.
        // In that case menuDidClose is the sole owner of the release.
        guard !isMenuOpen else { return }
        endAfterCurrentEvent()
    }

    func menuDidClose() {
        isMenuOpen = false
        TranslationPanelInteractionDiagnostics.record("native-menu-close", isActive: isActive)
        endAfterCurrentEvent()
    }

    func endAfterCurrentEvent() {
        let closingGeneration = generation
        scheduleRelease { [weak self] in
            guard let self, generation == closingGeneration else { return }
            reset()
        }
    }

    func reset() {
        generation &+= 1
        isMenuOpen = false
        guard isActive else { return }
        isActive = false
        onChange(false)
        TranslationPanelInteractionDiagnostics.record("menu-protection-ended", isActive: false)
    }
}

/// SwiftUI retains language values; this bridge owns only the native menu and
/// its lifecycle, which Picker(.menu) does not expose for dismissal protection.
struct TranslationLanguageMenuPicker: NSViewRepresentable {
    let title: String
    let identifier: String
    let entries: [TranslationLanguageMenuEntry]
    let selection: String
    let onSelection: (String) -> Void
    let onTrackingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onTrackingChange: onTrackingChange)
    }

    func makeNSView(context: Context) -> FirstMousePopUpButton {
        let button = FirstMousePopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(button)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: FirstMousePopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelection = onSelection
        coordinator.onTrackingChange = onTrackingChange
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        coordinator.update(entries: entries, selection: selection)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FirstMousePopUpButton,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 24)
    }

    static func dismantleNSView(_ button: FirstMousePopUpButton, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class FirstMousePopUpButton: NSPopUpButton {
        var tracking: TranslationLanguageMenuTracking?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { true }

        func prepareForMenuInteraction() {
            tracking?.begin()
            window?.makeKey()
        }

        override func mouseDown(with event: NSEvent) {
            prepareForMenuInteraction()
            defer { tracking?.mouseInteractionDidReturn() }
            super.mouseDown(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var onSelection: (String) -> Void
        var onTrackingChange: (Bool) -> Void
        lazy var tracking = TranslationLanguageMenuTracking { [weak self] active in
            guard let self else { return }
            if !active { applyPendingUpdates() }
            onTrackingChange(active)
        }
        private weak var button: FirstMousePopUpButton?
        private var entries: [TranslationLanguageMenuEntry] = []
        private var pendingEntries: [TranslationLanguageMenuEntry] = []
        private var pendingSelection = ""

        init(
            onSelection: @escaping (String) -> Void,
            onTrackingChange: @escaping (Bool) -> Void
        ) {
            self.onSelection = onSelection
            self.onTrackingChange = onTrackingChange
        }

        func attach(_ button: FirstMousePopUpButton) {
            self.button = button
            button.alignment = .center
            button.tracking = tracking
            button.target = self
            button.action = #selector(selectLanguage(_:))
        }

        func update(entries: [TranslationLanguageMenuEntry], selection: String) {
            pendingEntries = entries
            pendingSelection = selection
            applyPendingUpdates()
        }

        private func applyPendingUpdates() {
            guard let button, !tracking.isActive else { return }
            let entries = pendingEntries
            if self.entries != entries {
                self.entries = entries
                let menu = NSMenu()
                menu.autoenablesItems = false
                for entry in entries {
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.representedObject = entry.value
                    item.isEnabled = entry.value != nil
                    menu.addItem(item)
                }
                menu.delegate = self
                button.menu = menu
            }
            if let index = entries.firstIndex(where: { $0.value == pendingSelection }) {
                button.selectItem(at: index)
            }
        }

        @objc func selectLanguage(_ sender: NSPopUpButton) {
            guard sender === button,
                  let value = sender.selectedItem?.representedObject as? String else { return }
            onSelection(value)
        }

        func menuWillOpen(_ menu: NSMenu) {
            tracking.menuWillOpen()
        }

        func menuDidClose(_ menu: NSMenu) {
            tracking.menuDidClose()
        }

        func detach() {
            button?.menu?.cancelTracking()
            button?.menu?.delegate = nil
            button?.target = nil
            button?.action = nil
            button?.tracking = nil
            button = nil
            tracking.reset()
        }
    }
}
