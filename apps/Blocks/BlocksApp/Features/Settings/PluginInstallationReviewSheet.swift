import BlocksCore
import SwiftUI

struct PluginInstallationReviewSheet: View {
    let pending: BlocksNativePluginPendingInstallation
    let knownPlugins: [String: PluginInstallationKnownPluginPresentation]
    let isProcessing: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        let disclosure = PluginInstallationDisclosurePresentation(
            manifest: pending.manifest
        )
        let presentation = pending.manifest.presentation?.localized(
            fallbackName: pending.confirmation.displayName
        ) ?? .init(
            name: pending.confirmation.displayName,
            summary: L10n.string("plugin.center.presentation.summary.fallback"),
            purpose: L10n.string("plugin.center.presentation.purpose.fallback"),
            trigger: L10n.string("plugin.center.presentation.trigger.fallback"),
            dataUsage: L10n.string("plugin.center.presentation.data.fallback")
        )
        SettingsSheetScaffold(
            title: L10n.string("plugin.center.install"),
            detail: presentation.name ?? pending.confirmation.displayName,
            preferredHeight: 560
        ) {
            VStack(alignment: .leading, spacing: 16) {
                reviewText(
                    L10n.string("plugin.center.whatItDoes.purpose"),
                    presentation.purpose
                )
                reviewText(
                    L10n.string("plugin.center.whatItDoes.when"),
                    presentation.trigger
                )
                reviewText(
                    L10n.string("plugin.center.data.access"),
                    presentation.dataUsage
                )
                if !presentation.examples.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.whatItDoes.examples"),
                        presentation.examples.joined(separator: "\n")
                    )
                }
                if pending.installationOrigin == .builtIn {
                    reviewNotice(
                        kind: .information,
                        symbol: "checkmark.seal",
                        title: L10n.string("plugin.center.review.source.builtIn"),
                        text: L10n.string("plugin.center.review.source.builtIn.detail")
                    )
                } else {
                    reviewText(
                        L10n.string("plugin.center.review.source.external"),
                        pending.sourceDisplayName
                    )
                }
                if pending.installationOrigin == .external,
                   !pending.confirmation.isSigned {
                    reviewNotice(
                        kind: .warning,
                        symbol: "exclamationmark.shield",
                        title: L10n.string("plugin.center.review.unsigned"),
                        text: L10n.string(
                            "plugin.center.review.unsigned.detail"
                        )
                    )
                }
                if !pending.confirmation.networkDomains.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.networkDomains"),
                        pending.confirmation.networkDomains.joined(separator: "\n")
                    )
                    reviewNotice(
                        kind: .warning,
                        symbol: "network",
                        title: L10n.string(
                            "plugin.center.review.networkDomains"
                        ),
                        text: L10n.string(
                            "plugin.center.review.network.notice"
                        )
                    )
                }
                if !pending.confirmation.networkMethods.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.networkMethods"),
                        pending.confirmation.networkMethods
                            .map(\.rawValue)
                            .joined(separator: ", ")
                    )
                }
                if !pending.confirmation.networkDomains.isEmpty {
                    reviewText(
                        L10n.string(
                            "plugin.center.review.networkRequestBodyLimit"
                        ),
                        networkRequestBodyLimitText(
                            pending.confirmation.networkMaximumRequestBytes
                        )
                    )
                }
                if !disclosure.secrets.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.secrets"),
                        (disclosure.secrets.map(secretDisclosureText(_:))
                            + [L10n.string("plugin.center.review.secrets.detail")])
                            .joined(separator: "\n")
                    )
                }
                if !pending.confirmation.dataPermissions.isEmpty {
                    reviewText(
                        L10n.string(
                            "plugin.center.review.dataPermissions"
                        ),
                        pending.confirmation.dataPermissions
                            .map(dataPermissionDescription(_:))
                            .joined(separator: "\n")
                    )
                }
                if !pending.confirmation.translationContextFields.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.translationContext"),
                        pending.confirmation.translationContextFields
                            .map(translationContextDescription(_:))
                            .joined(separator: "\n")
                    )
                }
                if !disclosure.hooks.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.hooks"),
                        automaticWorkflowDisclosureText(disclosure)
                    )
                }
                if disclosure.hasFailClosedWorkflow {
                    reviewNotice(
                        kind: .error,
                        symbol: "xmark.octagon",
                        title: L10n.string("plugin.center.review.failClosed"),
                        text: L10n.string("plugin.center.review.failClosed.detail")
                    )
                }
                if pending.confirmation.includesBackgroundHookExecution
                    || (pending.confirmation.includesBackgroundExecution
                        && !pending.confirmation.includesScheduledExecution) {
                    reviewNotice(
                        kind: .warning,
                        symbol: "clock.arrow.circlepath",
                        title: L10n.string(
                            "plugin.center.review.background"
                        ),
                        text: L10n.string(
                            "plugin.center.review.background.detail"
                        )
                    )
                }
                if pending.confirmation.includesScheduledExecution {
                    reviewNotice(
                        kind: .warning,
                        symbol: "calendar.badge.clock",
                        title: L10n.string("plugin.center.review.schedules"),
                        text: L10n.string("plugin.center.review.schedules.detail")
                    )
                }
                if pending.confirmation.usesPrivateStorage {
                    reviewNotice(
                        kind: .information,
                        symbol: "internaldrive",
                        title: L10n.string("plugin.center.review.privateStorage"),
                        text: L10n.string("plugin.center.review.privateStorage.detail")
                    )
                }
                if !disclosure.hostActionIDs.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.hostActions"),
                        disclosure.hostActionIDs
                            .map {
                                PluginHostActionDisclosureCatalog.description(
                                    for: $0
                                )
                            }
                            .joined(separator: "\n")
                    )
                }
                if !disclosure.importedActions.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.importedActions"),
                        importedActionDisclosureText(disclosure)
                    )
                }
                if !disclosure.sharedState.isEmpty {
                    reviewText(
                        L10n.string("plugin.center.review.sharedState"),
                        sharedStateDisclosureText(
                            disclosure,
                            currentPluginName:
                                presentation.name
                                ?? pending.confirmation.displayName
                        )
                    )
                }
                if !pending.confirmation.uiSlots.isEmpty {
                    reviewNotice(
                        kind: .information,
                        symbol: "rectangle.on.rectangle",
                        title: L10n.string("plugin.center.review.uiSlots"),
                        text: L10n.format(
                            "plugin.center.review.uiSlots.detail",
                            Int64(pending.confirmation.uiSlots.count)
                        )
                    )
                }
                SettingsInlineFeedback(
                    kind: .information,
                    title: L10n.string("plugin.center.install"),
                    detail: L10n.string(
                        "plugin.center.install.review.detail"
                    )
                )
            }
        } actions: {
            Button(L10n.string("common.cancel"), action: cancel)
                .disabled(isProcessing)
                .accessibilityLabel(L10n.string("common.cancel"))
            Button(action: confirm) {
                ZStack {
                    Text(L10n.string("plugin.center.install.approve"))
                        .opacity(isProcessing ? 0 : 1)
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("plugin.center.install.approve")
                            )
                    }
                }
                .frame(minWidth: 82)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
            .accessibilityLabel(L10n.string("plugin.center.install.approve"))
        }
    }

    private func reviewText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewNotice(
        kind: SettingsInlineFeedbackKind,
        symbol: String,
        title: String?,
        text: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.headline)
                }
                Text(text).font(.callout)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(kind.color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blocksSurface(
            .section,
            cornerRadius: BlocksVisualTokens.CornerRadius.control
        )
    }

    private func networkRequestBodyLimitText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func dataPermissionDescription(
        _ permission: BlocksNativePluginDataPermission
    ) -> String {
        switch permission {
        case .screenshotImage:
            L10n.string("plugin.center.review.data.screenshotImage")
        case .clipboardContent:
            L10n.string("plugin.center.review.data.clipboardContent")
        case .screenshotDocument:
            L10n.string("plugin.center.review.data.screenshotDocument")
        case .translationContent:
            L10n.string("plugin.center.review.data.translationContent")
        case .providerMetadata:
            L10n.string("plugin.center.review.data.providerMetadata")
        case .appContext:
            L10n.string("plugin.center.review.data.appContext")
        case .userGrantedFiles:
            L10n.string("plugin.center.review.data.userGrantedFiles")
        @unknown default:
            L10n.string("plugin.center.review.data.other")
        }
    }

    private func translationContextDescription(
        _ field: TranslationSourceContextField
    ) -> String {
        switch field {
        case .inputSource:
            L10n.string("plugin.center.review.translationContext.inputSource")
        case .sourceApplicationBundleID:
            L10n.string("plugin.center.review.translationContext.sourceApplication")
        case .ocrSummary:
            L10n.string("plugin.center.review.translationContext.ocrSummary")
        @unknown default:
            L10n.string("plugin.center.review.translationContext.other")
        }
    }

    private func secretDisclosureText(
        _ secret: PluginInstallationDisclosurePresentation.Secret
    ) -> String {
        secret.localizedDisclosureText
    }

    private func automaticWorkflowDisclosureText(
        _ disclosure: PluginInstallationDisclosurePresentation
    ) -> String {
        disclosure.hooks.map { hook in
            L10n.format(
                "plugin.center.review.hooks.item",
                PluginInstallationEventDisclosureCatalog.description(
                    for: hook.event
                ),
                L10n.string(
                    hook.runsInBackground
                        ? "plugin.center.review.hooks.background"
                        : "plugin.center.review.hooks.foreground"
                ),
                L10n.string(
                    hook.failurePolicy == .failClosed
                        ? "plugin.center.review.hooks.failClosed"
                        : "plugin.center.review.hooks.failOpen"
                )
            )
        }
        .joined(separator: "\n")
    }

    private func importedActionDisclosureText(
        _ disclosure: PluginInstallationDisclosurePresentation
    ) -> String {
        disclosure.importedActions.map { imported in
            guard let plugin = knownPlugins[imported.pluginID],
                  let actionName = plugin.actionNames[imported.actionID] else {
                return L10n.string(
                    "plugin.center.review.importedActions.unavailable"
                )
            }
            return L10n.format(
                "plugin.center.review.importedActions.item",
                actionName,
                plugin.name
            )
        }
        .joined(separator: "\n")
    }

    private func sharedStateDisclosureText(
        _ disclosure: PluginInstallationDisclosurePresentation,
        currentPluginName: String
    ) -> String {
        disclosure.sharedState.enumerated().map { index, shared in
            let ownerName: String
            if shared.ownerPluginID == pending.manifest.id {
                ownerName = currentPluginName
            } else if let known = knownPlugins[shared.ownerPluginID] {
                ownerName = known.name
            } else {
                ownerName = L10n.string(
                    "plugin.center.review.sharedState.otherPlugin"
                )
            }
            return L10n.format(
                "plugin.center.review.sharedState.item",
                L10n.string(sharedStateAccessKey(shared.access)),
                shared.displayName ?? L10n.format(
                    "plugin.center.review.sharedState.fallback",
                    Int64(index + 1)
                ),
                ownerName
            )
        }
        .joined(separator: "\n")
    }

    private func sharedStateAccessKey(
        _ access: BlocksPluginSharedStateAccess
    ) -> String {
        switch access {
        case .read: "plugin.center.review.sharedState.access.read"
        case .write: "plugin.center.review.sharedState.access.write"
        case .readWrite: "plugin.center.review.sharedState.access.readWrite"
        }
    }
}

struct PluginInstallationKnownPluginPresentation: Equatable {
    let name: String
    let actionNames: [String: String]
}

enum PluginHostActionDisclosureCatalog {
    static func description(for actionID: String) -> String {
        L10n.string(key(for: actionID))
    }

    private static func key(for actionID: String) -> String {
        switch actionID {
        case "clipboard.copy_text":
            "plugin.center.review.hostAction.clipboard.copyText"
        case "clipboard.paste_record":
            "plugin.center.review.hostAction.clipboard.pasteRecord"
        case "clipboard.record.bring_to_front":
            "plugin.center.review.hostAction.clipboard.bringToFront"
        case "clipboard.record.delete":
            "plugin.center.review.hostAction.clipboard.deleteRecord"
        case "clipboard.record.favorite":
            "plugin.center.review.hostAction.clipboard.favoriteRecord"
        case "clipboard.record.ocr":
            "plugin.center.review.hostAction.clipboard.ocrRecord"
        case "clipboard.record.read":
            "plugin.center.review.hostAction.clipboard.readRecord"
        case "clipboard.record.update":
            "plugin.center.review.hostAction.clipboard.updateRecord"
        case "clipboard.tag.attach", "clipboard.tag.detach":
            "plugin.center.review.hostAction.clipboard.changeRecordTags"
        case "clipboard.tag.delete":
            "plugin.center.review.hostAction.clipboard.deleteTag"
        case "clipboard.tag.ensure", "clipboard.tag.ensure_and_attach":
            "plugin.center.review.hostAction.clipboard.createTag"
        case "clipboard.tag.list":
            "plugin.center.review.hostAction.clipboard.readTags"
        case "clipboard.tag.rename":
            "plugin.center.review.hostAction.clipboard.renameTag"
        case "provider.capabilities.query":
            "plugin.center.review.hostAction.provider.readCapabilities"
        case "provider.request":
            "plugin.center.review.hostAction.provider.request"
        case "screenshot.annotation.add_text",
             "screenshot.annotation.delete",
             "screenshot.annotation.update_text":
            "plugin.center.review.hostAction.screenshot.changeAnnotations"
        case "screenshot.capture.start":
            "plugin.center.review.hostAction.screenshot.capture"
        case "screenshot.corner_radius.set":
            "plugin.center.review.hostAction.screenshot.changeCornerRadius"
        case "screenshot.document.snapshot":
            "plugin.center.review.hostAction.screenshot.readDocument"
        case "screenshot.ocr":
            "plugin.center.review.hostAction.screenshot.ocr"
        case "screenshot.output.archive":
            "plugin.center.review.hostAction.screenshot.archive"
        case "screenshot.output.complete":
            "plugin.center.review.hostAction.screenshot.complete"
        case "screenshot.output.copy":
            "plugin.center.review.hostAction.screenshot.copy"
        case "screenshot.output.pin":
            "plugin.center.review.hostAction.screenshot.pin"
        case "screenshot.output.save":
            "plugin.center.review.hostAction.screenshot.save"
        case "screenshot.watermark.apply_default":
            "plugin.center.review.hostAction.screenshot.watermark"
        case "screenshot.color_sample.begin":
            "plugin.center.review.hostAction.screenshot.colorSample"
        case "system.notification":
            "plugin.center.review.hostAction.system.notification"
        case "system.open_plugin_page":
            "plugin.center.review.hostAction.system.openPluginPage"
        case "system.schedule.set_enabled":
            "plugin.center.review.hostAction.system.schedule"
        case "system.shortcut.execute":
            "plugin.center.review.hostAction.system.shortcut"
        case "translation.cancel":
            "plugin.center.review.hostAction.translation.cancel"
        case "translation.copy":
            "plugin.center.review.hostAction.translation.copy"
        case "translation.favorite":
            "plugin.center.review.hostAction.translation.favorite"
        case "translation.retry":
            "plugin.center.review.hostAction.translation.retry"
        case "translation.run":
            "plugin.center.review.hostAction.translation.run"
        default:
            "plugin.center.review.hostAction.other"
        }
    }
}

/// Exact, non-sensitive permission declarations presented before installation.
/// This intentionally derives from the manifest rather than the persisted
/// confirmation summary, whose identifier-only fields omit policy details.
struct PluginInstallationDisclosurePresentation: Equatable {
    struct Hook: Equatable {
        let id: String
        let event: BlocksPluginEventName
        let failurePolicy: BlocksPluginFailurePolicy
        let runsInBackground: Bool
    }

    struct ImportedAction: Equatable {
        let pluginID: String
        let actionID: String
    }

    struct SharedState: Equatable {
        let ownerPluginID: String
        let id: String
        let displayName: String?
        let access: BlocksPluginSharedStateAccess
    }

    struct Secret: Equatable {
        let id: String
        let displayName: String
        let required: Bool
        let isSessionCredential: Bool
        let allowedDomains: [String]

        init(
            id: String,
            displayName: String,
            required: Bool,
            isSessionCredential: Bool = false,
            allowedDomains: [String] = []
        ) {
            self.id = id
            self.displayName = displayName
            self.required = required
            self.isSessionCredential = isSessionCredential
            self.allowedDomains = allowedDomains
        }

        var localizedDisclosureText: String {
            var parts = [
                displayName,
                L10n.string(
                    required
                        ? "plugin.center.review.requirement.required"
                        : "plugin.center.review.requirement.optional"
                ),
            ]
            if isSessionCredential {
                parts.append(
                    L10n.string(
                        "plugin.center.review.secrets.sessionCredential"
                    )
                )
                if !allowedDomains.isEmpty {
                    parts.append(
                        L10n.format(
                            "plugin.center.review.secrets.allowedDomains",
                            allowedDomains.joined(separator: ", ")
                        )
                    )
                }
            }
            return parts.joined(separator: " · ")
        }
    }

    let hooks: [Hook]
    let hostActionIDs: [String]
    let importedActions: [ImportedAction]
    let sharedState: [SharedState]
    let secrets: [Secret]
    let networkMaximumRequestBytes: Int?

    var hookModuleCounts: [(BlocksPluginModule, Int)] {
        BlocksPluginModule.allCases.compactMap { module in
            let count = hooks.count { $0.event.module == module }
            return count > 0 ? (module, count) : nil
        }
    }

    var hasPreflightWorkflow: Bool {
        hooks.contains { $0.event.phase == .will }
    }

    var hasFailClosedWorkflow: Bool {
        hooks.contains { $0.failurePolicy == .failClosed }
    }

    var sharedStateAccessCounts: [(BlocksPluginSharedStateAccess, Int)] {
        [BlocksPluginSharedStateAccess.read, .write, .readWrite].compactMap { access in
            let count = sharedState.count { $0.access == access }
            return count > 0 ? (access, count) : nil
        }
    }

    init(manifest: BlocksNativePluginManifest) {
        let platform = manifest.platform
        hooks = (platform?.hooks ?? []).map {
            .init(
                id: $0.id,
                event: $0.event,
                failurePolicy: $0.failurePolicy,
                runsInBackground: $0.runsInBackground
            )
        }
        hostActionIDs = platform?.hostActions ?? []
        importedActions = (platform?.importedActions ?? []).map {
            .init(pluginID: $0.pluginID, actionID: $0.actionID)
        }
        sharedState = (platform?.sharedState ?? []).map {
            .init(
                ownerPluginID: $0.ownerPluginID ?? manifest.id,
                id: $0.id,
                displayName: $0.displayName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                access: $0.access
            )
        }
        let sensitiveFieldsByID = Dictionary(
            uniqueKeysWithValues: manifest.configurationFields
                .filter { $0.type.isSensitive }
                .map { ($0.id, $0) }
        )
        secrets = manifest.permissions.secrets.map {
            let field = sensitiveFieldsByID[$0.id]
            return .init(
                id: $0.id,
                displayName: $0.displayName,
                required: $0.required,
                isSessionCredential: field?.type == .sessionCredential,
                allowedDomains: field?.allowedDomains
                    .map { $0.lowercased() }
                    .sorted() ?? []
            )
        }
        networkMaximumRequestBytes = manifest.permissions.network?
            .maximumRequestBytes
    }
}

enum PluginInstallationEventDisclosureCatalog {
    static func description(for event: BlocksPluginEventName) -> String {
        L10n.string(key(for: event))
    }

    private static func key(for event: BlocksPluginEventName) -> String {
        switch event {
        case .clipboardWillPersistCapture: "plugin.center.review.hookEvent.clipboardWillPersistCapture"
        case .clipboardDidPersistCapture: "plugin.center.review.hookEvent.clipboardDidPersistCapture"
        case .clipboardCaptureFailed: "plugin.center.review.hookEvent.clipboardCaptureFailed"
        case .clipboardWillWritePasteboard: "plugin.center.review.hookEvent.clipboardWillWritePasteboard"
        case .clipboardDidDispatchPaste: "plugin.center.review.hookEvent.clipboardDidDispatchPaste"
        case .clipboardPasteFailed: "plugin.center.review.hookEvent.clipboardPasteFailed"
        case .clipboardRecordUpdated: "plugin.center.review.hookEvent.clipboardRecordUpdated"
        case .clipboardRecordDeleted: "plugin.center.review.hookEvent.clipboardRecordDeleted"
        case .clipboardTagChanged: "plugin.center.review.hookEvent.clipboardTagChanged"
        case .clipboardOCRCompleted: "plugin.center.review.hookEvent.clipboardOCRCompleted"
        case .screenshotCaptureCompleted: "plugin.center.review.hookEvent.screenshotCaptureCompleted"
        case .screenshotCaptureFailed: "plugin.center.review.hookEvent.screenshotCaptureFailed"
        case .screenshotEditorOpened: "plugin.center.review.hookEvent.screenshotEditorOpened"
        case .screenshotElementCommitted: "plugin.center.review.hookEvent.screenshotElementCommitted"
        case .screenshotWillFinalizeOutput: "plugin.center.review.hookEvent.screenshotWillFinalizeOutput"
        case .screenshotOutputFinished: "plugin.center.review.hookEvent.screenshotOutputFinished"
        case .screenshotOutputFailed: "plugin.center.review.hookEvent.screenshotOutputFailed"
        case .screenshotOCRCompleted: "plugin.center.review.hookEvent.screenshotOCRCompleted"
        case .screenshotLongCaptureAssembled: "plugin.center.review.hookEvent.screenshotLongCaptureAssembled"
        case .translationInputResolved: "plugin.center.review.hookEvent.translationInputResolved"
        case .translationWillRunSession: "plugin.center.review.hookEvent.translationWillRunSession"
        case .translationSessionCompleted: "plugin.center.review.hookEvent.translationSessionCompleted"
        case .translationSessionFailed: "plugin.center.review.hookEvent.translationSessionFailed"
        case .translationSourceStatus: "plugin.center.review.hookEvent.translationSourceStatus"
        case .translationSourceResult: "plugin.center.review.hookEvent.translationSourceResult"
        case .translationSourceFailed: "plugin.center.review.hookEvent.translationSourceFailed"
        case .translationWillCommitResult: "plugin.center.review.hookEvent.translationWillCommitResult"
        case .translationFavoriteChanged: "plugin.center.review.hookEvent.translationFavoriteChanged"
        case .translationCopyCompleted: "plugin.center.review.hookEvent.translationCopyCompleted"
        case .providerRouteResolved: "plugin.center.review.hookEvent.providerRouteResolved"
        case .providerWillSendRequest: "plugin.center.review.hookEvent.providerWillSendRequest"
        case .providerRequestCompleted: "plugin.center.review.hookEvent.providerRequestCompleted"
        case .providerRequestFailed: "plugin.center.review.hookEvent.providerRequestFailed"
        case .automationWillExecuteShortcut: "plugin.center.review.hookEvent.automationWillExecuteShortcut"
        case .automationDidExecuteShortcut: "plugin.center.review.hookEvent.automationDidExecuteShortcut"
        case .automationManualTrigger: "plugin.center.review.hookEvent.automationManualTrigger"
        case .automationScheduledTrigger: "plugin.center.review.hookEvent.automationScheduledTrigger"
        case .appLaunched: "plugin.center.review.hookEvent.appLaunched"
        case .appWillTerminate: "plugin.center.review.hookEvent.appWillTerminate"
        case .pluginLifecycleChanged: "plugin.center.review.hookEvent.pluginLifecycleChanged"
        case .pluginSharedStateChanged: "plugin.center.review.hookEvent.pluginSharedStateChanged"
        case .pluginHostActionCompleted: "plugin.center.review.hookEvent.pluginHostActionCompleted"
        case .pluginHostActionFailed: "plugin.center.review.hookEvent.pluginHostActionFailed"
        }
    }
}
