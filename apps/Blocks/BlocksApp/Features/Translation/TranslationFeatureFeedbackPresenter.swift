import AppKit
import BlocksCore
import OSLog

@MainActor
final class TranslationEntryTelemetry {
    private static let signposter = OSSignposter(
        subsystem: "app.blocks.app",
        category: "TranslationEntry"
    )
    private var interval: (
        id: UUID,
        source: TranslationInputSource,
        state: OSSignpostIntervalState
    )?

    func begin(id: UUID, source: TranslationInputSource) {
        cancel()
        interval = (
            id: id,
            source: source,
            state: Self.signposter.beginInterval(
                "PanelPresentation",
                id: Self.signposter.makeSignpostID()
            )
        )
    }

    func finish(id: UUID, outcome: String) {
        guard let interval, interval.id == id else { return }
        Self.signposter.endInterval(
            "PanelPresentation",
            interval.state,
            "source=\(interval.source.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
        self.interval = nil
    }

    func cancel() {
        guard let interval else { return }
        Self.signposter.endInterval(
            "PanelPresentation",
            interval.state,
            "source=\(interval.source.rawValue, privacy: .public) outcome=cancelled"
        )
        self.interval = nil
    }
}

@MainActor
final class TranslationFeatureFeedbackPresenter {
    private let notificationPresenter:
        (any BlocksNotificationPanelPresenting)?
    private var statusRecorder: (AppStatus) -> Void = { _ in }

    init(
        notificationPresenter:
            (any BlocksNotificationPanelPresenting)?
    ) {
        self.notificationPresenter = notificationPresenter
    }

    func configure(statusRecorder: @escaping (AppStatus) -> Void) {
        self.statusRecorder = statusRecorder
    }

    func presentClipboardUnavailable() {
        present(
            .translationClipboardUnavailable,
            deduplicationKey: "translation-clipboard-unavailable"
        )
    }

    func presentSelectionHelperUnsupported() {
        present(
            AppStatus(
                kind: .failed,
                title: L10n.string(
                    "translation.selection.unsupportedChannel.title"
                ),
                detail: L10n.string(
                    "translation.selection.unsupportedChannel.detail"
                )
            ),
            level: .warning,
            deduplicationKey: "translation-selection-channel-unsupported"
        )
    }

    func recordSelectionFailureIfNeeded(
        _ failure: AXSelectionReadFailure
    ) {
        guard failure.reason == .accessibilityPermissionDenied else {
            return
        }
        statusRecorder(
            AppStatus(
                kind: .failed,
                title: L10n.string(
                    "translation.selection.permission.title"
                ),
                detail: L10n.string(
                    "translation.selection.permission.detail"
                )
            )
        )
    }

    func present(
        _ status: AppStatus,
        anchor: TranslationInputAnchor? = nil,
        level: BlocksNotificationLevel = .error,
        deduplicationKey: String
    ) {
        statusRecorder(status)
        guard let notificationPresenter else { return }
        notificationPresenter.present(
            BlocksNotificationDescriptor(
                level: level,
                title: status.title,
                detail: status.detail,
                deduplicationKey: deduplicationKey
            ),
            on: screen(for: anchor),
            avoiding: []
        )
    }

    private func screen(
        for anchor: TranslationInputAnchor?
    ) -> NSScreen? {
        if let anchor {
            let rect = CGRect(
                x: anchor.x,
                y: anchor.y,
                width: anchor.width,
                height: anchor.height
            )
            return NSScreen.screens.max {
                let lhs = $0.frame.intersection(rect)
                let rhs = $1.frame.intersection(rect)
                return lhs.width * lhs.height
                    < rhs.width * rhs.height
            }
        }
        return NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
    }
}
