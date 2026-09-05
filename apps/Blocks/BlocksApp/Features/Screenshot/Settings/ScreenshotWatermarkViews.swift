import BlocksScreenshotCore
import SwiftUI

@MainActor
struct ScreenshotWatermarkConfirmationState {
    enum Action: Equatable {
        case delete(UUID)
        case resetAll

        var confirmationTitleKey: String {
            switch self {
            case .delete:
                "settings.screenshot.watermarks.delete.title"
            case .resetAll:
                "settings.screenshot.watermarks.reset.confirmTitle"
            }
        }

        var confirmationActionKey: String {
            switch self {
            case .delete:
                "common.delete"
            case .resetAll:
                "settings.screenshot.restoreSection"
            }
        }
    }

    private(set) var pendingAction: Action?

    mutating func requestDelete(id: UUID) {
        pendingAction = .delete(id)
    }

    mutating func requestReset() {
        pendingAction = .resetAll
    }

    mutating func cancel() {
        pendingAction = nil
    }

    mutating func confirm(using store: ScreenshotPreferencesStore) {
        guard let pendingAction else { return }
        defer { self.pendingAction = nil }

        switch pendingAction {
        case let .delete(id):
            store.removeWatermarkPreset(id: id)
        case .resetAll:
            for preset in store.preferences.watermarkPresets {
                store.removeWatermarkPreset(id: preset.id)
            }
            store.update { $0.captureDefaults.watermarkPresetID = nil }
        }
    }
}

struct ScreenshotWatermarkSettingsLibrary: View {
    @ObservedObject var store: ScreenshotPreferencesStore
    @State private var editedPreset: ScreenshotWatermarkPreset?
    @State private var confirmationState = ScreenshotWatermarkConfirmationState()

    private var preferences: ScreenshotPreferences { store.preferences }

    var body: some View {
        SettingsSection(
            title: L10n.string("settings.screenshot.watermarks"),
            headerActions: {
                BlocksCompactActionGroup(density: .compact) {
                    BlocksCompactIconButton(
                        systemImage: "plus",
                        label: L10n.string(
                            "settings.screenshot.watermarks.add"
                        ),
                        density: .compact,
                        action: addWatermark
                    )
                    BlocksCompactIconButton(
                        systemImage: "arrow.counterclockwise",
                        label: L10n.string(
                            "settings.screenshot.restoreSection"
                        ),
                        density: .compact,
                        action: { confirmationState.requestReset() }
                    )
                }
            }
        ) {
            SettingsFormRow(
                title: L10n.string("settings.screenshot.watermarks.default"),
                detail: L10n.string("settings.screenshot.watermarks.default.detail")
            ) {
                Picker("", selection: defaultPresetBinding) {
                    Text(L10n.string("settings.screenshot.watermarks.none"))
                        .tag(Optional<UUID>.none)
                    ForEach(preferences.watermarkPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180, alignment: .trailing)
                .accessibilityLabel(L10n.string("settings.screenshot.watermarks.default"))
            }

            SettingsRowDivider()

            if preferences.watermarkPresets.isEmpty {
                SettingsFormRow(
                    title: L10n.string("settings.screenshot.watermarks.empty"),
                    detail: L10n.string("settings.screenshot.watermarks.empty.detail")
                ) { EmptyView() }
            } else {
                ForEach(Array(preferences.watermarkPresets.enumerated()), id: \.element.id) { index, preset in
                    SettingsFormRow(title: preset.name, detail: presetDetail(preset)) {
                        HStack(spacing: 8) {
                            Button(L10n.string("common.edit")) { editedPreset = preset }
                            Button(role: .destructive) {
                                confirmationState.requestDelete(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.format("settings.screenshot.watermarks.deleteNamed", preset.name))
                        }
                    }
                    if index < preferences.watermarkPresets.count - 1 { SettingsRowDivider() }
                }
            }
        }
        .sheet(item: $editedPreset) { preset in
            ScreenshotWatermarkPresetEditor(preset: preset) { saved in
                store.saveWatermarkPreset(saved)
                editedPreset = nil
            } onCancel: {
                editedPreset = nil
            }
        }
        .confirmationDialog(
            L10n.string(
                confirmationState.pendingAction?.confirmationTitleKey
                    ?? "settings.screenshot.watermarks.delete.title"
            ),
            isPresented: Binding(
                get: { confirmationState.pendingAction != nil },
                set: { isPresented in
                    if !isPresented {
                        confirmationState.cancel()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(
                L10n.string(
                    confirmationState.pendingAction?.confirmationActionKey ?? "common.delete"
                ),
                role: .destructive
            ) {
                confirmationState.confirm(using: store)
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                confirmationState.cancel()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var defaultPresetBinding: Binding<UUID?> {
        Binding(
            get: {
                guard let presetID = preferences.captureDefaults.watermarkPresetID,
                      preferences.watermarkPresets.contains(where: { $0.id == presetID }) else {
                    return nil
                }
                return presetID
            },
            set: { presetID in
                store.update { $0.captureDefaults.watermarkPresetID = presetID }
            }
        )
    }

    private func addWatermark() {
        editedPreset = ScreenshotWatermarkPreset(
            name: L10n.string("screenshot.watermark.defaultName"),
            style: ScreenshotWatermarkStyle(
                text: L10n.string("screenshot.watermark.defaultText")
            )
        )
    }

    private var confirmationMessage: String {
        switch confirmationState.pendingAction {
        case let .delete(id):
            let name = preferences.watermarkPresets.first(where: { $0.id == id })?.name ?? ""
            return L10n.format(
                "settings.screenshot.watermarks.delete.message",
                name
            )
        case .resetAll:
            return L10n.string(
                "settings.screenshot.watermarks.reset.confirmMessage"
            )
        case nil:
            return ""
        }
    }

    private func presetDetail(_ preset: ScreenshotWatermarkPreset) -> String? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = preset.style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == text ? nil : text
    }
}

private struct ScreenshotWatermarkPresetEditor: View {
    @State private var preset: ScreenshotWatermarkPreset
    let onSave: (ScreenshotWatermarkPreset) -> Void
    let onCancel: () -> Void

    init(
        preset: ScreenshotWatermarkPreset,
        onSave: @escaping (ScreenshotWatermarkPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _preset = State(initialValue: preset)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SettingsSheetScaffold(
            title: L10n.string(
                "settings.screenshot.watermarks.editor.title"
            )
        ) {
            VStack(spacing: 0) {
                SettingsTextFieldRow(
                    title: L10n.string("screenshot.watermark.name"),
                    text: $preset.name
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title: L10n.string("screenshot.watermark.text.content"),
                    text: $preset.style.text
                )
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string("screenshot.watermark.color")
                ) {
                    ScreenshotColorPickerButton(
                        color: $preset.style.color,
                        recentColors: [],
                        onEditingChanged: { _ in },
                        onColorCommitted: { preset.style.color = $0 }
                    )
                }
                SettingsRowDivider()
                SettingsSliderRow(
                    title: L10n.string("screenshot.watermark.text.fontSize"),
                    value: $preset.style.fontSizeFraction,
                    range: 0.01...0.12,
                    valueText: "\(Int((preset.style.fontSizeFraction * 100).rounded()))%"
                )
                SettingsRowDivider()
                SettingsSliderRow(
                    title: L10n.string("screenshot.watermark.density"),
                    value: $preset.style.density,
                    range: 0...1,
                    valueText: "\(Int((preset.style.density * 100).rounded()))%"
                )
                SettingsRowDivider()
                SettingsSliderRow(
                    title: L10n.string("screenshot.watermark.angle"),
                    value: $preset.style.angleDegrees,
                    range: -90...90,
                    valueText: "\(Int(preset.style.angleDegrees.rounded()))°"
                )
                SettingsRowDivider()
                SettingsSliderRow(
                    title: L10n.string("screenshot.watermark.opacity"),
                    value: $preset.style.opacity,
                    range: 0...1,
                    valueText: "\(Int((preset.style.opacity * 100).rounded()))%"
                )
            }
        } actions: {
            HStack(spacing: 8) {
                Button(L10n.string("common.cancel"), action: onCancel)
                Button(L10n.string("common.save")) { onSave(preset) }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || preset.style.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
    }
}
