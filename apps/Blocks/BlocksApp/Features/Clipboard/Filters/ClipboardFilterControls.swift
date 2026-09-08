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

    var body: some View {
        HStack(spacing: ClipboardFilterBarLayout.islandContentSpacing) {
            if showsIcon {
                Image(systemName: group.systemImage)
                    .font(.system(size: ClipboardFilterBarLayout.islandIconSize, weight: .semibold))
            }
            Text(activeTitle ?? group.localizedTitle)
                .blocksFont(size: ClipboardFilterBarLayout.islandTextSize, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
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
                .frame(width: ClipboardFilterBarLayout.clearSlotWidth, height: ClipboardFilterBarLayout.clearSlotWidth)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        onClearGroup: @escaping () -> Void
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
    }

    private var fixedWidth: CGFloat {
        usesSideWidth
            ? ClipboardFilterBarLayout.sideFilterGroupFixedWidth(for: group, showsIcon: showsIcon)
            : ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)
    }

    private var accessibilityPresentation: ClipboardFilterAccessibilityPresentation {
        ClipboardFilterAccessibilityPresentation.resolve(
            group: group,
            activeTitle: activeTitle,
            isExpanded: false
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                switch group {
                case .format:
                    ForEach(ClipboardFormatFilter.allCases) { option in
                        menuOption(
                            title: option.localizedTitle,
                            systemImage: option.systemImage,
                            selected: filterState.format == option
                        ) {
                            onSelectFormat(option)
                        }
                    }
                case .time:
                    ForEach(ClipboardTimeFilter.allCases) { option in
                        menuOption(
                            title: option.localizedTitle,
                            systemImage: option.systemImage,
                            selected: filterState.time == option
                        ) {
                            onSelectTime(option)
                        }
                    }
                case .source:
                    menuOption(
                        title: L10n.string("clipboard.filter.all"),
                        systemImage: "app.badge",
                        selected: filterState.sourceFilterKey == nil
                    ) {
                        onSelectSource(nil)
                    }
                    ForEach(sourceOptions) { source in
                        sourceMenuOption(
                            title: source.displayName,
                            bundleIdentifier: source.bundleIdentifier,
                            selected: filterState.sourceFilterKey == source.key
                        ) {
                            onSelectSource(source.key)
                        }
                    }
                }
            } label: {
                ClipboardFilterIslandButton(
                    group: group,
                    activeTitle: activeTitle,
                    isExpanded: false,
                    hasActiveFilter: hasActiveFilter,
                    reservesClearSlot: false,
                    showsIcon: showsIcon
                )
                .frame(width: fixedWidth - ClipboardFilterBarLayout.clearSlotWidth, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(width: fixedWidth - ClipboardFilterBarLayout.clearSlotWidth)
            .accessibilityLabel(accessibilityPresentation.label)
            .accessibilityValue(accessibilityPresentation.value)
            .help(accessibilityPresentation.help)

            if hasActiveFilter {
                ClipboardFilterClearButton(group: group, action: onClearGroup)
            } else {
                Color.clear
                    .frame(width: ClipboardFilterBarLayout.clearSlotWidth, height: ClipboardFilterBarLayout.clearSlotWidth)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ClipboardFilterBarLayout.filterHitHorizontalPadding)
        .frame(
            width: fixedWidth + ClipboardFilterBarLayout.filterHitHorizontalPadding * 2,
            height: ClipboardFilterBarLayout.filterHitHeight
        )
        .contentShape(Rectangle())
    }

    private func menuOption(
        title: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ClipboardFilterOptionMenuLabel(
                title: title,
                systemImage: systemImage,
                selected: selected
            )
        }
    }

    private func sourceMenuOption(
        title: String,
        bundleIdentifier: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ClipboardFilterOptionMenuLabel(
                title: title,
                systemImage: nil,
                sourceBundleIdentifier: bundleIdentifier,
                usesSourceIcon: true,
                selected: selected
            )
        }
    }
}

private struct ClipboardFilterOptionMenuLabel: View {
    let title: String
    let systemImage: String?
    var sourceBundleIdentifier: String?
    var usesSourceIcon = false
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            if usesSourceIcon {
                ClipboardSourceIcon(bundleIdentifier: sourceBundleIdentifier)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
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

private enum ClipboardSourceAppIconResolver {
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
