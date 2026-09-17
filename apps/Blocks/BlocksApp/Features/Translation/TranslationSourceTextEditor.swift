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
    /// Includes marked IME text, which is visually present before it becomes
    /// committed model text. This controls presentation only; `onTextChange`
    /// continues to publish committed edits alone.
    var onDisplayedTextChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTextChange: onTextChange,
            onFocusChange: onFocusChange,
            onDisplayedTextChange: onDisplayedTextChange
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
        context.coordinator.onDisplayedTextChange = onDisplayedTextChange
        guard let textView =
            scrollView.documentView as? TranslationSourceNSTextView else {
            return
        }
        context.coordinator.attachIfNeeded(textView)
        if context.coordinator.shouldApplyModelText(
            text,
            to: textView
        ) {
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
            context.coordinator.publishDisplayedTextState(for: textView)
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
        var onDisplayedTextChange: (Bool) -> Void
        var isApplyingModelText = false
        var isPublishingChange = false
        var lastFocusRequest = 0
        private var pendingFocusRequest: Int?
        private var keyWindowObservation: NSObjectProtocol?
        private var textChangeObservation: NSObjectProtocol?
        private var retryCount = 0
        private var lastPublishedText: String?
        private var lastDisplayedTextState: Bool?
        private var awaitingMarkedTextCommit = false
        private var markedTextCommitGeneration = 0
        private var displayedTextStateGeneration = 0
        private var scheduledDisplayedTextStateGeneration: Int?
        private var pendingDisplayedTextState: Bool?
        private let isEligibleForFocus: (NSTextView) -> Bool
        private let performFocus: (NSTextView) -> Bool

        init(
            onTextChange: @escaping (String) -> Void,
            onFocusChange: @escaping (Bool) -> Void = { _ in },
            onDisplayedTextChange: @escaping (Bool) -> Void = { _ in },
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
            self.onDisplayedTextChange = onDisplayedTextChange
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
            textView.onDisplayedTextChange = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.updateMarkedTextCommitState(for: textView)
                self.publishDisplayedTextState(for: textView)
            }
            installKeyWindowObservation(for: textView)
            textChangeObservation =
                NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: textView,
                    queue: .main
                ) { [weak self] notification in
                    self?.publishTextChange(notification)
                }
            lastPublishedText = textView.string
            publishDisplayedTextState(for: textView)
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
            displayedTextStateGeneration += 1
            scheduledDisplayedTextStateGeneration = nil
            pendingDisplayedTextState = nil
            markedTextCommitGeneration += 1
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
            (textView as? TranslationSourceNSTextView)?.onDisplayedTextChange = nil
            textView = nil
            lastPublishedText = nil
            lastDisplayedTextState = nil
            awaitingMarkedTextCommit = false
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
                    notification.object as? TranslationSourceNSTextView,
                  !textView.isUpdatingComposition,
                  !textView.isComposingText else {
                return
            }
            awaitingMarkedTextCommit = false
            publishCommittedTextIfNeeded(from: textView)
        }

        func shouldApplyModelText(
            _ modelText: String,
            to textView: NSTextView
        ) -> Bool {
            let translationTextView =
                textView as? TranslationSourceNSTextView
            return !isPublishingChange
                && !isApplyingModelText
                && !textView.hasMarkedText()
                && translationTextView?.isUpdatingComposition != true
                && translationTextView?.isComposingText != true
                && !awaitingMarkedTextCommit
                && textView.string != modelText
        }

        private func updateMarkedTextCommitState(
            for textView: TranslationSourceNSTextView
        ) {
            if textView.isUpdatingComposition || textView.isComposingText {
                markedTextCommitGeneration += 1
                awaitingMarkedTextCommit = true
            } else {
                // Both cancellation and commit may finish through unmarkText
                // without a later did-change notification. Fence one main
                // queue turn, then publish the actual final string if it
                // differs from the last committed value. This also releases
                // cancellation with pre-existing text instead of leaving the
                // model-to-editor gate permanently closed.
                markedTextCommitGeneration += 1
                let generation = markedTextCommitGeneration
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          let textView,
                          self.markedTextCommitGeneration == generation,
                          !textView.isUpdatingComposition,
                          !textView.isComposingText else {
                        return
                    }
                    self.publishCommittedTextIfNeeded(from: textView)
                    self.awaitingMarkedTextCommit = false
                }
            }
        }

        private func publishCommittedTextIfNeeded(
            from textView: NSTextView
        ) {
            publishDisplayedTextState(for: textView)
            let text = textView.string
            guard lastPublishedText != text else { return }
            lastPublishedText = text
            isPublishingChange = true
            onTextChange(text)
            isPublishingChange = false
        }

        func publishDisplayedTextState(for textView: NSTextView) {
            publishDisplayedTextState(
                textView.hasMarkedText()
                    || (textView as? TranslationSourceNSTextView)?
                        .isComposingText == true
                    || !textView.string.isEmpty
            )
        }

        private func publishDisplayedTextState(_ hasDisplayedText: Bool) {
            guard lastDisplayedTextState != hasDisplayedText else {
                return
            }
            lastDisplayedTextState = hasDisplayedText
            pendingDisplayedTextState = hasDisplayedText
            guard scheduledDisplayedTextStateGeneration == nil else {
                return
            }
            let generation = displayedTextStateGeneration
            scheduledDisplayedTextStateGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.displayedTextStateGeneration == generation,
                      self.scheduledDisplayedTextStateGeneration == generation,
                      let state = self.pendingDisplayedTextState else {
                    return
                }
                self.scheduledDisplayedTextStateGeneration = nil
                self.pendingDisplayedTextState = nil
                self.onDisplayedTextChange(state)
            }
        }
    }
}

final class TranslationSourceNSTextView:
    NSTextView
{
    var onWindowChange: (() -> Void)?
    var onDisplayedTextChange: (() -> Void)?
    private var compositionMutationDepth = 0
    var isUpdatingComposition: Bool {
        compositionMutationDepth > 0
    }
    private(set) var isComposingText = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        compositionMutationDepth += 1
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        compositionMutationDepth -= 1
        isComposingText = Self.isNonEmptyMarkedPayload(string)
            && hasMarkedText()
        onDisplayedTextChange?()
    }

    override func unmarkText() {
        compositionMutationDepth += 1
        super.unmarkText()
        compositionMutationDepth -= 1
        isComposingText = false
        onDisplayedTextChange?()
    }

    override func insertText(
        _ string: Any,
        replacementRange: NSRange
    ) {
        let completesComposition = isComposingText || hasMarkedText()
        guard completesComposition else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        compositionMutationDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        compositionMutationDepth -= 1
        isComposingText = false
        onDisplayedTextChange?()
    }

    private static func isNonEmptyMarkedPayload(_ value: Any) -> Bool {
        if let value = value as? String {
            return !value.isEmpty
        }
        if let value = value as? NSAttributedString {
            return value.length > 0
        }
        return true
    }
}
