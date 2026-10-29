import AppKit
import SwiftUI

struct ClipboardFilterIslandButton: View {
    let group: ClipboardFilterGroup
    let activeTitle: String?
    let isExpanded: Bool
    let hasActiveFilter: Bool
    let reservesClearSlot: Bool
    let showsIcon: Bool

    private var displayTitle: String {
        activeTitle ?? group.localizedTitle
    }

    private var geometryProbePrefix: String { "clipboard.filter.\(group.rawValue).label" }

    var body: some View {
        HStack(spacing: ClipboardFilterBarLayout.islandContentSpacing) {
            if showsIcon {
                Image(systemName: group.systemImage)
                    .resizable()
                    .scaledToFit()
                    .font(.system(size: ClipboardFilterBarLayout.islandIconSize, weight: .semibold))
                    // A symbol's font point size is not its layout width.
                    // Keep it inside the 13pt budget rather than stealing
                    // room from a two-character active filter value.
                    .frame(width: ClipboardFilterBarLayout.islandIconSize,
                           height: ClipboardFilterBarLayout.islandIconSize)
                    .blocksInteractionGeometryProbe("\(geometryProbePrefix).icon")
            }
            Text(displayTitle)
                .blocksFont(size: ClipboardFilterBarLayout.islandTextSize, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .blocksInteractionGeometryProbe("\(geometryProbePrefix).title")
                .frame(maxWidth: .infinity, alignment: .leading)
                .blocksInteractionGeometryProbe("\(geometryProbePrefix).titleSlot")
                .transition(.opacity)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: ClipboardFilterBarLayout.menuIndicatorWidth)
                .blocksInteractionGeometryProbe("\(geometryProbePrefix).indicator")
            if reservesClearSlot {
                Color.clear
                    .frame(width: ClipboardFilterBarLayout.clearSlotWidth, height: ClipboardFilterBarLayout.clearSlotWidth)
            }
        }
        .foregroundStyle(hasActiveFilter ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.82))
        .padding(.horizontal, ClipboardFilterBarLayout.islandHorizontalPadding)
        .padding(.vertical, ClipboardFilterBarLayout.islandVerticalPadding)
        .blocksSurface(
            .interactive,
            cornerRadius: BlocksVisualTokens.CornerRadius.control,
            isActive: isExpanded || hasActiveFilter
        )
        .blocksAnimation(.selection, value: isExpanded || hasActiveFilter)
        .blocksInteractionGeometryProbe("\(geometryProbePrefix).surface")
    }
}

struct ClipboardFilterClearButton: View {
    let group: ClipboardFilterGroup
    let action: () -> Void

    private var accessibilityKeyPrefix: String {
        "clipboard.filter.clear.\(group.rawValue)"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.84))
                .frame(width: ClipboardFilterBarLayout.clearSlotWidth, height: ClipboardFilterBarLayout.filterHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ClipboardFilterWindowActivationModifier())
        .accessibilityIdentifier("clipboard.filter.clear.\(group.rawValue)")
        .accessibilityLabel(L10n.string("\(accessibilityKeyPrefix).label"))
        .accessibilityHint(L10n.string("\(accessibilityKeyPrefix).hint"))
        .help(L10n.string("\(accessibilityKeyPrefix).help"))
    }
}

struct ClipboardFilterMenuGroup: View {
    let group: ClipboardFilterGroup
    let activeTitle: String?
    let hasActiveFilter: Bool
    let showsIcon: Bool
    let usesSideWidth: Bool
    let sourceOptions: [ClipboardSourceFilterOption]
    let filterState: ClipboardFilterState
    let onSelectFormat: (ClipboardFormatFilter) -> Void
    let onSelectTime: (ClipboardTimeFilter) -> Void
    let onSelectSource: (ClipboardSourceFilterKey?) -> Void
    let onClearGroup: () -> Void
    let onMenuTrackingChange: (Bool) -> Void

    @State private var isExpanded = false

    init(
        group: ClipboardFilterGroup,
        activeTitle: String?,
        hasActiveFilter: Bool,
        showsIcon: Bool = true,
        usesSideWidth: Bool = false,
        sourceOptions: [ClipboardSourceFilterOption],
        filterState: ClipboardFilterState,
        onSelectFormat: @escaping (ClipboardFormatFilter) -> Void,
        onSelectTime: @escaping (ClipboardTimeFilter) -> Void,
        onSelectSource: @escaping (ClipboardSourceFilterKey?) -> Void,
        onClearGroup: @escaping () -> Void,
        onMenuTrackingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.group = group
        self.activeTitle = activeTitle
        self.hasActiveFilter = hasActiveFilter
        self.showsIcon = showsIcon
        self.usesSideWidth = usesSideWidth
        self.sourceOptions = sourceOptions
        self.filterState = filterState
        self.onSelectFormat = onSelectFormat
        self.onSelectTime = onSelectTime
        self.onSelectSource = onSelectSource
        self.onClearGroup = onClearGroup
        self.onMenuTrackingChange = onMenuTrackingChange
    }

    private var fixedWidth: CGFloat {
        usesSideWidth
            ? ClipboardFilterBarLayout.sideFilterGroupFixedWidth(for: group, showsIcon: showsIcon)
            : ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)
    }

    private var accessibilityPresentation: ClipboardFilterAccessibilityPresentation {
        ClipboardFilterAccessibilityPresentation.resolve(
            group: group,
            activeTitle: selectedTitle,
            isExpanded: isExpanded
        )
    }

    private var selectedID: String {
        switch group {
        case .format: filterState.format.id
        case .time: filterState.time.id
        case .source: filterState.sourceFilterKey?.id ?? "all"
        }
    }

    private var selectedTitle: String? {
        guard hasActiveFilter else { return nil }
        return menuEntries.first { $0.id == selectedID }?.title ?? activeTitle
    }

    private var menuEntries: [ClipboardNativeFilterMenuEntry] {
        switch group {
        case .format:
            ClipboardFormatFilter.allCases.map {
                ClipboardNativeFilterMenuEntry(id: $0.id, title: $0.localizedTitle, systemImage: $0.systemImage)
            }
        case .time:
            ClipboardTimeFilter.allCases.map {
                ClipboardNativeFilterMenuEntry(id: $0.id, title: $0.localizedTitle, systemImage: $0.systemImage)
            }
        case .source:
            [ClipboardNativeFilterMenuEntry(id: "all", title: L10n.string("clipboard.filter.all"), systemImage: "app.badge")]
                + sourceOptions.map {
                    ClipboardNativeFilterMenuEntry(id: $0.key.id, title: $0.displayName,
                        sourceBundleIdentifier: $0.bundleIdentifier, usesSourceIcon: true)
                }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ClipboardNativeFilterMenu(
                group: group,
                entries: menuEntries,
                selectedID: selectedID,
                accessibilityPresentation: accessibilityPresentation,
                onSelection: selectEntry,
                onTrackingChange: { active in
                    isExpanded = active
                    onMenuTrackingChange(active)
                }
            )
            .overlay {
                ClipboardFilterIslandButton(
                    group: group,
                    activeTitle: activeTitle,
                    isExpanded: isExpanded,
                    hasActiveFilter: hasActiveFilter,
                    reservesClearSlot: false,
                    showsIcon: showsIcon
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(width: ClipboardFilterBarLayout.menuWidth(groupWidth: fixedWidth, hasActiveFilter: hasActiveFilter),
                   height: ClipboardFilterBarLayout.filterHitHeight)

            if hasActiveFilter {
                ClipboardFilterClearButton(group: group, action: onClearGroup)
            }
        }
        .padding(.horizontal, ClipboardFilterBarLayout.filterHitHorizontalPadding)
        .frame(
            width: fixedWidth + ClipboardFilterBarLayout.filterHitHorizontalPadding * 2,
            height: ClipboardFilterBarLayout.filterHitHeight
        )
        .contentShape(Rectangle())
    }

    private func selectEntry(_ id: String) {
        switch group {
        case .format:
            if let option = ClipboardFormatFilter(rawValue: id) { onSelectFormat(option) }
        case .time:
            if let option = ClipboardTimeFilter(rawValue: id) { onSelectTime(option) }
        case .source:
            if id == "all" {
                onSelectSource(nil)
            } else if let source = sourceOptions.first(where: { $0.key.id == id }) {
                onSelectSource(source.key)
            }
        }
    }
}

struct ClipboardSourceIcon: View {
    let bundleIdentifier: String?

    var body: some View {
        Image(nsImage: ClipboardSourceAppIconResolver.icon(for: bundleIdentifier) ?? ClipboardSourceAppIconResolver.defaultAppIcon)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
    }
}

enum ClipboardSourceAppIconResolver {
    private static var iconCache: [String: NSImage] = [:]

    static var defaultAppIcon: NSImage {
        if let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) {
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        if let cached = iconCache[bundleIdentifier] {
            return cached
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        guard image.isValid else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[bundleIdentifier] = image
        return image
    }
}
