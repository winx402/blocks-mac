import AppKit
import SwiftUI

struct DataAuditSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var clipboardStore: ClipboardStore
    @EnvironmentObject private var providerStore: ProviderStore
    @EnvironmentObject private var permissionStore: PermissionStore
    @State private var showsClearAuditConfirmation = false
    @State private var diagnosticsExportStatus: SettingsRowStatus?
    @State private var diagnosticsExportGeneration = 0
    @State private var diagnosticsExportTask: Task<Void, Never>?
    @State private var isExportingDiagnostics = false

    var body: some View {
        content
            .onDisappear(perform: cancelDiagnosticsExport)
    }

    private var repositoryStateSummary: ClipboardRepositoryStateSummary {
        clipboardStore.repositoryStateSummary()
    }

    @ViewBuilder
    private var content: some View {
        SettingsSection(
            title: L10n.string("settings.dataAudit.auditSummary")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.providerAuditSummary"),
                detail: L10n.string("settings.dataAudit.detail")
            ) {
                Text(L10n.format("settings.providerAuditCount", providerStore.providerAuditEvents.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if providerStore.providerAuditEvents.isEmpty {
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string("settings.providerAuditEmpty")
                ) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } else {
                SettingsRowDivider()
                ForEach(Array(providerStore.providerAuditEvents.prefix(6))) { event in
                    ProviderAuditRow(event: event)
                    if event.id != providerStore.providerAuditEvents.prefix(6).last?.id {
                        SettingsRowDivider()
                    }
                }
            }
        }

        SettingsSection(
            title: L10n.string("settings.dataAudit.localData")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.dataAudit.clipboardIndex"),
                detail: L10n.string("settings.dataAudit.clipboardIndexDetail")
            ) {
                Text("\(clipboardStore.records.count)")
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }

            SettingsRowDivider()

            SettingsStatusRow(
                title: L10n.string("settings.clipboardStorage"),
                detail: repositoryStateSummary.detail,
                status: nil
            ) {
                if repositoryStateSummary.state == .unavailable {
                    Button(L10n.string("common.retry")) {
                        retryClipboardStorage()
                    }
                } else {
                    Text(repositoryStateSummary.title)
                        .foregroundStyle(.secondary)
                }
            }
        }

        SettingsSection(
            title: L10n.string("diagnostics.export.section")
        ) {
            SettingsStatusRow(
                title: L10n.string("diagnostics.export.title"),
                detail: L10n.string("diagnostics.export.detail"),
                status: diagnosticsExportStatus
            ) {
                Button(L10n.string("diagnostics.export.button")) {
                    exportDiagnostics()
                }
                .disabled(isExportingDiagnostics)
            }
        }
        SettingsSection(title: L10n.string("settings.dangerZone")) {
            SettingsDangerRow(
                title: L10n.string("settings.providerAuditClear"),
                detail: L10n.format(
                    "settings.providerAuditClearConfirmMessage",
                    providerStore.providerAuditEvents.count
                ),
                actionTitle: L10n.string("settings.providerAuditClear"),
                action: { showsClearAuditConfirmation = true }
            )
            .disabled(providerStore.providerAuditEvents.isEmpty)
        }
        .confirmationDialog(
            L10n.string("settings.providerAuditClearConfirmTitle"),
            isPresented: $showsClearAuditConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("settings.providerAuditClearConfirmAction"), role: .destructive) {
                appModel.clearProviderAuditEvents()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.format(
                    "settings.providerAuditClearConfirmMessage",
                    providerStore.providerAuditEvents.count
                )
            )
        }
    }

    private func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        diagnosticsExportStatus = nil
        let panel = NSSavePanel()
        panel.title = L10n.string("diagnostics.export.panelTitle")
        panel.nameFieldStringValue = DiagnosticsExportService.suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        diagnosticsExportGeneration &+= 1
        let generation = diagnosticsExportGeneration
        let report = DiagnosticsExportService.makeReport(
            permissionSnapshot: permissionStore.permissionSnapshot,
            providerAuditEvents: providerStore.providerAuditEvents
        )
        isExportingDiagnostics = true
        diagnosticsExportStatus = SettingsRowStatus(
            kind: .information,
            message: L10n.string("diagnostics.export.inProgress")
        )
        diagnosticsExportTask = Task { [report, destinationURL] in
            do {
                try await DiagnosticsExportService.writeReport(
                    report,
                    to: destinationURL
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == diagnosticsExportGeneration else {
                    return
                }
                isExportingDiagnostics = false
                diagnosticsExportStatus = SettingsRowStatus(
                    kind: .error,
                    message: L10n.string("diagnostics.export.failed")
                )
                return
            }
            guard !Task.isCancelled,
                  generation == diagnosticsExportGeneration else {
                return
            }
            isExportingDiagnostics = false
            diagnosticsExportStatus = SettingsRowStatus(
                kind: .success,
                message: L10n.string("diagnostics.export.succeeded")
            )
        }
    }

    private func retryClipboardStorage() {
        _ = clipboardStore.loadRepositoryState(limit: 500)
    }

    private func cancelDiagnosticsExport() {
        diagnosticsExportGeneration &+= 1
        diagnosticsExportTask?.cancel()
        diagnosticsExportTask = nil
        isExportingDiagnostics = false
        diagnosticsExportStatus = nil
    }

}

struct ProviderAuditRow: View {
    let event: ProviderAuditEvent
    @State private var showsTechnicalDetails = false

    private var presentation: ProviderAuditPresentation {
        ProviderAuditPresentation(event: event)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRowShell(
                title: presentation.title,
                detail: presentation.detail,
                minHeight: 58
            ) {
                HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                    Text(event.createdAt, style: .time)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    BlocksCompactIconButton(
                        systemImage: "info.circle",
                        label: L10n.string("settings.providerAuditDetails"),
                        isSelected: showsTechnicalDetails
                    ) {
                        showsTechnicalDetails.toggle()
                    }
                }
            }

            if showsTechnicalDetails {
                VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xxs) {
                    LabeledContent(L10n.string("settings.providerAuditConfirmation")) {
                        Text(presentation.technicalDetail)
                            .fontDesign(.monospaced)
                    }
                    LabeledContent(L10n.string("settings.providerAuditID")) {
                        Text(ProviderAuditID.display(event.auditID))
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, BlocksVisualTokens.Spacing.sm)
                .transition(.opacity)
            }

            ForEach(presentation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .blocksAnimation(.reveal, value: showsTechnicalDetails)
    }

}
