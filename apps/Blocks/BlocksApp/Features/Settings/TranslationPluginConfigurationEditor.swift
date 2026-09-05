import BlocksCore
import AppKit
import SwiftUI

struct TranslationPluginSecretDescriptor: Hashable, Sendable {
    let pluginID: String
    let secretID: String
    let maximumLength: Int

    init(
        pluginID: String,
        secretID: String,
        maximumLength: Int = 16_384
    ) {
        self.pluginID = pluginID
        self.secretID = secretID
        self.maximumLength = maximumLength
    }

    var storageKey: String {
        "\(pluginID)::\(secretID)"
    }
}

enum TranslationPluginSecretWorkerError:
    Error, LocalizedError, Equatable {
    case valueTooLong(fieldID: String, maximumLength: Int)

    var errorDescription: String? {
        switch self {
        case let .valueTooLong(fieldID, maximumLength):
            "The plugin credential \(fieldID) exceeds the configured "
                + "\(maximumLength)-character limit."
        }
    }
}

actor TranslationPluginSecretWorker {
    private let store: any BlocksNativePluginSecretStoring

    init(
        store: any BlocksNativePluginSecretStoring =
            BlocksNativePluginSecretStore()
    ) {
        self.store = store
    }

    func configuredKeys(
        for descriptors: [TranslationPluginSecretDescriptor]
    ) throws -> Set<String> {
        var configured: Set<String> = []
        for descriptor in descriptors {
            guard !Task.isCancelled else { break }
            if try store.contains(
                pluginID: descriptor.pluginID,
                secretID: descriptor.secretID
            ) {
                configured.insert(descriptor.storageKey)
            }
        }
        return configured
    }
}

struct TranslationPluginConfigurationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let plugin: BlocksNativePluginMetadata
    let sourceManagementService:
        TranslationSourceManagementService
    let onSaved: () -> Void

    @State private var configuration: [String: JSONValue] = [:]
    @State private var secretDrafts: [String: String] = [:]
    @State private var configuredSecretKeys: Set<String> = []
    @State private var pendingSecretDeletion: PluginSecretDeletion?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let secretWorker = TranslationPluginSecretWorker()

    private var manifest: BlocksNativePluginManifest? {
        TranslationPluginPermissionManifestResolver.decode(
            plugin.manifestJSON
        )
    }

    private var fields: [BlocksNativePluginConfigurationField] {
        manifest?.configurationFields ?? []
    }

    private var localizedPluginName: String {
        manifest?.presentation?.localized(
            fallbackName: plugin.displayName
        ).name ?? plugin.displayName
    }

    private var firstInvalidRequiredField:
        BlocksNativePluginConfigurationField? {
        fields.first { field in
            guard field.required else { return false }
            switch field.type {
            case .text, .url, .color, .file, .tag:
                return stringValue(field)
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            case .choice:
                let value = stringValue(field)
                return value.isEmpty
                    || !field.choices.contains {
                        $0.value == value
                    }
            case .boolean:
                return false
            case .number, .slider:
                return numberValue(field) == nil
            case .multipleChoice:
                if case let .array(values)? = configuration[field.id] {
                    return values.isEmpty
                }
                return true
            case .secret, .sessionCredential:
                let descriptor = secretDescriptor(field)
                let draft = secretDrafts[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return draft.isEmpty
                    && !configuredSecretKeys.contains(descriptor.storageKey)
            }
        }
    }

    var body: some View {
        SettingsSheetScaffold(
            title: L10n.string(
                "translation.plugin.configuration"
            ),
            detail: localizedPluginName,
            systemImage: "slider.horizontal.3",
            preferredHeight: configurationSheetHeight
        ) {
            Group {
                if isLoading {
                    SettingsStateView(
                        kind: .loading,
                        title: L10n.string(
                            "translation.plugin.configuration"
                        ),
                        detail: localizedPluginName
                    )
                    .frame(minHeight: 180)
                } else if fields.isEmpty {
                    SettingsStateView(
                        kind: .empty,
                        title: L10n.string(
                            "translation.plugin.configurationEmpty"
                        ),
                        detail: L10n.string(
                            "translation.plugin.configurationEmpty.detail"
                        )
                    )
                    .frame(minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(fields.enumerated()), id: \.element.id) {
                            index, field in
                            if index > 0 {
                                SettingsRowDivider()
                            }
                            let localizedField = field.localized()
                            SettingsFormRow(
                                title: localizedField.title,
                                detail: localizedField.detail
                            ) {
                                fieldControl(field)
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            SettingsFeedbackSlot(feedback: feedback)
        } actions: {
            Button(L10n.string("common.cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.string("common.save")) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                isLoading
                    || isSaving
                    || fields.isEmpty
                    || firstInvalidRequiredField != nil
            )
        }
        .task { await load() }
        .confirmationDialog(
            L10n.string("translation.plugin.secret.deleteConfirmation"),
            isPresented: Binding(
                get: { pendingSecretDeletion != nil },
                set: { if !$0 { pendingSecretDeletion = nil } }
            )
        ) {
            Button(
                L10n.string("translation.plugin.secret.delete"),
                role: .destructive
            ) {
                guard let pendingSecretDeletion else { return }
                deleteSecret(pendingSecretDeletion)
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                pendingSecretDeletion = nil
            }
        } message: {
            if let pendingSecretDeletion {
                Text(
                    L10n.format(
                        "translation.plugin.secret.deleteConfirmationDetail",
                        localizedPluginName,
                        pendingSecretDeletion.title
                    )
                )
            }
        }
    }

    private var configurationSheetHeight: CGFloat {
        // Keep small rule editors compact while allowing richer plugin forms
        // to grow before their content begins scrolling.
        min(560, max(280, 228 + CGFloat(fields.count) * 52))
    }

    private var feedback: SettingsFeedbackDescriptor? {
        if let errorMessage {
            return SettingsFeedbackDescriptor(
                kind: .error,
                title: L10n.string(
                    "translation.plugin.configurationSaveFailed"
                ),
                detail: errorMessage
            )
        }
        if !isLoading, let invalidField = firstInvalidRequiredField {
            return SettingsFeedbackDescriptor(
                kind: .warning,
                title: L10n.string(
                    "translation.plugin.configurationRequired"
                ),
                detail: L10n.format(
                    "translation.plugin.configurationRequired.detail",
                    invalidField.localized().title
                )
            )
        }
        return nil
    }

    @ViewBuilder
    private func fieldControl(
        _ field: BlocksNativePluginConfigurationField
    ) -> some View {
        let localizedField = field.localized()
        switch field.type {
        case .text, .url, .file, .tag:
            HStack(spacing: 8) {
                TextField(
                    localizedField.placeholder ?? "",
                    text: stringBinding(field)
                )
                .accessibilityLabel(localizedField.title)
                if let rawHelpURL = field.helpURL,
                   let helpURL = URL(string: rawHelpURL) {
                    Link(destination: helpURL) {
                        Image(systemName: "questionmark.circle")
                    }
                    .help(
                        L10n.string(
                            "translation.plugin.configurationHelp"
                        )
                    )
                }
            }
        case .boolean:
            SettingsBooleanSwitch(localizedField.title, isOn: boolBinding(field))
        case .choice:
            Picker("", selection: choiceBinding(field)) {
                if TranslationPluginConfigurationChoicePolicy
                    .allowsUnset(field) {
                    Text(L10n.string("settings.notSet"))
                        .tag(
                            TranslationPluginConfigurationChoicePolicy
                                .unsetValue
                        )
                    Divider()
                }
                ForEach(field.choices, id: \.value) { choice in
                    Text(choice.title).tag(choice.value)
                }
            }
            .labelsHidden()
            .accessibilityLabel(localizedField.title)
        case .number:
            TextField(
                localizedField.placeholder ?? "",
                value: numberBinding(field),
                format: .number
            )
            .accessibilityLabel(localizedField.title)
        case .slider:
            HStack(spacing: 8) {
                Slider(value: numberBinding(field), in: 0...1)
                Text(numberBinding(field).wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .accessibilityLabel(localizedField.title)
        case .multipleChoice:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(field.choices, id: \.value) { choice in
                    SettingsCheckbox(
                        choice.title,
                        isOn: multiChoiceBinding(field, value: choice.value)
                    )
                }
            }
        case .color:
            ColorPicker(
                localizedField.title,
                selection: colorBinding(field),
                supportsOpacity: true
            )
            .labelsHidden()
        case .secret, .sessionCredential:
            secretControl(field)
        }
    }

    private func secretControl(
        _ field: BlocksNativePluginConfigurationField
    ) -> some View {
        let localizedField = field.localized()
        let descriptor = secretDescriptor(field)
        let isConfigured = configuredSecretKeys.contains(
            descriptor.storageKey
        )
        return HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            SecureField(
                localizedField.placeholder
                    ?? L10n.string(
                        "translation.plugin.secret.placeholder"
                    ),
                text: Binding(
                    get: { secretDrafts[field.id, default: ""] },
                    set: {
                        secretDrafts[field.id] = String(
                            $0.prefix(field.maximumLength ?? 16_384)
                        )
                    }
                )
            )
            .accessibilityLabel(localizedField.title)

            if isConfigured {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(
                        L10n.string(
                            "translation.plugin.secret.configured"
                        )
                    )
                    .accessibilityLabel(
                        L10n.string(
                            "translation.plugin.secret.configured"
                        )
                    )
                Button(role: .destructive) {
                    pendingSecretDeletion = PluginSecretDeletion(
                        fieldID: field.id,
                        title: localizedField.title
                    )
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(
                    L10n.string("translation.plugin.secret.delete")
                )
                .accessibilityLabel(
                    L10n.format(
                        "translation.plugin.secret.fieldAccessibility",
                        localizedPluginName,
                        localizedField.title
                    )
                )
            }
        }
    }

    private func stringBinding(
        _ field: BlocksNativePluginConfigurationField
    ) -> Binding<String> {
        Binding(
            get: { stringValue(field) },
            set: {
                configuration[field.id] = .string(
                    String($0.prefix(field.maximumLength ?? 16_384))
                )
            }
        )
    }

    private func choiceBinding(
        _ field: BlocksNativePluginConfigurationField
    ) -> Binding<String> {
        Binding(
            get: { stringValue(field) },
            set: {
                TranslationPluginConfigurationChoicePolicy.apply(
                    $0,
                    field: field,
                    to: &configuration
                )
            }
        )
    }

    private func stringValue(
        _ field: BlocksNativePluginConfigurationField
    ) -> String {
        if case let .string(value)? =
            configuration[field.id] {
            return value
        }
        if case let .string(value)? = field.defaultValue {
            return value
        }
        return ""
    }

    private func boolBinding(
        _ field: BlocksNativePluginConfigurationField
    ) -> Binding<Bool> {
        Binding(
            get: {
                if case let .bool(value)? =
                    configuration[field.id] {
                    return value
                }
                if case let .bool(value)? = field.defaultValue {
                    return value
                }
                return false
            },
            set: { configuration[field.id] = .bool($0) }
        )
    }

    private func numberValue(
        _ field: BlocksNativePluginConfigurationField
    ) -> Double? {
        switch configuration[field.id] ?? field.defaultValue {
        case let .double(value): return value
        case let .int(value): return Double(value)
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    private func numberBinding(
        _ field: BlocksNativePluginConfigurationField
    ) -> Binding<Double> {
        Binding(
            get: { numberValue(field) ?? 0 },
            set: { configuration[field.id] = .double($0) }
        )
    }

    private func multiChoiceBinding(
        _ field: BlocksNativePluginConfigurationField,
        value: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard case let .array(values)? = configuration[field.id]
                    ?? field.defaultValue else { return false }
                return values.contains(.string(value))
            },
            set: { enabled in
                let current: [String]
                if case let .array(values)? = configuration[field.id]
                    ?? field.defaultValue {
                    current = values.compactMap {
                        if case let .string(value) = $0 { return value }
                        return nil
                    }
                } else {
                    current = []
                }
                var next = current.filter { $0 != value }
                if enabled { next.append(value) }
                configuration[field.id] = .array(next.map(JSONValue.string))
            }
        )
    }

    private func colorBinding(
        _ field: BlocksNativePluginConfigurationField
    ) -> Binding<Color> {
        Binding(
            get: { Color(hexRGBA: stringValue(field)) ?? .accentColor },
            set: { configuration[field.id] = .string($0.blocksHexRGBA) }
        )
    }

    private func load() async {
        do {
            configuration =
                try await sourceManagementService.pluginConfiguration(
                pluginID: plugin.id
            )
            configuredSecretKeys = try await secretWorker.configuredKeys(
                for: sensitiveFields.map(secretDescriptor)
            )
            errorMessage = nil
        } catch {
            errorMessage = String(error.localizedDescription.prefix(512))
        }
        isLoading = false
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await sourceManagementService
                    .savePluginConfiguration(
                    configuration,
                    pluginID: plugin.id
                    )
                for field in sensitiveFields {
                    let draft = secretDrafts[field.id, default: ""]
                    guard !draft.isEmpty else { continue }
                    try await sourceManagementService.savePluginSecret(
                        draft,
                        pluginID: plugin.id,
                        secretID: field.id
                    )
                    secretDrafts[field.id] = ""
                    configuredSecretKeys.insert(
                        secretDescriptor(field).storageKey
                    )
                }
                onSaved()
                dismiss()
            } catch {
                errorMessage = String(
                    error.localizedDescription.prefix(512)
                )
                isSaving = false
            }
        }
    }

    private var sensitiveFields: [BlocksNativePluginConfigurationField] {
        fields.filter { $0.type.isSensitive }
    }

    private func secretDescriptor(
        _ field: BlocksNativePluginConfigurationField
    ) -> TranslationPluginSecretDescriptor {
        TranslationPluginSecretDescriptor(
            pluginID: plugin.id,
            secretID: field.id,
            maximumLength: field.maximumLength ?? 16_384
        )
    }

    private func deleteSecret(_ pending: PluginSecretDeletion) {
        pendingSecretDeletion = nil
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await sourceManagementService.deletePluginSecret(
                    pluginID: plugin.id,
                    secretID: pending.fieldID
                )
                secretDrafts[pending.fieldID] = ""
                configuredSecretKeys.remove(
                    TranslationPluginSecretDescriptor(
                        pluginID: plugin.id,
                        secretID: pending.fieldID
                    ).storageKey
                )
                isSaving = false
            } catch {
                errorMessage = String(
                    error.localizedDescription.prefix(512)
                )
                isSaving = false
            }
        }
    }
}

private struct PluginSecretDeletion: Equatable {
    let fieldID: String
    let title: String
}

enum TranslationPluginConfigurationChoicePolicy {
    static let unsetValue = ""

    static func allowsUnset(
        _ field: BlocksNativePluginConfigurationField
    ) -> Bool {
        field.type == .choice
            && !field.required
            && field.defaultValue == nil
    }

    static func apply(
        _ selection: String,
        field: BlocksNativePluginConfigurationField,
        to configuration: inout [String: JSONValue]
    ) {
        if selection == unsetValue, allowsUnset(field) {
            configuration.removeValue(forKey: field.id)
            return
        }
        configuration[field.id] = .string(
            String(selection.prefix(field.maximumLength ?? 16_384))
        )
    }
}

private extension Color {
    init?(hexRGBA: String) {
        let value = hexRGBA.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let red = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(raw & 0xFF) / 255 : 1
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }

    var blocksHexRGBA: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return "#000000FF"
        }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Int((color.alphaComponent * 255).rounded())
        )
    }
}
