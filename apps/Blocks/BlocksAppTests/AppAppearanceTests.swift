import AppKit
import BlocksCore
import QuartzCore
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class AppAppearanceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testMissingPreferenceDefaultsToFollowingSystem() {
        var appliedAppearances: [NSAppearance?] = []

        let store = AppAppearanceStore(defaults: defaults) {
            appliedAppearances.append($0)
        }

        XCTAssertEqual(store.preference, .system)
        XCTAssertEqual(appliedAppearances.count, 1)
        XCTAssertNil(appliedAppearances[0])
        let persistentDomain = defaults.persistentDomain(forName: suiteName)
        XCTAssertNil(persistentDomain?["AppleInterfaceStyle"])
        XCTAssertNil(persistentDomain?["NSRequiresAquaSystemAppearance"])
    }

    func testInvalidPreferenceNormalizesToSystem() {
        defaults.set("invalid", forKey: AppAppearancePreference.defaultsKey)
        var appliedAppearance: NSAppearance? = NSAppearance(named: .darkAqua)

        let store = AppAppearanceStore(defaults: defaults) {
            appliedAppearance = $0
        }

        XCTAssertEqual(store.preference, .system)
        XCTAssertEqual(
            defaults.string(forKey: AppAppearancePreference.defaultsKey),
            AppAppearancePreference.system.rawValue
        )
        XCTAssertNil(appliedAppearance)
    }

    func testSelectionsPersistAndMapToNativeAppearances() {
        var appliedNames: [NSAppearance.Name?] = []
        let store = AppAppearanceStore(defaults: defaults) {
            appliedNames.append($0?.name)
        }

        store.setPreference(.light)
        XCTAssertEqual(store.preference, .light)
        XCTAssertEqual(appliedNames.last!, .aqua)
        XCTAssertEqual(defaults.string(forKey: AppAppearancePreference.defaultsKey), "light")

        store.setPreference(.dark)
        XCTAssertEqual(store.preference, .dark)
        XCTAssertEqual(appliedNames.last!, .darkAqua)
        XCTAssertEqual(defaults.string(forKey: AppAppearancePreference.defaultsKey), "dark")

        store.setPreference(.system)
        XCTAssertEqual(store.preference, .system)
        XCTAssertNil(appliedNames.last!)
        XCTAssertEqual(defaults.string(forKey: AppAppearancePreference.defaultsKey), "system")
    }

    func testLanguagePreferenceIsCapturedForTheWholeAppSession() {
        defaults.set(
            AppLanguagePreference.english.rawValue,
            forKey: AppLanguageSessionSnapshot.preferenceKey
        )
        let session = AppLanguageSessionSnapshot(defaults: defaults)

        defaults.set(
            AppLanguagePreference.japanese.rawValue,
            forKey: AppLanguageSessionSnapshot.preferenceKey
        )

        XCTAssertEqual(session.preference, .english)
        XCTAssertEqual(
            AppLanguageSessionSnapshot(defaults: defaults).preference,
            .japanese
        )
    }

    func testWindowsAndPanelsDoNotOverrideApplicationAppearance() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        // The application-level mapping is covered independently by
        // testSelectionsPersistAndMapToNativeAppearances. Keeping these
        // windows free of a local override proves that both surface roles
        // continue to inherit whichever appearance the real app store owns,
        // without introducing a second AppAppearanceStore that races the
        // launched test host for NSApplication.shared.appearance.
        XCTAssertNil(window.appearance)
        XCTAssertNil(panel.appearance)
    }

    func testShortcutRecorderMonitorReplacesPreviousCommandAndIgnoresOldHandler() {
        let monitorSpy = ShortcutRecorderMonitorSpy()
        let lifecycle = ShortcutRecorderMonitorLifecycle(
            installLocalMonitor: monitorSpy.install,
            removeLocalMonitor: monitorSpy.remove
        )
        var savedCommands: [ShortcutCommand] = []

        lifecycle.startRecording(for: .screenshotSmart) { event in
            savedCommands.append(.screenshotSmart)
            return nil
        }
        let oldHandler = monitorSpy.handlers[0]
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 1)

        lifecycle.startRecording(for: .clipboardHistory) { event in
            savedCommands.append(.clipboardHistory)
            return nil
        }

        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 1)
        XCTAssertEqual(monitorSpy.activeMonitorCount, 1)
        XCTAssertEqual(monitorSpy.removedMonitorCount, 1)
        _ = oldHandler(shortcutRecorderTestKeyEvent())
        XCTAssertTrue(savedCommands.isEmpty)

        _ = monitorSpy.handlers[1](shortcutRecorderTestKeyEvent())
        XCTAssertEqual(savedCommands, [.clipboardHistory])
    }

    func testShortcutRecorderMonitorStopsWhenReregisterOrRestoreResetsRecordingToIdle() {
        let monitorSpy = ShortcutRecorderMonitorSpy()
        let lifecycle = ShortcutRecorderMonitorLifecycle(
            installLocalMonitor: monitorSpy.install,
            removeLocalMonitor: monitorSpy.remove
        )

        lifecycle.startRecording(for: .screenshotSmart) { $0 }
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 1)

        lifecycle.synchronize(with: .idle)

        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 0)
        XCTAssertEqual(monitorSpy.activeMonitorCount, 0)
        XCTAssertEqual(monitorSpy.removedMonitorCount, 1)

        lifecycle.startRecording(for: .clipboardHistory) { $0 }
        lifecycle.synchronize(with: .idle)

        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 0)
        XCTAssertEqual(monitorSpy.activeMonitorCount, 0)
        XCTAssertEqual(monitorSpy.removedMonitorCount, 2)
    }

    func testShortcutRecorderMonitorStopsWhenSettingsPaneIsDestroyed() {
        let monitorSpy = ShortcutRecorderMonitorSpy()
        var lifecycle: ShortcutRecorderMonitorLifecycle? = ShortcutRecorderMonitorLifecycle(
            installLocalMonitor: monitorSpy.install,
            removeLocalMonitor: monitorSpy.remove
        )

        lifecycle?.startRecording(for: .translationPanel) { $0 }
        XCTAssertEqual(lifecycle?.activeMonitorCountForTesting, 1)
        XCTAssertEqual(monitorSpy.activeMonitorCount, 1)

        lifecycle = nil

        XCTAssertEqual(monitorSpy.activeMonitorCount, 0)
        XCTAssertEqual(monitorSpy.removedMonitorCount, 1)
    }

    func testShortcutRecorderMonitorStopsForOwningWindowAndApplicationLifecycle() {
        let monitorSpy = ShortcutRecorderMonitorSpy()
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutRecorderMonitorLifecycle(
            installLocalMonitor: monitorSpy.install,
            removeLocalMonitor: monitorSpy.remove,
            notificationCenter: notificationCenter
        )
        let settingsWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let unrelatedWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var endedCount = 0

        lifecycle.startRecording(
            for: .screenshotSmart,
            in: settingsWindow,
            onRecordingEnded: { endedCount += 1 }
        ) { $0 }
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 1)
        XCTAssertEqual(lifecycle.activeLifecycleObserverCountForTesting, 3)

        notificationCenter.post(
            name: NSWindow.didResignKeyNotification,
            object: unrelatedWindow
        )
        XCTAssertEqual(endedCount, 0)
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 1)

        notificationCenter.post(
            name: NSWindow.didResignKeyNotification,
            object: settingsWindow
        )
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 0)
        XCTAssertEqual(lifecycle.activeLifecycleObserverCountForTesting, 0)

        lifecycle.startRecording(
            for: .translationPanel,
            in: settingsWindow,
            onRecordingEnded: { endedCount += 1 }
        ) { $0 }
        notificationCenter.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        XCTAssertEqual(endedCount, 2)
        XCTAssertEqual(lifecycle.activeMonitorCountForTesting, 0)
        XCTAssertEqual(lifecycle.activeLifecycleObserverCountForTesting, 0)
    }

    func testTerminationCoordinatorRepliesAfterDispatcherCompletes() async {
        var dispatchCount = 0
        var replyCount = 0
        let replied = expectation(description: "completed dispatcher replies")
        let coordinator = AppTerminationCoordinator(
            dispatcher: {
                dispatchCount += 1
            },
            timeoutSleeper: { _ in },
            replyHandler: { accepted in
                XCTAssertTrue(accepted)
                replyCount += 1
                replied.fulfill()
            }
        )

        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(replyCount, 1)
        XCTAssertEqual(coordinator.requestTermination(), .terminateNow)
    }

    func testTerminationCoordinatorNeverUsesElapsedTimeoutToKillBusyWork() async {
        var dispatchCount = 0
        var replyCount = 0
        var finalizerCount = 0
        var finishWork: CheckedContinuation<Void, Never>?
        let started = expectation(description: "dispatcher owns unfinished work")
        let replied = expectation(description: "drained dispatcher replies once")
        let coordinator = AppTerminationCoordinator(
            dispatcher: {
                dispatchCount += 1
                await withCheckedContinuation { continuation in
                    finishWork = continuation
                    started.fulfill()
                }
            },
            finalizer: { finalizerCount += 1 },
            timeoutSleeper: { _ in },
            replyHandler: { accepted in
                XCTAssertTrue(accepted)
                replyCount += 1
                replied.fulfill()
            }
        )

        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [started], timeout: 1)

        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(finalizerCount, 0)
        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        finishWork?.resume()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replyCount, 1)
        XCTAssertEqual(finalizerCount, 1)
        XCTAssertEqual(coordinator.requestTermination(), .terminateNow)
        coordinator.finalizeTerminationResourcesIfNeeded()
        XCTAssertEqual(finalizerCount, 1)
    }

    func testTerminationCoordinatorCoalescesRepeatedRequests() async {
        var dispatchCount = 0
        var replyCount = 0
        var finishWork: CheckedContinuation<Void, Never>?
        let started = expectation(description: "one dispatcher started")
        let replied = expectation(description: "coalesced requests finish")
        let coordinator = AppTerminationCoordinator(
            dispatcher: {
                dispatchCount += 1
                await withCheckedContinuation { continuation in
                    finishWork = continuation
                    started.fulfill()
                }
            },
            timeoutSleeper: { _ in },
            replyHandler: { _ in
                replyCount += 1
                replied.fulfill()
            }
        )

        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [started], timeout: 1)

        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(replyCount, 0)
        finishWork?.resume()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replyCount, 1)
    }

    func testTerminationCoordinatorWithoutRuntimeCancelsUntilConfigured() async {
        var replyCount = 0
        let replied = expectation(description: "configured coordinator can retry")
        let coordinator = AppTerminationCoordinator(replyHandler: { _ in
            replyCount += 1
            replied.fulfill()
        })

        XCTAssertEqual(coordinator.requestTermination(), .terminateCancel)
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(coordinator.requestTermination(), .terminateCancel)
        coordinator.installDispatcher { }
        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(coordinator.requestTermination(), .terminateNow)
    }

    func testTerminationCoordinatorRejectedPreparationCanRetryWithoutFinalizing() async {
        var reject = true
        var replies: [Bool] = []
        var finalized = 0
        let rejected = expectation(description: "busy preparation cancels quit")
        let accepted = expectation(description: "retry completes after work finishes")
        let coordinator = AppTerminationCoordinator(dispatcher: {
            if reject { throw ApplicationOperationAdmissionGate.AdmissionError.busy("fixture") }
        }, finalizer: { finalized += 1 }, replyHandler: { reply in
            replies.append(reply)
            if reply { accepted.fulfill() } else { rejected.fulfill() }
        })
        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(finalized, 0)
        reject = false
        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [accepted], timeout: 1)
        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(finalized, 1)
    }

    func testApplicationChromeTypographyUsesNativeSystemFontsForEveryWeight() {
        let cases: [(BlocksTypographyWeight, NSFont.Weight)] = [
            (.regular, .regular),
            (.medium, .medium),
            (.semibold, .semibold),
            (.bold, .bold),
        ]

        for (weight, nativeWeight) in cases {
            let resolved = BlocksTypography.nsFont(size: 13, weight: weight)
            let expected = NSFont.systemFont(ofSize: 13, weight: nativeWeight)
            XCTAssertEqual(resolved.fontName, expected.fontName)
            XCTAssertEqual(resolved.pointSize, expected.pointSize)
        }
    }

    func testSurfaceRolesUseSemanticNativeMaterials() {
        XCTAssertEqual(BlocksSurfaceRole.sidebar.appKitMaterial, .sidebar)
        XCTAssertEqual(BlocksSurfaceRole.content.appKitMaterial, .contentBackground)
        XCTAssertEqual(BlocksSurfaceRole.section.appKitMaterial, .contentBackground)
        XCTAssertEqual(BlocksSurfaceRole.panel.appKitMaterial, .popover)
        XCTAssertEqual(BlocksSurfaceRole.popover.appKitMaterial, .popover)
        XCTAssertEqual(BlocksSurfaceRole.hud.appKitMaterial, .hudWindow)
        XCTAssertEqual(
            BlocksSurfaceRole.panel.glassTintColor(isActive: false).alphaComponent,
            0.26,
            accuracy: 0.001
        )
        XCTAssertEqual(
            BlocksSurfaceRole.hud.glassTintColor(isActive: false).alphaComponent,
            0.30,
            accuracy: 0.001
        )
        XCTAssertFalse(BlocksSurfaceRole.section.prefersLiquidGlass)
        XCTAssertTrue(BlocksSurfaceRole.panel.prefersLiquidGlass)
        XCTAssertFalse(BlocksSurfaceRole.interactive.prefersLiquidGlass)
        XCTAssertFalse(BlocksSurfaceRole.sidebar.prefersLiquidGlass)
        XCTAssertEqual(BlocksSurfaceRole.sidebar.layer, .structure)
        XCTAssertEqual(BlocksSurfaceRole.section.layer, .content)
        XCTAssertEqual(BlocksSurfaceRole.interactive.layer, .interaction)
        XCTAssertEqual(BlocksSurfaceRole.hud.layer, .overlay)
    }

    func testClipboardBottomTrayExposesOneStableCardWidthResizeHandle() {
        XCTAssertFalse(
            ClipboardPanelVisualPolicy.showsBottomCardWidthResizeHandle(after: 0, recordCount: 1)
        )
        XCTAssertTrue(
            ClipboardPanelVisualPolicy.showsBottomCardWidthResizeHandle(after: 0, recordCount: 4)
        )
        for index in 1..<4 {
            XCTAssertFalse(
                ClipboardPanelVisualPolicy.showsBottomCardWidthResizeHandle(
                    after: index,
                    recordCount: 4
                )
            )
        }

        let cardSpacing = BlocksVisualTokens.Spacing.sm
        let handleWidth = ClipboardBottomTrayLayout.cardWidthResizeHitWidth
        let trailingOffset = ClipboardPanelVisualPolicy.bottomCardWidthResizeHandleTrailingOffset(
            cardSpacing: cardSpacing,
            handleWidth: handleWidth
        )

        XCTAssertEqual(cardSpacing, 8)
        XCTAssertEqual(handleWidth, cardSpacing)
        XCTAssertEqual(trailingOffset, cardSpacing)
        XCTAssertEqual(trailingOffset - handleWidth, 0)
        XCTAssertEqual(trailingOffset - handleWidth / 2, cardSpacing / 2)
    }

    func testClipboardRecordAccessibilityOrderMatchesVisibleRecordOrder() {
        let priorities = (0..<4).map {
            ClipboardPanelVisualPolicy.recordAccessibilitySortPriority(at: $0)
        }

        XCTAssertEqual(priorities, [0, -1, -2, -3])
    }

    func testPluginInstallationDisclosurePreservesExactHighImpactDeclarations() {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 6,
            id: "com.example.maximum-permissions",
            displayName: "Maximum Permissions",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks, .actions],
            permissions: .init(
                secrets: [
                    .init(id: "service-token", displayName: "Service token"),
                    .init(
                        id: "optional-note",
                        displayName: "Optional note",
                        required: false
                    ),
                ]
            ),
            configurationFields: [
                .init(
                    id: "service-token",
                    type: .secret,
                    title: "Service token",
                    required: true
                ),
                .init(
                    id: "optional-note",
                    type: .secret,
                    title: "Optional note"
                ),
            ],
            presentation: .init(
                summary: "Reviews all sensitive capabilities.",
                purpose: "Validates the installation disclosure.",
                trigger: "When the configured workflows run.",
                dataUsage: "Uses only the data shown in this review."
            ),
            platform: .init(
                hooks: [
                    .init(
                        id: "delete-guard",
                        event: .clipboardWillPersistCapture,
                        failurePolicy: .failClosed,
                        runsInBackground: false
                    ),
                    .init(
                        id: "paste-audit",
                        event: .clipboardWillWritePasteboard,
                        failurePolicy: .failOpen,
                        runsInBackground: true
                    ),
                ],
                hostActions: [
                    "clipboard.record.delete",
                    "system.shortcut.execute",
                ],
                importedActions: [
                    .init(pluginID: "com.example.producer", actionID: "classify")
                ],
                sharedState: [
                    .init(id: "local-cache", access: .readWrite),
                    .init(
                        id: "shared-tags",
                        displayName: "Shared tags",
                        ownerPluginID: "com.example.owner",
                        access: .read
                    ),
                ]
            )
        )

        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(manifest: manifest)
        )
        let disclosure = PluginInstallationDisclosurePresentation(manifest: manifest)

        XCTAssertEqual(
            disclosure.hooks,
            [
                .init(
                    id: "delete-guard",
                    event: .clipboardWillPersistCapture,
                    failurePolicy: .failClosed,
                    runsInBackground: false
                ),
                .init(
                    id: "paste-audit",
                    event: .clipboardWillWritePasteboard,
                    failurePolicy: .failOpen,
                    runsInBackground: true
                ),
            ]
        )
        XCTAssertEqual(
            disclosure.hostActionIDs,
            ["clipboard.record.delete", "system.shortcut.execute"]
        )
        XCTAssertEqual(
            disclosure.importedActions,
            [.init(pluginID: "com.example.producer", actionID: "classify")]
        )
        XCTAssertEqual(
            disclosure.sharedState,
            [
                .init(
                    ownerPluginID: "com.example.maximum-permissions",
                    id: "local-cache",
                    displayName: nil,
                    access: .readWrite
                ),
                .init(
                    ownerPluginID: "com.example.owner",
                    id: "shared-tags",
                    displayName: "Shared tags",
                    access: .read
                ),
            ]
        )
        XCTAssertEqual(
            disclosure.secrets,
            [
                .init(id: "service-token", displayName: "Service token", required: true),
                .init(id: "optional-note", displayName: "Optional note", required: false),
            ]
        )
        XCTAssertEqual(
            disclosure.hookModuleCounts.map { "\($0.0.rawValue):\($0.1)" },
            ["clipboard:2"]
        )
        XCTAssertTrue(disclosure.hasPreflightWorkflow)
        XCTAssertTrue(disclosure.hasFailClosedWorkflow)
        XCTAssertEqual(
            disclosure.sharedStateAccessCounts.map { "\($0.0.rawValue):\($0.1)" },
            ["read:1", "read_write:1"]
        )
    }

    func testPluginReviewHostActionCatalogUsesDistinctHostControlledDescriptions() {
        let fallback = PluginHostActionDisclosureCatalog.description(
            for: "unsupported.fixture"
        )
        let descriptions = Dictionary(
            uniqueKeysWithValues: BlocksPluginHostAPIV2.actionIDs.map {
                ($0, PluginHostActionDisclosureCatalog.description(for: $0))
            }
        )

        XCTAssertTrue(descriptions.values.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(descriptions.values.allSatisfy { $0 != fallback })
        XCTAssertNotEqual(
            descriptions["clipboard.record.read"],
            descriptions["clipboard.record.delete"]
        )
        XCTAssertNotEqual(
            descriptions["provider.capabilities.query"],
            descriptions["provider.request"]
        )
        for (actionID, text) in descriptions {
            XCTAssertFalse(text.contains(actionID))
        }
    }

    func testPluginReviewEventCatalogHasSafeLocalizedTextForEveryHookEvent() {
        for event in BlocksPluginEventName.allCases {
            let text = PluginInstallationEventDisclosureCatalog.description(
                for: event
            )
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, event.rawValue)
            XCTAssertFalse(text.contains(event.rawValue))
        }
    }

    func testPluginDisclosureKeepsSameOwnerNamespacesDistinctWithoutRawIDs() {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.consumer",
            displayName: "Consumer",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(
                    id: "scope-a",
                    displayName: "Recent items",
                    ownerPluginID: "com.example.owner",
                    access: .read
                ),
                .init(
                    id: "scope-b",
                    displayName: "Saved searches",
                    ownerPluginID: "com.example.owner",
                    access: .read
                ),
                .init(id: "legacy-scope", access: .write),
            ])
        )

        let disclosure = PluginInstallationDisclosurePresentation(manifest: manifest)

        XCTAssertEqual(
            disclosure.sharedState.map(\.displayName),
            ["Recent items", "Saved searches", nil]
        )
        XCTAssertEqual(disclosure.sharedState.map(\.ownerPluginID), [
            "com.example.owner", "com.example.owner", "com.example.consumer",
        ])
    }

    func testPluginReviewSheetScaffoldKeepsActionsReachableWithScrollableLongContent() {
        let visibleText = PluginReviewSheetScaffoldTestFixture
            .maximumPermissionDisclosure
            .joined(separator: "\n")
        for rawIdentifier in [
            "clipboard.will_write_pasteboard",
            "delete-guard",
            "clipboard.delete",
            "com.example.producer",
            "com.example.owner",
            "local-cache",
            "shared-tags",
            "service-token",
        ] {
            XCTAssertFalse(
                visibleText.contains(rawIdentifier),
                "ordinary installation UI must not expose \(rawIdentifier)"
            )
        }
        for humanReadableDisclosure in [
            "Selected installation package",
            "Unsigned plugin",
            "api.example.com",
            "GET, POST",
            "Service token · Required",
            "The secret itself is not shown here.",
            "Clipboard contents",
            "Before Blocks writes to the clipboard",
            "runs while Blocks is active",
            "a failure stops this step of the original workflow",
            "Before a clipboard item is saved",
            "can run in the background",
            "a failure lets the original workflow continue",
            "Runs on a schedule",
            "Saves plugin data on this Mac",
            "Delete clipboard records",
            "Run an approved Blocks shortcut action",
            "Use “Classify” from Producer",
            "Read only access to Shared tags data shared by Producer",
            "Adds interface content",
            "Can add Blocks-rendered pages",
        ] {
            XCTAssertTrue(
                visibleText.contains(humanReadableDisclosure),
                "maximum-permission disclosure must explain \(humanReadableDisclosure)"
            )
        }

        let host = NSHostingView(rootView: PluginReviewSheetScaffoldTestFixture())
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 360, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = window.contentView!.bounds
        defer {
            window.orderOut(nil)
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertGreaterThanOrEqual(
            host.fittingSize.width,
            BlocksVisualTokens.Layout.settingsSheetMinimumWidth
        )
        guard let scrollView = firstDescendant(of: NSScrollView.self, in: host) else {
            XCTFail("plugin review content must remain vertically scrollable")
            return
        }
        XCTAssertLessThan(
            scrollView.frame.height,
            host.bounds.height,
            "long disclosures must leave a fixed action region outside the scroll view"
        )
    }

    func testClipboardDetailPresentationIdentityChangesOnlyForVisibleContentInputs() {
        let baseline = ClipboardDetailPresentationIdentity(
            recordID: "record-a",
            itemFontSize: 13,
            contentRevision: 7
        )
        XCTAssertEqual(
            baseline,
            ClipboardDetailPresentationIdentity(
                recordID: "record-a",
                itemFontSize: 13,
                contentRevision: 7
            )
        )
        XCTAssertNotEqual(
            baseline,
            ClipboardDetailPresentationIdentity(
                recordID: "record-a",
                itemFontSize: 14,
                contentRevision: 7
            )
        )
        XCTAssertNotEqual(
            baseline,
            ClipboardDetailPresentationIdentity(
                recordID: "record-a",
                itemFontSize: 13,
                contentRevision: 8
            )
        )
    }

    func testClipboardSideHeaderKeepsSearchAndFiltersOnPrimaryRow() {
        XCTAssertGreaterThanOrEqual(
            ClipboardPanelToolbarLayout.sideSearchMinimumWidth,
            108
        )
        XCTAssertLessThanOrEqual(
            ClipboardPanelToolbarLayout.sideSearchMaximumWidth,
            132
        )
        XCTAssertLessThanOrEqual(
            ClipboardPanelToolbarLayout.sideSearchMinimumWidth,
            ClipboardPanelToolbarLayout.sideSearchPreferredWidth
        )
        XCTAssertFalse(
            ClipboardPanelToolbarLayout.sideFiltersShowIcons,
            "side-panel filters use compact text-only controls"
        )
    }

    func testClipboardBottomHeaderUsesSingleStableRow() {
        XCTAssertEqual(
            ClipboardPanelToolbarLayout.bottomHeaderHeight,
            ClipboardPanelToolbarLayout.headerRowHeight,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            ClipboardPanelToolbarLayout.bottomHeaderHeight,
            ClipboardPanelToolbarLayout.searchHeight
        )
    }

    func testClipboardSideHeaderUsesStableTwoRowLayout() {
        XCTAssertEqual(
            ClipboardPanelToolbarLayout.sideHeaderHeight,
            ClipboardPanelToolbarLayout.headerRowHeight
                + BlocksVisualTokens.Spacing.sm
                + ClipboardPanelToolbarLayout.tagRowHeight,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            ClipboardPanelToolbarLayout.sideHeaderHeight,
            ClipboardPanelToolbarLayout.bottomHeaderHeight
        )
    }

    func testSharedSurfacesAdaptToContrastAndWindowActivityWithoutGeometryChanges() {
        for role in BlocksSurfaceRole.allCases {
            let normalBorder = role.borderOpacity(
                isActive: false,
                isWindowActive: true,
                increasesContrast: false
            )
            let increasedBorder = role.borderOpacity(
                isActive: false,
                isWindowActive: true,
                increasesContrast: true
            )
            let inactiveBorder = role.borderOpacity(
                isActive: false,
                isWindowActive: false,
                increasesContrast: false
            )

            XCTAssertGreaterThan(
                increasedBorder,
                normalBorder,
                "\(role) must strengthen its semantic boundary when contrast is increased"
            )
            XCTAssertGreaterThanOrEqual(
                inactiveBorder,
                normalBorder,
                "\(role) must remain visibly bounded when the window is inactive"
            )

            let normalTint = role.glassTintColor(
                isActive: false,
                isWindowActive: true,
                increasesContrast: false
            )
            let increasedTint = role.glassTintColor(
                isActive: false,
                isWindowActive: true,
                increasesContrast: true
            )
            XCTAssertGreaterThan(
                increasedTint.alphaComponent,
                normalTint.alphaComponent
            )

            XCTAssertLessThanOrEqual(
                role.resolvedShadowOpacity(
                    isWindowActive: false,
                    increasesContrast: false
                ),
                role.resolvedShadowOpacity(
                    isWindowActive: true,
                    increasesContrast: false
                )
            )
        }
    }

    func testAppKitSurfaceConfigurationUsesTheSameSemanticRoleContract() {
        let view = BlocksAppKitGlassSurfaceView(frame: CGRect(x: 0, y: 0, width: 240, height: 48))
        view.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .panel,
            cornerRadius: 14,
            isActive: true,
            drawsShadow: false
        )

        XCTAssertEqual(view.blocksSurfaceConfiguration.role, .panel)
        XCTAssertEqual(
            view.activeRenderingMode,
            BlocksSurfaceRole.panel.renderingMode(
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                supportsLiquidGlass: {
                    if #available(macOS 26.0, *) { return true }
                    return false
                }()
            )
        )
        XCTAssertNotNil(view.blocksContentView.superview)
        XCTAssertEqual(view.layer?.cornerRadius, 14)
        XCTAssertEqual(
            view.layer?.borderWidth,
            view.activeRenderingMode == .liquidGlass
                ? 0 : BlocksVisualTokens.Stroke.width
        )
        XCTAssertEqual(view.layer?.shadowOpacity, 0)
    }

    func testSurfaceRolesFallBackToOpaqueColorsWhenTransparencyIsReduced() {
        for role in BlocksSurfaceRole.allCases {
            XCTAssertEqual(
                role.renderingMode(reduceTransparency: true, supportsLiquidGlass: true),
                .opaque
            )
        }
        XCTAssertEqual(
            BlocksSurfaceRole.section.renderingMode(
                reduceTransparency: false,
                supportsLiquidGlass: true
            ),
            .opaque
        )
        XCTAssertEqual(
            BlocksSurfaceRole.sidebar.renderingMode(
                reduceTransparency: false,
                supportsLiquidGlass: true
            ),
            .material
        )
    }

    func testMotionRolesUseOneStablePolicyAndReduceMotionFallback() {
        XCTAssertEqual(BlocksMotionRole.press.policy(reduceMotion: false).duration, 0.08)
        XCTAssertEqual(BlocksMotionRole.hoverFocus.policy(reduceMotion: false).duration, 0.10)
        XCTAssertEqual(BlocksMotionRole.selection.policy(reduceMotion: false).duration, 0.14)
        XCTAssertEqual(BlocksMotionRole.reveal.policy(reduceMotion: false).duration, 0.18)
        XCTAssertEqual(BlocksMotionRole.reflow.policy(reduceMotion: false).duration, 0.18)
        XCTAssertEqual(BlocksMotionRole.panel.policy(reduceMotion: false).duration, 0.22)
        XCTAssertEqual(
            BlocksMotionRole.confirmation.policy(reduceMotion: false).duration,
            0.16
        )
        XCTAssertEqual(
            BlocksMotionRole.confirmation.policy(
                reduceMotion: false,
                phase: .removal
            ).duration,
            0.12
        )
        XCTAssertEqual(
            BlocksMotionRole.directManipulation.policy(reduceMotion: false).duration,
            0
        )

        for role in BlocksMotionRole.allCases {
            let reduced = role.policy(reduceMotion: true)
            XCTAssertFalse(reduced.allowsSpatialMotion)
            XCTAssertFalse(reduced.allowsGlassMorph)
            XCTAssertLessThanOrEqual(reduced.duration, 0.10)
        }
    }

    func testVisualTokensExposeTheCanonicalScale() {
        XCTAssertEqual(
            [
                BlocksVisualTokens.Spacing.xxs,
                BlocksVisualTokens.Spacing.xs,
                BlocksVisualTokens.Spacing.sm,
                BlocksVisualTokens.Spacing.md,
                BlocksVisualTokens.Spacing.lg,
                BlocksVisualTokens.Spacing.xl,
                BlocksVisualTokens.Spacing.xxl,
            ],
            [2, 4, 8, 12, 16, 24, 32]
        )
        XCTAssertEqual(
            [
                BlocksVisualTokens.CornerRadius.small,
                BlocksVisualTokens.CornerRadius.control,
                BlocksVisualTokens.CornerRadius.section,
                BlocksVisualTokens.CornerRadius.large,
            ],
            [6, 8, 12, 16]
        )
        XCTAssertEqual(
            BlocksVisualTokens.Control.settingsRowMinimumHeight,
            44
        )
        XCTAssertEqual(
            BlocksVisualTokens.Density.micro.controlHeight,
            28
        )
        XCTAssertEqual(
            BlocksVisualTokens.Density.standard.controlHeight,
            36
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsTrailingColumnWidth,
            280
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsFormContentMaxWidth,
            820
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsCollectionContentMaxWidth,
            1_120
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsSheetContentMaxWidth,
            640
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsSheetMinimumWidth,
            560
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsSheetIdealWidth,
            600
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsSheetCompactMinimumHeight,
            280
        )
        XCTAssertGreaterThanOrEqual(
            BlocksVisualTokens.Layout.settingsSheetMinimumWidth
                - (BlocksVisualTokens.Spacing.lg * 2),
            BlocksVisualTokens.Layout.settingsLabelMinimumWidth
                + BlocksVisualTokens.Spacing.md
                + BlocksVisualTokens.Layout.settingsTrailingColumnMinimumWidth
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsTrailingColumnMinimumWidth,
            220
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsTrailingColumnMaximumWidth,
            360
        )
        XCTAssertEqual(
            BlocksVisualTokens.Layout.settingsLabelMinimumWidth,
            260
        )
    }

    func testInteractionStatesHaveStableBehaviorContracts() {
        XCTAssertEqual(
            Set(BlocksInteractionState.allCases.map(\.rawValue)).count,
            BlocksInteractionState.allCases.count
        )
        XCTAssertFalse(BlocksInteractionState.disabled.isInteractive)
        XCTAssertFalse(BlocksInteractionState.loading.isInteractive)
        XCTAssertTrue(BlocksInteractionState.selected.isInteractive)
        XCTAssertTrue(BlocksInteractionState.error.isTransient)
        XCTAssertFalse(BlocksInteractionState.focused.isTransient)

        let focused = BlocksInteractionAppearance.resolve(.focused)
        let highContrastFocused = BlocksInteractionAppearance.resolve(
            .focused,
            increasesContrast: true
        )
        XCTAssertGreaterThan(
            highContrastFocused.borderOpacity,
            focused.borderOpacity
        )
        XCTAssertTrue(
            BlocksInteractionAppearance.resolve(.loading).showsProgress
        )
        XCTAssertFalse(
            BlocksInteractionAppearance.resolve(.idle).showsProgress
        )
    }

    func testAppKitInteractiveChromeSharesSelectedAndIdleContracts() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))

        BlocksAppKitInteractiveChrome.apply(
            to: view,
            selected: true,
            hovered: false,
            pressed: false
        )
        XCTAssertEqual(
            view.layer?.cornerRadius,
            BlocksVisualTokens.CornerRadius.control
        )
        XCTAssertEqual(
            view.layer?.borderWidth,
            BlocksVisualTokens.Stroke.width
        )
        XCTAssertNotNil(view.layer?.backgroundColor)

        BlocksAppKitInteractiveChrome.apply(
            to: view,
            selected: false,
            hovered: false,
            pressed: false
        )
        XCTAssertEqual(view.layer?.borderWidth, 0)
        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    func testSettingsRouteStateKeepsIndependentScrollOffsets() {
        let store = SettingsRouteStateStore()
        let screenshot = store.scrollOffsetBinding(for: .screenshot)
        let clipboard = store.scrollOffsetBinding(for: .clipboard)

        screenshot.wrappedValue = 412
        clipboard.wrappedValue = 86

        XCTAssertEqual(
            store.scrollOffsetBinding(for: .screenshot).wrappedValue,
            412
        )
        XCTAssertEqual(
            store.scrollOffsetBinding(for: .clipboard).wrappedValue,
            86
        )

        screenshot.wrappedValue = -20
        XCTAssertEqual(
            store.scrollOffsetBinding(for: .screenshot).wrappedValue,
            0
        )

        store.restoreSecondaryRoute(
            for: .screenshot,
            anchorID: SettingsSecondaryRouteAnchor.screenshotWatermarks
        )
        XCTAssertEqual(store.secondaryScrollRequest?.mode, .screenshot)
        XCTAssertEqual(
            store.secondaryScrollRequest?.anchorID,
            SettingsSecondaryRouteAnchor.screenshotWatermarks
        )
    }

    func testSettingsRouteStateKeepsProviderOverviewAndDetailOffsetsIndependent() {
        let store = SettingsRouteStateStore()
        let route = store.secondaryRouteBinding(
            for: .providers,
            default: "overview"
        )
        let overview = store.scrollOffsetBinding(for: .providers)
        overview.wrappedValue = 412

        route.wrappedValue = "details"
        let detail = store.scrollOffsetBinding(for: .providers)
        XCTAssertEqual(detail.wrappedValue, 0)
        detail.wrappedValue = 86

        route.wrappedValue = "overview"
        XCTAssertEqual(
            store.scrollOffsetBinding(for: .providers).wrappedValue,
            412
        )
    }

    func testSettingsRouteStateKeepsEveryFormSecondaryPageOffsetIndependent() {
        let scenarios: [(SettingsViewMode, [String])] = [
            (.screenshot, ["watermarks"]),
            (.clipboard, ["tags"]),
            (
                .translation,
                ["services", "languageResources", "compatibilitySelection"]
            ),
        ]

        for (mode, secondaryTokens) in scenarios {
            let store = SettingsRouteStateStore()
            let route = store.secondaryRouteBinding(
                for: mode,
                default: "root"
            )
            let root = store.scrollOffsetBinding(for: mode)
            root.wrappedValue = 412

            for (index, token) in secondaryTokens.enumerated() {
                route.wrappedValue = token
                let secondary = store.scrollOffsetBinding(for: mode)
                XCTAssertEqual(
                    secondary.wrappedValue,
                    0,
                    "A first visit to \(mode).\(token) must start at the top"
                )
                secondary.wrappedValue = CGFloat(80 + index)
            }

            route.wrappedValue = "root"
            XCTAssertEqual(
                store.scrollOffsetBinding(for: mode).wrappedValue,
                412,
                "Returning to \(mode).root must restore its own offset"
            )

            for (index, token) in secondaryTokens.enumerated() {
                route.wrappedValue = token
                XCTAssertEqual(
                    store.scrollOffsetBinding(for: mode).wrappedValue,
                    CGFloat(80 + index),
                    "Each \(mode) secondary route must retain only its own offset"
                )
            }
        }
    }

    func testSettingsRouteStateRestoresFocusedProviderDetailOnlyAfterSidebarSelection() throws {
        let store = SettingsRouteStateStore()
        let route = store.secondaryRouteBinding(
            for: .providers,
            default: "overview"
        )
        route.wrappedValue = "details"
        store.recordFocusTarget(
            "settings.providers.details.base-url",
            for: .providers,
            routeToken: "details"
        )

        // Programmatic route changes intentionally do not produce a request.
        XCTAssertNil(store.focusRestorationRequest)

        store.requestFocusRestorationForSidebarSelection(of: .providers)

        XCTAssertEqual(
            store.focusRestorationRequest?.target,
            "settings.providers.details.base-url"
        )
        XCTAssertTrue(
            store.shouldRestoreFocus(
                for: try XCTUnwrap(store.focusRestorationRequest),
                mode: .providers,
                routeToken: "details",
                voiceOverEnabled: false
            )
        )
    }

    func testSettingsRouteStateRejectsFocusRestoreForRouteMismatchAndVoiceOver() throws {
        let store = SettingsRouteStateStore()
        let route = store.secondaryRouteBinding(
            for: .providers,
            default: "overview"
        )
        route.wrappedValue = "details"
        store.recordFocusTarget(
            "settings.providers.details.model",
            for: .providers,
            routeToken: "details"
        )
        store.requestFocusRestorationForSidebarSelection(of: .providers)
        let request = try XCTUnwrap(store.focusRestorationRequest)

        XCTAssertFalse(
            store.shouldRestoreFocus(
                for: request,
                mode: .providers,
                routeToken: "overview",
                voiceOverEnabled: false
            )
        )
        XCTAssertFalse(
            store.shouldRestoreFocus(
                for: request,
                mode: .providers,
                routeToken: "details",
                voiceOverEnabled: true
            )
        )

        store.requestFocusRestorationForSidebarSelection(of: .clipboard)
        XCTAssertNil(
            store.focusRestorationRequest,
            "A newer sidebar selection without a target must invalidate an older request"
        )
    }

    func testSettingsRouteStateKeepsOnlyNonSensitiveProviderDetailsDraftInMemory() {
        let store = SettingsRouteStateStore()
        let draft = ProviderDetailsRouteDraft(
            apiBaseURLDraft: "https://draft.example/v1",
            accountAliasDraft: "work-account",
            modelNameDraft: "draft-model",
            baseURLValidationFailed: true
        )

        store.updateProviderDetailsDraft(draft, for: "details")
        XCTAssertEqual(store.providerDetailsDraft(for: "details"), draft)
        XCTAssertNil(store.providerDetailsDraft(for: "overview"))

        store.clearProviderDetailsDraft(for: "details")
        XCTAssertNil(store.providerDetailsDraft(for: "details"))
    }

    func testSettingsRouteStateKeepsPluginCatalogAndDetailOffsetsIndependent() {
        let store = SettingsRouteStateStore()
        let catalog = store.scrollOffsetBinding(
            key: "settings.plugins.route.catalog"
        )
        let detail = store.scrollOffsetBinding(
            key: "settings.plugins.route.installed.fixture"
        )
        catalog.wrappedValue = 412
        detail.wrappedValue = 86

        XCTAssertEqual(catalog.wrappedValue, 412)
        XCTAssertEqual(detail.wrappedValue, 86)
    }

    func testSettingsScrollBridgeRestoresNewRouteOnReusedScrollView() {
        let store = SettingsRouteStateStore()
        let firstDetail = store.scrollOffsetBinding(
            key: "settings.translationFavorites.detail.favorite-a"
        )
        let secondDetail = store.scrollOffsetBinding(
            key: "settings.translationFavorites.detail.favorite-b"
        )
        firstDetail.wrappedValue = 412
        secondDetail.wrappedValue = 86

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240)
        )
        let documentView = SettingsScrollTestDocumentView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 1_200)
        )
        let probe = SettingsScrollPositionBridge.ProbeView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        documentView.addSubview(probe)
        scrollView.documentView = documentView

        let coordinator = SettingsScrollPositionBridge.Coordinator(
            restorationID: "settings.translationFavorites.detail.favorite-a",
            offset: firstDetail
        )
        // Do not wait for the first restoration. In the real split view the
        // route can change while that deferred callback is still queued.
        coordinator.attach(from: probe)
        coordinator.update(
            restorationID: "settings.translationFavorites.detail.favorite-b",
            offset: secondDetail
        )
        coordinator.attach(from: probe)
        waitForScrollOffset(86, in: scrollView)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            86,
            accuracy: 0.5
        )
        XCTAssertEqual(secondDetail.wrappedValue, 86, accuracy: 0.5)
        XCTAssertEqual(firstDetail.wrappedValue, 412, accuracy: 0.5)

        // Reusing the exact same NSScrollView must restore the first detail's
        // stored position again, not the late callback from the second detail.
        coordinator.update(
            restorationID: "settings.translationFavorites.detail.favorite-a",
            offset: firstDetail
        )
        coordinator.attach(from: probe)
        waitForScrollOffset(412, in: scrollView)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            412,
            accuracy: 0.5
        )
        XCTAssertEqual(secondDetail.wrappedValue, 86, accuracy: 0.5)
        XCTAssertEqual(firstDetail.wrappedValue, 412, accuracy: 0.5)
    }

    func testSettingsScrollBridgeRestoresRouteInSwiftUIHostingView() {
        let state = SettingsScrollBridgeHostingState()
        state.screenshotOffset.wrappedValue = 412
        state.clipboardOffset.wrappedValue = 86

        let hostingView = NSHostingView(
            rootView: SettingsScrollBridgeHostingFixture(state: state)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 640, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = window.contentView!.bounds
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let scrollView = waitForScrollView(in: hostingView)
        waitForScrollOffset(412, in: scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 412, accuracy: 0.5)

        state.route = .clipboard
        waitForScrollOffset(86, in: scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 86, accuracy: 0.5)
        XCTAssertEqual(state.screenshotOffset.wrappedValue, 412, accuracy: 0.5)
        XCTAssertEqual(state.clipboardOffset.wrappedValue, 86, accuracy: 0.5)
    }

    private func waitForScrollOffset(
        _ expected: CGFloat,
        in scrollView: NSScrollView,
        timeout: TimeInterval = 1
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              abs(scrollView.contentView.bounds.origin.y - expected) > 0.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitForScrollView(
        in hostingView: NSHostingView<SettingsScrollBridgeHostingFixture>,
        timeout: TimeInterval = 1
    ) -> NSScrollView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let scrollView = firstDescendant(of: NSScrollView.self, in: hostingView) {
                return scrollView
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("SwiftUI settings fixture did not create an NSScrollView")
        fatalError("Missing NSScrollView")
    }

    func testSettingsRouteStateKeepsIndependentSecondaryRoutesPerModule() {
        let store = SettingsRouteStateStore()
        let plugins = store.secondaryRouteBinding(
            for: .hooks,
            default: "catalog"
        )
        let providers = store.secondaryRouteBinding(
            for: .providers,
            default: "overview"
        )

        XCTAssertEqual(plugins.wrappedValue, "catalog")
        XCTAssertEqual(providers.wrappedValue, "overview")

        plugins.wrappedValue = "installed:sample"
        providers.wrappedValue = "details"

        XCTAssertEqual(
            store.secondaryRouteBinding(
                for: .hooks,
                default: "catalog"
            ).wrappedValue,
            "installed:sample"
        )
        XCTAssertEqual(
            store.secondaryRouteBinding(
                for: .providers,
                default: "overview"
            ).wrappedValue,
            "details"
        )
    }

    func testSettingsSectionAndRowsShareAlignmentAtSupportedWidths() {
        for width: CGFloat in [820, 980, 1_440] {
            let geometry = SettingsLayout.alignmentGeometry(
                containerWidth: width
            )
            XCTAssertEqual(
                geometry.sectionTitleLeading,
                geometry.rowTitleLeading,
                accuracy: 1,
                "section and row titles must share a left baseline at \(width)pt"
            )
            XCTAssertEqual(
                geometry.headerActionTrailing,
                geometry.valueControlTrailing,
                accuracy: 1,
                "header actions and values must share a trailing edge at \(width)pt"
            )
            XCTAssertGreaterThanOrEqual(
                geometry.availableLabelWidth,
                SettingsLayout.labelMinimumWidth,
                "the 820pt minimum window must preserve the horizontal row contract"
            )
        }
    }

    func testRenderedSettingsSectionUsesSharedBaselinesAndTrailingEdge() {
        for width: CGFloat in [820, 980, 1_440] {
            let capture = SettingsGeometryCapture()
            let hostingView = NSHostingView(
                rootView: SettingsAlignmentTestFixture()
                    .frame(width: width, alignment: .top)
                    .settingsGeometryProbeReporter { identifier, frame in
                        capture.frames[identifier] = frame
                    }
            )
            let window = NSWindow(
                contentRect: NSRect(
                    x: -4_000,
                    y: -4_000,
                    width: width,
                    height: 420
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            hostingView.frame = window.contentView!.bounds
            window.orderFront(nil)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            guard
                let sectionFrame = capture.frames["section.Section title"],
                let rowFrame = capture.frames["row.Row title"],
                let rowShellFrame = capture.frames["rowShell.Row title"],
                let switchFrame = capture.frames["value.Row title"],
                let secondSwitchFrame = capture.frames["value.Second row"],
                let visibleSwitchFrame = capture.frames["control.Row switch"],
                let cleanupRowFrame = capture.frames["rowShell.Cleanup mode"],
                let cleanupValueFrame = capture.frames["value.Cleanup mode"],
                let cleanupControlFrame = capture.frames["control.Cleanup mode"],
                let textRowFrame = capture.frames["rowShell.Text value"],
                let textControlFrame = capture.frames["control.Text value"],
                let sliderRowFrame = capture.frames["rowShell.Slider value"],
                let sliderControlFrame = capture.frames["control.Slider value"]
            else {
                XCTFail("rendered settings geometry was not reported at \(width)pt")
                window.orderOut(nil)
                window.close()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                continue
            }

            XCTAssertEqual(sectionFrame.minX, rowFrame.minX, accuracy: 1)
            XCTAssertEqual(rowShellFrame.midY, visibleSwitchFrame.midY, accuracy: 1)
            XCTAssertEqual(
                cleanupRowFrame.midY,
                cleanupControlFrame.midY,
                accuracy: 1
            )
            XCTAssertEqual(textRowFrame.midY, textControlFrame.midY, accuracy: 1)
            XCTAssertEqual(sliderRowFrame.midY, sliderControlFrame.midY, accuracy: 1)
            XCTAssertEqual(
                switchFrame.maxX,
                secondSwitchFrame.maxX,
                accuracy: 1
            )
            XCTAssertEqual(
                secondSwitchFrame.maxX,
                cleanupValueFrame.maxX,
                accuracy: 1
            )
            XCTAssertEqual(
                visibleSwitchFrame.maxX,
                cleanupControlFrame.maxX,
                accuracy: 1,
                "visible controls, not transparent wrappers, must share the trailing edge"
            )
            XCTAssertEqual(cleanupControlFrame.maxX, textControlFrame.maxX, accuracy: 1)
            XCTAssertEqual(textControlFrame.maxX, sliderControlFrame.maxX, accuracy: 1)
            window.orderOut(nil)
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testAgentCLIActionsStayInsideValueColumnAtMinimumWidth() {
        let width: CGFloat = 820
        let capture = SettingsGeometryCapture()
        let hostingView = NSHostingView(
            rootView: SettingsSection(title: "Command Line") {
                SettingsStatusRow(
                    title: "Blocks Command",
                    detail: "Install the signed blocks command.",
                    status: SettingsRowStatus(
                        kind: .success,
                        message: "Installed with a recovery item available."
                    )
                ) {
                    AgentCLIActionControls(
                        installButtonTitle: "Update…",
                        canInstall: true,
                        showsUninstallAction: true,
                        canUninstall: true,
                        isBusy: false,
                        showsRecoveryAction: true,
                        installAction: {},
                        uninstallAction: {},
                        refreshAction: {},
                        recoveryAction: {}
                    )
                }
            }
            .frame(width: width, alignment: .top)
            .padding(BlocksVisualTokens.Layout.settingsPageHorizontalPadding)
            .settingsGeometryProbeReporter { identifier, frame in
                capture.frames[identifier] = frame
            }
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: -4_000,
                y: -4_000,
                width: width,
                height: 220
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = window.contentView!.bounds
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        guard
            let valueFrame = capture.frames["value.Blocks Command"],
            let installFrame = capture.frames["agentCLI.installAction"],
            let menuFrame = capture.frames["agentCLI.moreActions"]
        else {
            return XCTFail("Expected rendered CLI action geometry")
        }
        XCTAssertGreaterThanOrEqual(installFrame.minX, valueFrame.minX - 1)
        XCTAssertGreaterThanOrEqual(menuFrame.minX, installFrame.maxX)
        XCTAssertLessThanOrEqual(menuFrame.maxX, valueFrame.maxX + 1)
        XCTAssertLessThanOrEqual(valueFrame.width, SettingsLayout.trailingColumnMaximumWidth + 1)
    }

    func testProviderSettingsTreatLegacyFixtureCredentialsAsMissing() {
        let readiness = ProviderConnectionReadiness.make(
            apiKeychainAccountAlias: "personal-openai",
            apiBaseURL: "https://api.example.com/v1",
            apiModelName: "example-model",
            secretLifecycleState: .testSecretSaved
        )

        XCTAssertFalse(readiness.ready)
        XCTAssertEqual(
            ProviderSecretLifecycleState.testSecretSaved.localizedTitle,
            ProviderSecretLifecycleState.missing.localizedTitle
        )
    }

    func testProviderConnectionFailuresUseActionableLocalizedCopy() {
        for status in OpenAIConnectionStatus.allCases {
            XCTAssertFalse(status.localizedSettingsDetail.isEmpty)
            XCTAssertNotEqual(status.localizedSettingsDetail, status.rawValue)
            XCTAssertFalse(status.localizedSettingsDetail.contains("audit"))
        }
    }

    func testPermissionAssistArrowReducedMotionRestartsAndSnapsToComplete() {
        let animated = PermissionAssistArrowAnimationIdentity(
            direction: .right,
            reduceMotion: false
        )
        let reduced = PermissionAssistArrowAnimationIdentity(
            direction: .right,
            reduceMotion: true
        )

        XCTAssertNotEqual(animated, reduced)
        XCTAssertEqual(
            PermissionAssistArrowAnimationProgress.initialValue(
                reduceMotion: true
            ),
            1
        )
        XCTAssertEqual(
            PermissionAssistArrowAnimationProgress.initialValue(
                reduceMotion: false
            ),
            0
        )
    }

    func testProviderConfigurationCopyAvoidsInternalVocabulary() {
        let visibleDetails = [
            L10n.string("settings.providerConnectionRequirement.apiBaseURL.detail"),
            L10n.string("settings.providerConnectionRequirement.apiModel.detail")
        ]
        let internalTerms = ["metadata", "provider", "request"]

        for detail in visibleDetails {
            XCTAssertFalse(detail.isEmpty)
            for term in internalTerms {
                XCTAssertFalse(
                    detail.localizedCaseInsensitiveContains(term),
                    "User-facing provider setup copy exposed internal term: \(term)"
                )
            }
        }
    }

    func testPrimaryPermissionRowsDoNotExposeSigningDiagnostics() {
        let expected = L10n.string("settings.permissionActionRequest")
        XCTAssertEqual(
            PermissionRecommendedAction.stableSigningRecommended
                .localizedPrimaryRowDetail,
            expected
        )
        XCTAssertEqual(
            PermissionRecommendedAction.signingOrIdentityMismatch
                .localizedPrimaryRowDetail,
            expected
        )
        XCTAssertFalse(expected.localizedCaseInsensitiveContains("ad-hoc"))
        XCTAssertFalse(expected.localizedCaseInsensitiveContains("TCC"))
    }

    func testDesignSystemGalleryCatalogCoversFoundationMatrices() {
        XCTAssertEqual(
            BlocksDesignSystemGalleryCatalog.interactionStates,
            BlocksInteractionState.allCases
        )
        XCTAssertEqual(
            BlocksDesignSystemGalleryCatalog.surfaceLayers,
            BlocksSurfaceLayer.allCases
        )
        XCTAssertEqual(
            BlocksDesignSystemGalleryCatalog.densities,
            BlocksVisualTokens.Density.allCases
        )
        XCTAssertEqual(
            BlocksDesignSystemGalleryCatalog.localizationSamples.count,
            3
        )
        XCTAssertEqual(
            Set(SettingsDesignSystemGalleryCatalog.rowTypes),
            Set([
                "form", "toggle", "picker", "textField", "slider",
                "status", "navigation", "action", "danger", "state",
                "sheet",
            ])
        )
    }

    func testNotificationLevelsUseStableDefaultDismissPolicies() {
        XCTAssertEqual(
            BlocksNotificationLevel.success.defaultDismissPolicy,
            .automatic(after: 2.5)
        )
        XCTAssertEqual(
            BlocksNotificationLevel.info.defaultDismissPolicy,
            .automatic(after: 4)
        )
        XCTAssertEqual(BlocksNotificationLevel.warning.defaultDismissPolicy, .manual)
        XCTAssertEqual(BlocksNotificationLevel.error.defaultDismissPolicy, .manual)
    }

    func testNotificationActionForcesManualDismissal() {
        let descriptor = BlocksNotificationDescriptor(
            level: .success,
            title: "Saved",
            action: BlocksNotificationAction(title: "Open") {}
        )

        XCTAssertEqual(descriptor.dismissPolicy, .manual)
    }

    func testCompactConfirmationUsesShortAutomaticDismissalAndCustomIcon() {
        let descriptor = BlocksNotificationDescriptor(
            level: .success,
            title: "Favorited",
            presentationStyle: .compactConfirmation,
            systemImage: "star.fill"
        )

        XCTAssertEqual(descriptor.presentationStyle, .compactConfirmation)
        XCTAssertEqual(descriptor.systemImage, "star.fill")
        XCTAssertEqual(
            descriptor.dismissPolicy,
            .automatic(after: 2)
        )
        XCTAssertNil(descriptor.detail)
        XCTAssertNil(descriptor.action)
    }

    func testActivityNotificationUsesTargetedDismissalWithoutAffectingReplacement() {
        let state = BlocksNotificationPresentationState()
        state.present(
            BlocksNotificationDescriptor(
                level: .info,
                title: "Reading",
                showsIndeterminateProgress: true,
                deduplicationKey: "translation.selection.reading"
            )
        )

        XCTAssertTrue(
            state.current?.descriptor.showsIndeterminateProgress == true
        )
        state.present(
            BlocksNotificationDescriptor(
                level: .warning,
                title: "Network unavailable",
                deduplicationKey: "translation.network"
            )
        )
        state.dismiss(
            deduplicationKey: "translation.selection.reading"
        )

        XCTAssertEqual(
            state.current?.descriptor.deduplicationKey,
            "translation.network"
        )
    }

    func testHiddenNotificationHostDropsTransientButRetainsPersistentFailure() {
        let state = BlocksNotificationPresentationState(isHostVisible: false)

        state.present(BlocksNotificationDescriptor(level: .success, title: "Saved"))
        XCTAssertNil(state.current)

        state.present(BlocksNotificationDescriptor(level: .error, title: "Failed"))
        XCTAssertEqual(state.current?.descriptor.title, "Failed")

        state.setHostVisible(true)
        XCTAssertEqual(state.current?.descriptor.title, "Failed")
    }

    func testNotificationDeduplicationUpdatesCountWithoutReplayingPresentation() {
        let state = BlocksNotificationPresentationState()
        state.present(BlocksNotificationDescriptor(
            level: .warning,
            title: "First",
            deduplicationKey: "same"
        ))
        let revision = state.presentationRevision
        let identity = state.current?.id

        state.present(BlocksNotificationDescriptor(
            level: .warning,
            title: "Latest",
            deduplicationKey: "same"
        ))

        XCTAssertEqual(state.current?.id, identity)
        XCTAssertEqual(state.current?.descriptor.title, "Latest")
        XCTAssertEqual(state.current?.occurrenceCount, 2)
        XCTAssertEqual(state.presentationRevision, revision)
    }

    func testPersistentNotificationPreventsLowerPriorityReplacement() {
        let state = BlocksNotificationPresentationState()
        state.present(BlocksNotificationDescriptor(level: .error, title: "Failure"))
        state.present(BlocksNotificationDescriptor(level: .info, title: "FYI"))

        XCTAssertEqual(state.current?.descriptor.title, "Failure")
    }

    func testDeduplicatedNotificationCannotDowngradeExistingSeverity() {
        let state = BlocksNotificationPresentationState()
        state.present(BlocksNotificationDescriptor(
            level: .error,
            title: "Failure",
            deduplicationKey: "same"
        ))
        state.present(BlocksNotificationDescriptor(
            level: .warning,
            title: "Warning",
            deduplicationKey: "same"
        ))

        XCTAssertEqual(state.current?.descriptor.level, .error)
        XCTAssertEqual(state.current?.descriptor.title, "Failure")
        XCTAssertEqual(state.current?.occurrenceCount, 2)
    }

    func testNotificationAutoDismissCanPauseAndResume() async throws {
        let state = BlocksNotificationPresentationState()
        state.present(BlocksNotificationDescriptor(
            level: .info,
            title: "Short",
            dismissPolicy: .automatic(after: 0.08)
        ))
        try await Task.sleep(for: .milliseconds(25))
        state.setAutoDismissPaused(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(state.current)

        state.setAutoDismissPaused(false)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(state.current)
    }

    func testPresentingNotificationDoesNotMutateClipboardFocusState() {
        let focus = ClipboardPanelFocusCoordinator()
        focus.beginSession(sessionID: UUID())
        let target = focus.target
        let generation = focus.generation
        let state = BlocksNotificationPresentationState()

        state.present(BlocksNotificationDescriptor(level: .warning, title: "Warning"))

        XCTAssertEqual(focus.target, target)
        XCTAssertEqual(focus.generation, generation)
    }

    func testNotificationLayoutClampsCardToVisiblePanelWidth() {
        XCTAssertEqual(
            BlocksNotificationLayout.cardWidth(availableWidth: 500),
            300
        )
        XCTAssertEqual(
            BlocksNotificationLayout.cardWidth(availableWidth: 300),
            276
        )
        XCTAssertEqual(
            BlocksNotificationLayout.cardWidth(availableWidth: 260),
            236
        )
    }

    func testScreenNotificationFullyFitsA300PointVisibleFrame() {
        let visibleFrame = CGRect(x: -300, y: 24, width: 300, height: 876)
        let frame = BlocksNotificationLayout.screenFrame(
            size: CGSize(
                width: BlocksNotificationLayout.cardWidth(availableWidth: visibleFrame.width),
                height: 150
            ),
            visibleFrame: visibleFrame,
            avoiding: []
        )

        XCTAssertTrue(visibleFrame.contains(frame))
        XCTAssertEqual(frame.width, 276)
    }

    func testNotificationCardContentFitsNarrowPanelWidth() {
        let width: CGFloat = 236
        let state = BlocksNotificationPresentationState()
        state.present(
            BlocksNotificationDescriptor(
                level: .error,
                title: "A long failure title that must remain inside the panel",
                detail: "A detailed recovery explanation that is intentionally longer than the available width."
            )
        )
        guard let presentation = state.current else {
            return XCTFail("Expected a visible notification presentation.")
        }
        let hostingView = NSHostingView(
            rootView: BlocksNotificationCard(
                state: state,
                presentation: presentation,
                preferredWidth: width
            )
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: 180)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, width + 1)
    }

    func testPermissionAssistUsesNegativeCoordinateSecondaryScreenForSettingsCenter() {
        let mainVisibleFrame = CGRect(x: 0, y: 24, width: 1_440, height: 876)
        let secondaryVisibleFrame = CGRect(x: -1_280, y: 24, width: 1_280, height: 876)
        let settingsFrame = CGRect(x: -1_100, y: 180, width: 760, height: 620)

        XCTAssertEqual(
            PermissionAssistPlacementGeometry.visibleFrame(
                containingCenterOf: settingsFrame,
                screens: [
                    .init(
                        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                        visibleFrame: mainVisibleFrame
                    ),
                    .init(
                        frame: CGRect(x: -1_280, y: 0, width: 1_280, height: 900),
                        visibleFrame: secondaryVisibleFrame
                    ),
                ],
                fallback: mainVisibleFrame
            ),
            secondaryVisibleFrame
        )
    }

    func testPermissionAssistConvertsQuartzFrameOnVerticallyStackedDisplay() {
        let quartzWindow = CGRect(x: 220, y: -700, width: 760, height: 600)
        let converted = PermissionAssistPlacementGeometry.appKitFrame(
            forQuartzWindow: quartzWindow,
            coordinateSpaces: [
                .init(
                    quartzFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
                ),
                .init(
                    quartzFrame: CGRect(x: 0, y: -900, width: 1_440, height: 900),
                    appKitFrame: CGRect(x: 0, y: 900, width: 1_440, height: 900)
                ),
            ]
        )

        XCTAssertEqual(
            converted,
            CGRect(x: 220, y: 1_000, width: 760, height: 600)
        )
    }

    func testScreenNotificationStaysOnTargetScreenAndAvoidsChrome() {
        let visibleFrame = CGRect(x: 1_920, y: 24, width: 1_440, height: 876)
        let chrome = CGRect(x: 2_410, y: 760, width: 460, height: 110)
        let frame = BlocksNotificationLayout.screenFrame(
            size: CGSize(width: 324, height: 150),
            visibleFrame: visibleFrame,
            avoiding: [chrome]
        )

        XCTAssertTrue(visibleFrame.insetBy(dx: 12, dy: 12).contains(frame))
        XCTAssertFalse(frame.intersects(chrome))
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.5)
    }

    func testAnchoredNotificationPrefersAbovePanel() {
        let visible = CGRect(x: 0, y: 24, width: 1_200, height: 876)
        let anchor = CGRect(x: 300, y: 250, width: 600, height: 420)

        guard let frame = BlocksNotificationLayout.anchoredFrame(
            size: CGSize(width: 300, height: 96),
            anchorFrame: anchor,
            visibleFrame: visible
        ) else {
            return XCTFail("Expected a safe anchored notification position.")
        }

        XCTAssertEqual(
            frame.minY,
            anchor.maxY + BlocksNotificationLayout.anchoredGap
        )
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertFalse(frame.intersects(anchor))
    }

    func testAnchoredNotificationFallsBelowWithoutLeavingScreen() {
        let visible = CGRect(x: -1_400, y: 40, width: 1_300, height: 760)
        let anchor = CGRect(
            x: -1_160,
            y: 360,
            width: 820,
            height: 400
        )

        guard let frame = BlocksNotificationLayout.anchoredFrame(
            size: CGSize(width: 300, height: 110),
            anchorFrame: anchor,
            visibleFrame: visible
        ) else {
            return XCTFail("Expected a safe anchored notification position.")
        }

        XCTAssertEqual(
            frame.maxY,
            anchor.minY - BlocksNotificationLayout.anchoredGap
        )
        XCTAssertTrue(
            visible.insetBy(
                dx: BlocksNotificationLayout.horizontalScreenInset,
                dy: BlocksNotificationLayout.horizontalScreenInset
            ).contains(frame)
        )
        XCTAssertFalse(frame.intersects(anchor))
    }

    func testAnchoredNotificationReturnsNilWhenAnchorLeavesNoSafeExternalPosition() {
        let visible = CGRect(x: -1_200, y: 24, width: 1_200, height: 876)
        let anchor = visible.insetBy(dx: 12, dy: 12)

        XCTAssertNil(
            BlocksNotificationLayout.anchoredFrame(
                size: CGSize(width: 300, height: 104),
                anchorFrame: anchor,
                visibleFrame: visible
            )
        )
    }

    func testEditorNotificationMovesBelowOverlappingStatusBar() {
        XCTAssertEqual(
            BlocksNotificationLayout.editorTopInset(avoiding: .zero),
            12
        )
        XCTAssertEqual(
            BlocksNotificationLayout.editorTopInset(
                avoiding: CGRect(x: 20, y: 8, width: 240, height: 36)
            ),
            50
        )
    }

    func testSettingsSourceListHasFiveGroupsAndElevenUniqueRoutes() {
        XCTAssertEqual(SettingsSidebarSourceListModel.groups.count, 5)
        XCTAssertEqual(
            SettingsSidebarSourceListModel.groups.map(\.id),
            [.tools, .system, .intelligence, .data, .app]
        )
        XCTAssertEqual(SettingsSidebarSourceListModel.sections.count, 11)
        XCTAssertEqual(Set(SettingsSidebarSourceListModel.sections).count, 11)
        XCTAssertFalse(SettingsSidebarSourceListModel.sections.contains(.clipboardPrivacy))
        XCTAssertEqual(
            SettingsSidebarSourceListModel.groups.last?.sections,
            [.settings]
        )
        XCTAssertEqual(AppSection.settings.title, L10n.string("settings.general.title"))
    }

    func testSettingsSourceListGroupRowsAreNotSelectableAtMinimumWidth() {
        let sourceList = SettingsSourceListNativeView(
            frame: NSRect(x: 0, y: 0, width: 208, height: 150)
        )
        sourceList.layoutSubtreeIfNeeded()
        sourceList.update(selection: .settings)
        sourceList.layoutSubtreeIfNeeded()
        sourceList.scrollSelectionToVisible()

        XCTAssertEqual(sourceList.groupCount, 5)
        XCTAssertEqual(sourceList.routeCount, 11)
        XCTAssertEqual(sourceList.rowCount, 16)
        XCTAssertEqual((0 ..< sourceList.rowCount).filter(sourceList.isSelectable).count, 11)
        let groupRows = (0 ..< sourceList.rowCount).filter {
            !sourceList.isSelectable(row: $0)
        }
        XCTAssertEqual(groupRows.count, 5)
        XCTAssertTrue(groupRows.allSatisfy {
            sourceList.accessibilityRole(at: $0)?.rawValue == "AXHeading"
        })
        XCTAssertEqual(sourceList.selectedSection, .settings)
        XCTAssertTrue(sourceList.selectedRowIsVisible)
        XCTAssertEqual(sourceList.documentWidth, 208, accuracy: 0.5)
        XCTAssertFalse(sourceList.groupRowsFloat)
        XCTAssertTrue(sourceList.horizontalScrollingIsDisabled)
        XCTAssertTrue(sourceList.verticalScrollIndicatorIsHidden)
        XCTAssertEqual(sourceList.horizontalScrollOffset, 0, accuracy: 0.001)
    }

    func testSettingsSourceListClipViewRejectsHorizontalOrigins() {
        let clipView = SettingsVerticalOnlyClipView(
            frame: NSRect(x: 0, y: 0, width: 208, height: 150)
        )
        let constrained = clipView.constrainBoundsRect(
            NSRect(x: 42, y: 73, width: 208, height: 150)
        )

        XCTAssertEqual(constrained.origin.x, 0, accuracy: 0.001)
    }

    func testSettingsSourceListProgrammaticSelectionDoesNotOverrideInitialRoute() {
        let sourceList = SettingsSourceListNativeView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 520)
        )
        var reportedSelections: [AppSection] = []
        sourceList.onSelectionChange = { reportedSelections.append($0) }

        sourceList.update(selection: .settings)
        sourceList.layoutSubtreeIfNeeded()

        XCTAssertEqual(sourceList.selectedSection, .settings)
        XCTAssertTrue(reportedSelections.isEmpty)
    }

    func testCLIInstallerAtomicallyInstallsAndReplacesExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksCLIInstaller.\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("source-blocks")
        let destinationURL = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("blocks")

        try Data("first build".utf8).write(to: sourceURL)
        try BlocksCLIInstaller.install(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: destinationURL.path
            )
        )
        XCTAssertTrue(
            BlocksCLIInstaller.isCurrentInstallation(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )

        try Data("second build".utf8).write(to: sourceURL)
        XCTAssertFalse(
            BlocksCLIInstaller.isCurrentInstallation(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
        try BlocksCLIInstaller.install(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationURL),
            Data("second build".utf8)
        )
        try FileManager.default.removeItem(at: destinationURL)
        XCTAssertEqual(
            BlocksCLIInstaller.installationState(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            ),
            .notInstalled
        )
    }

    func testDistributionChannelsExposeLiteralCapabilityBoundaries() {
        XCTAssertTrue(DistributionChannel.directBeta.supportsCLIAndActionBroker)
        XCTAssertTrue(DistributionChannel.directBeta.supportsSelectionHelper)
        XCTAssertTrue(DistributionChannel.directBeta.supportsExternalPlugins)
        XCTAssertFalse(DistributionChannel.directBeta.usesSystemManagedUpdates)

        XCTAssertFalse(DistributionChannel.appStoreBeta.supportsCLIAndActionBroker)
        XCTAssertFalse(DistributionChannel.appStoreBeta.supportsSelectionHelper)
        XCTAssertFalse(DistributionChannel.appStoreBeta.supportsExternalPlugins)
        XCTAssertTrue(DistributionChannel.appStoreBeta.usesSystemManagedUpdates)
    }

    func testDiagnosticExportWritesOnlyRedactedAuditFields() async throws {
        let permission = PermissionDiagnosticSnapshot(
            kind: .screenRecording,
            granted: false,
            bundleID: "app.blocks.test",
            appPath: "/private/sensitive/path",
            signatureKind: "adhoc",
            teamID: "SENSITIVE_TEAM",
            hasUsageDescription: true,
            lastCheckedAt: Date(timeIntervalSince1970: 10),
            recommendedAction: .stableSigningRecommended,
            matchingRunningAppPaths: ["/private/other/path"],
            identityIssue: .adHocSigned
        )
        let snapshot = PermissionStateSnapshot(
            screenRecording: permission,
            accessibility: PermissionDiagnosticSnapshot(
                kind: .accessibility,
                granted: true,
                bundleID: permission.bundleID,
                appPath: permission.appPath,
                signatureKind: permission.signatureKind,
                teamID: permission.teamID,
                hasUsageDescription: true,
                lastCheckedAt: permission.lastCheckedAt,
                recommendedAction: .granted,
                matchingRunningAppPaths: permission.matchingRunningAppPaths,
                identityIssue: .none
            ),
            inputMonitoring: PermissionDiagnosticSnapshot(
                kind: .inputMonitoring,
                granted: false,
                bundleID: permission.bundleID,
                appPath: permission.appPath,
                signatureKind: permission.signatureKind,
                teamID: permission.teamID,
                hasUsageDescription: true,
                lastCheckedAt: permission.lastCheckedAt,
                recommendedAction: .requestInSystemSettings,
                matchingRunningAppPaths: permission.matchingRunningAppPaths,
                identityIssue: .none
            ),
            capturedAt: permission.lastCheckedAt
        )
        let event = ProviderAuditEvent(
            id: "SENSITIVE_AUDIT_ID",
            createdAt: Date(timeIntervalSince1970: 20),
            kind: .translationRuntime,
            providerSummary: "https://private.example SENSITIVE_PROVIDER",
            confirmationLevel: "SENSITIVE_CONFIRMATION",
            sourceSummary: "SENSITIVE_CLIPBOARD_CONTENT",
            resultSummary: "SENSITIVE_RESULT",
            auditID: "SENSITIVE_AUDIT_ID",
            warnings: ["SENSITIVE_WARNING"]
        )

        let report = DiagnosticsExportService.makeReport(
            permissionSnapshot: snapshot,
            providerAuditEvents: [event],
            now: Date(timeIntervalSince1970: 30)
        )
        let directoryURL = try makeDiagnosticsExportFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("diagnostics.json")

        try await DiagnosticsExportService.writeReport(report, to: destinationURL)

        let data = try Data(contentsOf: destinationURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("translation_runtime"))
        XCTAssertTrue(text.contains("\"warningCount\" : 1"))
        for sensitiveValue in [
            "SENSITIVE_AUDIT_ID",
            "SENSITIVE_PROVIDER",
            "SENSITIVE_CONFIRMATION",
            "SENSITIVE_CLIPBOARD_CONTENT",
            "SENSITIVE_RESULT",
            "SENSITIVE_WARNING",
            "SENSITIVE_TEAM",
            "/private/sensitive/path",
        ] {
            XCTAssertFalse(text.contains(sensitiveValue))
        }
    }

    func testDiagnosticExportCancellationBeforeCommitLeavesNewDestinationAbsentAndCleansTemporaryFile() async throws {
        let directoryURL = try makeDiagnosticsExportFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("new-diagnostics.json")
        let gate = DiagnosticsExportCommitGate()
        let exportTask = Task {
            try await DiagnosticsExportService.writeReport(
                diagnosticsExportTestReport(),
                to: destinationURL,
                beforeCommit: { gate.pauseBeforeCommit() }
            )
        }

        let reachedCommit = await Task.detached(priority: .utility) {
            gate.waitUntilPaused(timeout: 2)
        }.value
        XCTAssertTrue(reachedCommit)
        exportTask.cancel()
        gate.resume()

        do {
            try await exportTask.value
            XCTFail("Cancellation before commit must not report export success")
        } catch is CancellationError {
            // Expected: the final destination was not committed.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(diagnosticsExportTemporaryFiles(in: directoryURL).isEmpty)
    }

    func testDiagnosticExportCancellationBeforeCommitPreservesExistingDestination() async throws {
        let directoryURL = try makeDiagnosticsExportFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("existing-diagnostics.json")
        let originalData = Data("previous export".utf8)
        try originalData.write(to: destinationURL, options: .atomic)
        let gate = DiagnosticsExportCommitGate()
        let exportTask = Task {
            try await DiagnosticsExportService.writeReport(
                diagnosticsExportTestReport(),
                to: destinationURL,
                beforeCommit: { gate.pauseBeforeCommit() }
            )
        }

        let reachedCommit = await Task.detached(priority: .utility) {
            gate.waitUntilPaused(timeout: 2)
        }.value
        XCTAssertTrue(reachedCommit)
        exportTask.cancel()
        gate.resume()

        do {
            try await exportTask.value
            XCTFail("Cancellation before commit must not report export success")
        } catch is CancellationError {
            // Expected: the existing destination remains intact.
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), originalData)
        XCTAssertTrue(diagnosticsExportTemporaryFiles(in: directoryURL).isEmpty)
    }

    func testDiagnosticExportDoesNotOverwriteDestinationCreatedAfterSaveConfirmation() async throws {
        let directoryURL = try makeDiagnosticsExportFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("raced-diagnostics.json")
        let laterWriterData = Data("later writer".utf8)
        let gate = DiagnosticsExportCommitGate()
        let exportTask = Task {
            try await DiagnosticsExportService.writeReport(
                diagnosticsExportTestReport(),
                to: destinationURL,
                beforeCommit: { gate.pauseBeforeCommit() }
            )
        }

        let reachedCommit = await Task.detached(priority: .utility) {
            gate.waitUntilPaused(timeout: 2)
        }.value
        XCTAssertTrue(reachedCommit)
        try laterWriterData.write(to: destinationURL, options: .atomic)
        gate.resume()

        do {
            try await exportTask.value
            XCTFail("A destination created after confirmation must fail closed")
        } catch let error as DiagnosticsExportService.ExportError {
            XCTAssertEqual(error, .destinationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), laterWriterData)
        XCTAssertTrue(diagnosticsExportTemporaryFiles(in: directoryURL).isEmpty)
    }

    func testDiagnosticExportDoesNotOverwriteExistingDestinationReplacedBeforeCommit() async throws {
        let directoryURL = try makeDiagnosticsExportFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("existing-raced-diagnostics.json")
        try Data("confirmed version".utf8).write(to: destinationURL, options: .atomic)
        let laterWriterData = Data("later replacement".utf8)
        let gate = DiagnosticsExportCommitGate()
        let exportTask = Task {
            try await DiagnosticsExportService.writeReport(
                diagnosticsExportTestReport(),
                to: destinationURL,
                beforeCommit: { gate.pauseBeforeCommit() }
            )
        }

        let reachedCommit = await Task.detached(priority: .utility) {
            gate.waitUntilPaused(timeout: 2)
        }.value
        XCTAssertTrue(reachedCommit)
        try laterWriterData.write(to: destinationURL, options: .atomic)
        gate.resume()

        do {
            try await exportTask.value
            XCTFail("A replaced destination must fail closed")
        } catch let error as DiagnosticsExportService.ExportError {
            XCTAssertEqual(error, .destinationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), laterWriterData)
        XCTAssertTrue(diagnosticsExportTemporaryFiles(in: directoryURL).isEmpty)
    }

    func testPermissionAssistRestoresCapturedSettingsWindowForEveryTerminalPath() {
        for terminalPath in ["success", "cancel", "timeout", "settings-not-found", "shutdown"] {
            let window = permissionAssistTestWindow()
            defer { closePermissionAssistTestWindow(window) }
            let host = PermissionAssistWindowRestoreTestHost(
                windows: [window],
                mainWindow: window,
                keyWindow: window
            )
            let session = PermissionAssistMainWindowRestoreSession(host: host.host)

            let generation = session.begin()
            XCTAssertFalse(window.isVisible, "\(terminalPath) must hide only while guidance is active")

            session.restore(for: generation)

            XCTAssertTrue(window.isVisible, "\(terminalPath) must restore the captured settings window")
            XCTAssertEqual(host.orderOutCount, 1)
            XCTAssertEqual(host.orderFrontCount, 1)
            XCTAssertEqual(host.activationCount, 1)
            XCTAssertEqual(host.makeKeyCount, 1)
        }
    }

    func testPermissionAssistDoesNotRevivePanelWhileApplicationIsHidden() throws {
        var applicationIsHidden = false
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { CGRect(x: 160, y: 160, width: 720, height: 560) },
            isSystemSettingsRunning: { true },
            isApplicationHidden: { applicationIsHidden },
            openSystemSettings: { _ in }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording)
        presenter.monitorPermissionFlowForTesting()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertTrue(panel.isVisible)

        applicationIsHidden = true
        panel.orderOut(nil)
        presenter.monitorPermissionFlowForTesting()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(presenter.panelForTesting === panel)

        applicationIsHidden = false
        presenter.monitorPermissionFlowForTesting()
        XCTAssertTrue(panel.isVisible)
    }

    func testPermissionAssistKeepsWindowNotFoundFailureVisibleUntilUserClosesIt() throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var flowEndedCount = 0
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            now: { currentDate },
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { nil },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording) {
            flowEndedCount += 1
        }
        XCTAssertFalse(settingsWindow.isVisible)

        currentDate.addTimeInterval(8)
        presenter.monitorPermissionFlowForTesting()

        let assistPanel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertTrue(assistPanel.isVisible)
        XCTAssertEqual(presenter.sessionForTesting?.state, .failed)
        XCTAssertEqual(
            presenter.sessionForTesting?.lastFailureReason,
            L10n.string("permission.assist.settingsWindowNotFound")
        )
        XCTAssertFalse(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 0)
        XCTAssertEqual(flowEndedCount, 0)

        assistPanel.close()

        XCTAssertFalse(assistPanel.isVisible)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 1)
        XCTAssertEqual(flowEndedCount, 1)
    }

    func testPermissionAssistUsesSharedOpacityMotionWithoutUtilityTransform() throws {
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let motion = PermissionAssistPanelMotionSpy()
        let coordinator = BlocksFloatingPanelPresentationCoordinator(
            animationDriver: motion.driver
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { CGRect(x: 160, y: 160, width: 720, height: 560) },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in },
            panelPresentationCoordinator: coordinator
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording)
        presenter.monitorPermissionFlowForTesting()

        let panel = try XCTUnwrap(presenter.panelForTesting)
        let visibleFrame = panel.frame
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(
            motion.calls,
            [.init(role: .panel, phase: .insertion, alphaValue: 1)]
        )

        presenter.shutdown()

        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertEqual(panel.frame, visibleFrame)
        XCTAssertEqual(
            motion.calls,
            [
                .init(role: .panel, phase: .insertion, alphaValue: 1),
                .init(role: .confirmation, phase: .removal, alphaValue: 0),
            ]
        )
    }

    func testPermissionAssistReplacementInvalidatesPendingPanelDismissal() throws {
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let motion = PermissionAssistDeferredMotionSpy()
        let coordinator = BlocksFloatingPanelPresentationCoordinator(
            animationDriver: motion.driver
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { CGRect(x: 160, y: 160, width: 720, height: 560) },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in },
            panelPresentationCoordinator: coordinator
        )
        defer {
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording)
        presenter.monitorPermissionFlowForTesting()
        motion.completeNext()
        XCTAssertEqual(presenter.sessionForTesting?.kind, .screenRecording)

        presenter.shutdown()
        XCTAssertEqual(motion.calls.map(\.phase), [.insertion, .removal])

        presenter.present(kind: .accessibility)
        presenter.monitorPermissionFlowForTesting()

        XCTAssertEqual(presenter.sessionForTesting?.kind, .accessibility)
        XCTAssertEqual(
            motion.calls.map(\.phase),
            [.insertion, .removal, .insertion]
        )
        // Complete the stale removal after the replacement is already shown.
        // Its coordinator generation must reject the old completion.
        motion.completeNext()
        XCTAssertEqual(presenter.sessionForTesting?.kind, .accessibility)
        XCTAssertTrue(try XCTUnwrap(presenter.panelForTesting).isVisible)
        motion.completeNext()

        presenter.shutdown()
        XCTAssertEqual(
            motion.calls.map(\.phase),
            [.insertion, .removal, .insertion, .removal]
        )
        motion.completeNext()
        XCTAssertNil(presenter.sessionForTesting)
        XCTAssertTrue(settingsWindow.isVisible)
    }

    func testBlocksAppKitMotionReduceMotionOnlyAnimatesOpacity() {
        let panel = NSPanel(
            contentRect: CGRect(x: -4_000, y: -4_000, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView?.wantsLayer = true
        let stableFrame = panel.frame
        var completed = false
        let completion = expectation(description: "reduced-motion opacity animation completes")
        defer { closePermissionAssistTestWindow(panel) }

        BlocksAppKitMotion.animate(
            window: panel,
            to: stableFrame,
            alphaValue: 0,
            role: .panel,
            phase: .removal,
            reduceMotion: true
        ) {
            completed = true
            completion.fulfill()
        }

        XCTAssertEqual(panel.frame, stableFrame)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertFalse(
            panel.contentView?.layer?.animationKeys()?.contains(where: {
                $0.localizedCaseInsensitiveContains("transform")
            }) ?? false
        )
        wait(for: [completion], timeout: 1)
        XCTAssertTrue(completed)
        XCTAssertEqual(panel.alphaValue, 0)
    }

    func testPermissionAssistGrantDismissesThroughRealBlocksAppKitMotion() throws {
        try assertPermissionAssistGrantDismissesThroughRealBlocksAppKitMotion(
            reduceMotion: false
        )
    }

    func testPermissionAssistGrantDismissesThroughRealBlocksAppKitMotionWithReduceMotion() throws {
        try assertPermissionAssistGrantDismissesThroughRealBlocksAppKitMotion(
            reduceMotion: true
        )
    }

    private func assertPermissionAssistGrantDismissesThroughRealBlocksAppKitMotion(
        reduceMotion: Bool
    ) throws {
        var granted = false
        var flowEndedCount = 0
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let coordinator = BlocksFloatingPanelPresentationCoordinator(
            animationDriver: { window, frame, alphaValue, role, phase, completion in
                BlocksAppKitMotion.animate(
                    window: window,
                    to: frame,
                    alphaValue: alphaValue,
                    role: role,
                    phase: phase,
                    reduceMotion: reduceMotion,
                    completion: completion
                )
            }
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in granted },
            systemSettingsWindowFrame: { CGRect(x: 160, y: 160, width: 720, height: 560) },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in },
            panelPresentationCoordinator: coordinator
        )

        let flowEnded = expectation(
            description: "permission-assist flow ends after real dismissal"
        )
        presenter.present(kind: .screenRecording) {
            flowEndedCount += 1
            flowEnded.fulfill()
        }
        presenter.monitorPermissionFlowForTesting()
        let panel = try XCTUnwrap(presenter.panelForTesting)
        defer {
            presenter.shutdown()
            closePermissionAssistRealMotionFixture(panel)
            closePermissionAssistRealMotionFixture(settingsWindow)
        }

        XCTAssertTrue(panel.isVisible)
        granted = true
        presenter.completeFromUserActionForTesting()

        wait(for: [flowEnded], timeout: 2)

        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertNil(presenter.sessionForTesting)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 1)
        XCTAssertEqual(flowEndedCount, 1)
    }

    private func closePermissionAssistRealMotionFixture(_ window: NSWindow) {
        let didClose = expectation(description: "permission-assist fixture closes")
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            didClose.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        window.animationBehavior = .none
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        wait(for: [didClose], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func testPermissionAssistTerminalCallbackCanStartANewSession() {
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        var callbackCount = 0
        var presenter: PermissionAssistPanelPresenter!
        presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { nil },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording) {
            callbackCount += 1
            presenter.present(kind: .accessibility) {
                callbackCount += 1
            }
        }
        presenter.shutdown()

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(presenter.sessionForTesting?.kind, .accessibility)
        XCTAssertFalse(settingsWindow.isVisible)
        XCTAssertEqual(host.orderOutCount, 2)
        XCTAssertEqual(host.orderFrontCount, 1)

        presenter.shutdown()

        XCTAssertEqual(callbackCount, 2)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 2)
    }

    func testPermissionAssistReplacementDoesNotOverwriteSessionStartedByOldCallback() {
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        var openedSettingsURLs: [URL] = []
        var presenter: PermissionAssistPanelPresenter!
        presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { nil },
            isSystemSettingsRunning: { true },
            openSystemSettings: { openedSettingsURLs.append($0) }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording) {
            presenter.present(kind: .accessibility)
        }
        presenter.present(kind: .inputMonitoring)

        XCTAssertEqual(presenter.sessionForTesting?.kind, .accessibility)
        XCTAssertEqual(
            openedSettingsURLs,
            [
                PermissionAssistKind.screenRecording.settingsURL!,
                PermissionAssistKind.accessibility.settingsURL!,
            ]
        )
    }

    func testPermissionAssistFailedCompletionKeepsCallbackForLaterGrantedMonitor() {
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        var granted = false
        var flowEndedCount = 0
        let motion = PermissionAssistDeferredMotionSpy()
        let coordinator = BlocksFloatingPanelPresentationCoordinator(
            animationDriver: motion.driver
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in granted },
            systemSettingsWindowFrame: { nil },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in },
            panelPresentationCoordinator: coordinator
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording) {
            flowEndedCount += 1
        }
        presenter.completeFromUserActionForTesting()
        motion.completeNext()

        XCTAssertEqual(presenter.sessionForTesting?.kind, .screenRecording)
        XCTAssertEqual(presenter.sessionForTesting?.state, .failed)
        XCTAssertEqual(flowEndedCount, 0)
        XCTAssertFalse(settingsWindow.isVisible)

        granted = true
        presenter.monitorPermissionFlowForTesting()

        XCTAssertEqual(presenter.sessionForTesting?.state, .granted)
        XCTAssertEqual(flowEndedCount, 0)
        XCTAssertFalse(settingsWindow.isVisible)

        motion.completeNext()
        presenter.monitorPermissionFlowForTesting()

        XCTAssertNil(presenter.sessionForTesting)
        XCTAssertEqual(flowEndedCount, 1)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 1)
    }

    func testPermissionAssistOverallTimeoutStaysVisibleUntilUserCloses() throws {
        var currentDate = Date(timeIntervalSince1970: 2_000)
        var flowEndedCount = 0
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            now: { currentDate },
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { nil },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .inputMonitoring) {
            flowEndedCount += 1
        }
        currentDate.addTimeInterval(90)
        presenter.monitorPermissionFlowForTesting()
        presenter.monitorPermissionFlowForTesting()

        let panel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertEqual(presenter.sessionForTesting?.state, .timedOut)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(panel.contentView)
        XCTAssertFalse(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 0)
        XCTAssertEqual(flowEndedCount, 0)

        panel.close()

        XCTAssertNil(presenter.sessionForTesting)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(host.orderFrontCount, 1)
        XCTAssertEqual(flowEndedCount, 1)
    }

    func testPermissionAssistRestoreIsIdempotentAndDoesNotReactivateNonKeyWindow() {
        let window = permissionAssistTestWindow()
        defer { closePermissionAssistTestWindow(window) }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [window],
            mainWindow: window,
            keyWindow: nil
        )
        host.mainWindowWasPrimary = false
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let generation = session.begin()
        session.restore(for: generation)
        session.restore(for: generation)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(host.orderFrontCount, 1)
        XCTAssertEqual(host.activationCount, 0)
        XCTAssertEqual(host.makeKeyCount, 0)
    }

    func testPermissionAssistDoesNotRestoreSettingsWindowClosedDuringGuidance() {
        let window = permissionAssistTestWindow()
        window.animationBehavior = .documentWindow
        defer { closePermissionAssistTestWindow(window) }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [window],
            mainWindow: window,
            keyWindow: window
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let generation = session.begin()
        host.windows = []
        session.restore(for: generation)

        XCTAssertEqual(host.orderFrontCount, 0)
        XCTAssertEqual(host.activationCount, 0)
        XCTAssertEqual(host.makeKeyCount, 0)
        XCTAssertEqual(window.animationBehavior, .documentWindow)
    }

    func testPermissionAssistWillCloseObserverPreventsRestoringClosedSettingsWindow() {
        let window = permissionAssistTestWindow()
        window.animationBehavior = .documentWindow
        defer { closePermissionAssistTestWindow(window) }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [window],
            mainWindow: window,
            keyWindow: window
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let generation = session.begin()
        window.close()
        session.restore(for: generation)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.orderFrontCount, 0)
        XCTAssertEqual(host.activationCount, 0)
        XCTAssertEqual(host.makeKeyCount, 0)
        XCTAssertEqual(window.animationBehavior, .documentWindow)
    }

    func testPermissionAssistIgnoresLateRestoreFromPreviousGeneration() {
        let first = permissionAssistTestWindow()
        let second = permissionAssistTestWindow()
        defer {
            closePermissionAssistTestWindow(first)
            closePermissionAssistTestWindow(second)
        }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [first, second],
            mainWindow: first,
            keyWindow: first
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let firstGeneration = session.begin()
        host.mainWindow = second
        host.keyWindow = second
        let secondGeneration = session.begin()

        session.restore(for: firstGeneration)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)

        session.restore(for: secondGeneration)
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(host.orderedFrontWindows, [second])
    }

    func testPermissionAssistLeavesNonMainFloatingPanelsUntouched() {
        let mainWindow = permissionAssistTestWindow()
        let floatingPanel = NSPanel(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 180, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.level = .floating
        floatingPanel.animationBehavior = .none
        floatingPanel.isReleasedWhenClosed = false
        mainWindow.orderFront(nil)
        floatingPanel.orderFront(nil)
        defer {
            closePermissionAssistTestWindow(mainWindow)
            closePermissionAssistTestWindow(floatingPanel)
        }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [mainWindow, floatingPanel],
            mainWindow: mainWindow,
            keyWindow: mainWindow
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let generation = session.begin()

        XCTAssertFalse(mainWindow.isVisible)
        XCTAssertTrue(floatingPanel.isVisible)
        session.restore(for: generation)
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertTrue(floatingPanel.isVisible)
        XCTAssertEqual(host.orderedOutWindows, [mainWindow])
        XCTAssertEqual(host.orderedFrontWindows, [mainWindow])
    }

    func testPermissionAssistRestoresAnimationBehaviorAfterRestoreOperations() {
        let window = permissionAssistTestWindow()
        window.animationBehavior = .documentWindow
        defer { closePermissionAssistTestWindow(window) }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [window],
            mainWindow: window,
            keyWindow: window
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let generation = session.begin()
        XCTAssertEqual(window.animationBehavior, .none)

        session.restore(for: generation)

        XCTAssertEqual(window.animationBehavior, .documentWindow)
        XCTAssertEqual(
            host.operationLog,
            [
                "animation.none", "orderOut", "setFrame", "orderFront",
                "activate", "makeKey", "animation.restore",
            ]
        )
    }

    func testPermissionAssistNewGenerationRestoresPreviousAnimationBehavior() {
        let first = permissionAssistTestWindow()
        let second = permissionAssistTestWindow()
        first.animationBehavior = .documentWindow
        second.animationBehavior = .utilityWindow
        defer {
            closePermissionAssistTestWindow(first)
            closePermissionAssistTestWindow(second)
        }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [first, second],
            mainWindow: first,
            keyWindow: first
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        let firstGeneration = session.begin()
        host.mainWindow = second
        host.keyWindow = second
        let secondGeneration = session.begin()

        XCTAssertEqual(first.animationBehavior, .documentWindow)
        XCTAssertEqual(second.animationBehavior, .none)
        session.restore(for: firstGeneration)
        session.restore(for: secondGeneration)
        XCTAssertEqual(second.animationBehavior, .utilityWindow)
    }

    func testPermissionAssistWindowRestoreStressRestoresBehaviorAndClosesFixture() {
        let window = permissionAssistTestWindow()
        window.animationBehavior = .documentWindow
        let windowDidClose = expectation(description: "stress-test window closes")
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            windowDidClose.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(closeObserver) }
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [window],
            mainWindow: window,
            keyWindow: window
        )
        let session = PermissionAssistMainWindowRestoreSession(host: host.host)

        for _ in 0..<500 {
            autoreleasepool {
                let generation = session.begin()
                session.restore(for: generation)
                XCTAssertEqual(window.animationBehavior, .documentWindow)
            }
        }

        // The assertion above covers the production restore contract. Close
        // the synthetic fixture without introducing a separate AppKit window
        // transform that can spill into the next XCTest in the shared host.
        window.animationBehavior = .none
        window.close()
        wait(for: [windowDidClose], timeout: 1)
        XCTAssertFalse(window.isVisible)
    }

    func testPermissionRestartReportsFailureWithoutTerminatingUnlessLaunchSucceeds() {
        let launchError = NSError(domain: "AppAppearanceTests", code: 1)
        let launchResults: [(NSRunningApplication?, Error?, PermissionRestartResult)] = [
            (nil, launchError, .failed),
            (nil, nil, .failed),
            (NSRunningApplication.current, nil, .launched),
        ]

        for (application, error, expectedResult) in launchResults {
            var receivedResult: PermissionRestartResult?
            var terminatorCallCount = 0
            let actions = DefaultPermissionSystemActions(
                applicationLauncher: { completion in
                    completion(application, error)
                },
                applicationTerminator: {
                    terminatorCallCount += 1
                }
            )

            actions.restartForPermissionRefresh { receivedResult = $0 }

            XCTAssertEqual(receivedResult, expectedResult)
            XCTAssertEqual(
                terminatorCallCount,
                expectedResult == .launched ? 1 : 0,
                "The current app must terminate only after a replacement app launches."
            )
        }
    }

    func testPermissionAssistMonitorUpdatesPreserveHostingViewAndFirstResponder() throws {
        var settingsFrame = CGRect(x: 160, y: 160, width: 720, height: 560)
        let settingsWindow = permissionAssistTestWindow()
        let host = PermissionAssistWindowRestoreTestHost(
            windows: [settingsWindow],
            mainWindow: settingsWindow,
            keyWindow: settingsWindow
        )
        let presenter = PermissionAssistPanelPresenter(
            mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession(host: host.host),
            permissionGranted: { _ in false },
            systemSettingsWindowFrame: { settingsFrame },
            isSystemSettingsRunning: { true },
            openSystemSettings: { _ in }
        )
        defer {
            presenter.shutdown()
            presenter.panelForTesting?.close()
            closePermissionAssistTestWindow(settingsWindow)
        }

        presenter.present(kind: .screenRecording)
        presenter.monitorPermissionFlowForTesting()

        let panel = try XCTUnwrap(presenter.panelForTesting)
        let originalContentView = try XCTUnwrap(panel.contentView)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 220)
        XCTAssertLessThanOrEqual(panel.frame.height, 360)
        panel.makeKeyAndOrderFront(nil)
        let firstResponder = try XCTUnwrap(firstDescendant(of: NSButton.self, in: originalContentView))
        XCTAssertTrue(panel.makeFirstResponder(firstResponder))
        XCTAssertTrue(panel.firstResponder === firstResponder)

        settingsFrame = CGRect(x: 260, y: 200, width: 720, height: 560)
        presenter.monitorPermissionFlowForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertTrue(panel.contentView === originalContentView)
        XCTAssertTrue(panel.firstResponder === firstResponder)
    }

    func testPermissionAssistLongFailureKeepsFooterOutsideScrollableContent() throws {
        let session = PermissionAssistSession(
            kind: .screenRecording,
            state: .failed,
            startedAt: Date(),
            systemSettingsFrame: nil,
            arrowDirection: .left,
            lastFailureReason: String(repeating: "A detailed failure and recovery instruction. ", count: 24)
        )
        let sessionModel = PermissionAssistPanelSessionModel(
            session: session,
            appURL: Bundle.main.bundleURL
        )
        let hostingView = NSHostingView(
            rootView: PermissionAssistPanelView(
                sessionModel: sessionModel,
                onCompleted: {},
                onClose: {}
            )
        )
        let panel = NSPanel(
            contentRect: CGRect(x: -4_000, y: -4_000, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        hostingView.frame = panel.contentView!.bounds
        panel.orderFrontRegardless()
        defer { closePermissionAssistTestWindow(panel) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertGreaterThanOrEqual(panel.frame.height, 220)
        XCTAssertLessThanOrEqual(panel.frame.height, 360)
        let scrollView = try XCTUnwrap(firstDescendant(of: NSScrollView.self, in: hostingView))
        let scrollFrame = scrollView.convert(scrollView.bounds, to: hostingView)
        XCTAssertLessThan(scrollFrame.height, hostingView.bounds.height)
        XCTAssertGreaterThan(
            try XCTUnwrap(scrollView.documentView).frame.height,
            scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThan(scrollFrame.minY, hostingView.bounds.minY)
        XCTAssertLessThan(scrollFrame.maxY, hostingView.bounds.maxY)
    }
}

private func diagnosticsExportTestReport() -> BlocksDiagnosticReport {
    BlocksDiagnosticReport(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1),
        application: .init(
            releaseName: "Blocks",
            version: "1.0",
            build: "1",
            channel: "test",
            bundleIdentifier: "app.blocks.tests"
        ),
        system: .init(operatingSystem: "testOS", architecture: "test"),
        permissions: .init(
            screenRecordingGranted: false,
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            signatureKind: "test",
            screenRecordingAction: "none",
            accessibilityAction: "none",
            inputMonitoringAction: "none"
        ),
        redactedAuditEvents: [],
        excludedData: []
    )
}

private func makeDiagnosticsExportFixtureDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BlocksDiagnosticsExportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    return directoryURL
}

private func diagnosticsExportTemporaryFiles(in directoryURL: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
    ))?.filter {
        $0.lastPathComponent.hasPrefix(".")
            && $0.lastPathComponent.contains(".diagnostics-")
            && $0.pathExtension == "tmp"
    } ?? []
}

private final class DiagnosticsExportCommitGate: @unchecked Sendable {
    private let reachedCommit = DispatchSemaphore(value: 0)
    private let resumeCommit = DispatchSemaphore(value: 0)

    func pauseBeforeCommit() {
        reachedCommit.signal()
        resumeCommit.wait()
    }

    func waitUntilPaused(timeout: TimeInterval) -> Bool {
        reachedCommit.wait(timeout: .now() + timeout) == .success
    }

    func resume() {
        resumeCommit.signal()
    }
}

@MainActor
private final class ShortcutRecorderMonitorSpy {
    private(set) var handlers: [(NSEvent) -> NSEvent?] = []
    private(set) var removedMonitorCount = 0
    private(set) var activeMonitorCount = 0

    func install(
        _ mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        XCTAssertEqual(mask, .keyDown)
        handlers.append(handler)
        activeMonitorCount += 1
        return NSObject()
    }

    func remove(_ monitor: Any) {
        removedMonitorCount += 1
        activeMonitorCount -= 1
    }
}

@MainActor
private func shortcutRecorderTestKeyEvent() -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0
    ) else {
        fatalError("Unable to create a shortcut recorder test key event")
    }
    return event
}

@MainActor
private final class PermissionAssistPanelMotionSpy {
    struct Call: Equatable {
        let role: BlocksMotionRole
        let phase: BlocksMotionPhase
        let alphaValue: CGFloat
    }

    private(set) var calls: [Call] = []

    var driver: BlocksFloatingPanelPresentationCoordinator.AnimationDriver {
        { [weak self] window, frame, alphaValue, role, phase, completion in
            XCTAssertEqual(window.frame, frame)
            self?.calls.append(
                Call(role: role, phase: phase, alphaValue: alphaValue)
            )
            window.alphaValue = alphaValue
            completion()
        }
    }
}

@MainActor
private final class PermissionAssistDeferredMotionSpy {
    struct Call: Equatable {
        let phase: BlocksMotionPhase
        let alphaValue: CGFloat
    }

    private(set) var calls: [Call] = []
    private var completions: [() -> Void] = []

    var driver: BlocksFloatingPanelPresentationCoordinator.AnimationDriver {
        { [weak self] window, _, alphaValue, _, phase, completion in
            self?.calls.append(.init(phase: phase, alphaValue: alphaValue))
            window.alphaValue = alphaValue
            self?.completions.append(completion)
        }
    }

    func completeNext() {
        XCTAssertFalse(
            completions.isEmpty,
            "Expected a pending permission-assist motion completion"
        )
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}

@MainActor
private final class PermissionAssistWindowRestoreTestHost {
    var windows: [NSWindow]
    var mainWindow: NSWindow?
    var keyWindow: NSWindow?
    var mainWindowWasPrimary = true
    var keyWindowWasPrimary = true
    private(set) var orderOutCount = 0
    private(set) var orderFrontCount = 0
    private(set) var activationCount = 0
    private(set) var makeKeyCount = 0
    private(set) var orderedOutWindows: [NSWindow] = []
    private(set) var orderedFrontWindows: [NSWindow] = []
    private(set) var operationLog: [String] = []

    init(
        windows: [NSWindow],
        mainWindow: NSWindow?,
        keyWindow: NSWindow?
    ) {
        self.windows = windows
        self.mainWindow = mainWindow
        self.keyWindow = keyWindow
    }

    var host: PermissionAssistMainWindowRestoreSession.WindowHost {
        .init(
            windows: { [weak self] in self?.windows ?? [] },
            mainWindow: { [weak self] in self?.mainWindow },
            keyWindow: { [weak self] in self?.keyWindow },
            isMainWindow: { [weak self] window in
                guard let self else { return false }
                return self.mainWindowWasPrimary && self.mainWindow === window
            },
            isKeyWindow: { [weak self] window in
                guard let self else { return false }
                return self.keyWindowWasPrimary && self.keyWindow === window
            },
            activateApplication: { [weak self] in
                self?.activationCount += 1
                self?.operationLog.append("activate")
            },
            orderOut: { [weak self] window in
                self?.orderOutCount += 1
                self?.orderedOutWindows.append(window)
                self?.operationLog.append("orderOut")
                window.orderOut(nil)
            },
            orderFront: { [weak self] window in
                self?.orderFrontCount += 1
                self?.orderedFrontWindows.append(window)
                self?.operationLog.append("orderFront")
                window.orderFront(nil)
            },
            makeKey: { [weak self] window in
                self?.makeKeyCount += 1
                self?.operationLog.append("makeKey")
                window.makeKey()
            },
            setFrame: { [weak self] window, frame in
                self?.operationLog.append("setFrame")
                window.setFrame(frame, display: false)
            },
            animationBehavior: { $0.animationBehavior },
            setAnimationBehavior: { [weak self] window, behavior in
                self?.operationLog.append(
                    behavior == .none ? "animation.none" : "animation.restore"
                )
                window.animationBehavior = behavior
            }
        )
    }
}

@MainActor
private func permissionAssistTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: -4_000, y: -4_000, width: 320, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
}

@MainActor
private func closePermissionAssistTestWindow(_ window: NSWindow) {
    window.animationBehavior = .none
    window.close()
}

private final class SettingsScrollTestDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsScrollBridgeHostingState: ObservableObject {
    @Published var route: SettingsViewMode = .screenshot

    let routeStateStore = SettingsRouteStateStore()

    var screenshotOffset: Binding<CGFloat> {
        routeStateStore.scrollOffsetBinding(for: .screenshot)
    }

    var clipboardOffset: Binding<CGFloat> {
        routeStateStore.scrollOffsetBinding(for: .clipboard)
    }
}

private struct SettingsScrollBridgeHostingFixture: View {
    @ObservedObject var state: SettingsScrollBridgeHostingState

    var body: some View {
        ScrollView {
            Color.clear
                .frame(width: 640, height: 1_200)
                .background {
                    SettingsScrollPositionBridge(
                        restorationID: state.route == .screenshot
                            ? "screenshot"
                            : "clipboard",
                        offset: state.routeStateStore.scrollOffsetBinding(for: state.route)
                    )
                    .frame(width: 0, height: 0)
                }
        }
        .frame(width: 640, height: 240)
    }
}

private struct SettingsAlignmentTestFixture: View {
    @State private var first = true
    @State private var second = false
    @State private var cleanupMode = ClipboardCleanupMode.count
    @State private var text = "Blocks"
    @State private var slider = 0.5

    var body: some View {
        SettingsSection(title: "Section title") {
            SettingsFormRow(
                title: "Row title",
                detail: "A detail that validates first-line alignment."
            ) {
                SettingsBooleanSwitch("Row switch", isOn: $first)
            }
            SettingsRowDivider()
            SettingsFormRow(title: "Second row") {
                SettingsBooleanSwitch("Second switch", isOn: $second)
            }
            SettingsRowDivider()
            SettingsSegmentedRow(
                title: "Cleanup mode",
                selection: $cleanupMode,
                controlWidth: 220
            ) {
                Text("Time").tag(ClipboardCleanupMode.time)
                Text("Count").tag(ClipboardCleanupMode.count)
            }
            SettingsRowDivider()
            SettingsTextFieldRow(
                title: "Text value",
                detail: "The visible input remains centered against a multiline label.",
                text: $text
            )
            SettingsRowDivider()
            SettingsSliderRow(
                title: "Slider value",
                detail: "The visible slider group shares the same trailing edge.",
                value: $slider,
                range: 0...1,
                valueText: "50%"
            )
        }
        .padding(BlocksVisualTokens.Layout.settingsPageHorizontalPadding)
    }
}

private struct PluginReviewSheetScaffoldTestFixture: View {
    static let maximumPermissionDisclosure = [
        "Selected installation package",
        "Unsigned plugin",
        "Network Domains\napi.example.com",
        "Network Methods\nGET, POST",
        "Sensitive configuration\nService token · Required\nOptional note · Optional\nThe secret itself is not shown here.",
        "Data Permissions\nClipboard contents",
        "Automatic workflow access\nBefore a clipboard item is saved — runs while Blocks is active; a failure stops this step of the original workflow\nBefore Blocks writes to the clipboard — can run in the background; a failure lets the original workflow continue",
        "Runs on a schedule",
        "Saves plugin data on this Mac",
        "Blocks actions\nDelete clipboard records\nRun an approved Blocks shortcut action",
        "Actions from other plugins\nUse “Classify” from Producer",
        "Shared plugin data\nRead only access to Shared tags data shared by Producer",
        "Adds interface content\nCan add Blocks-rendered pages, details, badges, or actions in approved locations (2).",
    ]

    var body: some View {
        SettingsSheetScaffold(
            title: "Install plugin",
            detail: "Maximum permission disclosure",
            preferredHeight: 360
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.maximumPermissionDisclosure, id: \.self) { disclosure in
                    Text(disclosure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(0..<25, id: \.self) { index in
                    Text("Additional approved capability \(index + 1)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel", action: {})
                .accessibilityLabel("Cancel plugin installation")
            Button("Approve", action: {})
                .accessibilityLabel("Approve plugin installation")
        }
    }
}

private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
    if let view = view as? T { return view }
    for child in view.subviews {
        if let result = firstDescendant(of: type, in: child) { return result }
    }
    return nil
}

@MainActor
private final class SettingsGeometryCapture {
    var frames: [String: CGRect] = [:]
}
