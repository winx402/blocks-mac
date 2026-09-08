import Foundation
import XCTest
@testable import Blocks

@MainActor
final class MainWindowPresentationCoordinatorTests: XCTestCase {
    func testPresentsOnceWhenActivationPrecedesMainWindowAttachment() {
        var isActive = false
        let window = MainWindowPresentationWindowSpy()
        let coordinator = MainWindowPresentationCoordinator(
            isUnitTestHost: { false },
            isApplicationActive: { isActive }
        )

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())
        XCTAssertEqual(window.presentationCount, 0)

        isActive = true
        coordinator.applicationDidBecomeActive()
        XCTAssertEqual(window.presentationCount, 0)

        coordinator.applicationDidFinishRestoringWindows()
        XCTAssertEqual(window.presentationCount, 1)

        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())
        coordinator.applicationDidFinishRestoringWindows()
        XCTAssertEqual(window.presentationCount, 1)
    }

    func testPresentsWhenRestoredMainWindowAttachesAfterActivation() {
        let window = MainWindowPresentationWindowSpy()
        let coordinator = MainWindowPresentationCoordinator(
            isUnitTestHost: { false },
            isApplicationActive: { true }
        )

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())
        coordinator.applicationDidFinishRestoringWindows()

        XCTAssertEqual(window.presentationCount, 1)
    }

    func testPresentsWhenRestorationCompletesBeforeMainWindowAttachment() {
        let window = MainWindowPresentationWindowSpy()
        let coordinator = MainWindowPresentationCoordinator(
            isUnitTestHost: { false },
            isApplicationActive: { true }
        )

        coordinator.applicationDidFinishRestoringWindows()
        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())

        XCTAssertEqual(window.presentationCount, 1)
    }

    func testPresentsAfterRestorationHidesAWindowThatWasTemporarilyVisible() {
        let window = MainWindowPresentationWindowSpy(state: .visible)
        let coordinator = MainWindowPresentationCoordinator(
            isUnitTestHost: { false },
            isApplicationActive: { true }
        )

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())
        XCTAssertEqual(window.presentationCount, 0)

        window.state = .hidden
        coordinator.applicationDidFinishRestoringWindows()
        XCTAssertEqual(window.presentationCount, 1)

        coordinator.applicationDidFinishRestoringWindows()
        XCTAssertEqual(window.presentationCount, 1)
    }

    func testInitialRecoveryPreservesVisibleAndMiniaturizedWindows() {
        for state in [
            MainWindowPresentationWindowSpy.State.visible,
            .miniaturized,
        ] {
            let window = MainWindowPresentationWindowSpy(state: state)
            let coordinator = MainWindowPresentationCoordinator(
                isUnitTestHost: { false },
                isApplicationActive: { true }
            )

            coordinator.applicationDidFinishLaunching()
            coordinator.applicationDidBecomeActive()
            coordinator.attachMainWindow(window.makeAttachment())
            coordinator.applicationDidFinishRestoringWindows()

            XCTAssertEqual(window.presentationCount, 0)
        }
    }

    func testUnitTestHostNeverPresentsItsAttachedWindow() {
        let window = MainWindowPresentationWindowSpy()
        let coordinator = MainWindowPresentationCoordinator(
            isUnitTestHost: { true },
            isApplicationActive: { true }
        )

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidBecomeActive()
        coordinator.attachMainWindow(window.makeAttachment())
        coordinator.applicationDidFinishRestoringWindows()

        XCTAssertEqual(window.presentationCount, 0)
    }
}

private final class MainWindowPresentationWindowSpy {
    enum State {
        case hidden
        case visible
        case miniaturized
    }

    private let identityObject = NSObject()
    var presentationCount = 0
    var state: State

    init(state: State = .hidden) {
        self.state = state
    }

    func makeAttachment() -> MainWindowPresentationCoordinator.Attachment {
        MainWindowPresentationCoordinator.Attachment(
            identity: ObjectIdentifier(identityObject),
            isAttached: { true },
            isVisible: { self.state == .visible },
            isMiniaturized: { self.state == .miniaturized },
            present: { self.presentationCount += 1 }
        )
    }
}
