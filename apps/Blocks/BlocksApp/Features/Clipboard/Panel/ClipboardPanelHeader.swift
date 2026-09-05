import BlocksCore
import SwiftUI

struct ClipboardNotificationAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

struct ClipboardPanelHeaderValues {
    let position: FloatingPanelPosition
    let hasActiveFilters: Bool
    let filterState: ClipboardFilterState
    let sourceOptions: [ClipboardSourceFilterOption]
    let favoriteTag: ClipboardTag?
    let tags: [ClipboardTag]
    let selectedTagID: String?
    let tagOperationErrorMessage: String?
    let recorderPaused: Bool
    let isPinned: Bool
    let activeTitle: (ClipboardFilterGroup) -> String?
    let tagUseCount: (String) -> Int
}

struct ClipboardPanelHeaderActions {
    let onSubmitSearch: () -> Void
    let onFocusSearch: () -> Void
    let onClearAllFilters: () -> Void
    let onOpenSettings: () -> Void
    let onTogglePin: () -> Void
    let onSelectFormat: (ClipboardFormatFilter) -> Void
    let onSelectTime: (ClipboardTimeFilter) -> Void
    let onSelectSource: (ClipboardSourceFilterKey?) -> Void
    let onSelectTag: (String?) -> Void
    let onClearFilterGroup: (ClipboardFilterGroup) -> Void
    let onCreateTag: (String, String?) async -> String?
    let onRenameTag: (String, String) async -> Bool
    let onDeleteTag: (String) async -> Bool
    let onMoveTag: (String, String?) async -> Bool
}

enum ClipboardPanelToolbarLayout {
    static let searchHeight = BlocksVisualTokens.Control.compactHeight
    static let filterRowHeight = ClipboardFilterBarLayout.filterHitHeight
    static let tagRowHeight = BlocksVisualTokens.Control.compactHeight
    static let actionButtonSize = BlocksCompactIconButtonDensity.micro.hitTarget
    static let bottomSearchMinimumWidth: CGFloat = 220
    static let bottomSearchPreferredWidth: CGFloat = 360
    static let bottomSearchMaximumWidth: CGFloat = 440
    static let sideSearchMinimumWidth: CGFloat = 108
    static let sideSearchPreferredWidth: CGFloat = 120
    static let sideSearchMaximumWidth: CGFloat = 132
    static let sideFiltersShowIcons = false
    static let headerRowHeight = max(
        searchHeight,
        max(ClipboardFilterBarLayout.filterHitHeight, actionButtonSize)
    )
    static let bottomHeaderHeight = headerRowHeight
    static let sideHeaderHeight =
        headerRowHeight
        + BlocksVisualTokens.Spacing.sm
        + tagRowHeight
    static let searchHorizontalPadding: CGFloat = 10
    static let searchVerticalPadding: CGFloat = 2
}

struct ClipboardPanelHeader: View {
    @Binding var query: String
    let searchFocused: FocusState<Bool>.Binding
    let values: ClipboardPanelHeaderValues
    let actions: ClipboardPanelHeaderActions
    let pluginActions: AnyView?

    @ViewBuilder
    var body: some View {
        if values.position == .bottom {
            bottomHeader
        } else {
            sideHeader
        }
    }

    private var bottomHeader: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            searchBar
                .frame(
                    minWidth: ClipboardPanelToolbarLayout.bottomSearchMinimumWidth,
                    idealWidth: ClipboardPanelToolbarLayout.bottomSearchPreferredWidth,
                    maxWidth: ClipboardPanelToolbarLayout.bottomSearchMaximumWidth
                )
                .frame(height: ClipboardPanelToolbarLayout.searchHeight)

            filterStrip
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ClipboardPanelToolbarLayout.filterRowHeight)

            bottomTrailingActionGroup
        }
        .frame(height: ClipboardPanelToolbarLayout.bottomHeaderHeight, alignment: .leading)
    }

    private var sideHeader: some View {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.sm) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                searchBar
                    .frame(
                        minWidth: ClipboardPanelToolbarLayout.sideSearchMinimumWidth,
                        idealWidth: ClipboardPanelToolbarLayout.sideSearchPreferredWidth,
                        maxWidth: ClipboardPanelToolbarLayout.sideSearchMaximumWidth
                    )
                    .frame(height: ClipboardPanelToolbarLayout.searchHeight)

                sideFilterStrip
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: ClipboardPanelToolbarLayout.filterRowHeight)

                sidePrimaryActionGroup
            }
            .frame(height: ClipboardPanelToolbarLayout.headerRowHeight)

            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                tagFilterStrip
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: ClipboardPanelToolbarLayout.tagRowHeight)

                sideSecondaryActionGroup
            }
            .frame(height: ClipboardPanelToolbarLayout.tagRowHeight)
        }
        .frame(height: ClipboardPanelToolbarLayout.sideHeaderHeight, alignment: .topLeading)
    }

    private var bottomTrailingActionGroup: some View {
        BlocksCompactActionGroup(density: .micro) {
            if values.hasActiveFilters {
                BlocksCompactIconButton(
                    systemImage: "xmark.circle",
                    label: L10n.string("clipboard.filter.clearAll"),
                    density: .micro,
                    action: actions.onClearAllFilters
                )
            }

            recorderStatusSlot

            if let pluginActions {
                pluginActions
            }

            BlocksCompactIconButton(
                systemImage: "gearshape",
                label: L10n.string("menu.settings"),
                density: .micro,
                action: actions.onOpenSettings
            )

            BlocksCompactIconButton(
                systemImage: values.isPinned ? "pin.fill" : "pin",
                label: values.isPinned ? L10n.string("clipboard.panel.unpin") : L10n.string("clipboard.panel.pin"),
                isSelected: values.isPinned,
                emphasis: values.isPinned ? .accent : .standard,
                density: .micro,
                action: actions.onTogglePin
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sidePrimaryActionGroup: some View {
        BlocksCompactActionGroup(density: .micro) {
            Group {
                if values.hasActiveFilters {
                    BlocksCompactIconButton(
                        systemImage: "xmark.circle",
                        label: L10n.string("clipboard.filter.clearAll"),
                        density: .micro,
                        action: actions.onClearAllFilters
                    )
                } else {
                    Color.clear
                        .frame(
                            width: ClipboardPanelToolbarLayout.actionButtonSize,
                            height: ClipboardPanelToolbarLayout.actionButtonSize
                        )
                        .accessibilityHidden(true)
                }
            }

            BlocksCompactIconButton(
                systemImage: "gearshape",
                label: L10n.string("menu.settings"),
                density: .micro,
                action: actions.onOpenSettings
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sideSecondaryActionGroup: some View {
        BlocksCompactActionGroup(density: .micro) {
            recorderStatusSlot

            if let pluginActions {
                pluginActions
            }

            BlocksCompactIconButton(
                systemImage: values.isPinned ? "pin.fill" : "pin",
                label: values.isPinned ? L10n.string("clipboard.panel.unpin") : L10n.string("clipboard.panel.pin"),
                isSelected: values.isPinned,
                emphasis: values.isPinned ? .accent : .standard,
                density: .micro,
                action: actions.onTogglePin
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var recorderStatusSlot: some View {
        Image(systemName: values.recorderPaused ? "pause.circle.fill" : "record.circle")
            .font(.system(size: BlocksCompactIconButtonDensity.micro.iconSize, weight: .semibold))
            .foregroundStyle(values.recorderPaused ? Color.orange : Color.secondary.opacity(0.64))
            .frame(
                width: BlocksCompactIconButtonDensity.micro.hitTarget,
                height: BlocksCompactIconButtonDensity.micro.hitTarget
            )
            .accessibilityLabel(
                values.recorderPaused
                    ? L10n.string("clipboard.pausedTitle")
                    : L10n.string("clipboard.recordingTitle")
            )
            .help(
                values.recorderPaused
                    ? L10n.string("clipboard.pausedTitle")
                    : L10n.string("clipboard.recordingTitle")
            )
            .blocksAnimation(.selection, value: values.recorderPaused)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.string("clipboard.searchPlaceholder"), text: $query)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .blocksFont(size: 12)
                .onSubmit(actions.onSubmitSearch)
        }
        .padding(.horizontal, ClipboardPanelToolbarLayout.searchHorizontalPadding)
        .padding(.vertical, ClipboardPanelToolbarLayout.searchVerticalPadding)
        .blocksSurface(
            .interactive,
            cornerRadius: BlocksVisualTokens.CornerRadius.control
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded(actions.onFocusSearch)
        )
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                ForEach(ClipboardFilterGroup.nonTagCases) { group in
                    ClipboardFilterMenuGroup(
                        group: group,
                        activeTitle: values.activeTitle(group),
                        hasActiveFilter: values.activeTitle(group) != nil,
                        showsIcon: true,
                        usesSideWidth: false,
                        sourceOptions: values.sourceOptions,
                        filterState: values.filterState,
                        onSelectFormat: actions.onSelectFormat,
                        onSelectTime: actions.onSelectTime,
                        onSelectSource: actions.onSelectSource,
                        onClearGroup: { actions.onClearFilterGroup(group) }
                    )
                }
                tagFilterChips
            }
        }
        .anchorPreference(
            key: ClipboardNotificationAnchorPreferenceKey.self,
            value: .bounds
        ) { $0 }
    }

    private func sideFilterMenuGroup(group: ClipboardFilterGroup, showsIcon: Bool) -> some View {
        ClipboardFilterMenuGroup(
            group: group,
            activeTitle: values.activeTitle(group),
            hasActiveFilter: values.activeTitle(group) != nil,
            showsIcon: showsIcon,
            usesSideWidth: true,
            sourceOptions: values.sourceOptions,
            filterState: values.filterState,
            onSelectFormat: actions.onSelectFormat,
            onSelectTime: actions.onSelectTime,
            onSelectSource: actions.onSelectSource,
            onClearGroup: { actions.onClearFilterGroup(group) }
        )
        .frame(
            width: ClipboardFilterBarLayout.sideFilterGroupFixedWidth(for: group, showsIcon: showsIcon)
                + ClipboardFilterBarLayout.filterHitHorizontalPadding * 2,
            height: ClipboardPanelToolbarLayout.filterRowHeight,
            alignment: .center
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sideFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                ForEach(ClipboardFilterGroup.nonTagCases) { group in
                    sideFilterMenuGroup(
                        group: group,
                        showsIcon: ClipboardPanelToolbarLayout.sideFiltersShowIcons
                    )
                }
            }
        }
    }

    private var tagFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tagFilterChips
            }
        }
        .anchorPreference(
            key: ClipboardNotificationAnchorPreferenceKey.self,
            value: .bounds
        ) { $0 }
    }

    private var tagFilterChips: some View {
        ClipboardFlatTagFilterChips(
            favoriteTag: values.favoriteTag,
            tags: values.tags,
            selectedTagID: values.selectedTagID,
            operationErrorMessage: values.tagOperationErrorMessage,
            tagUseCount: values.tagUseCount,
            onSelectTag: actions.onSelectTag,
            onCreateTag: actions.onCreateTag,
            onRenameTag: actions.onRenameTag,
            onDeleteTag: actions.onDeleteTag,
            onMoveTag: actions.onMoveTag
        )
    }
}
