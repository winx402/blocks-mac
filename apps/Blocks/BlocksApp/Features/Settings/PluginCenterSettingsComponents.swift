import BlocksCore
import SwiftUI

enum PluginCenterRoute: Equatable {
    case catalog
    case installed(String)
    case builtIn(String)

    init(token: String) {
        if token.hasPrefix("installed:") {
            self = .installed(String(token.dropFirst("installed:".count)))
        } else if token.hasPrefix("builtin:") {
            self = .builtIn(String(token.dropFirst("builtin:".count)))
        } else {
            self = .catalog
        }
    }

    var token: String {
        switch self {
        case .catalog: "catalog"
        case let .installed(id): "installed:\(id)"
        case let .builtIn(id): "builtin:\(id)"
        }
    }
}

extension BlocksBuiltInPluginCategory {
    var localizedTitle: String {
        switch self {
        case .clipboard:
            L10n.string("plugin.center.category.clipboard")
        case .screenshot:
            L10n.string("plugin.center.category.screenshot")
        case .translation:
            L10n.string("plugin.center.category.translation")
        case .productivity:
            L10n.string("plugin.center.category.productivity")
        }
    }
}

enum PluginCenterOperationScope: Equatable {
    case catalog
    case installation
    case plugin(String)
}

enum PluginCenterCatalogPolicy {
    static func visibleEntries(
        _ entries: [BlocksBuiltInPluginCatalogEntry],
        installedPluginIDs: Set<String>,
        query: String
    ) -> [BlocksBuiltInPluginCatalogEntry] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return entries.filter { entry in
            guard !installedPluginIDs.contains(entry.id) else {
                return false
            }
            let localization = entry.localized()
            return normalizedQuery.isEmpty
                || localization.name.localizedCaseInsensitiveContains(
                    normalizedQuery
                )
                || localization.summary.localizedCaseInsensitiveContains(
                    normalizedQuery
                )
        }
    }
}

struct PluginCenterSymbol: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.54, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .blocksSurface(
                .section,
                cornerRadius: BlocksVisualTokens.CornerRadius.control
            )
            .accessibilityHidden(true)
    }
}

struct PluginCenterSafeModeRow: View {
    @ObservedObject var runtime: BlocksPluginRuntimeCoordinator

    var body: some View {
        SettingsFormRow(
            title: L10n.string("plugin.center.safeMode"),
            detail: L10n.string("plugin.center.safeMode.help")
        ) {
            SettingsBooleanSwitch(
                L10n.string("plugin.center.safeMode"),
                isOn: Binding(
                    get: { runtime.safeModeEnabled },
                    set: { enabled in
                        Task { @MainActor in
                            await runtime.setSafeModeEnabled(enabled)
                        }
                    }
                )
            )
            .disabled(runtime.safeModeTransitionInProgress)
        }
    }
}

struct PluginCenterActivityRow: View {
    let plugin: BlocksNativePluginMetadata
    @ObservedObject var runtime: BlocksPluginRuntimeCoordinator
    let operationInFlight: Bool
    let resume: () -> Void

    var body: some View {
        if let activity = runtime.recentActivityByPluginID[plugin.id] {
            SettingsStatusRow(
                title: activityTitle(activity.state),
                detail: activity.message?.isEmpty == false
                    ? activity.message
                    : nil,
                status: SettingsRowStatus(
                    kind: activityFeedbackKind(activity.state),
                    message: activity.occurredAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            ) {
                if activity.state == .failed || plugin.safetyDisabled {
                    Button(
                        L10n.string("plugin.center.activity.resume"),
                        action: resume
                    )
                    .disabled(operationInFlight)
                }
            }
        } else {
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.activity.notRun"),
                detail: L10n.string("plugin.center.activity.notRun.detail")
            )
        }
    }

    private func activityFeedbackKind(
        _ state: BlocksPluginRecentActivity.State
    ) -> SettingsInlineFeedbackKind {
        switch state {
        case .running: .information
        case .succeeded: .success
        case .failed: .error
        }
    }

    private func activityTitle(
        _ state: BlocksPluginRecentActivity.State
    ) -> String {
        switch state {
        case .running: L10n.string("plugin.center.activity.running")
        case .succeeded: L10n.string("plugin.center.activity.succeeded")
        case .failed: L10n.string("plugin.center.activity.failed")
        }
    }
}

struct PluginCenterDetailHeader<Trailing: View>: View {
    let name: String
    let summary: String
    let symbolName: String
    let symbolColor: Color
    let showsOfficialBadge: Bool
    let backAction: () -> Void
    @ViewBuilder let trailing: Trailing

    init(
        name: String,
        summary: String,
        symbolName: String,
        symbolColor: Color,
        showsOfficialBadge: Bool,
        backAction: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.symbolColor = symbolColor
        self.showsOfficialBadge = showsOfficialBadge
        self.backAction = backAction
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.sm) {
            SettingsSecondaryPageHeader(
                title: name,
                backTitle: L10n.string("plugin.center.back"),
                backAction: backAction
            )

            HStack(spacing: BlocksVisualTokens.Spacing.md) {
                PluginCenterSymbol(
                    systemName: symbolName,
                    color: symbolColor,
                    size: 36
                )
                VStack(
                    alignment: .leading,
                    spacing: BlocksVisualTokens.Spacing.xxs
                ) {
                    if showsOfficialBadge {
                        Label(
                            L10n.string("plugin.center.official.badge"),
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BlocksVisualTokens.Spacing.md)
                trailing
            }
            .padding(
                .horizontal,
                SettingsLayout.sectionContentHorizontalInset
            )
            .frame(minHeight: 52)
        }
    }
}
