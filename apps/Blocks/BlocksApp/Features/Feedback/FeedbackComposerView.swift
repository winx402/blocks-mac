import BlocksCore
import SwiftUI

struct FeedbackComposerView: View {
    var report: FeedbackReport? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller = FeedbackController.shared
    @State private var title = ""
    @State private var bodyText = ""
    @State private var preview: FeedbackPreview?
    @State private var previewAccount = ""
    @State private var validationFailed = false

    var body: some View {
        SettingsSheetScaffold(title: L10n.string("feedback.manual.title"), detail: L10n.string("feedback.consent.public")) {
            SettingsReadOnlyRow(title: FeedbackPolicy.repositoryURL,
                                detail: L10n.format("feedback.consent.account", previewAccount.isEmpty ? controller.account ?? L10n.string("feedback.account.none") : previewAccount))
            if let preview {
                SettingsReadOnlyRow(title: preview.title, detail: preview.body)
            } else {
                SettingsTextFieldRow(title: L10n.string("feedback.composer.title"), detail: nil, text: $title)
                SettingsReadOnlyRow(title: L10n.string("feedback.composer.body"), detail: L10n.string("feedback.manual.detail"))
                TextEditor(text: $bodyText)
                    .font(.body)
                    .accessibilityLabel(L10n.string("feedback.composer.body"))
                    .frame(minHeight: SettingsLayout.rowMinHeight * 3)
            }
            SettingsFeedbackSlot(feedback: SettingsFeedbackDescriptor(kind: validationFailed ? .warning : .information,
                title: L10n.string("feedback.section"), detail: validationFailed ? L10n.string("feedback.status.credential") : controller.statusText))
            if let url = controller.issueURL, let destination = URL(string: url) {
                Link(L10n.string("feedback.openIssue"), destination: destination)
            }
        } actions: {
            Button(L10n.string("feedback.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                .disabled(controller.isBusy)
            if preview != nil {
                if report == nil {
                    Button(L10n.string("feedback.edit")) { preview = nil }.disabled(controller.isBusy)
                }
                Button(L10n.string("feedback.submitPublic")) {
                    guard !previewAccount.isEmpty else { return }
                    if let report { controller.submitLatest(id: report.id, expectedAccount: previewAccount) }
                    else { controller.create(title: title, body: bodyText, expectedAccount: previewAccount) }
                }
                .disabled(controller.isBusy || previewAccount.isEmpty || controller.issueURL != nil)
            } else {
                Button(L10n.string("feedback.preview")) {
                    do {
                        preview = try FeedbackService().manualPreview(title: title, body: bodyText)
                        previewAccount = controller.account ?? ""
                        validationFailed = false
                    } catch { validationFailed = true }
                }
                .disabled(controller.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            controller.prepareComposer()
            if let report {
                preview = FeedbackPreview(title: report.publicTitle, body: report.publicBody)
                previewAccount = controller.account ?? ""
            }
        }
    }
}
