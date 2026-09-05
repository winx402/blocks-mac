import AppKit
import BlocksCore

@MainActor
final class ScreenshotFeatureCoordinator {
    private let store: ScreenshotStore
    private var statusRecorder: (AppStatus) -> Void = { _ in }
    private var requestScreenRecordingPermissionAssist: () -> Void = {}
    private var requestInputMonitoringPermissionAssist: () -> Void = {}

    init(store: ScreenshotStore) {
        self.store = store
    }

    func disableRuntime() {
        store.disableRuntime()
    }

    func configure(
        statusRecorder: @escaping (AppStatus) -> Void,
        requestScreenRecordingPermissionAssist: @escaping () -> Void,
        requestInputMonitoringPermissionAssist: @escaping () -> Void,
        dispatchPluginEvent: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult = {
            .allowed($0)
        },
        registerPluginResource: @escaping @Sendable (
            Data,
            BlocksPluginResourceKind,
            String?,
            [String: JSONValue]
        ) -> BlocksPluginResourceReference? = { _, _, _, _ in nil },
        removePluginResources: @escaping @Sendable ([String]) -> Void = { _ in },
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil
    ) {
        self.statusRecorder = statusRecorder
        self.requestScreenRecordingPermissionAssist = requestScreenRecordingPermissionAssist
        self.requestInputMonitoringPermissionAssist = requestInputMonitoringPermissionAssist
        store.configureCoordinator(
            statusRecorder: statusRecorder,
            retakeHandler: { [weak self] startsInScrollingMode in
                Task { @MainActor in
                    await self?.startSmartScreenshot(
                        startsInScrollingMode: startsInScrollingMode
                    )
                }
            },
            dispatchPluginEvent: dispatchPluginEvent,
            registerPluginResource: registerPluginResource,
            removePluginResources: removePluginResources,
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime
        )
    }

    @discardableResult
    func startSmartScreenshot() async -> ScreenshotStartResult {
        await startSmartScreenshot(startsInScrollingMode: false)
    }

    @discardableResult
    private func startSmartScreenshot(
        startsInScrollingMode: Bool
    ) async -> ScreenshotStartResult {
        let result = await store.startSmartScreenshot(
            startsInScrollingMode: startsInScrollingMode
        )
        if result == .screenRecordingPermissionMissing {
            await showScreenRecordingAlert()
        } else if result == .inputMonitoringPermissionMissing {
            requestInputMonitoringPermissionAssist()
        } else if result == .featureDisabled {
            statusRecorder(AppStatus(
                kind: .ready,
                title: L10n.string("feature.screenshot.disabled.title"),
                detail: L10n.string("feature.screenshot.disabled.detail")
            ))
        } else if result == .busy {
            store.presentBusyFeedback()
        }
        return result
    }

    private func showScreenRecordingAlert() async {
        let alert = NSAlert()
        alert.messageText = L10n.string("status.screenRecordingRequired.title")
        alert.informativeText = L10n.string("alert.screenRecording.message")
        alert.addButton(withTitle: L10n.string("alert.openSettings"))
        alert.addButton(withTitle: L10n.string("alert.cancel"))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) else {
            requestScreenRecordingPermissionAssist()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let shouldOpenSettings = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
        if shouldOpenSettings {
            requestScreenRecordingPermissionAssist()
        }
    }
}
