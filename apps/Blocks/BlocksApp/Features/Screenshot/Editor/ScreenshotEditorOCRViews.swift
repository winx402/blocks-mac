import SwiftUI

enum ScreenshotManualOCRPanelLayout {
    static func size(for state: ScreenshotManualOCRState) -> CGSize? {
        switch state {
        case .result, .failed:
            ScreenshotDesignTokens.ocrPanelSize
        case .idle, .selecting, .recognizing:
            nil
        }
    }
}

struct ScreenshotManualOCRProgressOverlay: View {
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.001).contentShape(Rectangle())
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.string("screenshot.ocr.recognizing"))
                    .font(.system(size: 12, weight: .medium))
                Button(L10n.string("common.cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 52, minHeight: BlocksVisualTokens.Control.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 14)
            .blocksSurface(
                .hud,
                cornerRadius: BlocksVisualTokens.CornerRadius.control
            )
        }
    }
}

struct ScreenshotManualOCRResultPanel: View {
    @Binding var text: String
    let allowsCopy: Bool
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string("screenshot.ocr.result"), systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                ScreenshotToolbarIconButton(
                    systemImage: "xmark",
                    label: L10n.string("common.close"),
                    action: onClose
                )
            }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .accessibilityLabel(
                    L10n.string("screenshot.ocr.result")
                )
                .accessibilityHint(
                    L10n.string("screenshot.editor.accessibility.editText")
                )
                .padding(6)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                )
            HStack {
                Spacer()
                Button(L10n.string("screenshot.ocr.copy"), action: onCopy)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(minHeight: BlocksVisualTokens.Control.minimumHitTarget)
                    .opacity(allowsCopy ? 1 : 0)
                    .allowsHitTesting(allowsCopy)
                    .accessibilityHidden(!allowsCopy)
            }
        }
        .padding(10)
        .frame(
            width: ScreenshotDesignTokens.ocrPanelSize.width,
            height: ScreenshotDesignTokens.ocrPanelSize.height
        )
        .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
    }
}

struct ScreenshotManualOCRFailurePanel: View {
    let reason: ScreenshotManualOCRFailure
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                reason == .timedOut
                    ? L10n.string("screenshot.ocr.timedOut")
                    : L10n.string("screenshot.ocr.failed"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            HStack {
                Button(L10n.string("common.close"), action: onClose)
                Spacer()
                Button(L10n.string("screenshot.ocr.retry"), action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(
            width: ScreenshotDesignTokens.ocrPanelSize.width,
            height: ScreenshotDesignTokens.ocrPanelSize.height
        )
        .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
    }
}
