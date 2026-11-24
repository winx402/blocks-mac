import AppKit
import BlocksCore
import Combine

/// Owns the status item for the lifetime of the process, not of a SwiftUI scene.
/// Visibility belongs to AppKit, including the persisted value and system edits.
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSMenuDelegate {
    private enum Command: Int {
        case screenshot, clipboard, translation, translationScreenshot
        case toggleRecorder, showMainWindow, settings, checkForUpdates, quit
    }

    @Published private(set) var isVisible = true
    private(set) var statusItem: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    weak var appModel: AppModel?

    func install(autosaveName: NSStatusItem.AutosaveName? = .init("BlocksMenuBar")) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Unlike a primary MenuBarExtra, removing this item must never quit.
        item.behavior = .removalAllowed
        if let autosaveName { item.autosaveName = autosaveName }
        let appName = L10n.string("app.name")
        item.button?.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: appName)
        item.button?.setAccessibilityLabel(appName)
        item.button?.toolTip = appName

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        publishVisibility()
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            // Read current state on the main actor, not a possibly superseded value.
            Task { @MainActor [weak self] in self?.publishVisibility() }
        }
    }

    func setVisible(_ visible: Bool) {
        guard let statusItem, statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
        publishVisibility()
    }

    func uninstall() {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func publishVisibility() {
        guard let value = statusItem?.isVisible, isVisible != value else { return }
        isVisible = value
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let appModel else { return }
        let paused = appModel.clipboardStore.recorderPaused
        let updates = AppUpdateCoordinator.shared

        add(.screenshot, L10n.string("menu.screenshot"), "camera.viewfinder", to: menu)
        add(.clipboard, L10n.string("menu.clipboard"), "doc.on.clipboard", to: menu)
        add(.translation, L10n.string("menu.translation"), "character.book.closed", to: menu)
        add(.translationScreenshot, L10n.string("translation.screenshot.menu"), "viewfinder", to: menu)
        menu.addItem(.separator())
        add(.toggleRecorder, L10n.string(paused ? "clipboard.resumeRecorder" : "menu.pauseRecorder"),
            paused ? "play.circle" : "pause.circle", to: menu)
        add(.showMainWindow, L10n.string("menu.recentStatus"), "list.bullet.rectangle", to: menu)
        add(.settings, L10n.string("menu.settings"), "gearshape", to: menu)
        menu.addItem(.separator())
        add(.checkForUpdates, updates.checkButtonTitle, "arrow.triangle.2.circlepath", to: menu).toolTip = updates.statusText
        add(.quit, L10n.string("menu.quit"), nil, to: menu, key: "q")
    }

    @discardableResult
    private func add(_ command: Command, _ title: String, _ symbol: String?, to menu: NSMenu,
                     key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: key)
        item.target = self
        item.tag = command.rawValue
        item.isEnabled = appModel.map { isEnabled(command, in: $0) } ?? false
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    private func isEnabled(_ command: Command, in appModel: AppModel) -> Bool {
        switch command {
        case .screenshot, .translationScreenshot: appModel.featureAvailabilityStore.screenshotEnabled
        case .clipboard, .toggleRecorder: appModel.featureAvailabilityStore.clipboardEnabled
        case .checkForUpdates: AppUpdateCoordinator.shared.canCheckForUpdates
        default: true
        }
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = Command(rawValue: sender.tag), let appModel,
              !AppTerminationCoordinator.shared.isQuitting, isEnabled(command, in: appModel) else { return }
        switch command {
        case .screenshot:
            Task { await appModel.startSmartScreenshot() }
        case .clipboard:
            appModel.showClipboardFloatingPanel { [weak appModel] in
                appModel?.showClipboardHistory()
                appModel?.openMainWindow(section: .clipboardSettings)
            }
        case .translation:
            appModel.showTranslationFloatingPanel()
        case .translationScreenshot:
            appModel.showTranslationScreenshot()
        case .toggleRecorder:
            appModel.toggleClipboardRecorderPaused()
            appModel.showClipboardHistory()
            appModel.openMainWindow(section: .clipboardSettings)
        case .showMainWindow:
            appModel.openMainWindow(section: appModel.selectedSection)
        case .settings:
            appModel.openMainWindow(section: .settings)
        case .checkForUpdates:
            AppUpdateCoordinator.shared.checkForUpdates()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
