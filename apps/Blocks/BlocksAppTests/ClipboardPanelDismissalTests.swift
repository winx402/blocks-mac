import AppKit
import SwiftUI
import XCTest
@testable import Blocks
@testable import BlocksCore

@MainActor
final class ClipboardPanelDismissalTests: XCTestCase {
    func testExternalDismissHidesBeforeTeardownAndDoesNotAnimateRemoval() {
        var window: NSWindow?
        var phases: [BlocksMotionPhase] = []
        let coordinator = BlocksFloatingPanelPresentationCoordinator { panel, _, alpha, _, phase, completion in
            window = panel
            phases.append(phase)
            panel.alphaValue = alpha
            completion()
        }
        let presenter = ClipboardHistoryPanelPresenter(presentationCoordinator: coordinator)
        var closeCount = 0
        var beganHidden = false
        present(presenter, onCloseStarted: { _, _ in beganHidden = window?.isVisible == false }, onClosed: { _ in closeCount += 1 })
        defer { presenter.forceCloseForRuntimeDisable() }
        XCTAssertTrue(presenter.isVisible)
        presenter.dismissForExternalInteraction()
        XCTAssertTrue(beganHidden)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(presenter.invocationID)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(phases, [.insertion])
        XCTAssertEqual(coordinator.phase, .hidden)
        let events = ClipboardInteractionTrace.shared.snapshot().events
        let tail = events.filter { [.externalDismiss, .closeRequested, .closeStarted, .orderedOut, .closeCompleted].contains($0.stage) }.suffix(5)
        XCTAssertEqual(tail.map(\.stage), [.externalDismiss, .closeRequested, .closeStarted, .orderedOut, .closeCompleted])
        XCTAssertEqual(tail.first(where: { $0.stage == .orderedOut })?.visible, false)
    }

    func testExternalDismissDoesNotClosePinnedPanel() {
        let coordinator = BlocksFloatingPanelPresentationCoordinator { panel, _, alpha, _, _, completion in
            panel.alphaValue = alpha
            completion()
        }
        let presenter = ClipboardHistoryPanelPresenter(presentationCoordinator: coordinator)
        present(presenter)
        defer { presenter.forceCloseForRuntimeDisable() }
        presenter.pinStateForTesting.setPinned(true)
        presenter.dismissForExternalInteraction()
        XCTAssertTrue(presenter.isVisible)
    }

    func testExternalDismissInvalidatesPendingInsertionCompletion() {
        var insertion: (@MainActor () -> Void)?
        let coordinator = BlocksFloatingPanelPresentationCoordinator { _, _, _, _, _, completion in insertion = completion }
        let presenter = ClipboardHistoryPanelPresenter(presentationCoordinator: coordinator)
        present(presenter)
        defer { presenter.forceCloseForRuntimeDisable() }
        XCTAssertEqual(coordinator.phase, .presenting)
        presenter.dismissForExternalInteraction()
        insertion?()
        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(presenter.invocationID)
        XCTAssertEqual(coordinator.phase, .hidden)
    }

    func testCompactButtonTintIsOptIn() {
        let ordinary = BlocksCompactIconButton(systemImage: "star", label: "Favorite", action: {})
        let favorite = BlocksCompactIconButton(systemImage: "star", label: "Favorite", emphasis: .accent,
                                              tint: Color.yellow.opacity(0.95), action: {})
        XCTAssertNil(ordinary.tint)
        XCTAssertEqual(favorite.tint, Color.yellow.opacity(0.95))
    }

    private func present(_ presenter: ClipboardHistoryPanelPresenter,
                         onCloseStarted: @escaping (UUID?, UUID?) -> Void = { _, _ in },
                         onClosed: @escaping (UUID?) -> Void = { _ in }) {
        let store = ClipboardStore(repository: nil)
        _ = presenter.present(
            clipboardStore: store,
            notificationState: BlocksNotificationPresentationState(),
            actions: ClipboardPanelActions(pasteQuickRecord: { _ in }, pasteRecord: { _ in },
                translateRecord: { _ in }, copyRecordAsPlainText: { _ in },
                deleteHistoryItem: { _ in true }, toggleFavorite: { _ in }, setTagFilter: { _ in }),
            position: .bottom,
            invocationContext: ClipboardPanelInvocationContext(id: UUID(), source: .floatingPanel,
                openedAt: Date(), targetContext: nil),
            openMainWindow: {}, openSettings: {}, onCloseStarted: onCloseStarted, onClosed: onClosed)
    }
}
