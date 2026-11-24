import BlocksScreenshotCore
import SwiftUI

/// Give every open request the same value so the WindowGroup can reuse the
/// settings window without making its closure an application termination.
enum MainWindowIdentity: String, Codable, Hashable {
    case singleton
}

@main
struct BlocksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    @StateObject private var appearanceStore = AppAppearanceStore()
    @StateObject private var appUpdates = AppUpdateCoordinator.shared

    var body: some Scene {
        WindowGroup(L10n.string("app.name"), id: "main", for: MainWindowIdentity.self) { _ in
            ContentView(
                initialSection:
                    verificationSettingsMode?.appSection
            )
                .environmentObject(appModel)
                .environmentObject(appModel.clipboardStore)
                .environmentObject(appModel.providerStore)
                .environmentObject(appModel.translationStore)
                .environmentObject(appModel.translationPluginManager)
                .environmentObject(appModel.pluginRuntimeCoordinator)
                .environmentObject(appModel.permissionStore)
                .environmentObject(appModel.screenshotStore)
                .environmentObject(appModel.shortcutStore)
                .environmentObject(appearanceStore)
                .frame(minWidth: 820, minHeight: 520)
                .blocksDefaultFont()
                .task { appUpdates.startIfPossible() }
                .background {
                    MainWindowAttachmentObserver(
                        onAttach: { window in
                            appDelegate.attachMainWindow(window)
                        },
                        onDetach: { window in
                            appDelegate.detachMainWindow(window)
                        }
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } defaultValue: { .singleton }
        .defaultSize(width: 980, height: 680)
        .commands {
            SettingsSidebarCommands()
            SettingsNavigationCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(appUpdates.checkButtonTitle) {
                    appUpdates.checkForUpdates()
                }
                .disabled(!appUpdates.canCheckForUpdates)
                .help(appUpdates.statusText)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.string("menu.settings")) {
                    appModel.openMainWindow(section: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(L10n.string("command.menu.blocks")) {
                Button(L10n.string("menu.startScreenshot")) {
                    Task { await appModel.startSmartScreenshot() }
                }
                .disabled(!appModel.featureAvailabilityStore.screenshotEnabled)

                Button(L10n.string("menu.clipboard")) {
                    appModel.showClipboardFloatingPanel {
                        appModel.openMainWindow(section: .clipboardSettings)
                    }
                }
                .disabled(!appModel.featureAvailabilityStore.clipboardEnabled)

                Divider()

                Button(L10n.string("menu.translation")) {
                    appModel.showTranslationFloatingPanel()
                }

                Button(L10n.string("translation.screenshot.menu")) {
                    appModel.showTranslationScreenshot()
                }
                .disabled(!appModel.featureAvailabilityStore.screenshotEnabled)
            }
        }
    }

    private var verificationSettingsMode: SettingsViewMode? {
        switch ProcessInfo.processInfo.environment["BLOCKS_SETTINGS_MODE"] {
        case "clipboard":
            .clipboard
        case "clipboardPrivacy":
            .clipboardPrivacy
        case "screenshot":
            .screenshot
        default:
            nil
        }
    }
}
