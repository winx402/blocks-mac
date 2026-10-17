import AppKit
import BlocksCore
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class TranslationPanelInteractionTests: XCTestCase {
    func testSourceSizingMeasuresWrappingAndBoundsLongPastedText() {
        let short = TranslationPanelSourceLayout.preferredEditorHeight(
            text: "", width: 496, source: .manual
        )
        let pasted = TranslationPanelSourceLayout.preferredEditorHeight(
            text: String(repeating: "A line of pasted text\n", count: 50),
            width: 496, source: .manual
        )
        XCTAssertEqual(short, 96)
        XCTAssertEqual(pasted, 160)
        let wrappingText = String(repeating: "Multiple words wrap naturally. ", count: 12)
        let wide = TranslationPanelSourceLayout.preferredEditorHeight(
            text: wrappingText, width: 900, source: .manual
        )
        let narrow = TranslationPanelSourceLayout.preferredEditorHeight(
            text: wrappingText, width: 200, source: .manual
        )
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(
            TranslationPanelSourceLayout.preferredEditorHeight(
                text: "OCR text", width: 496, source: .screenshotOCR
            ), 112
        )
    }

    func testMinimumWindowKeepsLanguageBarAndResultsSpace() {
        let availableHeight = TranslationPanelMetrics.minimumHeight
            - TranslationPanelMetrics.headerTotalHeight - 1
        let editorHeight = TranslationPanelSourceLayout.boundedEditorHeight(
            preferredHeight: 160, availableHeight: availableHeight, source: .manual
        )
        let fixedHeight = editorHeight
            + TranslationPanelSourceLayout.sourceHeaderHeight(for: .manual)
            + TranslationPanelSourceLayout.sourceEditorSpacing
            + TranslationPanelSourceLayout.sourceVerticalInset * 2
            + TranslationPanelSourceLayout.languageBarHeight + 2
        XCTAssertGreaterThanOrEqual(editorHeight, 96)
        XCTAssertGreaterThanOrEqual(
            availableHeight - fixedHeight,
            TranslationPanelSourceLayout.minimumResultsHeight - 0.01
        )
    }

    func testRenderedSourceGrowsOnTextChangesButNotResultStreaming() {
        let state = TranslationLayoutFixtureState()
        let capture = TranslationEditorHeightCapture()
        let host = NSHostingView(rootView: TranslationLayoutFixture(state: state, capture: capture))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 345),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }
        layout()
        XCTAssertEqual(capture.height, 96)
        state.sourceText = String(repeating: "Editable source line\n", count: 12)
        layout()
        let expandedHeight = capture.height
        XCTAssertGreaterThan(expandedHeight, 96)
        XCTAssertLessThanOrEqual(expandedHeight, 160)
        for chunk in 1 ... 5 {
            state.resultLines = chunk * 20
            layout()
            XCTAssertEqual(capture.height, expandedHeight)
            XCTAssertEqual(window.frame.height, 345)
        }
    }

    func testNativeLanguageMenuAcceptsFirstMouseAndProtectsBeforeActivation() {
        let button = TranslationLanguageMenuPicker.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        var transitions: [Bool] = []
        let coordinator = TranslationLanguageMenuPicker.Coordinator(
            onSelection: { _ in }, onTrackingChange: { transitions.append($0) }
        )
        coordinator.attach(button)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertTrue(button.needsPanelToBecomeKey)
        XCTAssertEqual(button.alignment, .center)
        XCTAssertEqual(button.cell?.alignment, .center)
        // This is the production pre-super.mouseDown seam, not a synthetic
        // keyboard shortcut. Actual menu tracking still needs mouse acceptance.
        button.prepareForMenuInteraction()
        XCTAssertEqual(transitions, [true])
        coordinator.detach()
        XCTAssertEqual(transitions, [true, false])
    }

    func testNativeMenuSelectionUsesTargetActionWithoutEditingSourceOrFocus() {
        let (model, _, suite) = makeModel(sourceLanguage: nil)
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let originalSource = model.sourceText
        let originalFocusRequest = model.sourceFocusRequest
        let button = TranslationLanguageMenuPicker.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        let coordinator = TranslationLanguageMenuPicker.Coordinator(
            onSelection: { model.updateSourceLanguage(TranslationLanguageTag($0)) },
            onTrackingChange: { _ in }
        )
        coordinator.attach(button)
        coordinator.update(entries: [
            .init(title: "Automatic", value: ""),
            .init(title: "Common", value: nil),
            .init(title: "English", value: "en"),
            .init(title: "Japanese", value: "ja"),
        ], selection: "")
        XCTAssertFalse(button.item(at: 1)!.isEnabled)
        button.selectItem(at: 3)
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(model.sourceLanguage, TranslationLanguageTag("ja"))
        XCTAssertEqual(model.sourceText, originalSource)
        XCTAssertEqual(model.sourceFocusRequest, originalFocusRequest)
        coordinator.detach()
    }

    func testMenuTrackingDefersReleaseAndRejectsStaleReleaseAfterReopening() {
        var releases: [() -> Void] = []
        var transitions: [Bool] = []
        let tracking = TranslationLanguageMenuTracking(
            onChange: { transitions.append($0) },
            scheduleRelease: { releases.append($0) }
        )
        tracking.begin()
        tracking.endAfterCurrentEvent()
        XCTAssertTrue(tracking.isActive)
        tracking.begin()
        releases.removeFirst()()
        XCTAssertTrue(tracking.isActive)
        tracking.endAfterCurrentEvent()
        releases.removeFirst()()
        XCTAssertFalse(tracking.isActive)
        XCTAssertEqual(transitions, [true, false])
    }

    func testMouseDownReturnCannotReleaseAnOpenNativeMenu() {
        var releases: [() -> Void] = []
        let tracking = TranslationLanguageMenuTracking(
            onChange: { _ in }, scheduleRelease: { releases.append($0) }
        )
        tracking.begin()
        tracking.menuWillOpen()
        tracking.mouseInteractionDidReturn()
        XCTAssertTrue(tracking.isActive)
        XCTAssertTrue(tracking.isMenuOpen)
        XCTAssertTrue(releases.isEmpty, "An asynchronously open popup must retain Esc protection")
        tracking.menuDidClose()
        XCTAssertTrue(tracking.isActive, "Closing Escape still owns the current native event")
        XCTAssertEqual(releases.count, 1)
        releases.removeFirst()()
        XCTAssertFalse(tracking.isActive)
    }

    func testClosingMenuEscapeCannotDismissPanelUntilNativeTrackingUnwinds() {
        let panel = NSPanel(
            contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 160),
            styleMask: [.nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        var dismissCount = 0
        let controller = TranslationPanelDismissalController(
            onDismiss: { dismissCount += 1 },
            escapeHotKeyLifecycle: TranslationMenuEscapeHotKeyStub()
        )
        controller.attach(panel: panel)
        controller.update(dismissalState(directInteraction: false))
        let tracking = TranslationLanguageMenuTracking { active in
            controller.update(self.dismissalState(directInteraction: active))
        }
        defer {
            tracking.reset()
            controller.shutdown()
            panel.orderOut(nil)
            panel.close()
        }
        tracking.menuWillOpen()
        tracking.mouseInteractionDidReturn()
        tracking.menuDidClose()
        // NSMenu can deliver cancelOperation while unwinding its nested loop.
        // A main-queue async release is not an event-tracking boundary.
        controller.requestEscapeDismissIfAllowed(origin: "test-menu-cancel")
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        controller.requestEscapeDismissIfAllowed(origin: "test-menu-cancel-tail")
        XCTAssertTrue(tracking.isActive)
        XCTAssertEqual(dismissCount, 0)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertFalse(tracking.isActive)
        controller.requestDismissIfAllowed()
        XCTAssertEqual(dismissCount, 1, "A subsequent outside click must still dismiss normally")
    }

    func testMenuTeardownInvalidatesQueuedReleaseAndRestoresDismissal() {
        var releases: [() -> Void] = []
        var transitions: [Bool] = []
        let tracking = TranslationLanguageMenuTracking(
            onChange: { transitions.append($0) },
            scheduleRelease: { releases.append($0) }
        )
        tracking.begin()
        XCTAssertFalse(dismissalState(directInteraction: tracking.isActive).allowsImplicitDismissal)
        tracking.endAfterCurrentEvent()
        tracking.reset()
        releases.removeFirst()()
        XCTAssertEqual(transitions, [true, false])
        XCTAssertTrue(dismissalState(directInteraction: tracking.isActive).allowsImplicitDismissal)
    }

    func testMenuCloseAppliesPendingModelSelectionAndDetachRemovesActions() async {
        let button = TranslationLanguageMenuPicker.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        let coordinator = TranslationLanguageMenuPicker.Coordinator(
            onSelection: { _ in }, onTrackingChange: { _ in }
        )
        coordinator.attach(button)
        let entries: [TranslationLanguageMenuEntry] = [
            .init(title: "English", value: "en"),
            .init(title: "Japanese", value: "ja"),
        ]
        coordinator.update(entries: entries, selection: "en")
        coordinator.menuWillOpen(button.menu!)
        coordinator.update(entries: entries, selection: "ja")
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "en")
        coordinator.menuDidClose(button.menu!)
        await waitUntil { !coordinator.tracking.isActive }
        XCTAssertFalse(coordinator.tracking.isActive)
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "ja")
        coordinator.detach()
        XCTAssertNil(button.target)
        XCTAssertNil(button.action)
        XCTAssertNil(button.menu?.delegate)
    }

    func testAutomaticSourceSwapExplainsWithoutTranslationOrDirectionChanges() async {
        let (model, adapter, suite) = makeModel(sourceLanguage: nil)
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let previousTarget = model.targetLanguage
        model.swapLanguagesAndRun()
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertNil(model.sourceLanguage)
        XCTAssertEqual(model.targetLanguage, previousTarget)
        XCTAssertEqual(model.operationError, L10n.string("translation.panel.swapLanguages.automaticSourceHint"))
        XCTAssertEqual(adapter.requestCount, 0)
        XCTAssertNil(model.snapshot)
    }

    func testExplicitSourceSwapStartsExactlyOneImmediateRun() async {
        let (model, adapter, suite) = makeModel(sourceLanguage: TranslationLanguageTag("en")!)
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.swapLanguagesAndRun()
        await waitUntil { adapter.requestCount > 0 }
        XCTAssertEqual(model.sourceLanguage, TranslationLanguageTag("zh-Hans"))
        XCTAssertEqual(model.targetLanguage, TranslationLanguageTag("en"))
        XCTAssertEqual(adapter.requestCount, 1)
    }

    func testAutomaticSourceSwapAlsoExplainsAfterDetectedResult() async {
        let (model, adapter, suite) = makeModel(sourceLanguage: nil)
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.runImmediately()
        await waitUntil { model.snapshot?.successfulResults.isEmpty == false }
        XCTAssertNotNil(model.snapshot?.direction.source)
        XCTAssertNil(model.sourceLanguage)
        let previousSession = model.snapshot?.id
        let previousRequestCount = adapter.requestCount
        model.swapLanguagesAndRun()
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertEqual(model.snapshot?.id, previousSession)
        XCTAssertEqual(adapter.requestCount, previousRequestCount)
        XCTAssertEqual(model.operationError, L10n.string("translation.panel.swapLanguages.automaticSourceHint"))
        XCTAssertNil(model.sourceLanguage)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dismissalState(directInteraction: Bool) -> TranslationPanelDismissalState {
        TranslationPanelDismissalState(
            isVisible: true, isPinned: false, isSuspended: false,
            isSystemInteractionActive: false, isDirectInteractionActive: directInteraction
        )
    }

    private func makeModel(sourceLanguage: TranslationLanguageTag?) -> (
        TranslationPanelSessionModel, TranslationInteractionAdapter, String
    ) {
        let suite = "TranslationPanelInteractionTests.\(UUID().uuidString)"
        let store = TranslationStore(defaults: UserDefaults(suiteName: suite)!)
        let adapter = TranslationInteractionAdapter()
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        return (TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "Source text remains unchanged"),
            direction: TranslationLanguageDirection(
                source: sourceLanguage, target: TranslationLanguageTag("zh-Hans")!
            ), translationStore: store
        ), adapter, suite)
    }
}

@MainActor
private final class TranslationInteractionAdapter: TranslationServiceAdapter {
    let descriptor = TranslationServiceDescriptor(
        id: "plugin:translation-interaction-fixture", displayName: "Interaction Fixture", kind: .plugin
    )
    private(set) var requestCount = 0
    func translate(_ request: TranslationServiceRequest) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed("Fixture result"))
            continuation.finish()
        }
    }
}

@MainActor
private final class TranslationMenuEscapeHotKeyStub: TranslationPanelEscapeHotKeyLifecycle {
    func start() -> Bool { true }
    func stop() {}
}

@MainActor
private final class TranslationLayoutFixtureState: ObservableObject {
    @Published var sourceText = ""
    @Published var resultLines = 1
}

private final class TranslationEditorHeightCapture {
    var height: CGFloat = 0
}

private struct TranslationLayoutFixture: View {
    @ObservedObject var state: TranslationLayoutFixtureState
    let capture: TranslationEditorHeightCapture
    var body: some View {
        TranslationPanelContentLayout(
            inputSource: .manual, sourceText: state.sourceText,
            sourceContent: { height in
                let _ = capture.height = height
                VStack(spacing: TranslationPanelSourceLayout.sourceEditorSpacing) {
                    Color.clear.frame(height: TranslationPanelSourceLayout.sourceHeaderHeight(for: .manual))
                    TranslationSourceTextEditor(text: state.sourceText, focusRequest: 0, onTextChange: { state.sourceText = $0 })
                        .frame(height: height)
                }
            }, languageContent: { Color.clear },
            resultsContent: { Text(String(repeating: "Streamed result\n", count: state.resultLines)) }
        )
    }
}
