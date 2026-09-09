import BlocksCore
import SwiftUI

struct FeedbackSettingsSection: View {
    @ObservedObject private var controller = FeedbackController.shared
    private struct ConsentContext: Identifiable {
        let id = UUID()
        let account: String
    }
    @State private var consentContext: ConsentContext?
    @State private var showComposer = false
    @State private var showLatest = false

    var body: some View {
        SettingsSection(title: L10n.string("feedback.section")) {
            SettingsToggleRow(title: L10n.string("feedback.automatic.title"),
                              detail: L10n.string("feedback.automatic.detail"),
                              isOn: Binding(get: { controller.consent.enabled }, set: { enabled in
                if enabled {
                    consentContext = ConsentContext(account: controller.account ?? "")
                } else { controller.setAutomatic(false) }
            }))
            .disabled(controller.isBusy)

            SettingsRowDivider()
            SettingsStatusRow(title: L10n.string("feedback.account.title"),
                              detail: controller.account ?? L10n.string("feedback.account.none"),
                              status: SettingsRowStatus(kind: .information, message: controller.statusText)) {
                Button(L10n.string("feedback.refresh")) { controller.refresh() }
                    .disabled(controller.isBusy)
            }
            SettingsRowDivider()
            SettingsFormRow(title: L10n.string("feedback.latest.title"), detail: L10n.string("feedback.latest.detail")) {
                Button(L10n.string("feedback.preview")) { showLatest = true }
                    .disabled(controller.latest == nil || controller.isBusy)
            }
            SettingsRowDivider()
            SettingsFormRow(title: L10n.string("feedback.manual.title"), detail: L10n.string("feedback.manual.detail")) {
                Button(L10n.string("feedback.manual.compose")) { showComposer = true }
                    .disabled(controller.isBusy)
            }
        }
        .task { controller.refresh() }
        .sheet(item: $consentContext) { context in
            SettingsSheetScaffold(title: L10n.string("feedback.consent.title"), detail: L10n.string("feedback.consent.public")) {
                SettingsReadOnlyRow(title: FeedbackPolicy.repositoryURL, detail: L10n.format("feedback.consent.account", context.account.isEmpty ? L10n.string("feedback.account.none") : context.account))
                SettingsReadOnlyRow(title: L10n.string("feedback.consent.fields.title"), detail: L10n.string("feedback.consent.fields"))
                SettingsReadOnlyRow(title: L10n.string("feedback.consent.excludes.title"), detail: L10n.string("feedback.consent.excludes"))
                SettingsSectionNote(text: L10n.string("feedback.consent.behavior"))
            } actions: {
                Button(L10n.string("feedback.cancel")) { consentContext = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.string("feedback.consent.enable")) {
                    controller.setAutomatic(true, account: context.account)
                    consentContext = nil
                }
                .disabled(context.account.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $showComposer) { FeedbackComposerView() }
        .sheet(isPresented: $showLatest) {
            if let report = controller.latest { FeedbackComposerView(report: report) }
        }
    }
}
