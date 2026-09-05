import BlocksCore
import SwiftUI

@MainActor
final class TranslationOfficialServiceProfileEditorSaveSession {
    private var sessionID = UUID()
    private var saveCompleted = false

    func begin() -> UUID {
        sessionID = UUID()
        saveCompleted = false
        return sessionID
    }

    func isCurrent(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && !Task.isCancelled
    }

    func owns(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID
    }

    @discardableResult
    func finishSuccess(ifCurrent sessionID: UUID) -> Bool {
        guard isCurrent(sessionID) else { return false }
        saveCompleted = true
        return true
    }

    var shouldInvalidateOnDisappear: Bool {
        !saveCompleted
    }

    func invalidate() {
        sessionID = UUID()
        saveCompleted = false
    }
}

struct TranslationServiceProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var translationStore: TranslationStore

    let existingProfile: TranslationServiceProfile?
    let fixedTemplateID: TranslationServiceTemplateID?
    let saveAndEnable: Bool
    let onSaved: (TranslationServiceProfile) -> Void

    @State private var selectedTemplateID:
        TranslationServiceTemplateID
    @State private var profileID: String
    @State private var profileCreatedAt: Date
    @State private var displayName: String
    @State private var configurationDrafts: [String: String]
    @State private var credentialDrafts: [String: String] = [:]
    @State private var configuredCredentialIDs: Set<String> = []
    @State private var credentialFieldIDsToDelete: Set<String> = []
    @State private var hasLoadedCredentialState: Bool
    @State private var isSaving = false
    @State private var saveSession =
        TranslationOfficialServiceProfileEditorSaveSession()
    @State private var savingTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var errorTitleLocalizationKey =
        "translation.services.profile.saveFailed"

    init(
        existingProfile: TranslationServiceProfile?,
        fixedTemplateID: TranslationServiceTemplateID? = nil,
        saveAndEnable: Bool = false,
        onSaved: @escaping (TranslationServiceProfile) -> Void
    ) {
        self.existingProfile = existingProfile
        self.fixedTemplateID = fixedTemplateID
        self.saveAndEnable = saveAndEnable
        self.onSaved = onSaved
        let templateID =
            existingProfile?.templateID
            ?? fixedTemplateID
            ?? TranslationServiceTemplateCatalog.externalTemplates[0].id
        _selectedTemplateID = State(initialValue: templateID)
        _profileID = State(
            initialValue:
                existingProfile?.id
                ?? UUID().uuidString.lowercased()
        )
        _profileCreatedAt = State(
            initialValue: existingProfile?.createdAt ?? Date()
        )
        _displayName = State(
            initialValue:
                existingProfile?.displayName
                ?? TranslationServiceTemplateCatalog.descriptor(
                    for: templateID
                )?.displayName
                ?? ""
        )
        _configurationDrafts = State(
            initialValue: existingProfile?.configuration.compactMapValues {
                if case let .string(value) = $0 { return value }
                return nil
            } ?? [:]
        )
        _hasLoadedCredentialState = State(
            initialValue: existingProfile == nil
        )
    }

    private var template: TranslationServiceTemplateDescriptor {
        TranslationServiceTemplateCatalog.descriptor(
            for: selectedTemplateID
        )!
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && template.fields.allSatisfy { field in
                guard field.required else { return true }
                switch field.kind {
                case .secret:
                    let draftIsPresent = !credentialDrafts[
                            field.id,
                            default: ""
                        ].trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    return draftIsPresent
                        || (
                            hasLoadedCredentialState
                                && configuredCredentialIDs.contains(
                                    field.id
                                )
                                && !credentialFieldIDsToDelete.contains(
                                    field.id
                                )
                        )
                case .text, .url, .choice:
                    return !resolvedConfigurationValue(
                        field
                    ).isEmpty
                }
            }
    }

    var body: some View {
        SettingsSheetScaffold(
            title:
                existingProfile == nil
                    ? L10n.string(
                        "translation.services.profile.addTitle"
                    )
                    : L10n.string(
                        "translation.services.profile.editTitle"
                    ),
            detail: L10n.string(
                "translation.services.profile.externalDataNotice"
            ),
            systemImage: "network"
        ) {
            VStack(spacing: 0) {
                SettingsFormRow(
                    title: L10n.string(
                        "translation.services.profile.template"
                    )
                ) {
                    Picker(
                        L10n.string(
                            "translation.services.profile.template"
                        ),
                        selection: $selectedTemplateID
                    ) {
                        ForEach(
                            TranslationServiceTemplateCatalog
                                .externalTemplates
                        ) { template in
                            Text(template.displayName)
                                .tag(template.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(
                        existingProfile != nil
                            || fixedTemplateID != nil
                    )
                    .onChange(of: selectedTemplateID) { _, value in
                        guard existingProfile == nil,
                              let template =
                                TranslationServiceTemplateCatalog
                                    .descriptor(for: value) else {
                            return
                        }
                        displayName = template.displayName
                        configurationDrafts = [:]
                        credentialDrafts = [:]
                    }
                }
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title: L10n.string(
                        "translation.services.profile.name"
                    ),
                    text: $displayName
                )

                ForEach(template.fields) { field in
                    SettingsRowDivider()
                    SettingsFormRow(
                        title: fieldTitle(field.id)
                    ) {
                        fieldControl(field)
                    }
                }

                SettingsRowDivider()
                SettingsActionRow(
                    title: L10n.string(
                        "translation.services.profile.officialRules"
                    )
                ) {
                    Link(
                        L10n.string(
                            "translation.services.profile.officialRules"
                        ),
                        destination: template.documentationURL
                    )
                }
            }
            .disabled(isSaving)
            SettingsInlineFeedback(
                kind: .information,
                title: costTitle,
                detail: L10n.format(
                    saveAndEnable
                        ? "translation.services.profile.enableDisclosure"
                        : "translation.services.profile.validationDisclosure",
                    template.transmitsDataTo,
                    template.verifiedOn
                )
            )
            SettingsFeedbackSlot(
                feedback: errorMessage.map {
                    SettingsFeedbackDescriptor(
                        kind: .error,
                        title: L10n.string(errorTitleLocalizationKey),
                        detail: $0
                    )
                }
            )
        } actions: {
            Button(L10n.string("common.cancel")) {
                invalidateSavingSession()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(
                L10n.string(
                    saveAndEnable
                        ? "translation.services.profile.saveAndEnable"
                        : "translation.services.profile.saveAndValidate"
                )
            ) {
                beginSaving()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || isSaving)
        }
        .task(id: existingProfile?.id) {
            guard let existingProfile else { return }
            do {
                configuredCredentialIDs =
                    try await translationStore
                        .configuredCredentialFieldIDs(
                            for: existingProfile
                        )
                hasLoadedCredentialState = true
            } catch {
                errorMessage = String(
                    error.localizedDescription.prefix(512)
                )
            }
        }
        .onDisappear {
            guard saveSession.shouldInvalidateOnDisappear else { return }
            invalidateSavingSession()
        }
    }

    @ViewBuilder
    private func fieldControl(
        _ field: TranslationServiceTemplateDescriptor.Field
    ) -> some View {
        Group {
            switch field.kind {
            case .secret:
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(
                        existingProfile == nil
                            ? L10n.string(
                                "translation.services.profile.credential"
                            )
                            : L10n.string(
                                "translation.services.profile.credentialKeep"
                            ),
                        text: Binding(
                            get: {
                                credentialDrafts[field.id, default: ""]
                            },
                            set: { value in
                                credentialDrafts[field.id] = value
                                if !value.isEmpty {
                                    credentialFieldIDsToDelete.remove(field.id)
                                }
                            }
                        )
                    )
                    if existingProfile != nil,
                       !field.required,
                       configuredCredentialIDs.contains(field.id)
                            || credentialFieldIDsToDelete.contains(field.id) {
                        HStack(spacing: 8) {
                            Text(
                                credentialFieldIDsToDelete.contains(field.id)
                                    ? L10n.string(
                                        "translation.services.profile.credentialPendingRemoval"
                                    )
                                    : L10n.string(
                                        "translation.services.profile.credentialConfigured"
                                    )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button(
                                credentialFieldIDsToDelete.contains(field.id)
                                    ? L10n.string(
                                        "translation.services.profile.credentialKeepAction"
                                    )
                                    : L10n.string(
                                        "translation.services.profile.credentialRemove"
                                    )
                            ) {
                                credentialDrafts[field.id] = ""
                                if credentialFieldIDsToDelete.contains(field.id) {
                                    credentialFieldIDsToDelete.remove(field.id)
                                } else {
                                    credentialFieldIDsToDelete.insert(field.id)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            case .text, .url:
                TextField(
                    "",
                    text: Binding(
                        get: {
                            configurationDrafts[field.id]
                                ?? field.defaultValue
                                ?? ""
                        },
                        set: { configurationDrafts[field.id] = $0 }
                    )
                )
            case let .choice(options):
                Picker(
                    "",
                    selection: Binding(
                        get: {
                            configurationDrafts[field.id]
                                ?? field.defaultValue
                                ?? options.first
                                ?? ""
                        },
                        set: { configurationDrafts[field.id] = $0 }
                    )
                ) {
                    ForEach(options, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
            }
        }
        .accessibilityLabel(fieldTitle(field.id))
    }

    private func resolvedConfigurationValue(
        _ field: TranslationServiceTemplateDescriptor.Field
    ) -> String {
        (configurationDrafts[field.id] ?? field.defaultValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginSaving() {
        guard !isSaving else { return }
        let now = Date()
        let profile = TranslationServiceProfile(
            id: profileID,
            templateID: selectedTemplateID,
            displayName: displayName,
            configuration: Dictionary(
                uniqueKeysWithValues: template.fields.compactMap { field in
                    switch field.kind {
                    case .secret:
                        return nil
                    case .text, .url, .choice:
                        let value = resolvedConfigurationValue(field)
                        return value.isEmpty
                            ? nil
                            : (field.id, JSONValue.string(value))
                    }
                }
            ),
            createdAt: profileCreatedAt,
            updatedAt: now
        )
        isSaving = true
        errorMessage = nil
        errorTitleLocalizationKey =
            "translation.services.profile.saveFailed"
        let sessionID = saveSession.begin()
        let credentials = credentialDrafts
        let fieldsToDelete = credentialFieldIDsToDelete
        savingTask = Task { @MainActor in
            await save(
                profile,
                credentials: credentials,
                credentialFieldIDsToDelete: fieldsToDelete,
                sessionID: sessionID
            )
            guard saveSession.owns(sessionID) else { return }
            isSaving = false
            savingTask = nil
        }
    }

    private func save(
        _ profile: TranslationServiceProfile,
        credentials: [String: String],
        credentialFieldIDsToDelete: Set<String>,
        sessionID: UUID
    ) async {
        guard saveSession.isCurrent(sessionID) else { return }
        let saved: TranslationServiceProfile
        do {
            saved = try await translationStore.saveServiceProfile(
                profile,
                credentials: credentials,
                credentialFieldIDsToDelete: credentialFieldIDsToDelete
            )
        } catch {
            guard saveSession.isCurrent(sessionID) else { return }
            errorTitleLocalizationKey =
                "translation.services.profile.saveFailed"
            errorMessage = String(error.localizedDescription.prefix(512))
            return
        }

        guard saveSession.isCurrent(sessionID) else { return }
        if saveAndEnable {
            guard saveSession.finishSuccess(ifCurrent: sessionID) else { return }
            translationStore.setServiceEnabled(
                true,
                serviceID: saved.serviceID
            )
            onSaved(saved)
            dismiss()
            return
        }

        do {
            _ = try await translationStore.connectionTest(profile: saved)
            guard saveSession.finishSuccess(ifCurrent: sessionID) else { return }
            onSaved(saved)
            dismiss()
        } catch {
            guard saveSession.isCurrent(sessionID) else { return }
            errorTitleLocalizationKey =
                "translation.services.profile.savedValidationFailed"
            errorMessage = L10n.format(
                "translation.services.profile.savedValidationFailed.detail",
                String(error.localizedDescription.prefix(384))
            )
        }
    }

    private func invalidateSavingSession() {
        savingTask?.cancel()
        savingTask = nil
        isSaving = false
        saveSession.invalidate()
    }

    private func fieldTitle(_ fieldID: String) -> String {
        L10n.string(
            "translation.services.profile.field.\(fieldID)"
        )
    }

    private var costTitle: String {
        template.costKinds.map {
            L10n.string(
                "translation.services.profile.cost.\($0.rawValue)"
            )
        }.joined(separator: " · ")
    }
}
