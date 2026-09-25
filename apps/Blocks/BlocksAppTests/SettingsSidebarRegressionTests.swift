import AppKit
import XCTest
@testable import Blocks

@MainActor
final class SettingsSidebarRegressionTests: XCTestCase {
    func testSettingsArtworkUsesOpticalSizesAndKeepsSymbolsInsideBadge() throws {
        for section in AppSection.allCases {
            XCTAssertTrue((12...14).contains(section.settingsIconPointSize))
            XCTAssertNotNil(NSImage(systemSymbolName: section.settingsIconSystemImage, accessibilityDescription: nil))
            let badge = BlocksSettingsIconView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            XCTAssertTrue(badge.wantsLayer, "Reusable source-list artwork needs its own backing on cold launch")
            badge.configure(systemImage: section.settingsIconSystemImage,
                            tint: NSColor(section.settingsIconColor),
                            pointSize: section.settingsIconPointSize)
            badge.layoutSubtreeIfNeeded()
            let symbol = try XCTUnwrap(badge.subviews.first as? NSImageView)
            XCTAssertTrue(badge.bounds.contains(symbol.frame))
            XCTAssertNotNil(symbol.image)
            XCTAssertFalse(badge.isAccessibilityElement())
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                badge.appearance = NSAppearance(named: appearance)
                let bitmap = try XCTUnwrap(badge.bitmapImageRepForCachingDisplay(in: badge.bounds))
                badge.cacheDisplay(in: badge.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            }
        }
        XCTAssertEqual(AppSection.shortcuts.settingsIconPointSize, 14)
        XCTAssertEqual(AppSection.permissions.systemImage, "lock.shield", "Non-settings icons must not change")
    }

    func testSidebarUsesThirtyPointRowsAndSingleTenPointGroupGaps() throws {
        let view = SettingsSourceListNativeView(frame: NSRect(x: 0, y: 0, width: 232, height: 680))
        view.layoutSubtreeIfNeeded()
        let screenshot = try XCTUnwrap(view.rowFrame(for: .screenshot))
        let clipboard = try XCTUnwrap(view.rowFrame(for: .clipboardSettings))
        let favorites = try XCTUnwrap(view.rowFrame(for: .translationFavorites))
        let shortcuts = try XCTUnwrap(view.rowFrame(for: .shortcuts))
        XCTAssertEqual(screenshot.height, 30, accuracy: 0.1)
        XCTAssertEqual(clipboard.minY - screenshot.maxY, 0, accuracy: 0.1)
        XCTAssertEqual(shortcuts.minY - favorites.maxY, 10, accuracy: 0.1)
    }

    func testSidebarEmphasisUsesSystemSelectedTextInsteadOfVibrantLabel() throws {
        let sidebar = SettingsSourceListNativeView(frame: NSRect(x: 0, y: 0, width: 232, height: 680))
        sidebar.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(firstDescendant(of: NSOutlineView.self, in: sidebar))
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        cell.backgroundStyle = .emphasized
        XCTAssertEqual(cell.textField?.textColor, NSColor.alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        XCTAssertEqual(cell.textField?.textColor, NSColor.labelColor)
    }

    func testSecondaryPageInsetDoesNotChangeOverviewRoutes() {
        let routes = SettingsRouteStateStore()
        for mode: SettingsViewMode in [.translation, .clipboard, .screenshot, .providers] {
            XCTAssertFalse(routes.isSecondaryPage(for: mode))
            let root = mode == .providers ? "overview" : "root"
            let binding = routes.secondaryRouteBinding(for: mode, default: root)
            binding.wrappedValue = "details"
            XCTAssertTrue(routes.isSecondaryPage(for: mode))
            binding.wrappedValue = root
            XCTAssertFalse(routes.isSecondaryPage(for: mode))
        }
    }

    func testLocalizedSourceListKeepsViewportWidthAndVerticalSelectionAcrossResizeAndReload() async throws {
        let sourceList = SettingsSourceListNativeView(
            frame: NSRect(x: 0, y: 0, width: 208, height: 150),
            groups: longLocalizedGroups
        )
        let window = sourceListWindow(
            containing: sourceList,
            size: NSSize(width: 208, height: 150)
        )
        defer { window.orderOut(nil) }

        window.orderFront(nil)

        for size in [
            NSSize(width: 208, height: 150),
            NSSize(width: 248, height: 240),
            NSSize(width: 224, height: 180),
        ] {
            window.setContentSize(size)
            sourceList.update(selection: .settings, navigationGeneration: 1)
            sourceList.layoutSubtreeIfNeeded()
            sourceList.reloadSourceList()
            sourceList.layoutSubtreeIfNeeded()
            for _ in 0..<10 { await Task.yield() }
            sourceList.layoutSubtreeIfNeeded()

            let scrollView = try XCTUnwrap(firstDescendant(of: NSScrollView.self, in: sourceList))
            XCTAssertGreaterThan(scrollView.contentView.bounds.width, 0)
            XCTAssertEqual(
                sourceList.documentWidth,
                sourceList.viewportWidth,
                accuracy: 0.5
            )
            XCTAssertEqual(
                sourceList.documentColumnWidth,
                sourceList.viewportWidth,
                accuracy: 0.5
            )
            XCTAssertTrue(sourceList.horizontalScrollingIsDisabled)
            XCTAssertEqual(sourceList.horizontalScrollOffset, 0, accuracy: 0.001)
            XCTAssertEqual(sourceList.selectedSection, .settings)
            XCTAssertTrue(sourceList.selectedRowIsVisible)
        }

        XCTAssertEqual(sourceList.groupCount, 5)
        let groupRows = (0 ..< sourceList.rowCount).filter { !sourceList.isSelectable(row: $0) }
        XCTAssertEqual(groupRows.count, 5)
        XCTAssertTrue(groupRows.allSatisfy {
            sourceList.accessibilityRole(at: $0)?.rawValue != "AXHeading"
        })
    }

    func testSourceListRejectsDirectHorizontalClipViewScroll() async throws {
        let sourceList = SettingsSourceListNativeView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 150)
        )
        let window = sourceListWindow(
            containing: sourceList,
            size: NSSize(width: 224, height: 150)
        )
        defer { window.orderOut(nil) }

        window.orderFront(nil)
        sourceList.update(selection: .settings, navigationGeneration: 1)
        sourceList.layoutSubtreeIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        sourceList.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(firstDescendant(of: NSScrollView.self, in: sourceList))
        let verticalOrigin = scrollView.contentView.bounds.origin.y
        scrollView.contentView.scroll(to: NSPoint(x: 96, y: verticalOrigin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sourceList.layoutSubtreeIfNeeded()

        XCTAssertEqual(sourceList.horizontalScrollOffset, 0, accuracy: 0.001)
        XCTAssertEqual(
            sourceList.documentWidth,
            sourceList.viewportWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(
            sourceList.documentColumnWidth,
            sourceList.viewportWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(sourceList.selectedSection, .settings)
        XCTAssertTrue(sourceList.selectedRowIsVisible)
    }

    private func sourceListWindow(
        containing sourceList: SettingsSourceListNativeView,
        size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4_000, y: -4_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = sourceList
        return window
    }

    private var longLocalizedGroups: [SettingsSidebarGroupDescriptor] {
        let longJapaneseTitle = String(
            repeating: "長いローカライズ済み設定ナビゲーション",
            count: 4
        )
        return SettingsSidebarSourceListModel.groups.map { group in
            SettingsSidebarGroupDescriptor(
                id: group.id,
                localizationKey: group.localizationKey,
                sections: group.sections,
                displayTitle: longJapaneseTitle
            )
        }
    }

    private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        for child in view.subviews {
            if let result = firstDescendant(of: type, in: child) {
                return result
            }
        }
        return nil
    }
}
