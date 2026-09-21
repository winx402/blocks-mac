import AppKit
import SwiftUI

struct SettingsNavigationCommandActions {
    let canGoBack: Bool
    let canGoForward: Bool
    let navigate: (Bool) -> Void
}

private struct SettingsNavigationActionsKey: FocusedValueKey {
    typealias Value = SettingsNavigationCommandActions
}

extension FocusedValues {
    var settingsNavigationActions: SettingsNavigationCommandActions? {
        get { self[SettingsNavigationActionsKey.self] }
        set { self[SettingsNavigationActionsKey.self] = newValue }
    }
}

/// Menu commands, rather than toolbar key equivalents, remain available while
/// a text field is first responder. They apply only to the focused settings scene.
struct SettingsNavigationCommands: Commands {
    @FocusedValue(\.settingsNavigationActions) private var actions

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(L10n.string("settings.navigation.back")) {
                actions?.navigate(true)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(actions?.canGoBack != true)

            Button(L10n.string("settings.navigation.forward")) {
                actions?.navigate(false)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(actions?.canGoForward != true)
        }
    }
}

struct SettingsHistoryMenuEntry {
    let index: Int
    let title: String
}

/// The AppKit boundary is limited to button events and contextual menus.
/// It never owns the history, observes global keys, or changes the window title.
struct SettingsNavigationButtonsBridge: NSViewRepresentable {
    let backEntries: [SettingsHistoryMenuEntry]
    let forwardEntries: [SettingsHistoryMenuEntry]
    let navigate: (Bool) -> Void
    let jump: (Int) -> Void

    func makeNSView(context: Context) -> SettingsHistoryButtonGroup {
        let stack = SettingsHistoryButtonGroup()
        stack.orientation = .horizontal
        stack.spacing = 2
        for backward in [true, false] {
            let button = SettingsHistoryButton(backward: backward)
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        return stack
    }

    func updateNSView(_ stack: SettingsHistoryButtonGroup, context: Context) {
        for case let button as SettingsHistoryButton in stack.arrangedSubviews {
            let backward = button.backward
            button.configure(
                entries: backward ? backEntries : forwardEntries,
                primaryAction: { navigate(backward) },
                jump: jump
            )
        }
    }

    static func dismantleNSView(_ stack: SettingsHistoryButtonGroup, coordinator: ()) {
        stack.stopMonitoringContextClicks()
    }
}

/// AppKit may ask the toolbar's hosted container for a contextual menu before
/// dispatching the button's mouse event. Resolve it at both levels.
final class SettingsHistoryButtonGroup: NSStackView {
    private var contextClickMonitor: Any?
    var isMonitoringContextClicks: Bool { contextClickMonitor != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringContextClicks()
        guard window != nil else { return }
        // NSToolbar can intercept a contextual click before dispatching it to
        // hosted views. Filter only this app's clicks inside these exact two
        // controls; unrelated windows, coordinates and event types pass through.
        contextClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let button = self?.historyButton(for: event), let menu = button.menu else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return nil
        }
    }

    func stopMonitoringContextClicks() {
        if let contextClickMonitor {
            NSEvent.removeMonitor(contextClickMonitor)
            self.contextClickMonitor = nil
        }
    }

    deinit {
        if let contextClickMonitor { NSEvent.removeMonitor(contextClickMonitor) }
    }

    func historyButton(for event: NSEvent) -> SettingsHistoryButton? {
        guard event.type == .rightMouseDown,
              let window, event.window === window,
              window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else { return nil }
        return arrangedSubviews.compactMap { $0 as? SettingsHistoryButton }.first { button in
            button.isEnabled
                && !button.isHiddenOrHasHiddenAncestor
                && button.menu?.items.isEmpty == false
                && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        historyButton(for: event)?.menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class SettingsHistoryButton: NSButton {
    let backward: Bool
    private var primaryAction: () -> Void = {}
    private var jump: (Int) -> Void = { _ in }

    init(backward: Bool) {
        self.backward = backward
        super.init(frame: .zero)
        let label = L10n.string(backward ? "settings.navigation.back" : "settings.navigation.forward")
        title = label
        image = NSImage(systemSymbolName: backward ? "chevron.left" : "chevron.right", accessibilityDescription: label)
        imagePosition = .imageOnly
        bezelStyle = .texturedRounded
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(performPrimaryAction)
        toolTip = L10n.string(backward ? "settings.navigation.backHistory" : "settings.navigation.forwardHistory")
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(backward ? "settings.navigation.back" : "settings.navigation.forward")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: toolTip ?? label) { [weak self] in
                self?.showHistoryMenu() ?? false
            }
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func configure(entries: [SettingsHistoryMenuEntry], primaryAction: @escaping () -> Void, jump: @escaping (Int) -> Void) {
        self.primaryAction = primaryAction
        self.jump = jump
        isEnabled = !entries.isEmpty
        let historyMenu = NSMenu(title: toolTip ?? title)
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(selectHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.index
            historyMenu.addItem(item)
        }
        menu = historyMenu
    }

    override func rightMouseDown(with event: NSEvent) {
        // Do not bubble to NSToolbar's customization menu, even when disabled.
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, let menu, !menu.items.isEmpty else { return nil }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func performPrimaryAction() {
        guard isEnabled else { return }
        primaryAction()
    }

    @objc private func selectHistoryEntry(_ sender: NSMenuItem) {
        guard isEnabled else { return }
        jump(sender.tag)
    }

    private func showHistoryMenu() -> Bool {
        guard isEnabled, let menu, !menu.items.isEmpty else { return false }
        return menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
}
