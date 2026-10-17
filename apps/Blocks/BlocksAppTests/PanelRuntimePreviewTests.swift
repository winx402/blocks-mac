import AppKit
import BlocksCore
import SwiftUI
import XCTest
@testable import Blocks

/// Opt-in CUA acceptance harness. Production panels/views, isolated defaults,
/// in-memory records and synthetic translation only. No pasteboard/network/TCC.
@MainActor
final class PanelRuntimePreviewTests: XCTestCase {
    func testManualProductionPanels() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLOCKS_PANEL_PREVIEW"] == "1",
                          "Manual CUA acceptance only")
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides[TranslationPanelPresenter.userResizedPreferenceKey] = false
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        let preview = PanelAcceptanceController()
        preview.show()
        defer {
            preview.shutdown()
            UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
        }
        let deadline = ContinuousClock.now + .seconds(600)
        while !preview.finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(preview.finished, "Finish acceptance with the dashboard button")
        print("PANEL_ACCEPTANCE_COUNTS \(preview.events.counts)")
    }
}

@MainActor
private final class PanelAcceptanceEvents: ObservableObject {
    @Published var counts: [String: Int] = [:]
    func record(_ key: String) { counts[key, default: 0] += 1 }
}

@MainActor
private final class PanelAcceptanceController: NSObject {
    private var dashboard: NSWindow?
    private var clipboardPanel: NSPanel?
    private let clipboardDismissal = FloatingPanelDismissMonitor()
    private var translation: TranslationPanelPresenter?
    private var suites: [String] = []
    let events = PanelAcceptanceEvents()
    private(set) var finished = false

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 400, width: 280, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Panel Acceptance — Synthetic Only"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        for (tag, title) in [(0, "Translation: empty"), (1, "Translation: multiline"),
                             (2, "Translation: OCR"), (3, "Translation: non-key"),
                             (4, "Translation: minimum size"), (5, "Clipboard: bottom cards"),
                             (6, "Clipboard: left rows"), (7, "Clipboard: right rows"),
                             (8, "Finish acceptance")] {
            let button = NSButton(title: title, target: self, action: #selector(handlePreviewAction(_:)))
            button.tag = tag
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let root = window.contentView {
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
        }
        window.makeKeyAndOrderFront(nil)
        dashboard = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handlePreviewAction(_ sender: NSButton) {
        switch sender.tag {
        case 0...3: showTranslation(mode: sender.tag)
        case 4:
            translation?.panelForTesting?.setContentSize(NSSize(width: 420, height: 282))
            translation?.focus()
        case 5...7: showClipboard(mode: sender.tag)
        default: finished = true
        }
    }

    private func showTranslation(mode: Int) {
        translation?.forceClose()
        let suite = "PanelAcceptance.\(UUID().uuidString)"
        suites.append(suite)
        let store = TranslationStore(defaults: UserDefaults(suiteName: suite)!)
        let adapter = PanelAcceptanceTranslationAdapter()
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let text = mode == 0 || mode == 3 ? "" : String(repeating: "Synthetic editable source line.\n", count: 10)
        let source: TranslationInputSource = mode == 2 ? .screenshotOCR : (mode == 3 ? .selection : .manual)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: source, text: text),
            direction: TranslationLanguageDirection(source: nil, target: TranslationLanguageTag("en")!),
            translationStore: store)
        translation = TranslationPanelPresenter(model: model, actions: TranslationPanelActions(
            copyText: { [events] _ in events.record("copy-result"); return .failed },
            openFavorites: {}, openTranslationSettings: {}, retakeScreenshot: {}),
            onClose: { [weak self, events] _ in
                events.record("translation-closed")
                if mode == 2 || mode == 3 { self?.dashboard?.makeKeyAndOrderFront(nil) }
            })
        translation?.present()
        if mode == 2 || mode == 3 { dashboard?.orderOut(nil) }
    }

    private func showClipboard(mode: Int) {
        clipboardDismissal.stop()
        clipboardPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: mode == 7 ? 800 : 360, y: 120,
                                               width: mode == 5 ? 860 : 350,
                                               height: mode == 5 ? 250 : 420),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = mode == 5 ? "Production Clipboard Cards" : "Production Clipboard Rows"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PanelAcceptanceRecords(bottom: mode == 5, events: events))
        panel.makeKeyAndOrderFront(nil)
        clipboardPanel = panel
        clipboardDismissal.start(panel: panel) { [weak panel, events] in
            panel?.orderOut(nil)
            events.record("clipboard-dismissed")
        }
    }

    func shutdown() {
        clipboardDismissal.stop()
        clipboardPanel?.orderOut(nil)
        translation?.forceClose()
        dashboard?.orderOut(nil)
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
}

@MainActor
private final class PanelAcceptanceTranslationAdapter: TranslationServiceAdapter {
    let descriptor = TranslationServiceDescriptor(id: "plugin:panel-acceptance", displayName: "Synthetic Offline", kind: .plugin)
    func translate(_ request: TranslationServiceRequest) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed("Synthetic offline result. No network request was made."))
            continuation.finish()
        }
    }
}

private struct PanelAcceptanceRecords: View {
    let bottom: Bool
    @ObservedObject var events: PanelAcceptanceEvents
    @StateObject private var tags = ClipboardTagStore(repository: nil)
    var body: some View {
        VStack {
            if bottom {
                HStack(spacing: 12) { ForEach(0..<3) { card($0) } }
            } else {
                VStack(spacing: 12) { ForEach(0..<3) { row($0) } }
            }
            Text(events.counts.keys.sorted().map { "\($0)=\(events.counts[$0]!)" }.joined(separator: ", "))
                .font(.caption.monospaced()).lineLimit(3)
        }.padding(14)
    }
    private func record(_ index: Int) -> ClipboardRecorderRecord {
        ClipboardRecorderRecord(id: "acceptance-\(index)", createdAt: Date(), changeCount: index,
            kind: index == 1 ? .image : .text,
            formatSummary: ClipboardRecorderFormatSummary(itemCount: 1, types: [index == 1 ? "public.png" : "public.utf8-plain-text"]),
            sourceApp: nil, signatureSHA256: String(repeating: "a", count: 64),
            signatureSHA256_12: String(repeating: "a", count: 12), fixtureOwned: true,
            restorable: true, summary: "Synthetic item")
    }
    private func preview(_ index: Int) -> ClipboardRecordPreview {
        ClipboardRecordPreview(title: "Synthetic \(index)", body: "Synthetic clipboard content only.", badge: "Fixture",
                               image: index == 1 ? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) : nil)
    }
    private func card(_ i: Int) -> some View {
        ClipboardFloatingRecordCard(record: record(i), preview: preview(i), ocrState: .notRequired, tagStore: tags,
            isSelected: false, isFocused: false, cardWidth: 260, cardHeight: 180, bodyLineLimit: 4, itemFontSize: 13,
            quickPasteIndex: nil, accessibilitySortPriority: 0, panelSessionID: nil, pluginBadge: nil, pluginContextActions: nil,
            onPointerPress: { events.record("press") }, onSingleClick: { events.record("select") },
            onDoubleClick: { events.record("double-paste") }, onPaste: { events.record("menu-paste") },
            onTranslate: { events.record("translate") }, onRetryOCR: { events.record("ocr") },
            onToggleFavorite: { events.record("favorite"); Task { _ = await tags.toggleFavorite(recordID: record(i).id) } },
            onToggleTag: { _ in events.record("tag") }, onCreateTag: { _ in events.record("create-tag") },
            onCopyPlainText: { events.record("plain-copy") }, onRemove: { events.record("delete") })
    }
    private func row(_ i: Int) -> some View {
        ClipboardFloatingRecordRow(record: record(i), preview: preview(i), ocrState: .notRequired, tagStore: tags,
            isSelected: false, isFocused: false, rowHeight: 100, bodyLineLimit: 3, itemFontSize: 13,
            quickPasteIndex: nil, accessibilitySortPriority: 0, panelSessionID: nil, pluginBadge: nil, pluginContextActions: nil,
            onPointerPress: { events.record("press") }, onSingleClick: { events.record("select") },
            onDoubleClick: { events.record("double-paste") }, onPaste: { events.record("menu-paste") },
            onTranslate: { events.record("translate") }, onRetryOCR: { events.record("ocr") },
            onToggleFavorite: { events.record("favorite"); Task { _ = await tags.toggleFavorite(recordID: record(i).id) } },
            onToggleTag: { _ in events.record("tag") }, onCreateTag: { _ in events.record("create-tag") },
            onCopyPlainText: { events.record("plain-copy") }, onRemove: { events.record("delete") })
    }
}
