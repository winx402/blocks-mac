import AppKit
import SwiftUI

struct ShortcutSettingsPane: View {
    @EnvironmentObject private var shortcutStore: ShortcutStore
    @AppStorage("shortcut.globalModifier") private var globalShortcutModifierRawValue = ShortcutModifierPreset.controlOption.rawValue
    @State private var shortcutRecorderState: ShortcutRecorderState = .idle
    @StateObject private var shortcutRecorderMonitor = ShortcutRecorderMonitorLifecycle()
    @State private var registrationFeedback: SettingsFeedbackDescriptor?
    @State private var registrationFeedbackGeneration: UInt64?

    private var globalShortcutModifier: Binding<ShortcutModifierPreset> {
        Binding {
            ShortcutModifierPreset(rawValue: globalShortcutModifierRawValue) ?? .controlOption
        } set: { preset in
            globalShortcutModifierRawValue = preset.rawValue
            shortcutStore.setGlobalShortcutModifierPreset(preset)
        }
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        SettingsSection(
            title: L10n.string("settings.shortcuts")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.shortcutGlobalModifier"),
                detail: L10n.string("settings.shortcutGlobalModifierNote")
            ) {
                Picker(L10n.string("settings.shortcutGlobalModifier"), selection: globalShortcutModifier) {
                    ForEach(ShortcutModifierPreset.allCases) { preset in
                        Text(preset.localizedTitle)
                            .tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.shortcutDiagnosticsTitle"),
                detail: L10n.string("settings.shortcutDiagnosticsDetail")
            ) {
                Label(
                    registrationSummary,
                    systemImage: shortcutStore.failedShortcutCount == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    shortcutStore.failedShortcutCount == 0
                        ? Color.secondary
                        : Color.orange
                )
            }
        }

        SettingsSection(
            title: L10n.string("settings.shortcutStatus"),
            headerActions: {
                Button {
                    finishRecording()
                    let summary = shortcutStore.refreshShortcutRegistrations()
                    registrationFeedback = registrationStatus(for: summary)
                    registrationFeedbackGeneration = shortcutStore.registrationGeneration
                } label: {
                    Label(
                        L10n.string("settings.shortcutReregister"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .controlSize(.small)
            }
        ) {
            ForEach(ShortcutCommand.settingsVisibleCases) { command in
                ShortcutRecorderRow(
                    command: command,
                    recorderState: $shortcutRecorderState,
                    recorderMonitor: shortcutRecorderMonitor
                )
                if command != ShortcutCommand.settingsVisibleCases.last {
                    SettingsRowDivider()
                }
            }

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string("settings.shortcutRestoreAllDefaults"),
                detail: L10n.string("settings.translationShortcutDefault")
            ) {
                Button {
                    finishRecording()
                    shortcutStore.restoreDefaultShortcuts()
                } label: {
                    Label(L10n.string("settings.shortcutRestoreAllDefaults"), systemImage: "arrow.counterclockwise")
                }
            }

            SettingsRowDivider()
            SettingsFeedbackSlot(feedback: registrationFeedback)
        }
        .onChange(of: shortcutStore.registrationGeneration) { _, generation in
            guard let feedbackGeneration = registrationFeedbackGeneration,
                  feedbackGeneration != generation else {
                return
            }
            registrationFeedback = nil
            registrationFeedbackGeneration = nil
        }
        .onChange(of: shortcutRecorderState) { _, state in
            shortcutRecorderMonitor.synchronize(with: state)
        }
        .onDisappear {
            finishRecording()
        }
    }

    private var registrationSummary: String {
        [
            L10n.format(
                "settings.shortcutPrimaryRegisteredCount",
                shortcutStore.registeredPrimaryShortcutCount
            ),
            L10n.format(
                "settings.shortcutQuickPasteRegisteredCount",
                shortcutStore.registeredQuickPasteShortcutCount
            ),
            L10n.format(
                "settings.shortcutFailedCount",
                shortcutStore.failedShortcutCount
            ),
        ].joined(separator: " · ")
    }

    private func registrationStatus(for summary: ShortcutRegistrationSummary) -> SettingsFeedbackDescriptor {
        if summary.succeeded {
            return SettingsFeedbackDescriptor(
                kind: .success,
                title: L10n.string("settings.shortcutReregisterAcceptedTitle"),
                detail: L10n.format(
                    "settings.shortcutReregisterAcceptedDetail",
                    summary.acceptedCount,
                    summary.disabledCount
                )
            )
        }
        let failures = summary.failedResults.map {
            "\($0.command.localizedTitle) (OSStatus \($0.osStatus))"
        }.joined(separator: "、")
        return SettingsFeedbackDescriptor(
            kind: .warning,
            title: L10n.string("settings.shortcutReregisterFailedTitle"),
            detail: L10n.format("settings.shortcutReregisterFailedDetail", failures)
        )
    }

    private func finishRecording() {
        shortcutRecorderMonitor.stopRecording()
        shortcutRecorderState = .idle
    }
}

enum ShortcutRecorderState: Equatable {
    case idle
    case recording(ShortcutCommand)
}

@MainActor
final class ShortcutRecorderMonitorLifecycle: ObservableObject {
    typealias LocalMonitorInstaller = (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> NSEvent?
    ) -> Any?

    private let installLocalMonitor: LocalMonitorInstaller
    private let removeLocalMonitor: (Any) -> Void
    private let notificationCenter: NotificationCenter
    private var eventMonitor: Any?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var recordingCommand: ShortcutCommand?
    private var recordingGeneration: UInt64 = 0
    private var recordingEnded: (() -> Void)?

    var activeMonitorCountForTesting: Int {
        eventMonitor == nil ? 0 : 1
    }

    var activeLifecycleObserverCountForTesting: Int {
        lifecycleObservers.count
    }

    init(
        installLocalMonitor: @escaping LocalMonitorInstaller = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        removeLocalMonitor: @escaping (Any) -> Void = { monitor in
            NSEvent.removeMonitor(monitor)
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.installLocalMonitor = installLocalMonitor
        self.removeLocalMonitor = removeLocalMonitor
        self.notificationCenter = notificationCenter
    }

    deinit {
        if let eventMonitor {
            removeLocalMonitor(eventMonitor)
        }
        lifecycleObservers.forEach(notificationCenter.removeObserver)
    }

    func startRecording(
        for command: ShortcutCommand,
        onRecordingEnded: @escaping () -> Void = {},
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        startRecording(
            for: command,
            in: NSApp.keyWindow,
            onRecordingEnded: onRecordingEnded,
            handler: handler
        )
    }

    func startRecording(
        for command: ShortcutCommand,
        in settingsWindow: NSWindow?,
        onRecordingEnded: @escaping () -> Void = {},
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        stopRecording()
        recordingGeneration &+= 1
        let generation = recordingGeneration
        recordingCommand = command
        recordingEnded = onRecordingEnded
        installLifecycleObservers(for: settingsWindow, generation: generation)
        eventMonitor = installLocalMonitor(.keyDown) { [weak self] event in
            guard self?.recordingGeneration == generation,
                  self?.recordingCommand == command else {
                return event
            }
            return handler(event)
        }
    }

    func synchronize(with state: ShortcutRecorderState) {
        guard case let .recording(command) = state,
              recordingCommand == command else {
            stopRecording()
            return
        }
    }

    func stopRecording() {
        recordingCommand = nil
        recordingEnded = nil
        if let eventMonitor {
            self.eventMonitor = nil
            removeLocalMonitor(eventMonitor)
        }
        lifecycleObservers.forEach(notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
    }

    private func installLifecycleObservers(
        for settingsWindow: NSWindow?,
        generation: UInt64
    ) {
        lifecycleObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishRecording(for: generation)
                }
            }
        )

        guard let settingsWindow else { return }
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            lifecycleObservers.append(
                notificationCenter.addObserver(
                    forName: name,
                    object: settingsWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.finishRecording(for: generation)
                    }
                }
            )
        }
    }

    private func finishRecording(for generation: UInt64) {
        guard recordingGeneration == generation else { return }
        let recordingEnded = recordingEnded
        stopRecording()
        recordingEnded?()
    }
}

struct ShortcutRecorderRow: View {
    @EnvironmentObject private var shortcutStore: ShortcutStore
    let command: ShortcutCommand
    @Binding var recorderState: ShortcutRecorderState
    let recorderMonitor: ShortcutRecorderMonitorLifecycle

    private var result: ShortcutRegistrationResult? {
        shortcutStore.shortcutRegistrationResult(for: command)
    }

    private var binding: ShortcutBinding {
        shortcutStore.shortcutBinding(for: command)
    }

    private var bindingSource: ShortcutBindingSource {
        shortcutStore.shortcutBindingSource(for: command)
    }

    private var isRecording: Bool {
        recorderState == .recording(command)
    }

    var body: some View {
        SettingsRowShell(
            title: command.localizedTitle,
            detail: "\(binding.displayValue)\n\(L10n.format("settings.shortcutSource", bindingSource.localizedTitle))",
            minHeight: 58
        ) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                if let statusPresentation {
                    Image(systemName: statusPresentation.systemImage)
                        .foregroundStyle(statusPresentation.color)
                        .help(statusPresentation.text)
                        .accessibilityLabel(statusPresentation.text)
                }

                BlocksCompactActionGroup(
                    density: .compact,
                    reservedSlotCount: 2
                ) {
                    BlocksCompactIconButton(
                        systemImage: isRecording
                            ? "record.circle.fill"
                            : "keyboard",
                        label: L10n.format(
                            isRecording
                                ? "settings.shortcutRecordingFor"
                                : "settings.shortcutRecordFor",
                            command.localizedTitle
                        ),
                        isSelected: isRecording,
                        emphasis: isRecording ? .accent : .standard
                    ) {
                        isRecording ? stopRecording() : startRecording()
                    }

                    BlocksCompactIconButton(
                        systemImage: "arrow.uturn.backward",
                        label: L10n.format(
                            "settings.shortcutRestoreDefaultFor",
                            command.localizedTitle
                        ),
                        isEnabled: bindingSource == .custom
                    ) {
                        stopRecording()
                        shortcutStore.restoreShortcutDefault(for: command)
                    }
                }

                SettingsBooleanSwitch(
                    L10n.format(
                        "settings.shortcutEnabledFor",
                        command.localizedTitle
                    ),
                    isOn: enabledBinding
                )
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            binding.enabled
        } set: { isEnabled in
            shortcutStore.setShortcutEnabled(isEnabled, for: command)
        }
    }

    private var statusPresentation: (
        systemImage: String,
        color: Color,
        text: String
    )? {
        guard let result else { return nil }
        guard result.binding.enabled else { return nil }
        if !result.registered {
            return (
                "exclamationmark.triangle.fill",
                .orange,
                result.localizedStatus
            )
        }
        if shortcutStore.hasDelivered(command) {
            return (
                "checkmark.circle.fill",
                .green,
                L10n.string("settings.shortcutTriggered")
            )
        }
        return nil
    }

    private func startRecording() {
        recorderMonitor.startRecording(
            for: command,
            onRecordingEnded: {
                recorderState = .idle
            }
        ) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let nextBinding = ShortcutBinding.make(command: command, event: event, enabled: binding.enabled) else {
                NSSound.beep()
                return nil
            }
            shortcutStore.saveShortcutBinding(nextBinding)
            stopRecording()
            return nil
        }
        recorderState = .recording(command)
    }

    private func stopRecording() {
        recorderMonitor.stopRecording()
        recorderState = .idle
    }
}
