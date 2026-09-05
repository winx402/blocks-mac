import BlocksScreenshotCore

extension ScreenshotResolvedCaptureKind {
    var localizedTitle: String {
        switch self {
        case .region:
            L10n.string("screenshot.mode.region")
        case .window:
            L10n.string("screenshot.mode.window")
        case .display:
            L10n.string("screenshot.mode.display")
        }
    }
}
