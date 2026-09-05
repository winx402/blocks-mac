import AppKit
import SwiftUI

enum SettingsViewMode: Hashable {
    case general
    case screenshot
    case clipboard
    case clipboardPrivacy
    case translation
    case translationFavorites
    case shortcuts
    case providers
    case agentCLI
    case hooks
    case dataAudit
    case permissions
}

enum SettingsContentLayoutProfile: Equatable {
    case form
    case content
    case sheet

    var maximumWidth: CGFloat {
        switch self {
        case .form:
            BlocksVisualTokens.Layout.settingsFormContentMaxWidth
        case .content:
            BlocksVisualTokens.Layout.settingsCollectionContentMaxWidth
        case .sheet:
            BlocksVisualTokens.Layout.settingsSheetContentMaxWidth
        }
    }
}

enum SettingsLayout {
    static let trailingColumnMinimumWidth = BlocksVisualTokens.Layout.settingsTrailingColumnMinimumWidth
    static let trailingColumnWidth = BlocksVisualTokens.Layout.settingsTrailingColumnWidth
    static let trailingColumnMaximumWidth = BlocksVisualTokens.Layout.settingsTrailingColumnMaximumWidth
    static let labelMinimumWidth = BlocksVisualTokens.Layout.settingsLabelMinimumWidth
    static let rowSpacing = BlocksVisualTokens.Spacing.xl
    static let rowMinHeight = BlocksVisualTokens.Control.settingsRowMinimumHeight
    static let rowVerticalPadding = BlocksVisualTokens.Spacing.xs
    /// The shared inset for both section headers and their row content.
    /// Keeping this value in one place prevents the two left baselines from
    /// drifting when a section surface changes.
    static let sectionContentHorizontalInset = BlocksVisualTokens.Spacing.lg

    static func alignmentGeometry(
        containerWidth: CGFloat,
        profile: SettingsContentLayoutProfile = .form
    ) -> SettingsAlignmentGeometry {
        let availableWidth = max(
            0,
            containerWidth
                - BlocksVisualTokens.Layout.settingsPageHorizontalPadding * 2
        )
        let contentWidth = min(profile.maximumWidth, availableWidth)
        let contentLeading = max(0, (containerWidth - contentWidth) / 2)
        let alignedLeading = contentLeading + sectionContentHorizontalInset
        let alignedTrailing = contentLeading + contentWidth
            - sectionContentHorizontalInset
        return SettingsAlignmentGeometry(
            sectionTitleLeading: alignedLeading,
            rowTitleLeading: alignedLeading,
            headerActionTrailing: alignedTrailing,
            valueControlTrailing: alignedTrailing,
            availableLabelWidth: max(
                0,
                contentWidth
                    - sectionContentHorizontalInset * 2
                    - rowSpacing
                    - trailingColumnMinimumWidth
            )
        )
    }
}

struct SettingsAlignmentGeometry: Equatable {
    let sectionTitleLeading: CGFloat
    let rowTitleLeading: CGFloat
    let headerActionTrailing: CGFloat
    let valueControlTrailing: CGFloat
    let availableLabelWidth: CGFloat
}

struct SettingsSectionHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: Actions

    init(title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: BlocksVisualTokens.Spacing.sm) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHeading(.h2)
                .settingsGeometryProbe("section.\(title)")
            Spacer(minLength: BlocksVisualTokens.Spacing.sm)
            actions
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(.horizontal, SettingsLayout.sectionContentHorizontalInset)
    }
}

struct SettingsSection<Content: View, HeaderActions: View>: View {
    let title: String
    @ViewBuilder let headerActions: HeaderActions
    @ViewBuilder let content: Content

    init(
        title: String,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerActions = headerActions()
        self.content = content()
    }

    var body: some View {
        // Keep the visual title separate from the material surface. SwiftUI's
        // macOS GroupBox exposes reciprocal title relationships that cause
        // some accessibility-tree readers to recurse and terminate.
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.sm) {
            SettingsSectionHeader(title: title) {
                headerActions
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, SettingsLayout.sectionContentHorizontalInset)
            .padding(.vertical, BlocksVisualTokens.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blocksSurface(.section)
        }
    }
}

extension SettingsSection where HeaderActions == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, headerActions: { EmptyView() }, content: content)
    }
}

struct SettingsValueColumn<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content
        }
        .controlSize(.small)
        .frame(
            minWidth: SettingsLayout.trailingColumnMinimumWidth,
            idealWidth: SettingsLayout.trailingColumnWidth,
            maxWidth: SettingsLayout.trailingColumnMaximumWidth,
            alignment: .trailing
        )
    }
}

struct SettingsRowShell<Trailing: View>: View {
    let title: String
    let detail: String?
    let status: SettingsRowStatus?
    let reservesStatusSpace: Bool
    let minHeight: CGFloat
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        detail: String? = nil,
        status: SettingsRowStatus? = nil,
        reservesStatusSpace: Bool = false,
        minHeight: CGFloat = SettingsLayout.rowMinHeight,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.reservesStatusSpace = reservesStatusSpace
        self.minHeight = minHeight
        self.trailing = trailing()
    }

    var body: some View {
        horizontalLayout
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
            .settingsGeometryProbe("rowShell.\(title)")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xxs) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .settingsGeometryProbe("row.\(title)")
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if reservesStatusSpace {
                Group {
                    if let status {
                        Label(status.message, systemImage: status.kind.systemImage)
                            .foregroundStyle(status.kind.color)
                            .help(status.message)
                            .accessibilityLabel(status.message)
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: SettingsLayout.rowSpacing) {
            label
                .frame(minWidth: SettingsLayout.labelMinimumWidth)

            SettingsValueColumn {
                trailing
                    .settingsGeometryProbe("value.\(title)")
            }
        }
    }

}

struct SettingsRowStatus: Equatable {
    let kind: SettingsInlineFeedbackKind
    let message: String
}

typealias SettingsInlineFeedbackKind = BlocksInlineFeedbackKind

struct SettingsInlineFeedback: View {
    let kind: SettingsInlineFeedbackKind
    let title: String
    let detail: String

    var body: some View {
        BlocksInlineFeedback(
            kind: kind,
            title: title,
            detail: detail
        )
    }
}

struct SettingsFeedbackDescriptor: Equatable {
    let kind: SettingsInlineFeedbackKind
    let title: String
    let detail: String
}

/// Reserves one stable feedback region so validation and completion messages
/// never push the surrounding form controls.
struct SettingsFeedbackSlot: View {
    let feedback: SettingsFeedbackDescriptor?
    var minimumHeight: CGFloat = 54

    var body: some View {
        Group {
            if let feedback {
                SettingsInlineFeedback(
                    kind: feedback.kind,
                    title: feedback.title,
                    detail: feedback.detail
                )
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
    }
}

struct SettingsFormRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        SettingsRowShell(title: title, detail: detail) {
            trailing
        }
    }
}

struct SettingsSegmentedRow<SelectionValue: Hashable, Options: View>: View {
    let title: String
    let detail: String?
    @Binding var selection: SelectionValue
    let controlWidth: CGFloat?
    @ViewBuilder let options: Options

    init(
        title: String,
        detail: String? = nil,
        selection: Binding<SelectionValue>,
        controlWidth: CGFloat? = nil,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.controlWidth = controlWidth
        self.options = options()
    }

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            Picker(title, selection: $selection) {
                options
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .settingsGeometryProbe("control.\(title)")
            .frame(width: controlWidth, alignment: .trailing)
        }
    }
}

/// A full-width informational row without a value column. Use it for
/// explanations and read-only summaries so pages do not create a fake empty
/// trailing control area.
struct SettingsReadOnlyRow: View {
    let title: String
    let detail: String?
    var minHeight: CGFloat = SettingsLayout.rowMinHeight

    var body: some View {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xxs) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .settingsGeometryProbe("row.\(title)")
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }
}

/// A low-emphasis, full-width explanation at the start of a section.
/// It deliberately has no synthetic title or value column.
struct SettingsSectionNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(
                maxWidth: .infinity,
                minHeight: SettingsLayout.rowMinHeight,
                alignment: .leading
            )
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }
}

struct SettingsStatusRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let status: SettingsRowStatus?
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        detail: String? = nil,
        status: SettingsRowStatus?,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.trailing = trailing()
    }

    var body: some View {
        SettingsRowShell(
            title: title,
            detail: detail,
            status: status,
            reservesStatusSpace: true
        ) {
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                trailing
            }
        }
    }
}

struct SettingsTextFieldRow: View {
    let title: String
    let detail: String?
    @Binding var text: String

    init(
        title: String,
        detail: String? = nil,
        text: Binding<String>
    ) {
        self.title = title
        self.detail = detail
        _text = text
    }

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            TextField(title, text: $text)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .settingsGeometryProbe("control.\(title)")
                .accessibilityLabel(title)
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    let detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String

    init(
        title: String,
        detail: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) {
        self.title = title
        self.detail = detail
        _value = value
        self.range = range
        self.valueText = valueText
    }

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                Slider(value: $value, in: range)
                    .accessibilityLabel(title)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .settingsGeometryProbe("control.\(title)")
        }
    }
}

struct SettingsCustomLabelRow<Label: View, Trailing: View>: View {
    let detail: String?
    @ViewBuilder let label: Label
    @ViewBuilder let trailing: Trailing

    init(
        detail: String? = nil,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.detail = detail
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsLayout.rowSpacing) {
            VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xxs) {
                label
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(
                minWidth: SettingsLayout.labelMinimumWidth,
                maxWidth: .infinity,
                alignment: .leading
            )

            SettingsValueColumn {
                trailing
            }
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: SettingsLayout.rowMinHeight,
            alignment: .center
        )
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(
        title: String,
        detail: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            SettingsBooleanSwitch(title, isOn: $isOn)
        }
    }
}

struct SettingsNavigationRow: View {
    let title: String
    let detail: String?
    var value: String?
    let action: () -> Void

    var body: some View {
        BlocksInteractiveRowButton(action: action) {
            SettingsRowShell(title: title, detail: detail) {
                HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                    if let value, !value.isEmpty {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityLabel(title)
    }
}

struct SettingsSecondaryPageHeader: View {
    let title: String
    let backTitle: String
    let backAction: () -> Void

    var body: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.md) {
            Button(action: backAction) {
                Label(backTitle, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .frame(minHeight: BlocksVisualTokens.Control.settingsRowMinimumHeight)
        .accessibilityLabel("\(backTitle), \(title)")
        .accessibilityElement(children: .contain)
    }
}

struct SettingsDangerRow: View {
    let title: String
    let detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            Button(actionTitle, role: .destructive, action: action)
        }
    }
}

struct SettingsBooleanSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        BlocksBooleanSwitch(title, isOn: $isOn)
            .settingsGeometryProbe("control.\(title)")
    }
}

/// A checkbox is reserved for acknowledgement and multiple-selection
/// semantics. Persistent on/off preferences use `SettingsBooleanSwitch`.
struct SettingsCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
    }
}

struct SettingsActionRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        SettingsFormRow(title: title, detail: detail) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                trailing
            }
        }
    }
}

struct SettingsStateView: View {
    let kind: BlocksStateViewKind
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        BlocksStateView(
            kind: kind,
            title: title,
            detail: detail,
            actionTitle: actionTitle,
            action: action
        )
    }
}

struct SettingsSheetScaffold<Content: View, Actions: View>: View {
    let title: String
    let detail: String?
    let systemImage: String?
    let preferredHeight: CGFloat?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    private var maximumHeight: CGFloat {
        let visibleHeight = (
            NSApp.keyWindow?.screen
                ?? NSApp.mainWindow?.screen
                ?? NSScreen.main
        )?.visibleFrame.height ?? 720
        return max(360, min(680, visibleHeight - 96))
    }

    init(
        title: String,
        detail: String? = nil,
        systemImage: String? = nil,
        preferredHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.preferredHeight = preferredHeight
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        let maximumHeight = maximumHeight
        let minimumHeight = min(
            preferredHeight == nil
                ? 360
                : BlocksVisualTokens.Layout.settingsSheetCompactMinimumHeight,
            maximumHeight
        )
        let idealHeight = min(
            max(minimumHeight, preferredHeight ?? 540),
            maximumHeight
        )
        VStack(spacing: 0) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                VStack(
                    alignment: .leading,
                    spacing: BlocksVisualTokens.Spacing.xxs
                ) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BlocksVisualTokens.Spacing.lg)

            Divider()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BlocksVisualTokens.Spacing.lg)
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                Spacer(minLength: 0)
                actions
            }
            .padding(BlocksVisualTokens.Spacing.lg)
        }
        .frame(
            minWidth: BlocksVisualTokens.Layout.settingsSheetMinimumWidth,
            idealWidth: BlocksVisualTokens.Layout.settingsSheetIdealWidth,
            maxWidth: SettingsContentLayoutProfile.sheet.maximumWidth,
            minHeight: minimumHeight,
            idealHeight: idealHeight,
            maxHeight: maximumHeight
        )
        .blocksBackground(.content)
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
    }
}

enum SettingsDesignSystemGalleryCatalog {
    static let rowTypes = [
        "form",
        "toggle",
        "picker",
        "textField",
        "slider",
        "status",
        "navigation",
        "action",
        "danger",
        "state",
        "sheet",
    ]
}

#if DEBUG
struct SettingsDesignSystemGallery: View {
    @State private var enabled = true
    @State private var text = "Blocks"
    @State private var sliderValue = 0.45
    @State private var selection = 0

    var body: some View {
        ScrollView {
            VStack(spacing: SettingsLayout.rowSpacing) {
                SettingsSection(
                    title: "Settings section",
                    headerActions: {
                        BlocksCompactIconButton(
                            systemImage: "arrow.counterclockwise",
                            label: "Reset"
                        ) {}
                    }
                ) {
                    SettingsToggleRow(
                        title: "Persistent Boolean preference",
                        detail: "Switch, title and detail share the canonical first-line geometry.",
                        isOn: $enabled
                    )
                    SettingsRowDivider()
                    SettingsFormRow(title: "Picker") {
                        Picker("Picker", selection: $selection) {
                            Text("Automatic").tag(0)
                            Text("Manual").tag(1)
                        }
                        .labelsHidden()
                    }
                    SettingsRowDivider()
                    SettingsTextFieldRow(
                        title: "Text field",
                        detail: "A long localized explanation can wrap without moving the value column.",
                        text: $text
                    )
                    SettingsRowDivider()
                    SettingsSliderRow(
                        title: "Slider",
                        value: $sliderValue,
                        range: 0...1,
                        valueText: sliderValue.formatted(.percent.precision(.fractionLength(0)))
                    )
                    SettingsRowDivider()
                    SettingsStatusRow(
                        title: "Stable feedback",
                        detail: "Status space is reserved before a message appears.",
                        status: SettingsRowStatus(
                            kind: .success,
                            message: "Saved"
                        )
                    ) {
                        Button("Test") {}
                    }
                }

                SettingsSection(title: "Navigation and actions") {
                    SettingsNavigationRow(
                        title: "Secondary page",
                        detail: "The complete row is interactive.",
                        value: "3 items"
                    ) {}
                    SettingsRowDivider()
                    SettingsActionRow(title: "Action") {
                        Button("Run") {}
                    }
                    SettingsRowDivider()
                    SettingsDangerRow(
                        title: "Dangerous action",
                        detail: "Destructive work requires an explicit confirmation flow.",
                        actionTitle: "Delete"
                    ) {}
                }

                SettingsSection(title: "State") {
                    SettingsStateView(
                        kind: .empty,
                        title: "No items",
                        detail: "Empty, loading and error states use the shared state component."
                    )
                }
            }
            .frame(
                maxWidth: SettingsContentLayoutProfile.form.maximumWidth,
                alignment: .top
            )
            .padding(BlocksVisualTokens.Layout.settingsPageHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .blocksBackground(.content)
    }
}
#endif

#if DEBUG
private struct SettingsGeometryProbeReporterKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    var settingsGeometryProbeReporter: ((String, CGRect) -> Void)? {
        get { self[SettingsGeometryProbeReporterKey.self] }
        set { self[SettingsGeometryProbeReporterKey.self] = newValue }
    }
}

private struct SettingsGeometryProbe: NSViewRepresentable {
    let identifier: String
    let reporter: (String, CGRect) -> Void

    func makeNSView(context: Context) -> SettingsGeometryProbeNSView {
        SettingsGeometryProbeNSView(probeID: identifier, reporter: reporter)
    }

    func updateNSView(
        _ nsView: SettingsGeometryProbeNSView,
        context: Context
    ) {
        nsView.probeID = identifier
        nsView.reporter = reporter
        nsView.needsLayout = true
    }
}

private struct SettingsGeometryProbeModifier: ViewModifier {
    let identifier: String
    @Environment(\.settingsGeometryProbeReporter) private var reporter

    @ViewBuilder
    func body(content: Content) -> some View {
        if let reporter {
            content.background(
                SettingsGeometryProbe(
                    identifier: identifier,
                    reporter: reporter
                )
            )
        } else {
            // Geometry probes exist solely for NSHostingView contract tests.
            // Omitting the representable entirely keeps zero-sized AppKit test
            // views out of the shipping accessibility hierarchy.
            content
        }
    }
}

private final class SettingsGeometryProbeNSView: NSView {
    var probeID: String
    var reporter: ((String, CGRect) -> Void)?

    init(
        probeID: String,
        reporter: ((String, CGRect) -> Void)?
    ) {
        self.probeID = probeID
        self.reporter = reporter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let window else { return }
        let windowRect = convert(bounds, to: nil)
        reporter?(probeID, window.convertToScreen(windowRect))
    }
}

extension View {
    func settingsGeometryProbe(_ identifier: String) -> some View {
        modifier(SettingsGeometryProbeModifier(identifier: identifier))
    }

    func settingsGeometryProbeReporter(
        _ reporter: @escaping (String, CGRect) -> Void
    ) -> some View {
        environment(\.settingsGeometryProbeReporter, reporter)
    }
}
#else
extension View {
    func settingsGeometryProbe(_ identifier: String) -> some View { self }
}
#endif

struct FlowTags: View {
    let tags: [String]
    private let columns = [
        GridItem(
            .adaptive(minimum: 78),
            spacing: 6,
            alignment: .leading
        ),
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .blocksSurface(
                        .interactive,
                        cornerRadius: BlocksVisualTokens.CornerRadius.pill
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
