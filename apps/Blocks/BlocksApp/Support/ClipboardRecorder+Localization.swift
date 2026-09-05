import BlocksCore

extension ClipboardRecorderItemKind {
    var localizedTitle: String {
        switch self {
        case .text:
            L10n.string("clipboard.kind.text")
        case .richText:
            L10n.string("clipboard.kind.richText")
        case .image:
            L10n.string("clipboard.kind.image")
        case .url:
            L10n.string("clipboard.kind.url")
        case .fileURL:
            L10n.string("clipboard.kind.fileURL")
        case .mixed:
            L10n.string("clipboard.kind.mixed")
        case .unknown:
            L10n.string("clipboard.kind.unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .text:
            "text.alignleft"
        case .richText:
            "textformat"
        case .image:
            "photo"
        case .url:
            "link"
        case .fileURL:
            "doc"
        case .mixed:
            "square.stack.3d.up"
        case .unknown:
            "questionmark.square"
        }
    }
}

extension ClipboardCaptureSkipReason {
    var localizedPreviewBody: String {
        switch self {
        case .paused:
            L10n.string("clipboard.preview.capturePaused")
        case .privacyPolicyUnavailable:
            L10n.string("clipboard.preview.privacyPolicyUnavailable")
        case .excludedSource:
            L10n.string("clipboard.preview.excludedSource")
        case .unsupportedContent:
            L10n.string("clipboard.preview.unsupportedContent")
        }
    }
}
