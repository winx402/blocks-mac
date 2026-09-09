import AppKit
import BlocksCore
import SwiftUI

struct GeneralSettingsPane: View {
    @EnvironmentObject private var appearanceStore: AppAppearanceStore
    @AppStorage("app.language") private var selectedLanguageRawValue = AppLanguagePreference.system.rawValue
    @State private var glassDiagnosticsExpanded = false
    @ObservedObject private var appUpdates = AppUpdateCoordinator.shared

    private var selectedLanguage: Binding<AppLanguagePreference> {
        Binding {
            AppLanguagePreference(rawValue: selectedLanguageRawValue) ?? .system
        } set: { preference in
            selectedLanguageRawValue = preference.rawValue
        }
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        FeedbackSettingsSection()

        SettingsSection(
            title: L10n.string("settings.general.application")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.appearance.picker"),
                detail: L10n.string("settings.appearance.detail")
            ) {
                Picker(
                    L10n.string("settings.appearance.picker"),
                    selection: Binding(
                        get: { appearanceStore.preference },
                        set: { preference in
                            // A segmented Picker writes its binding while SwiftUI is
                            // reconciling the control. Applying the application-wide
                            // appearance synchronously from that callback publishes a
                            // new environment during the same update pass. Move the
                            // mutation to the next main-actor turn so the control can
                            // finish committing its selection first.
                            Task { @MainActor in
                                await Task.yield()
                                appearanceStore.setPreference(preference)
                            }
                        }
                    )
                ) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Label(preference.displayName, systemImage: preference.systemImage)
                            .tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(L10n.string("settings.appearance.picker"))
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.languagePicker"),
                detail: L10n.string("settings.languageRestartNote")
            ) {
                Picker(L10n.string("settings.languagePicker"), selection: selectedLanguage) {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(preference.displayName)
                            .tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingsRowDivider()

            DisclosureGroup(isExpanded: $glassDiagnosticsExpanded) {
                VStack(spacing: 0) {
                    SettingsFormRow(
                        title: L10n.string("settings.glassDiagnostics.system"),
                        detail: SystemTransparencyDiagnostics.reduceTransparencyEnabled
                            ? L10n.string("settings.glassDiagnostics.reduceOnDetail")
                            : L10n.string("settings.glassDiagnostics.reduceOffDetail")
                    ) {
                        Text(SystemTransparencyDiagnostics.reduceTransparencyEnabled ? L10n.string("settings.glassDiagnostics.reduceOn") : L10n.string("settings.glassDiagnostics.reduceOff"))
                            .foregroundStyle(SystemTransparencyDiagnostics.reduceTransparencyEnabled ? .orange : .secondary)
                    }

                    SettingsRowDivider()

                    SettingsFormRow(
                        title: L10n.string("settings.glassDiagnostics.materialNote"),
                        detail: nil
                    ) {
                        Text("macOS")
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label(L10n.string("settings.diagnostics.disclosure"), systemImage: "circle.lefthalf.filled")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
        }

        SettingsSection(
            title: L10n.string("release.section.title")
        ) {
            SettingsFormRow(
                title: L10n.string("release.version.title"),
                detail: BlocksReleaseMetadata.releaseName
            ) {
                Text("\(BlocksReleaseMetadata.version) (\(BlocksReleaseMetadata.build))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("release.channel.title"),
                detail: channelDetail
            ) {
                Text(DistributionChannel.current.localizedName)
                    .foregroundStyle(.secondary)
            }

            SettingsRowDivider()

            SettingsStatusRow(
                title: L10n.string("updates.title"),
                detail: L10n.string("updates.detail"),
                status: SettingsRowStatus(
                    kind: appUpdates.isAvailable ? .information : .warning,
                    message: appUpdates.statusText
                )
            ) {
                Button(appUpdates.checkButtonTitle) {
                    appUpdates.checkForUpdates()
                }
                .disabled(!appUpdates.canCheckForUpdates)
                .help(appUpdates.statusText)
            }

            SettingsRowDivider()

            SettingsToggleRow(
                title: L10n.string("updates.automatic.title"),
                detail: L10n.string("updates.automatic.detail"),
                isOn: Binding(
                    get: { appUpdates.automaticallyChecksForUpdates },
                    set: { appUpdates.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .disabled(!appUpdates.canChangePreferences)

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("updates.track.title"),
                detail: L10n.string("updates.track.detail")
            ) {
                Picker(L10n.string("updates.track.title"), selection: Binding(
                    get: { appUpdates.track },
                    set: { appUpdates.setTrack($0) }
                )) {
                    ForEach(AppUpdateTrack.allCases) { track in
                        Text(track.title).tag(track)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!appUpdates.canChangePreferences)
                .accessibilityLabel(L10n.string("updates.track.title"))
            }
        }
    }

    private var channelDetail: String {
        switch DistributionChannel.current {
        case .development, .localDevelopment:
            L10n.string("release.channel.developmentDetail")
        case .directStable:
            L10n.string("updates.distribution.official")
        case .directBeta:
            L10n.string("release.channel.directBetaDetail")
        case .appStoreBeta:
            L10n.string("release.channel.appStoreBetaDetail")
        }
    }
}

enum SystemTransparencyDiagnostics {
    static var reduceTransparencyEnabled: Bool {
        let domains = [
            UserDefaults.standard.persistentDomain(forName: "com.apple.universalaccess"),
            UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
            UserDefaults.standard.persistentDomain(forName: "com.apple.Accessibility")
        ]
        for domain in domains.compactMap({ $0 }) {
            for key in ["reduceTransparency", "AppleReduceTransparency", "ReduceTransparency"] {
                if let boolValue = domain[key] as? Bool {
                    return boolValue
                }
                if let intValue = domain[key] as? Int {
                    return intValue != 0
                }
            }
        }
        return false
    }
}
