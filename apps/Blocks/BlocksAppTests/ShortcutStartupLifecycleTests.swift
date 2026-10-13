import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Blocks

@MainActor
final class ShortcutStartupLifecycleTests: XCTestCase {
    func testBothModulesRegisterAtApplicationLaunchWithoutAWindow() async {
        let controller = makeController()
        let store = ShortcutStore(shortcutController: controller)
        store.setRuntimeAvailability(screenshotEnabled: true, clipboardEnabled: true)
        XCTAssertTrue(store.shortcutRegistrationResults.isEmpty)
        let visibleWindows = NSApp.windows.filter(\.isVisible).map(\.windowNumber)
        let wasActive = NSApp.isActive
        let launch = ShortcutApplicationLaunchCoordinator()
        launch.attach(store)

        launch.applicationDidFinishLaunching()
        await launch.initializationTask?.value

        XCTAssertTrue(store.shortcutRegistrationResult(for: .clipboardHistory)?.registered == true)
        XCTAssertTrue(store.shortcutRegistrationResult(for: .screenshotSmart)?.registered == true)
        XCTAssertEqual(store.registrationGeneration, 1)
        XCTAssertEqual(controller.systemRegistrationCallCountsForFixtures, .zero)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).map(\.windowNumber), visibleWindows)
        XCTAssertEqual(NSApp.isActive, wasActive)
    }

    func testStoreAttachedAfterLaunchUsesTheSameStoreAndRegistersOnce() async {
        let controller = makeController()
        let store = ShortcutStore(shortcutController: controller)
        let launch = ShortcutApplicationLaunchCoordinator()
        launch.applicationDidFinishLaunching()
        XCTAssertNil(launch.initializationTask)

        launch.attach(store)
        await launch.initializationTask?.value
        let generation = store.registrationGeneration
        launch.attach(store)
        launch.applicationDidFinishLaunching()
        await launch.initializationTask?.value

        XCTAssertEqual(generation, 1)
        XCTAssertEqual(store.registrationGeneration, generation)
        XCTAssertTrue(store.shortcutRegistrationResult(for: .clipboardHistory)?.registered == true)
    }

    func testEarlyNotRunningFailureRecoversWithOneModuleDisabled() async {
        for screenshotEnabled in [false, true] {
            var running = false
            let controller = makeController()
            controller.setApplicationRunningForFixtures { running }
            var waitCount = 0
            let store = ShortcutStore(shortcutController: controller, startupRetryWait: { _ in
                waitCount += 1
                running = true
            })
            store.setRuntimeAvailability(
                screenshotEnabled: screenshotEnabled,
                clipboardEnabled: !screenshotEnabled
            )
            XCTAssertFalse(store.shortcutRegistrationResults.isEmpty)
            XCTAssertTrue(store.shortcutRegistrationResults.allSatisfy { $0.failureReason == .applicationNotReady })

            await store.initializeShortcutsAfterApplicationLaunch()

            let screenshot = store.shortcutRegistrationResult(for: .screenshotSmart)
            let clipboard = store.shortcutRegistrationResult(for: .clipboardHistory)
            XCTAssertEqual(screenshot?.registered, screenshotEnabled)
            XCTAssertEqual(screenshot?.runtimeDisabled, !screenshotEnabled)
            XCTAssertEqual(clipboard?.registered, !screenshotEnabled)
            XCTAssertEqual(clipboard?.runtimeDisabled, screenshotEnabled)
            XCTAssertEqual(waitCount, 1)
            XCTAssertEqual(store.failedShortcutCount, 0)
            let generation = store.registrationGeneration
            await store.initializeShortcutsAfterApplicationLaunch()
            XCTAssertEqual(store.registrationGeneration, generation)
        }
    }

    func testReadinessRetryIsBounded() async {
        let controller = makeController()
        var readinessCheckCount = 0
        controller.setApplicationRunningForFixtures {
            readinessCheckCount += 1
            return false
        }
        var waitCount = 0
        let store = ShortcutStore(shortcutController: controller, startupRetryWait: { _ in
            waitCount += 1
        })

        await store.initializeShortcutsAfterApplicationLaunch()

        XCTAssertEqual(readinessCheckCount, 5)
        XCTAssertEqual(waitCount, 4)
        XCTAssertEqual(store.registrationGeneration, 5)
        XCTAssertTrue(store.shortcutRegistrationResults.allSatisfy { $0.failureReason == .applicationNotReady })
        XCTAssertEqual(store.registeredShortcutCount, 0)
    }

    func testCarbonErrorMatchingReadinessStatusDoesNotRetryOrClaimSuccess() async {
        var registrarCount = 0
        let controller = makeController(registrar: { _, _, _, _ in
            registrarCount += 1
            return (status: OSStatus(-9879), hasReference: false)
        })
        var waitCount = 0
        let store = ShortcutStore(shortcutController: controller, startupRetryWait: { _ in
            waitCount += 1
        })

        await store.initializeShortcutsAfterApplicationLaunch()
        let firstRegistrarCount = registrarCount
        await store.initializeShortcutsAfterApplicationLaunch()
        store.registerDefaultShortcuts()

        XCTAssertGreaterThan(firstRegistrarCount, 0)
        XCTAssertEqual(registrarCount, firstRegistrarCount)
        XCTAssertEqual(waitCount, 0)
        XCTAssertEqual(store.registrationGeneration, 1)
        let result = store.shortcutRegistrationResult(for: .clipboardHistory)
        XCTAssertEqual(result?.osStatus, OSStatus(-9879))
        XCTAssertNil(result?.failureReason)
        XCTAssertFalse(result?.registered ?? true)
        XCTAssertGreaterThan(store.failedShortcutCount, 0)
    }

    func testStartupDuringUpdatePauseDefersUntilResumeAndKeepsModuleAvailability() async throws {
        let controller = makeController()
        let store = ShortcutStore(shortcutController: controller)
        try await store.prepareForApplicationUpdate()
        store.setRuntimeAvailability(screenshotEnabled: false, clipboardEnabled: true)

        await store.initializeShortcutsAfterApplicationLaunch()
        XCTAssertTrue(store.shortcutRegistrationResults.isEmpty)
        XCTAssertEqual(store.registrationGeneration, 0)

        await store.resumeAfterCancelledApplicationUpdate()

        XCTAssertEqual(store.registrationGeneration, 1)
        XCTAssertTrue(store.shortcutRegistrationResult(for: .clipboardHistory)?.registered == true)
        XCTAssertTrue(store.shortcutRegistrationResult(for: .screenshotSmart)?.runtimeDisabled == true)
        XCTAssertEqual(store.failedShortcutCount, 0)
    }

    func testUpdatePauseDuringReadinessWaitDoesNotRegisterUntilResume() async throws {
        var running = false
        let controller = makeController()
        controller.setApplicationRunningForFixtures { running }
        var waiting: CheckedContinuation<Void, Never>?
        let store = ShortcutStore(shortcutController: controller, startupRetryWait: { _ in
            await withCheckedContinuation { waiting = $0 }
        })
        let startup = Task { @MainActor in await store.initializeShortcutsAfterApplicationLaunch() }
        for _ in 0..<100 where waiting == nil { await Task.yield() }
        guard let waiting else {
            startup.cancel()
            return XCTFail("Startup should suspend after the first readiness rejection.")
        }
        try await store.prepareForApplicationUpdate()
        running = true
        waiting.resume()
        await startup.value
        XCTAssertEqual(store.registrationGeneration, 1)
        XCTAssertEqual(store.registeredShortcutCount, 0)

        await store.resumeAfterCancelledApplicationUpdate()

        XCTAssertEqual(store.registrationGeneration, 2)
        XCTAssertTrue(store.shortcutRegistrationResult(for: .clipboardHistory)?.registered == true)
    }

    func testSuccessfulStartupPreservesActionsEpochAndUpdatePauseContract() async throws {
        let controller = makeController()
        var clipboardCount = 0
        var screenshotCount = 0
        var quickPasteIndices: [Int] = []
        let store = ShortcutStore(shortcutController: controller, actions: ShortcutActionHandlers(
            screenshotSmart: { screenshotCount += 1 },
            clipboardHistory: { clipboardCount += 1 },
            translationPanel: {},
            translationScreenshot: {},
            clipboardQuickPaste: { quickPasteIndices.append($0) }
        ))
        await store.initializeShortcutsAfterApplicationLaunch()
        let generation = store.registrationGeneration
        let oldRoute = try XCTUnwrap(controller.routeTokenForFixtures(for: .clipboardHistory))
        controller.simulateRoutedEventForFixtures(routeToken: oldRoute, pressed: true)
        controller.simulateRoutedEventForFixtures(routeToken: oldRoute, pressed: false)
        for _ in 0..<100 where clipboardCount == 0 { await Task.yield() }
        XCTAssertEqual(clipboardCount, 1)

        await store.initializeShortcutsAfterApplicationLaunch()
        store.registerDefaultShortcuts()
        XCTAssertEqual(store.registrationGeneration, generation)

        try await store.prepareForApplicationUpdate()
        let screenshotRoute = try XCTUnwrap(controller.routeTokenForFixtures(for: .screenshotSmart))
        let quickPasteRoute = try XCTUnwrap(controller.routeTokenForFixtures(for: .clipboardQuickPaste1))
        for route in [screenshotRoute, quickPasteRoute] {
            controller.simulateRoutedEventForFixtures(routeToken: route, pressed: true)
            controller.simulateRoutedEventForFixtures(routeToken: route, pressed: false)
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(screenshotCount, 0)
        XCTAssertTrue(quickPasteIndices.isEmpty)
        await store.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(store.registrationGeneration, generation)

        for route in [screenshotRoute, quickPasteRoute] {
            controller.simulateRoutedEventForFixtures(routeToken: route, pressed: true)
            controller.simulateRoutedEventForFixtures(routeToken: route, pressed: false)
        }
        for _ in 0..<100 where screenshotCount == 0 || quickPasteIndices.isEmpty { await Task.yield() }
        XCTAssertEqual(screenshotCount, 1)
        XCTAssertEqual(quickPasteIndices, [1])

        store.setRuntimeAvailability(screenshotEnabled: true, clipboardEnabled: false)
        controller.simulateRoutedEventForFixtures(routeToken: oldRoute, pressed: true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(clipboardCount, 1, "Retired registration epochs must not deliver after module disable.")
        XCTAssertTrue(store.shortcutRegistrationResult(for: .clipboardHistory)?.runtimeDisabled == true)
    }

    private func makeController(
        registrar: @escaping ShortcutController.FixtureHotKeyRegistrar = { _, _, _, _ in
            (status: noErr, hasReference: true)
        }
    ) -> ShortcutController {
        let controller = ShortcutController.fixture(registrar: registrar)
        controller.setApplicationRunningForFixtures { true }
        // No test reads or rewrites the user's persisted shortcut bindings.
        controller.setConfiguredBindingsForFixtures(Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { command in
            (command, command.defaultBinding)
        }))
        return controller
    }
}
