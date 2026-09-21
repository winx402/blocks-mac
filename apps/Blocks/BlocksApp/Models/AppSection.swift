import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case screenshot
    case clipboardSettings
    case clipboardPrivacy
    case translationSettings
    case translationFavorites
    case shortcuts
    case permissions
    case providers
    case agentCLI
    case hooks
    case dataAudit
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot:
            L10n.string("menu.screenshot")
        case .clipboardSettings:
            L10n.string("menu.clipboard")
        case .clipboardPrivacy:
            L10n.string("menu.clipboardPrivacy")
        case .translationSettings:
            L10n.string("menu.translation")
        case .translationFavorites:
            L10n.string("menu.translationFavorites")
        case .shortcuts:
            L10n.string("menu.shortcuts")
        case .permissions:
            L10n.string("menu.permissions")
        case .providers:
            L10n.string("menu.providers")
        case .agentCLI:
            L10n.string("menu.agentCLI")
        case .hooks:
            L10n.string("menu.hooks")
        case .dataAudit:
            L10n.string("menu.dataAudit")
        case .settings:
            L10n.string("settings.general.title")
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot:
            "camera.viewfinder"
        case .clipboardSettings:
            "doc.on.clipboard.fill"
        case .clipboardPrivacy:
            "hand.raised.fill"
        case .translationSettings:
            "character.book.closed.fill"
        case .translationFavorites:
            "star.bubble.fill"
        case .shortcuts:
            "keyboard"
        case .permissions:
            "lock.shield"
        case .providers:
            "point.3.connected.trianglepath.dotted"
        case .agentCLI:
            "terminal"
        case .hooks:
            "puzzlepiece.extension"
        case .dataAudit:
            "list.bullet.rectangle.portrait"
        case .settings:
            "gearshape"
        }
    }

    var iconColor: Color {
        switch self {
        case .screenshot:
            .orange
        case .clipboardSettings:
            .mint
        case .clipboardPrivacy:
            .green
        case .translationSettings:
            .indigo
        case .translationFavorites:
            .yellow
        case .shortcuts:
            .purple
        case .permissions:
            .red
        case .providers:
            .teal
        case .agentCLI:
            .cyan
        case .hooks:
            .pink
        case .dataAudit:
            .blue
        case .settings:
            .gray
        }
    }

    /// Settings-only artwork: do not change floating-panel or menu icons.
    var settingsIconSystemImage: String {
        switch self {
        case .clipboardSettings: "clipboard"
        case .translationSettings: "character.bubble"
        case .translationFavorites: "star"
        case .providers: "sparkles"
        default: systemImage
        }
    }

    var settingsIconColor: Color {
        let base: NSColor = switch self {
        case .screenshot: .systemOrange
        case .clipboardSettings: .systemTeal
        case .clipboardPrivacy: .systemGreen
        case .translationSettings: .systemIndigo
        case .translationFavorites: .systemOrange
        case .shortcuts: .systemPurple
        case .permissions: .systemRed
        case .providers: .systemTeal
        case .agentCLI: .systemBlue
        case .hooks: .systemPink
        case .dataAudit: .systemBlue
        case .settings: .systemGray
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                resolved = base.blended(withFraction: dark ? 0.24 : 0.12, of: .darkGray) ?? base
            }
            return resolved
        })
    }
}
