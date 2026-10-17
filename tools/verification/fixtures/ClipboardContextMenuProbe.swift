import AppKit
import SwiftUI

enum ClipboardPanelActivationSource: String {
    case bottomCard, sideRow, keyboard, contextMenu, toolbar
}

@MainActor final class PointerProbeState: ObservableObject {
    @Published var counts: [String: Int] = [:]
    func record(_ event: String) {
        counts[event, default: 0] += 1
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeMarker") as? String,
              let data = try? JSONSerialization.data(withJSONObject: counts, options: .sortedKeys) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

struct PointerProbeView: View {
    @ObservedObject var state: PointerProbeState
    var body: some View {
        VStack(spacing: 16) {
            Text("Synthetic clipboard item — no user data")
                .font(.headline)
            VStack(alignment: .leading) {
                Text("Right-click or Control-click here")
                Text("Single-click selects; double-click increments a synthetic paste counter.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                ClipboardRecordPointerSurface(
                    panelSessionID: nil, recordID: "synthetic-only", source: .bottomCard,
                    onPointerPress: { state.record("press") },
                    onSingleClick: { state.record("select") },
                    onDoubleClick: { state.record("paste") })
            }
            .overlay(alignment: .topTrailing) {
                Button { state.record("favorite") } label: { Image(systemName: "star") }
                    .buttonStyle(.borderless).padding(12)
                    .accessibilityLabel("Synthetic favorite")
            }
            .contextMenu {
                Button("Synthetic Paste") { state.record("menu-paste") }
                Button("Synthetic Favorite") { state.record("menu-favorite") }
                Divider()
                Button("Synthetic Delete", role: .destructive) { state.record("menu-delete") }
            }
            Text("Events: " + state.counts.keys.sorted().map { "\($0)=\(state.counts[$0]!)" }.joined(separator: ", "))
                .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 480, height: 280)
    }
}

@MainActor final class PointerProbeDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private let state = PointerProbeState()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Clipboard Pointer Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clipboard Pointer Probe"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PointerProbeView(state: state))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        state.record("opened")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main enum PointerProbeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PointerProbeDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
