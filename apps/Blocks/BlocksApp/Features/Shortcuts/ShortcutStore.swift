import Combine
import Foundation
import OSLog

struct ShortcutActionHandlers {
    let screenshotSmart: () -> Void
    let clipboardHistory: () -> Void
    let translationPanel: () -> Void
    let translationScreenshot: () -> Void
    let clipboardQuickPaste: (Int) -> Void

    static let disabled = ShortcutActionHandlers(
        screenshotSmart: {},
        clipboardHistory: {},
        translationPanel: {},
        translationScreenshot: {},
        clipboardQuickPaste: { _ in }
    )
}

struct ShortcutDeliveryEvent: Equatable {
    let command: ShortcutCommand
    let deliveredAt: Date
}

struct ShortcutRegistrationSummary {
    let acceptedCount: Int
    let disabledCount: Int
    let failedResults: [ShortcutRegistrationResult]

    var succeeded: Bool { failedResults.isEmpty }
}

@MainActor
final class ShortcutStore: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blocks.app",
        category: "global-shortcut"
    )
    private var applicationUpdatePaused = false
    private var registrationDeferredForApplicationUpdate = false
    private var applicationLaunchCompleted = false
    private var startupInitializationInProgress = false
    private let startupRetryWait: (UInt64) async throws -> Void

    func prepareForApplicationUpdate() async throws {
        applicationUpdatePaused = true
    }

    func resumeAfterCancelledApplicationUpdate() async {
        applicationUpdatePaused = false
        if registrationDeferredForApplicationUpdate {
            registrationDeferredForApplicationUpdate = false
            registerDefaultShortcuts(force: true)
        }
        if applicationLaunchCompleted {
            await initializeShortcutsAfterApplicationLaunch()
        }
    }
    @Published private(set) var shortcutRegistrationResults: [ShortcutRegistrationResult] = []
    @Published private(set) var lastDeliveryEvent: ShortcutDeliveryEvent?
    @Published private(set) var registrationGeneration: UInt64 = 0

    private let shortcutController: ShortcutController
    private var actions: ShortcutActionHandlers
    private var runtimeDisabledCommands: Set<ShortcutCommand> = []
    private var deliveredCommands: Set<ShortcutCommand> = []

    init(
        shortcutController: ShortcutController = ShortcutController(),
        actions: ShortcutActionHandlers = .disabled,
        startupRetryWait: @escaping (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.shortcutController = shortcutController
        self.actions = actions
        self.startupRetryWait = startupRetryWait
        shortcutController.setEventDeliveryObserver { [weak self] command, registrationEpoch in
            Task { @MainActor [weak self] in
                guard self?.registrationGeneration == registrationEpoch else {
                    return
                }
                self?.deliveredCommands.insert(command)
                self?.lastDeliveryEvent = ShortcutDeliveryEvent(command: command, deliveredAt: Date())
            }
        }
    }

    var registeredShortcutCount: Int {
        shortcutRegistrationResults.filter { $0.binding.enabled && $0.registered }.count
    }

    var registeredPrimaryShortcutCount: Int {
        shortcutRegistrationResults.filter {
            $0.command.quickPasteIndex == nil && $0.binding.enabled && $0.registered
        }.count
    }

    var registeredQuickPasteShortcutCount: Int {
        shortcutRegistrationResults.filter {
            $0.command.quickPasteIndex != nil && $0.binding.enabled && $0.registered
        }.count
    }

    var disabledShortcutCount: Int {
        shortcutRegistrationResults.filter { !$0.binding.enabled || $0.runtimeDisabled }.count
    }

    var failedShortcutCount: Int {
        shortcutRegistrationResults.filter { $0.binding.enabled && !$0.registered && !$0.runtimeDisabled }.count
    }

    func configureActions(_ actions: ShortcutActionHandlers) {
        self.actions = actions
    }

    private var needsStartupRegistration: Bool {
        shortcutRegistrationResults.isEmpty
            || shortcutRegistrationResults.contains { $0.failureReason == .applicationNotReady }
    }

    /// App lifecycle owns this entry point; no view, window or activation is required.
    /// Only readiness failures are retried. Carbon conflicts remain visible until
    /// an explicit binding change or manual registration refresh.
    func initializeShortcutsAfterApplicationLaunch() async {
        applicationLaunchCompleted = true
        guard !startupInitializationInProgress, needsStartupRegistration else { return }
        startupInitializationInProgress = true
        defer { startupInitializationInProgress = false }
        // didFinishLaunching can precede NSApplication's running flag. Let its
        // current callback unwind, then allow at most four readiness retries.
        await Task.yield()
        let retryDelays: [UInt64] = [50_000_000, 100_000_000, 250_000_000, 500_000_000]
        for attempt in 0...retryDelays.count {
            guard !Task.isCancelled, !applicationUpdatePaused else { return }
            registerDefaultShortcuts()
            Self.logger.notice("stage=startup-registration attempt=\(attempt + 1, privacy: .public) completed=\(!self.needsStartupRegistration, privacy: .public) registered=\(self.registeredShortcutCount, privacy: .public) failed=\(self.failedShortcutCount, privacy: .public)")
            guard needsStartupRegistration, attempt < retryDelays.count else { return }
            do {
                try await startupRetryWait(retryDelays[attempt])
            } catch {
                return
            }
        }
    }

    func setRuntimeAvailability(screenshotEnabled: Bool, clipboardEnabled: Bool) {
        var disabled: Set<ShortcutCommand> = []
        if !screenshotEnabled {
            disabled.insert(.screenshotSmart)
            disabled.insert(.translationScreenshot)
        }
        if !clipboardEnabled {
            disabled.insert(.clipboardHistory)
            for command in ShortcutCommand.allCases where command.quickPasteIndex != nil {
                disabled.insert(command)
            }
        }
        guard disabled != runtimeDisabledCommands else { return }
        runtimeDisabledCommands = disabled
        registerDefaultShortcuts(force: true)
    }

    func registerDefaultShortcuts(force: Bool = false) {
        guard !applicationUpdatePaused else {
            if force || needsStartupRegistration {
                registrationDeferredForApplicationUpdate = true
            }
            return
        }
        guard force || needsStartupRegistration else {
            return
        }
        // A delivery proves only the currently registered binding. Replacing
        // the Carbon registrations invalidates that evidence; otherwise a
        // newly edited shortcut is incorrectly shown as “triggered” before it
        // has ever delivered an event.
        deliveredCommands.removeAll()
        lastDeliveryEvent = nil
        shortcutRegistrationResults = shortcutController.registerConfiguredShortcuts(
            actions: registeredActions,
            runtimeDisabledCommands: runtimeDisabledCommands
        )
        registrationGeneration = shortcutController.currentRegistrationEpoch
    }

    func shortcutBinding(for command: ShortcutCommand) -> ShortcutBinding {
        shortcutRegistrationResult(for: command)?.binding ?? ShortcutBindingStore.effectiveBinding(for: command)
    }

    func shortcutRegistrationResult(for command: ShortcutCommand) -> ShortcutRegistrationResult? {
        shortcutRegistrationResults.first { $0.command == command }
    }

    func shortcutBindingSource(for command: ShortcutCommand) -> ShortcutBindingSource {
        ShortcutBindingStore.bindingSource(for: command)
    }

    func hasCustomShortcutBinding(for command: ShortcutCommand) -> Bool {
        ShortcutBindingStore.hasCustomBinding(for: command)
    }

    func globalShortcutModifierPreset() -> ShortcutModifierPreset {
        ShortcutBindingStore.globalModifierPreset()
    }

    func setGlobalShortcutModifierPreset(_ preset: ShortcutModifierPreset) {
        ShortcutBindingStore.setGlobalModifierPreset(preset)
        registerDefaultShortcuts(force: true)
    }

    func saveShortcutBinding(_ binding: ShortcutBinding) {
        ShortcutBindingStore.save(binding)
        registerDefaultShortcuts(force: true)
    }

    func setShortcutEnabled(_ enabled: Bool, for command: ShortcutCommand) {
        ShortcutBindingStore.setEnabled(enabled, for: command)
        registerDefaultShortcuts(force: true)
    }

    func restoreShortcutDefault(for command: ShortcutCommand) {
        ShortcutBindingStore.restoreDefault(for: command)
        registerDefaultShortcuts(force: true)
    }

    func restoreDefaultShortcuts() {
        ShortcutBindingStore.restoreAllDefaults()
        registerDefaultShortcuts(force: true)
    }

    @discardableResult
    func refreshShortcutRegistrations() -> ShortcutRegistrationSummary {
        registerDefaultShortcuts(force: true)
        return ShortcutRegistrationSummary(
            acceptedCount: registeredShortcutCount,
            disabledCount: disabledShortcutCount,
            failedResults: shortcutRegistrationResults.filter {
                $0.binding.enabled && !$0.registered && !$0.runtimeDisabled
            }
        )
    }

    func hasDelivered(_ command: ShortcutCommand) -> Bool {
        deliveredCommands.contains(command)
    }

    private var registeredActions: [ShortcutCommand: () -> Void] {
        var actionsByCommand: [ShortcutCommand: () -> Void] = [
            .screenshotSmart: actions.screenshotSmart,
            .clipboardHistory: actions.clipboardHistory,
            .translationPanel: actions.translationPanel,
            .translationScreenshot: actions.translationScreenshot
        ]
        for command in ShortcutCommand.allCases {
            guard let index = command.quickPasteIndex else {
                continue
            }
            actionsByCommand[command] = { [actions] in
                actions.clipboardQuickPaste(index)
            }
        }
        return actionsByCommand.mapValues { action in
            { [weak self] in
                guard let self, !self.applicationUpdatePaused else { return }
                action()
            }
        }
    }
}
