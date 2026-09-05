import AppKit
import BlocksCore
import SwiftUI

struct PermissionSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var permissionStore: PermissionStore
    @State private var diagnosticsExpanded = false
    @State private var permissionHelpExpanded = false
    @State private var restartFeedback: SettingsFeedbackDescriptor?

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        SettingsSection(
            title: L10n.string("settings.permissionsPrivacy")
        ) {
            PermissionDiagnosticRow(
                diagnostic: permissionStore.permissionSnapshot.screenRecording,
                requestAction: appModel.requestScreenRecordingPermissionAssist
            )
            SettingsRowDivider()
            PermissionDiagnosticRow(
                diagnostic: permissionStore.permissionSnapshot.accessibility,
                requestAction: appModel.requestAccessibilityPermissionAssist
            )
            if let controller = appModel.selectionHelperSettingsController {
                SettingsRowDivider()
                SelectionHelperPermissionStatusRow(controller: controller)
            }
            SettingsRowDivider()
            PermissionDiagnosticRow(
                diagnostic: permissionStore.permissionSnapshot.inputMonitoring,
                requestAction: { permissionStore.requestInputMonitoringPermissionAssist() }
            )
            SettingsRowDivider()
            SettingsActionRow(
                title: L10n.string("settings.permissionRefresh"),
                detail: permissionStore.permissionSnapshot.screenRecordingRestartLikely
                    ? L10n.string("status.screenRecordingRestartRequired.detail")
                    : nil
            ) {
                Button {
                    appModel.refreshPermissionState()
                } label: {
                    Label(
                        L10n.string("settings.permissionRefresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
                if permissionStore.permissionSnapshot.screenRecordingRestartLikely {
                    Button {
                        restartFeedback = nil
                        appModel.restartForPermissionRefresh { result in
                            guard result == .failed else {
                                return
                            }
                            restartFeedback = SettingsFeedbackDescriptor(
                                kind: .error,
                                title: L10n.string("permission.assist.state.failed"),
                                detail: L10n.string("settings.permissionActionReopen")
                            )
                        }
                    } label: {
                        Label(L10n.string("settings.permissionRestartApp"), systemImage: "power")
                    }
                }
            }
            if permissionStore.permissionSnapshot.screenRecordingRestartLikely {
                SettingsRowDivider()
                SettingsFeedbackSlot(feedback: restartFeedback)
            }
        }

        SettingsSection(title: L10n.string("settings.permissionHelp")) {
            DisclosureGroup(isExpanded: $permissionHelpExpanded) {
                VStack(spacing: 0) {
                    SettingsActionRow(
                        title: L10n.string("settings.permissionShowInFinder"),
                        detail: L10n.string("settings.permissionDrag.detail")
                    ) {
                        Button {
                            appModel.revealCurrentAppInFinder()
                        } label: {
                            Label(
                                L10n.string("settings.permissionShowInFinder"),
                                systemImage: "folder"
                            )
                        }
                    }

                    SettingsRowDivider()
                    PermissionDragDropCard()

                    SettingsRowDivider()
                    DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                        VStack(spacing: BlocksVisualTokens.Spacing.md) {
                            PermissionDiagnosticCard(diagnostic: permissionStore.permissionSnapshot.screenRecording)
                            Divider()
                            PermissionDiagnosticCard(diagnostic: permissionStore.permissionSnapshot.accessibility)
                            Divider()
                            PermissionDiagnosticCard(diagnostic: permissionStore.permissionSnapshot.inputMonitoring)
                        }
                        .padding(.vertical, BlocksVisualTokens.Spacing.sm)
                    } label: {
                        Label(
                            L10n.string("settings.permissionDiagnostics.disclosure"),
                            systemImage: "stethoscope"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .padding(.vertical, SettingsLayout.rowVerticalPadding)
                }
            } label: {
                Label(
                    L10n.string("settings.permissionHelpDisclosure"),
                    systemImage: "questionmark.circle"
                )
                .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
        }
    }
}

private struct SelectionHelperPermissionStatusRow: View {
    @ObservedObject var controller: SelectionHelperSettingsController

    var body: some View {
        SettingsStatusRow(
            title: L10n.string("translation.selectionHelper.title"),
            detail: nil,
            status: status
        ) {
            actions
        }
        .onAppear {
            controller.refresh()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("translation.selectionHelper.title"))
        .accessibilityValue(stateDetail)
    }

    private var status: SettingsRowStatus {
        SettingsRowStatus(kind: feedbackKind, message: stateDetail)
    }

    private var feedbackKind: SettingsInlineFeedbackKind {
        switch controller.state {
        case .ready:
            .success
        case .checking, .connecting:
            .information
        case .notInstalled, .notRunning, .notPaired,
             .missingAccessibilityPermission, .versionOutdated:
            .warning
        case .installationConflict, .connectionFailed:
            .error
        }
    }

    private var stateDetail: String {
        let suffix: String
        switch controller.state {
        case .checking:
            suffix = "checking"
        case .notInstalled:
            suffix = "notInstalled"
        case .notRunning:
            suffix = "notRunning"
        case .installationConflict:
            suffix = "installationConflict"
        case .notPaired:
            suffix = "notPaired"
        case .connecting:
            suffix = "connecting"
        case .missingAccessibilityPermission:
            suffix = "missingPermission"
        case let .ready(version):
            return L10n.format("translation.selectionHelper.state.ready", version)
        case .versionOutdated:
            suffix = "outdated"
        case .connectionFailed:
            suffix = "connectionFailed"
        }
        return L10n.string("translation.selectionHelper.state.\(suffix)")
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.state {
        case .checking, .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.string("translation.selectionHelper.connecting"))
        case .notInstalled:
            Button(L10n.string("translation.selectionHelper.download")) {
                controller.openDownloadPage()
            }
        case .notRunning, .notPaired:
            Button(L10n.string("translation.selectionHelper.open")) {
                controller.openHelper()
            }
        case .missingAccessibilityPermission:
            Button(L10n.string("translation.selectionHelper.requestPermission")) {
                controller.requestAccessibilityPermission()
            }
            Button(L10n.string("translation.selectionHelper.openPermissionSettings")) {
                controller.openAccessibilitySettings()
            }
        case .versionOutdated:
            Button(L10n.string("translation.selectionHelper.update")) {
                controller.openDownloadPage()
            }
        case .ready, .installationConflict, .connectionFailed:
            Button(L10n.string("translation.selectionHelper.recheck")) {
                controller.refresh()
            }
        }
    }
}

struct PermissionDiagnosticCard: View {
    let diagnostic: PermissionDiagnosticSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            LabeledContent(L10n.string("settings.permissionDiagnostic.status")) {
                Text(diagnostic.granted ? L10n.string("settings.granted") : L10n.string("settings.missing"))
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.bundleID")) {
                Text(diagnostic.bundleID)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.appPath")) {
                Text(diagnostic.appPath)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.signature")) {
                Text(signatureText)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.teamID")) {
                Text(diagnostic.teamID ?? L10n.string("settings.permissionDiagnostic.none"))
                    .textSelection(.enabled)
            }
            if diagnostic.kind == .screenRecording {
                LabeledContent(L10n.string("settings.permissionDiagnostic.usageDescription")) {
                    Text(diagnostic.hasUsageDescription ? L10n.string("settings.present") : L10n.string("settings.missing"))
                }
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.recommendedAction")) {
                Text(recommendedActionText)
                    .foregroundStyle(diagnostic.granted ? .secondary : .primary)
            }
            LabeledContent(L10n.string("settings.permissionDiagnostic.identityIssue")) {
                Text(identityIssueText)
                    .foregroundStyle(diagnostic.identityIssue == .none ? Color.secondary : Color.orange)
            }
            if !diagnostic.matchingRunningAppPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("settings.permissionDiagnostic.runningPaths"))
                        .font(.caption.weight(.semibold))
                    ForEach(diagnostic.matchingRunningAppPaths, id: \.self) { path in
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.vertical, BlocksVisualTokens.Spacing.xs)
    }

    private var title: String {
        switch diagnostic.kind {
        case .screenRecording:
            L10n.string("settings.screenRecording")
        case .accessibility:
            L10n.string("permission.assist.blocksAccessibility.title")
        case .inputMonitoring:
            L10n.string("permission.assist.inputMonitoring.title")
        }
    }

    private var systemImage: String {
        switch diagnostic.kind {
        case .screenRecording:
            "record.circle"
        case .accessibility:
            "figure.wave"
        case .inputMonitoring:
            "keyboard"
        }
    }

    private var signatureText: String {
        switch diagnostic.signatureKind {
        case "adhoc":
            return L10n.string("settings.permissionDebugAdHoc")
        case "signed":
            return L10n.format("settings.permissionDebugTeamID", diagnostic.teamID ?? "-")
        default:
            return diagnostic.signatureKind
        }
    }

    private var recommendedActionText: String {
        switch diagnostic.recommendedAction {
        case .granted:
            L10n.string("settings.permissionActionGranted")
        case .requestInSystemSettings:
            L10n.string("settings.permissionActionRequest")
        case .reopenApp:
            L10n.string("settings.permissionActionReopen")
        case .stableSigningRecommended:
            L10n.string("settings.permissionActionStableSigning")
        case .signingOrIdentityMismatch:
            L10n.string("settings.permissionActionSigningOrIdentityMismatch")
        }
    }

    private var identityIssueText: String {
        switch diagnostic.identityIssue {
        case .none:
            L10n.string("settings.permissionIdentityIssue.none")
        case .adHocSigned:
            L10n.string("settings.permissionIdentityIssue.adHocSigned")
        case .missingUsageDescription:
            L10n.string("settings.permissionIdentityIssue.missingUsageDescription")
        case .signingOrIdentityMismatch:
            L10n.string("settings.permissionIdentityIssue.signingOrIdentityMismatch")
        }
    }
}

struct PermissionDiagnosticRow: View {
    let diagnostic: PermissionDiagnosticSnapshot
    let requestAction: () -> Void

    var body: some View {
        SettingsRowShell(
            title: title,
            detail: diagnostic.granted ? nil : recommendedActionText,
            minHeight: 56
        ) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                Label(
                    diagnostic.granted ? L10n.string("settings.granted") : L10n.string("settings.missing"),
                    systemImage: diagnostic.granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(diagnostic.granted ? .green : .orange)
                if !diagnostic.granted {
                    Button(requestButtonTitle, action: requestAction)
                }
            }
        }
    }

    private var requestButtonTitle: String {
        switch diagnostic.kind {
        case .screenRecording:
            L10n.string("settings.permissionRequestScreenRecording")
        case .accessibility:
            L10n.string("settings.permissionRequestAccessibility")
        case .inputMonitoring:
            L10n.string("settings.permissionRequestInputMonitoring")
        }
    }

    private var title: String {
        switch diagnostic.kind {
        case .screenRecording:
            L10n.string("settings.screenRecording")
        case .accessibility:
            L10n.string("permission.assist.blocksAccessibility.title")
        case .inputMonitoring:
            L10n.string("permission.assist.inputMonitoring.title")
        }
    }

    private var recommendedActionText: String {
        diagnostic.recommendedAction.localizedPrimaryRowDetail
    }
}

extension PermissionRecommendedAction {
    var localizedPrimaryRowDetail: String {
        switch self {
        case .granted:
            L10n.string("settings.permissionActionGranted")
        case .requestInSystemSettings:
            L10n.string("settings.permissionActionRequest")
        case .reopenApp:
            L10n.string("settings.permissionActionReopen")
        case .stableSigningRecommended, .signingOrIdentityMismatch:
            // Keep signing, bundle identity and TCC diagnostics inside the
            // explicit help disclosure. The primary permission row should
            // describe the user action instead of exposing build internals.
            L10n.string("settings.permissionActionRequest")
        }
    }
}

struct PermissionDragDropCard: View {
    private var appURL: URL {
        Bundle.main.bundleURL
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 42, height: 42)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.control,
                        style: .continuous
                    )
                )
                .onDrag {
                    NSItemProvider(object: appURL as NSURL)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("settings.permissionDrag.title"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("settings.permissionDrag.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(L10n.string("settings.permissionDrag.badge"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .blocksSurface(
                    .interactive,
                    cornerRadius: BlocksVisualTokens.CornerRadius.pill
                )
        }
        .padding(.vertical, BlocksVisualTokens.Spacing.sm)
    }
}
