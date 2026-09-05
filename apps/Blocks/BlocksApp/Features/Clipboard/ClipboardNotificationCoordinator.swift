import AppKit
import Foundation

@MainActor
final class ClipboardNotificationCoordinator {
    let presentationState = BlocksNotificationPresentationState(isHostVisible: false)
    private let fallbackPanelPresenter: BlocksNotificationPanelPresenting

    convenience init() {
        self.init(
            fallbackPanelPresenter: BlocksNotificationPanelPresenter()
        )
    }

    init(fallbackPanelPresenter: BlocksNotificationPanelPresenting) {
        self.fallbackPanelPresenter = fallbackPanelPresenter
    }

    func setHostVisible(_ isVisible: Bool) {
        presentationState.setHostVisible(isVisible)
    }

    func capturePersistenceFailed() {
        present(
            level: .error,
            titleKey: "status.clipboardPolicyApplyFailed.title",
            detailKey: "status.clipboardPolicyApplyFailed.detail",
            deduplicationKey: "clipboard.capture.persistence"
        )
    }

    func repositoryUnavailable() {
        present(
            level: .error,
            titleKey: "clipboard.hardening.state.unavailable.title",
            detailKey: "clipboard.hardening.state.unavailable.detail",
            deduplicationKey: "clipboard.repository.unavailable"
        )
    }

    func favoriteChanged(recordID: String, isFavorite: Bool) {
        present(
            level: .success,
            titleKey: isFavorite ? "status.clipboardFavorite.title" : "status.clipboardFavoriteRemoved.title",
            detailKey: isFavorite ? "status.clipboardFavorite.detail" : "status.clipboardFavoriteRemoved.detail",
            deduplicationKey: "clipboard.favorite.\(recordID)"
        )
    }

    func plainTextCopyFailed() {
        present(
            level: .error,
            titleKey: "status.clipboardPlainTextCopyFailed.title",
            detailKey: "status.clipboardPlainTextCopyFailed.detail",
            deduplicationKey: "clipboard.copy-plain-text.failed"
        )
    }

    func plainTextCopied() {
        present(
            level: .success,
            titleKey: "status.clipboardPlainTextCopied.title",
            detailKey: "status.clipboardPlainTextCopied.detail",
            deduplicationKey: "clipboard.copy-plain-text.succeeded"
        )
    }

    /// The ordinary clipboard panel closes as soon as the Pasteboard write
    /// succeeds. Present this partial-success result in an independent HUD so
    /// it remains visible without leaking into the next panel invocation.
    func copiedWithoutAutomaticPaste(
        reason: ClipboardPasteFailureReason,
        screen: NSScreen? = nil
    ) {
        fallbackPanelPresenter.present(
            BlocksNotificationDescriptor(
                level: .warning,
                title: L10n.string(
                    "status.clipboardPasteCopiedFallback.title"
                ),
                detail: L10n.string(
                    "status.clipboardPasteCopiedFallback.detail"
                ),
                dismissPolicy: .automatic(after: 4),
                deduplicationKey:
                    "clipboard.paste.fallback.\(reason.rawValue)"
            ),
            on: screen ?? Self.screenUnderPointer(),
            avoiding: []
        )
    }

    func dismissCopiedFallback() {
        fallbackPanelPresenter.dismiss()
    }

    func shutdown() {
        presentationState.shutdown()
        fallbackPanelPresenter.shutdown()
    }

    func recordRemoved(remainingCount: Int) {
        presentationState.present(BlocksNotificationDescriptor(
            level: .success,
            title: L10n.string("status.clipboardRemoved.title"),
            detail: L10n.format("status.clipboardRemoved.detail", remainingCount),
            deduplicationKey: "clipboard.record.removed"
        ))
    }

    func present(
        level: BlocksNotificationLevel,
        titleKey: String,
        detail: String,
        deduplicationKey: String
    ) {
        presentationState.present(BlocksNotificationDescriptor(
            level: level,
            title: L10n.string(titleKey),
            detail: detail,
            deduplicationKey: deduplicationKey
        ))
    }

    private func present(
        level: BlocksNotificationLevel,
        titleKey: String,
        detailKey: String,
        deduplicationKey: String
    ) {
        present(
            level: level,
            titleKey: titleKey,
            detail: L10n.string(detailKey),
            deduplicationKey: deduplicationKey
        )
    }

    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? NSScreen.main
    }
}
