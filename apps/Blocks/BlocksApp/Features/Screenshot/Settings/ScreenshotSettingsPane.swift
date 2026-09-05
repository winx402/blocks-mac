import AppKit
import BlocksScreenshotCore
import SwiftUI

struct ScreenshotSettingsPane: View {
    @EnvironmentObject private var screenshotStore: ScreenshotStore

    var body: some View {
        ScreenshotSettingsWorkbench(store: screenshotStore.preferencesStore)
            .blocksImmediateTooltipHost()
    }
}

private struct ScreenshotSettingsWorkbench: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @ObservedObject var store: ScreenshotPreferencesStore
    @State private var showsEditorConfiguration = false
    @StateObject private var notificationState = BlocksNotificationPresentationState()

    private static let rootRouteToken = "root"
    private static let watermarkRouteToken = "watermarks"

    private var preferences: ScreenshotPreferences { store.preferences }

    private var routeToken: Binding<String> {
        routeStateStore.secondaryRouteBinding(
            for: .screenshot,
            default: Self.rootRouteToken
        )
    }

    private var showsWatermarkLibrary: Bool {
        routeToken.wrappedValue == Self.watermarkRouteToken
    }

    private func setWatermarkLibraryVisible(_ isVisible: Bool) {
        routeToken.wrappedValue = isVisible
            ? Self.watermarkRouteToken
            : Self.rootRouteToken
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: BlocksVisualTokens.Spacing.xl
        ) {
            if showsWatermarkLibrary {
                SettingsSecondaryPageHeader(
                    title: L10n.string("settings.screenshot.watermarks"),
                    backTitle: L10n.string("common.back"),
                    backAction: {
                        setWatermarkLibraryVisible(false)
                        routeStateStore.restoreSecondaryRoute(
                            for: .screenshot,
                            anchorID: SettingsSecondaryRouteAnchor.screenshotWatermarks
                        )
                    }
                )
                ScreenshotWatermarkSettingsLibrary(store: store)
            } else {
                SettingsSection(title: L10n.string("settings.screenshot.feature")) {
                    SettingsFormRow(
                        title: L10n.string("settings.screenshot.feature.enabled"),
                        detail: L10n.string("settings.screenshot.feature.enabled.detail")
                    ) {
                        SettingsBooleanSwitch(
                            L10n.string("settings.screenshot.feature.enabled"),
                            isOn: Binding(
                                get: { appModel.featureAvailabilityStore.screenshotEnabled },
                                set: { appModel.setScreenshotFeatureEnabled($0) }
                            )
                        )
                    }
                }

                VStack(
                    alignment: .leading,
                    spacing: BlocksVisualTokens.Spacing.xl
                ) {
                SettingsSection(
                    title: L10n.string("settings.screenshot.capture"),
                    headerActions: {
                        resetSectionButton {
                            performReset(store.resetCaptureDefaults)
                        }
                    }
                ) {
                    ScreenshotCaptureDefaultsRows(
                        defaults: binding(\.captureDefaults),
                        customConstraints: preferences.customConstraints,
                        watermarkPresets: preferences.watermarkPresets,
                        onSaveConstraint: store.saveCustomConstraint,
                        onDeleteConstraint: store.removeCustomConstraint
                    )
                    SettingsRowDivider()
                    SettingsFormRow(
                        title: L10n.string("settings.screenshot.retainsCaptureDefaults"),
                        detail: L10n.string("settings.screenshot.retainsCaptureDefaults.detail")
                    ) {
                        SettingsBooleanSwitch(
                            L10n.string("settings.screenshot.retainsCaptureDefaults"),
                            isOn: binding(\.retainsCaptureDefaults)
                        )
                    }
                }

                SettingsSection(
                    title: L10n.string("settings.screenshot.editor"),
                    headerActions: {
                        resetSectionButton {
                            performReset(store.resetEditorDefaults)
                        }
                    }
                ) {
                    ScreenshotEditorLayoutPreview(
                        quickTools: preferences.visibleQuickToolbarItemIDs,
                        extendedTools: preferences.visibleExtendedToolbarItemIDs,
                        onConfigure: { showsEditorConfiguration = true }
                    )
                    .padding(.vertical, 6)
                    SettingsRowDivider()
                    SettingsFormRow(
                        title: L10n.string("settings.screenshot.confirmsDiscardBeforeClosing"),
                        detail: L10n.string("settings.screenshot.confirmsDiscardBeforeClosing.detail")
                    ) {
                        SettingsBooleanSwitch(
                            L10n.string("settings.screenshot.confirmsDiscardBeforeClosing"),
                            isOn: binding(\.confirmsDiscardBeforeClosing)
                        )
                    }
                }

                SettingsSection(title: L10n.string("settings.screenshot.watermarks")) {
                    SettingsNavigationRow(
                        title: L10n.string("settings.screenshot.watermarks"),
                        detail: L10n.string("settings.screenshot.watermarks.default.detail"),
                        value: String(preferences.watermarkPresets.count),
                        action: { setWatermarkLibraryVisible(true) }
                    )
                    .id(SettingsSecondaryRouteAnchor.screenshotWatermarks)
                }

                SettingsSection(
                    title: L10n.string("settings.screenshot.output"),
                    headerActions: {
                        resetSectionButton {
                            performReset(store.resetOutputDefaults)
                        }
                    }
                ) {
                    SettingsFormRow(title: L10n.string("settings.screenshot.format")) {
                        Picker("", selection: binding(\.outputFormat)) {
                            Text("PNG").tag(ScreenshotOutputFormat.png)
                            Text("JPEG").tag(ScreenshotOutputFormat.jpeg)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 112)
                    }
                    if preferences.outputFormat == .jpeg {
                        SettingsRowDivider()
                        SettingsFormRow(title: L10n.string("settings.screenshot.jpegQuality")) {
                            HStack(spacing: 8) {
                                Slider(value: binding(\.jpegQuality), in: 0.5...1)
                                    .frame(width: 170)
                                    .accessibilityLabel(L10n.string("settings.screenshot.jpegQuality"))
                                Text("\(Int((preferences.jpegQuality * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                    SettingsRowDivider()
                    SettingsFormRow(
                        title: L10n.string("settings.screenshot.automaticallyRecognizesHistory"),
                        detail: L10n.string("settings.screenshot.automaticallyRecognizesHistory.detail")
                    ) {
                        SettingsBooleanSwitch(
                            L10n.string("settings.screenshot.automaticallyRecognizesHistory"),
                            isOn: binding(\.automaticallyRecognizesHistory)
                        )
                            .accessibilityHint(L10n.string("settings.screenshot.automaticallyRecognizesHistory.detail"))
                    }
                }
            }

                .disabled(!appModel.featureAvailabilityStore.screenshotEnabled)
            }
        }
        .overlay(alignment: .topTrailing) {
            BlocksNotificationHost(state: notificationState)
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
        .sheet(isPresented: $showsEditorConfiguration) {
            ScreenshotEditorConfigurationSheet(store: store)
                .frame(width: 640)
                .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(
            showsWatermarkLibrary
                ? L10n.string("settings.screenshot.watermarks")
                : L10n.string("settings.screenshot.title")
        )
        .onDisappear { notificationState.shutdown() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ScreenshotPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func performReset(_ action: () -> Void) {
        action()
        notificationState.present(BlocksNotificationDescriptor(
            level: .success,
            title: L10n.string("settings.screenshot.restoreSection"),
            deduplicationKey: "screenshot.settings.reset"
        ))
    }

    private func resetSectionButton(
        action: @escaping () -> Void
    ) -> some View {
        BlocksCompactIconButton(
            systemImage: "arrow.counterclockwise",
            label: L10n.string("settings.screenshot.restoreSection"),
            density: .compact,
            action: action
        )
    }
}

private extension View {
    func settingsAttentionPulse(
        request: SettingsAttentionRequest?,
        target: SettingsAttentionTarget
    ) -> some View {
        modifier(SettingsAttentionPulseModifier(request: request, target: target))
    }
}

private struct SettingsAttentionPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: SettingsAttentionRequest?
    let target: SettingsAttentionTarget

    @State private var highlighted = false
    @State private var pulseTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.control,
                    style: .continuous
                )
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(highlighted ? 1 : 0)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
                    .allowsHitTesting(false)
            }
            .onChange(of: request?.token) { _, _ in
                guard request?.target == target else { return }
                runPulse()
            }
            .onAppear {
                guard request?.target == target else { return }
                runPulse()
            }
            .onDisappear {
                pulseTask?.cancel()
                pulseTask = nil
            }
    }

    private func runPulse() {
        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            let iterations = reduceMotion ? 1 : 2
            for _ in 0..<iterations {
                withAnimation(BlocksMotionRole.hoverFocus.animation(reduceMotion: reduceMotion)) {
                    highlighted = true
                }
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled else { return }
                withAnimation(BlocksMotionRole.hoverFocus.animation(reduceMotion: reduceMotion)) {
                    highlighted = false
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            highlighted = false
        }
    }
}

private struct ScreenshotCaptureDefaultsRows: View {
    @Binding var defaults: ScreenshotCaptureDefaults
    let customConstraints: [ScreenshotCustomConstraintPreset]
    let watermarkPresets: [ScreenshotWatermarkPreset]
    let onSaveConstraint: (ScreenshotCustomConstraintPreset) -> Void
    let onDeleteConstraint: (UUID) -> Void
    @State private var showsSizePanel = false

    private static let delays: [Double] = [0, 3, 5, 10]

    var body: some View {
        SettingsFormRow(title: L10n.string("screenshot.selection.constraint")) {
            Button(sizeTitle) {
                showsSizePanel.toggle()
            }
            .popover(isPresented: $showsSizePanel, arrowEdge: .bottom) {
                ScreenshotAspectRatioCapturePopover(
                    selection: currentSelection,
                    customConstraints: customConstraints,
                    onSelect: { selection in
                        defaults.regionConstraint = selection.resolvedConstraint
                    },
                    onSave: onSaveConstraint,
                    onDelete: onDeleteConstraint
                )
            }
        }
        SettingsRowDivider()
        SettingsFormRow(title: L10n.string("screenshot.selection.delay")) {
            Picker("", selection: $defaults.delaySeconds) {
                ForEach(Self.delays, id: \.self) { delay in
                    Text(delayTitle(delay)).tag(delay)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120, alignment: .trailing)
            .accessibilityLabel(L10n.string("screenshot.selection.delay"))
        }
        SettingsRowDivider()
        SettingsFormRow(title: L10n.string("screenshot.selection.freeze")) {
            SettingsBooleanSwitch(
                L10n.string("screenshot.selection.freeze"),
                isOn: $defaults.freezesFrame
            )
        }
        SettingsRowDivider()
        SettingsFormRow(title: L10n.string("screenshot.selection.watermark")) {
            Picker("", selection: watermarkPresetBinding) {
                Text(L10n.string("screenshot.watermark.none"))
                    .tag(Optional<UUID>.none)
                ForEach(watermarkPresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
            .accessibilityLabel(L10n.string("screenshot.selection.watermark"))
        }
    }

    private var currentSelection: ScreenshotAspectSelection {
        let ratio = defaults.regionConstraint.aspectRatio ?? 1
        return ScreenshotAspectSelection(
            orientation: ratio >= 1 ? .landscape : .portrait,
            constraint: defaults.regionConstraint
        )
    }

    private var watermarkPresetBinding: Binding<UUID?> {
        Binding(
            get: {
                guard let presetID = defaults.watermarkPresetID,
                      watermarkPresets.contains(where: { $0.id == presetID }) else {
                    return nil
                }
                return presetID
            },
            set: { defaults.watermarkPresetID = $0 }
        )
    }

    private var sizeTitle: String {
        ScreenshotAspectControlModel.title(for: defaults.regionConstraint)
    }

    private func delayTitle(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))s"
            : "\(value)s"
    }
}

private struct ScreenshotEditorLayoutPreview: View {
    let quickTools: [ScreenshotToolbarItemID]
    let extendedTools: [ScreenshotToolbarItemID]
    let onConfigure: () -> Void

    var body: some View {
        GeometryReader { geometry in
            // A transient zero-width proposal is not a valid toolbar layout.
            // Keep the stable row height and instantiate the controls only once
            // SwiftUI has provided usable horizontal space.
            if geometry.size.width > 1 {
                let layout = ScreenshotEditorToolbarLayout.resolve(
                    availableWidth: geometry.size.width,
                    quickTools: quickTools,
                    extendedTools: extendedTools,
                    selectedItem: .select,
                    allowsDirectImageCopy: true,
                    edgeMargin: 0
                )
                toolbar(presentation: layout.presentation)
                    .frame(width: layout.width, height: ScreenshotDesignTokens.toolbarMainHeight)
                    .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(height: ScreenshotDesignTokens.toolbarMainHeight)
        // This visual preview has one semantic action. Presenting its decorative
        // controls as separate actions creates a noisy and misleading AX tree.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("settings.screenshot.tools"))
        .accessibilityHint(L10n.string("settings.screenshot.tools.detail"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onConfigure() }
    }

    private func toolbar(
        presentation: ScreenshotToolbarPresentation
    ) -> some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "xmark",
                    label: configureAccessibilityLabel(L10n.string("common.close")),
                    action: onConfigure
                )
                ScreenshotToolbarIconButton(
                    systemImage: ScreenshotToolbarItemID.select.systemImage,
                    label: configureAccessibilityLabel(
                        ScreenshotToolbarItemID.select.localizedSettingsTitle
                    ),
                    isSelected: true,
                    action: onConfigure
                )
            }

            if !presentation.visibleQuickTools.isEmpty || !presentation.overflowTools.isEmpty {
                BlocksCompactControlGroup {
                    ScreenshotEditorToolStrip(
                        tools: presentation.visibleQuickTools,
                        selectedItem: .select,
                        label: { configureAccessibilityLabel($0.localizedTitle) },
                        onSelect: { _ in onConfigure() }
                    )
                    if !presentation.overflowTools.isEmpty {
                        ScreenshotToolbarIconButton(
                            systemImage: "ellipsis",
                            label: configureAccessibilityLabel(
                                L10n.format(
                                    "screenshot.editor.moreTools.count",
                                    presentation.overflowTools.count
                                )
                            ),
                            action: onConfigure
                        )
                    }
                }
            }

            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "arrow.uturn.backward",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.editor.undo")
                    ),
                    action: onConfigure
                )
                ScreenshotToolbarIconButton(
                    systemImage: "arrow.uturn.forward",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.editor.redo")
                    ),
                    action: onConfigure
                )
            }

            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "pin.fill",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.result.pin")
                    ),
                    action: onConfigure
                )
                ScreenshotToolbarIconButton(
                    systemImage: "square.and.arrow.down",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.result.saveAs")
                    ),
                    action: onConfigure
                )
                ScreenshotToolbarIconButton(
                    systemImage: "camera.rotate",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.result.retake")
                    ),
                    action: onConfigure
                )
                ScreenshotToolbarIconButton(
                    systemImage: "checkmark",
                    label: configureAccessibilityLabel(
                        L10n.string("screenshot.editor.done")
                    ),
                    emphasis: .accent,
                    action: onConfigure
                )
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, BlocksVisualTokens.Spacing.sm)
    }

    private func configureAccessibilityLabel(_ itemName: String) -> String {
        L10n.format("settings.screenshot.tools.configureNamed", itemName)
    }
}

private struct ScreenshotEditorConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ScreenshotPreferencesStore
    @State private var focusedTool: ScreenshotToolbarItemID?

    private var preferences: ScreenshotPreferences { store.preferences }

    var body: some View {
        SettingsSheetScaffold(
            title: L10n.string("settings.screenshot.tools"),
            detail: L10n.string("settings.screenshot.tools.detail")
        ) {
            ScreenshotUnifiedToolConfigurationSimulator(
                quickTools: preferences.visibleQuickToolbarItemIDs,
                extendedTools: preferences.visibleExtendedToolbarItemIDs,
                hiddenTools: preferences.hiddenToolIDs,
                onMoveTool: moveTool,
                onMove: { moveTool($0, offset: $1) },
                focusedTool: $focusedTool
            )
        } actions: {
            Button(L10n.string("settings.screenshot.tools.restore")) {
                store.resetToolConfiguration()
            }
            Button(L10n.string("settings.screenshot.close")) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxHeight: 520)
    }

    private func moveTool(
        _ tool: ScreenshotToolbarItemID,
        to zone: ScreenshotToolZone,
        before target: ScreenshotToolbarItemID?
    ) {
        guard store.moveTool(tool, to: zone, before: target) else { return }
        refocus(tool)
    }

    private func moveTool(_ tool: ScreenshotToolbarItemID, offset: Int) {
        store.moveTool(tool, offset: offset)
        refocus(tool)
    }

    private func refocus(_ tool: ScreenshotToolbarItemID) {
        focusedTool = nil
        DispatchQueue.main.async { focusedTool = tool }
    }
}

private struct ScreenshotUnifiedToolConfigurationSimulator: View {
    let quickTools: [ScreenshotToolbarItemID]
    let extendedTools: [ScreenshotToolbarItemID]
    let hiddenTools: [ScreenshotToolbarItemID]
    let onMoveTool: (ScreenshotToolbarItemID, ScreenshotToolZone, ScreenshotToolbarItemID?) -> Void
    let onMove: (ScreenshotToolbarItemID, Int) -> Void
    let focusedTool: Binding<ScreenshotToolbarItemID?>

    var body: some View {
        ScreenshotToolZonesBoardBridge(
            snapshot: ScreenshotToolZonesSnapshot(
                quick: quickTools,
                expanded: extendedTools,
                hidden: hiddenTools
            ),
            onMoveTool: onMoveTool,
            onMove: onMove,
            focusedTool: focusedTool
        )
        .frame(height: ScreenshotToolZonesBoardMetrics.requiredHeight)
        .accessibilityElement(children: .contain)
    }
}
