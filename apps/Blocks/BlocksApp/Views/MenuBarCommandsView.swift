import BlocksCore
import SwiftUI

struct MenuBarCommandsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var clipboardStore: ClipboardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            Task { await appModel.startSmartScreenshot() }
        } label: {
            Label(L10n.string("menu.screenshot"), systemImage: "camera.viewfinder")
        }
        .disabled(!appModel.featureAvailabilityStore.screenshotEnabled)

        Button {
            appModel.showClipboardFloatingPanel {
                appModel.showClipboardHistory()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Label(L10n.string("menu.clipboard"), systemImage: "doc.on.clipboard")
        }
        .disabled(!appModel.featureAvailabilityStore.clipboardEnabled)

        Button {
            appModel.showTranslationFloatingPanel()
        } label: {
            Label(L10n.string("menu.translation"), systemImage: "character.book.closed")
        }

        Button {
            appModel.showTranslationScreenshot()
        } label: {
            Label(L10n.string("translation.screenshot.menu"), systemImage: "viewfinder")
        }
        .disabled(!appModel.featureAvailabilityStore.screenshotEnabled)

        Divider()

        Button {
            appModel.toggleClipboardRecorderPaused()
            appModel.showClipboardHistory()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label(
                clipboardStore.recorderPaused ? L10n.string("clipboard.resumeRecorder") : L10n.string("menu.pauseRecorder"),
                systemImage: clipboardStore.recorderPaused ? "play.circle" : "pause.circle"
            )
        }
        .disabled(!appModel.featureAvailabilityStore.clipboardEnabled)

        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label(L10n.string("menu.recentStatus"), systemImage: "list.bullet.rectangle")
        }

        Button {
            appModel.openMainWindow(section: .settings)
        } label: {
            Label(L10n.string("menu.settings"), systemImage: "gearshape")
        }

        Divider()

        Button(L10n.string("menu.quit")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
