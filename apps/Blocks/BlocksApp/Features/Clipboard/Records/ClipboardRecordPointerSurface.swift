import AppKit
import OSLog
import SwiftUI

/// A narrow AppKit bridge that resolves primary-button press, single-click, and
/// double-click before forwarding semantic actions to SwiftUI.
///
/// SwiftUI remains the source of truth for selection and record actions. This
/// view owns only the native gesture-recognizer lifecycle so callers never
/// inspect a transient application event or infer double-clicks from timestamps.
struct ClipboardRecordPointerSurface: NSViewRepresentable {
    let panelSessionID: UUID?
    let recordID: String
    let source: ClipboardPanelActivationSource
    let onPointerPress: () -> Void
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClipboardRecordPointerSurfaceView {
        let view = ClipboardRecordPointerSurfaceView()
        view.configure(
            panelSessionID: panelSessionID,
            recordID: recordID,
            source: source,
            onPointerPress: onPointerPress,
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick
        )
        return view
    }

    func updateNSView(_ nsView: ClipboardRecordPointerSurfaceView, context: Context) {
        nsView.configure(
            panelSessionID: panelSessionID,
            recordID: recordID,
            source: source,
            onPointerPress: onPointerPress,
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick
        )
    }
}

@MainActor
final class ClipboardRecordPointerSurfaceView: NSView, NSGestureRecognizerDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-pointer"
    )

    let pressRecognizer = NSPressGestureRecognizer()
    let singleClickRecognizer = NSClickGestureRecognizer()
    let doubleClickRecognizer = NSClickGestureRecognizer()

    private var panelSessionID: UUID?
    private var recordID = ""
    private var source = ClipboardPanelActivationSource.bottomCard
    private var onPointerPress: () -> Void = {}
    private var onSingleClick: () -> Void = {}
    private var onDoubleClick: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)

        pressRecognizer.target = self
        pressRecognizer.action = #selector(handlePress(_:))
        pressRecognizer.buttonMask = 0x1
        pressRecognizer.minimumPressDuration = 0
        pressRecognizer.delegate = self

        singleClickRecognizer.target = self
        singleClickRecognizer.action = #selector(handleSingleClick(_:))
        singleClickRecognizer.buttonMask = 0x1
        singleClickRecognizer.numberOfClicksRequired = 1
        singleClickRecognizer.delegate = self

        doubleClickRecognizer.target = self
        doubleClickRecognizer.action = #selector(handleDoubleClick(_:))
        doubleClickRecognizer.buttonMask = 0x1
        doubleClickRecognizer.numberOfClicksRequired = 2
        doubleClickRecognizer.delegate = self

        addGestureRecognizer(pressRecognizer)
        addGestureRecognizer(singleClickRecognizer)
        addGestureRecognizer(doubleClickRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(
        panelSessionID: UUID?,
        recordID: String,
        source: ClipboardPanelActivationSource,
        onPointerPress: @escaping () -> Void,
        onSingleClick: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void
    ) {
        self.panelSessionID = panelSessionID
        self.recordID = recordID
        self.source = source
        self.onPointerPress = onPointerPress
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        isPressAndClickPair(gestureRecognizer, otherGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        gestureRecognizer === singleClickRecognizer
            && otherGestureRecognizer === doubleClickRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        let isPrimaryPointerEvent = switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            event.buttonNumber == 0
        default:
            false
        }
        if !isPrimaryPointerEvent {
            log(stage: "ignored", recognizer: gestureRecognizer, committed: false)
        }
        return isPrimaryPointerEvent
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            log(stage: "press", recognizer: recognizer, committed: true)
            onPointerPress()
        case .cancelled, .failed:
            log(stage: "cancel", recognizer: recognizer, committed: false)
        default:
            break
        }
    }

    @objc private func handleSingleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        log(stage: "single", recognizer: recognizer, committed: true)
        onSingleClick()
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        log(stage: "double", recognizer: recognizer, committed: true)
        onDoubleClick()
    }

    private func isPressAndClickPair(
        _ first: NSGestureRecognizer,
        _ second: NSGestureRecognizer
    ) -> Bool {
        let firstIsPress = first === pressRecognizer
        let secondIsPress = second === pressRecognizer
        let firstIsClick = first === singleClickRecognizer || first === doubleClickRecognizer
        let secondIsClick = second === singleClickRecognizer || second === doubleClickRecognizer
        return (firstIsPress && secondIsClick) || (secondIsPress && firstIsClick)
    }

    private func log(
        stage: String,
        recognizer: NSGestureRecognizer,
        committed: Bool
    ) {
#if DEBUG
        let recognizerName: String
        if recognizer === pressRecognizer {
            recognizerName = "press"
        } else if recognizer === singleClickRecognizer {
            recognizerName = "single"
        } else if recognizer === doubleClickRecognizer {
            recognizerName = "double"
        } else {
            recognizerName = "unknown"
        }
        Self.logger.debug(
            "session=\(self.panelSessionID?.uuidString ?? "none", privacy: .public) record=\(String(self.recordID.suffix(8)), privacy: .public) source=\(self.source.rawValue, privacy: .public) stage=\(stage, privacy: .public) recognizer=\(recognizerName, privacy: .public) state=\(self.recognizerStateName(recognizer.state), privacy: .public) committed=\(committed, privacy: .public)"
        )
#endif
    }

    private func recognizerStateName(_ state: NSGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "unknown"
        }
    }
}
