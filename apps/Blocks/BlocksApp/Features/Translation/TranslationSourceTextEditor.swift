import AppKit
import SwiftUI

/// A narrow AppKit bridge used only where the translation panel must prove
/// the real first responder after a nonactivating panel becomes key.
/// SwiftUI remains the text source of truth.
struct TranslationSourceTextEditor:
    NSViewRepresentable
{
    let text: String
    let focusRequest: Int
    let onTextChange: (String) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTextChange: onTextChange,
            onFocusChange: onFocusChange
        )
    }

    func makeNSView(
        context: Context
    ) -> NSScrollView {
        let textView = TranslationSourceNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize
        )
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(
            width: 8,
            height: 8
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.onWindowChange = {
            context.coordinator.retryPendingFocus()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.attach(textView)
        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onFocusChange = onFocusChange
        guard let textView =
            scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.attachIfNeeded(textView)
        if !context.coordinator.isPublishingChange,
           textView.string != text {
            let previousSelection = textView.selectedRange()
            context.coordinator.isApplyingModelText = true
            textView.string = text
            let safeLocation = min(
                previousSelection.location,
                (text as NSString).length
            )
            textView.setSelectedRange(NSRange(
                location: safeLocation,
                length: 0
            ))
            context.coordinator.isApplyingModelText = false
        }

        if focusRequest > 0 {
            context.coordinator.requestFocus(
                generation: focusRequest
            )
        }
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        if let textView =
            scrollView.documentView
                as? TranslationSourceNSTextView {
            textView.onWindowChange = nil
        }
        coordinator.detach()
    }

    final class Coordinator:
        NSObject,
        NSTextViewDelegate
    {
        weak var textView: NSTextView?
        var onTextChange: (String) -> Void
        var onFocusChange: (Bool) -> Void
        var isApplyingModelText = false
        var isPublishingChange = false
        var lastFocusRequest = 0
        private var pendingFocusRequest: Int?
        private var keyWindowObservation: NSObjectProtocol?
        private var textChangeObservation: NSObjectProtocol?
        private var retryCount = 0
        private var lastPublishedText: String?
        private let isEligibleForFocus: (NSTextView) -> Bool
        private let performFocus: (NSTextView) -> Bool

        init(
            onTextChange: @escaping (String) -> Void,
            onFocusChange: @escaping (Bool) -> Void = { _ in },
            isEligibleForFocus:
                @escaping (NSTextView) -> Bool = {
                    $0.window?.isKeyWindow == true
                },
            performFocus:
                @escaping (NSTextView) -> Bool = {
                    guard let window = $0.window else {
                        return false
                    }
                    return window.firstResponder === $0
                        || window.makeFirstResponder($0)
                }
        ) {
            self.onTextChange = onTextChange
            self.onFocusChange = onFocusChange
            self.isEligibleForFocus = isEligibleForFocus
            self.performFocus = performFocus
        }

        deinit {
            detach()
        }

        func attach(
            _ textView: TranslationSourceNSTextView
        ) {
            detachTextView()
            self.textView = textView
            textView.delegate = self
            installKeyWindowObservation(for: textView)
            textChangeObservation =
                NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: textView,
                    queue: .main
                ) { [weak self] notification in
                    self?.publishTextChange(notification)
                }
        }

        func attachIfNeeded(_ textView: NSTextView) {
            guard self.textView !== textView else {
                if textView.delegate !== self {
                    textView.delegate = self
                }
                return
            }
            guard let translationTextView =
                textView as? TranslationSourceNSTextView else {
                return
            }
            attach(translationTextView)
        }

        func detach() {
            detachTextView()
            pendingFocusRequest = nil
        }

        private func detachTextView() {
            if let keyWindowObservation {
                NotificationCenter.default.removeObserver(
                    keyWindowObservation
                )
            }
            if let textChangeObservation {
                NotificationCenter.default.removeObserver(
                    textChangeObservation
                )
            }
            keyWindowObservation = nil
            textChangeObservation = nil
            if textView?.delegate === self {
                textView?.delegate = nil
            }
            textView = nil
            lastPublishedText = nil
        }

        func requestFocus(generation: Int) {
            guard generation > lastFocusRequest else {
                return
            }
            if pendingFocusRequest != generation {
                pendingFocusRequest = generation
                retryCount = 0
            }
            retryPendingFocus()
        }

        func retryPendingFocus() {
            guard let generation = pendingFocusRequest,
                  generation > lastFocusRequest,
                  let textView else {
                return
            }
            installKeyWindowObservation(for: textView)
            guard isEligibleForFocus(textView) else {
                return
            }
            if performFocus(textView) {
                lastFocusRequest = generation
                pendingFocusRequest = nil
                retryCount = 0
                return
            }
            guard retryCount < 3 else { return }
            retryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.retryPendingFocus()
            }
        }

        private func installKeyWindowObservation(
            for textView: NSTextView
        ) {
            guard keyWindowObservation == nil,
                  let window = textView.window else {
                return
            }
            keyWindowObservation =
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.retryPendingFocus()
                }
        }

        func textDidChange(
            _ notification: Notification
        ) {
            publishTextChange(notification)
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange(false)
        }

        private func publishTextChange(
            _ notification: Notification
        ) {
            guard !isApplyingModelText,
                  let textView =
                    notification.object as? NSTextView else {
                return
            }
            let text = textView.string
            guard lastPublishedText != text else { return }
            lastPublishedText = text
            isPublishingChange = true
            onTextChange(text)
            isPublishingChange = false
        }
    }
}

final class TranslationSourceNSTextView:
    NSTextView
{
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
