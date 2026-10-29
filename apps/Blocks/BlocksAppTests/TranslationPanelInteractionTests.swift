import AppKit
import BlocksCore
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class TranslationPanelInteractionTests: XCTestCase {
    func testSourceEditorRemainsTransparentAndEditableWithoutNativeFocusDecoration() throws {
        let host = NSHostingView(rootView: TranslationSourceTextEditor(
            text: "Synthetic editor text", focusRequest: 0, onTextChange: { _ in }
        ).frame(width: 400, height: 120))
        let window = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 120),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
            .first { $0.documentView is TranslationSourceNSTextView })
        let editor = try XCTUnwrap(scroll.documentView as? TranslationSourceNSTextView)
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertEqual(scroll.borderType, .noBorder)
        XCTAssertEqual(scroll.focusRingType, .none)
        XCTAssertFalse(editor.drawsBackground)
        XCTAssertEqual(editor.focusRingType, .none)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: 0, length: 9))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 9))
        editor.insertText("中文", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "中文 editor text")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(editor.string, "中文 editor text")
        XCTAssertFalse(editor.drawsBackground)
        XCTAssertEqual(editor.focusRingType, .none)
    }

    func testHelperSetupUsesItsDedicatedPanelAction() {
        var translationSettingsCount = 0
        var helperSetupCount = 0
        let actions = TranslationPanelActions(
            copyText: { _ in .failed }, openFavorites: {},
            openTranslationSettings: { translationSettingsCount += 1 },
            retakeScreenshot: {},
            openSelectionHelperSettings: { helperSetupCount += 1 }
        )
        actions.openSelectionHelperSettings()
        XCTAssertEqual(helperSetupCount, 1)
        XCTAssertEqual(translationSettingsCount, 0)
    }

    func testSelectionHelperFeedbackIsScopedAndRoutesTheExplicitSetupAction() throws {
        let helperFailures: [AXSelectionReadFailureReason] = [
            .agentUnavailable, .agentRequiresApproval, .accessibilityPermissionDenied,
            .agentInstallationConflict, .agentVersionOutdated, .agentConnectionFailed,
        ]
        var openedSetup = 0
        for (index, reason) in helperFailures.enumerated() {
            let descriptor = try XCTUnwrap(TranslationPanelSelectionFeedback.descriptor(
                for: reason, detail: "Synthetic helper detail", deduplicationKey: "selection-test",
                openSetup: { openedSetup += 1 }
            ))
            XCTAssertEqual(descriptor.level, .info)
            XCTAssertEqual(descriptor.dismissPolicy, .manual)
            XCTAssertNotEqual(descriptor.title, L10n.string("translation.panel.operationFailed"))
            XCTAssertTrue(try XCTUnwrap(descriptor.detail).contains("Synthetic helper detail"))
            let action = try XCTUnwrap(descriptor.action)
            XCTAssertEqual(action.title, L10n.string("translation.selection.status.completeSetup"))
            XCTAssertEqual(openedSetup, index)
            action.handler()
        }
        XCTAssertEqual(openedSetup, helperFailures.count)

        for reason in [AXSelectionReadFailureReason.timedOut, .targetExited, .selectionTooLarge, .passwordField] {
            let descriptor = try XCTUnwrap(TranslationPanelSelectionFeedback.descriptor(
                for: reason, detail: "Real operation failure", deduplicationKey: "selection-test",
                openSetup: { XCTFail("a real operation failure must not open helper setup") }
            ))
            XCTAssertEqual(descriptor.level, .warning)
            XCTAssertNil(descriptor.action)
        }
        XCTAssertNil(TranslationPanelSelectionFeedback.descriptor(
            for: .emptySelection, detail: "", deduplicationKey: "selection-test", openSetup: {}
        ))
    }

    func testFeedbackBudgetIncludesOnlyTheMeasuredIndependentRow() {
        XCTAssertEqual(TranslationPanelSourceLayout.feedbackReservedHeight(0), 0)
        XCTAssertEqual(TranslationPanelSourceLayout.feedbackReservedHeight(28),
                       28 + TranslationPanelSourceLayout.sourceEditorSpacing)
        let withoutFeedback = TranslationPanelSourceLayout.boundedEditorHeight(
            preferredHeight: 160, availableHeight: 260, source: .manual
        )
        let withFeedback = TranslationPanelSourceLayout.boundedEditorHeight(
            preferredHeight: 160, availableHeight: 260, source: .manual, feedbackHeight: 60
        )
        XCTAssertEqual(withoutFeedback - withFeedback,
                       TranslationPanelSourceLayout.feedbackReservedHeight(60), accuracy: 0.5)
        for source in [TranslationInputSource.manual, .screenshotOCR] {
            XCTAssertEqual(TranslationPanelSourceLayout.boundedEditorHeight(
                preferredHeight: TranslationPanelSourceLayout.expandedEditorHeight(for: source),
                availableHeight: 400, source: source, feedbackHeight: 28
            ), source == .screenshotOCR ? 112 : 96)
        }
    }

    func testFeedbackPresentationAndDismissalDoNotMutateSourceLanguageOrFocus() {
        let (model, _, suite) = makeModel(sourceLanguage: TranslationLanguageTag("en"))
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let source = model.sourceText
        let sourceLanguage = model.sourceLanguage
        let targetLanguage = model.targetLanguage
        let focusRequest = model.sourceFocusRequest
        let state = BlocksNotificationPresentationState()
        state.present(BlocksNotificationDescriptor(
            level: .info, title: "Selection helper not connected", dismissPolicy: .manual
        ))
        state.dismiss()
        XCTAssertEqual(model.sourceText, source)
        XCTAssertEqual(model.sourceLanguage, sourceLanguage)
        XCTAssertEqual(model.targetLanguage, targetLanguage)
        XCTAssertEqual(model.sourceFocusRequest, focusRequest)
    }

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

    func testHostedFeedbackWrapsInItsOwnBudgetAndPreservesEditorAtDefaultWidthAndNarrowWidth() {
        for width: CGFloat in [420, 520] {
            let state = TranslationLayoutFixtureState()
            let capture = TranslationEditorHeightCapture()
            state.sourceText = "Synthetic input retained while helper feedback changes."
            let originalText = state.sourceText
            let host = NSHostingView(rootView: TranslationLayoutFixture(state: state, capture: capture))
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: width, height: 420),
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
            XCTAssertEqual(state.feedbackHeight, 0)
            state.feedback.present(BlocksNotificationDescriptor(
                level: .info,
                title: "Selection helper not connected. Manual input remains available.",
                detail: String(repeating: "Synthetic setup help. ", count: 30),
                dismissPolicy: .manual
            ))
            state.showsFeedback = true
            layout()
            XCTAssertGreaterThanOrEqual(state.feedbackHeight, TranslationPanelMetrics.compactIconHitTarget)
            XCTAssertEqual(capture.height, 96)
            XCTAssertEqual(state.sourceText, originalText)
            let feedbackHeight = state.feedbackHeight
            state.resultLines = 100
            layout()
            XCTAssertEqual(state.feedbackHeight, feedbackHeight, accuracy: 0.5)
            XCTAssertEqual(capture.height, 96)
            state.feedback.dismiss()
            state.showsFeedback = false
            layout()
            XCTAssertEqual(capture.height, 96)
            XCTAssertEqual(state.sourceText, originalText)
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

    func testFeedbackHelpEscapeProtectsParentThroughClosingEventThenRestoresNextEscape() {
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
        let detailTracking = TranslationLanguageMenuTracking { active in
            controller.update(self.dismissalState(directInteraction: active))
        }
        defer {
            detailTracking.reset()
            controller.shutdown()
            panel.orderOut(nil)
            panel.close()
        }
        // The help button begins this same production tracking synchronously,
        // before SwiftUI changes native popover/key-window state.
        detailTracking.begin()
        controller.requestEscapeDismissIfAllowed(origin: "test-help-open-carbon-escape")
        XCTAssertEqual(dismissCount, 0)
        detailTracking.endAfterCurrentEvent()
        controller.requestEscapeDismissIfAllowed(origin: "test-help-closing-escape")
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        controller.requestEscapeDismissIfAllowed(origin: "test-help-closing-escape-tail")
        XCTAssertTrue(detailTracking.isActive)
        XCTAssertEqual(dismissCount, 0)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertFalse(detailTracking.isActive)
        controller.requestEscapeDismissIfAllowed(origin: "test-help-next-escape")
        XCTAssertEqual(dismissCount, 1)
    }

    func testPresenterFeedbackLifecycleDefersCloseRejectsStaleReleaseAndClearsOnTeardown() {
        let (model, _, suite) = makeModel(sourceLanguage: nil)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: TranslationPanelActions(
                copyText: { _ in .copiedAndRecorded }, openFavorites: {},
                openTranslationSettings: {}, retakeScreenshot: {}
            ), onClose: { _ in }
        )
        defer { presenter.forceClose() }
        // Exercise the exact callback wired from the help binding, notification
        // descriptor replacement and feedback view disappearance, without
        // creating a GUI popover or registering a real Carbon shortcut.
        presenter.feedbackDetailInteractionChanged(true)
        XCTAssertTrue(presenter.directInteractionActiveForTesting)
        presenter.feedbackDetailInteractionChanged(false)
        XCTAssertTrue(presenter.directInteractionActiveForTesting)
        presenter.feedbackDetailInteractionChanged(true)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertTrue(presenter.directInteractionActiveForTesting,
                      "a release from the previous help session must not end a quick reopen")
        presenter.feedbackDetailInteractionChanged(false)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertFalse(presenter.directInteractionActiveForTesting,
                       "replacement/disappearance must not leave dismissal permanently disabled")
        presenter.feedbackDetailInteractionChanged(true)
        presenter.feedbackDetailInteractionChanged(false)
        presenter.forceClose()
        XCTAssertFalse(presenter.directInteractionActiveForTesting)
        // A queued release and late disappearing-view callbacks must not
        // restore monitoring or recreate protection after parent teardown.
        presenter.feedbackDetailInteractionChanged(true)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertFalse(presenter.directInteractionActiveForTesting)
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
    @Published var showsFeedback = false
    @Published var feedbackHeight: CGFloat = 0
    let feedback = BlocksNotificationPresentationState()
}

private struct TranslationFixtureFeedbackHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
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
            feedbackHeight: state.showsFeedback ? state.feedbackHeight : 0,
            sourceContent: { height in
                let _ = capture.height = height
                VStack(spacing: TranslationPanelSourceLayout.sourceEditorSpacing) {
                    Color.clear.frame(height: TranslationPanelSourceLayout.sourceHeaderHeight(for: .manual))
                    if state.showsFeedback {
                        TranslationPanelInlineFeedbackView(state: state.feedback)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TranslationFixtureFeedbackHeightKey.self,
                                        value: geometry.size.height
                                    )
                                }
                            }
                            .onPreferenceChange(TranslationFixtureFeedbackHeightKey.self) {
                                state.feedbackHeight = $0
                            }
                    }
                    TranslationSourceTextEditor(text: state.sourceText, focusRequest: 0, onTextChange: { state.sourceText = $0 })
                        .frame(height: height)
                }
            }, languageContent: { Color.clear },
            resultsContent: { Text(String(repeating: "Streamed result\n", count: state.resultLines)) }
        )
    }
}
