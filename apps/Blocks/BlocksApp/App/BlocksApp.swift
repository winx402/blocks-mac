import BlocksScreenshotCore
import SwiftUI

@main
struct BlocksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    @StateObject private var appearanceStore = AppAppearanceStore()

    var body: some Scene {
        Window(L10n.string("app.name"), id: "main") {
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
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
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

        MenuBarExtra(L10n.string("app.name"), systemImage: "sparkles.rectangle.stack") {
            MenuBarCommandsView()
                .environmentObject(appModel)
                .environmentObject(appModel.clipboardStore)
                .environmentObject(appModel.translationStore)
                .environmentObject(appModel.translationPluginManager)
                .environmentObject(appModel.pluginRuntimeCoordinator)
                .environmentObject(appearanceStore)
                .blocksDefaultFont()
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
