import AppKit
import BlocksCore
import SwiftUI

enum TranslationPanelSourceLayout {
    /// A text-only source header follows the system subheadline's natural
    /// line height. Screenshot OCR additionally exposes a compact action, so
    /// that variant retains the shared compact-control hit target.
    static var sourceTextHeaderHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(
            for: NSFont.preferredFont(forTextStyle: .subheadline)
        )
    }

    static func sourceHeaderHeight(
        for source: TranslationInputSource
    ) -> CGFloat {
        source == .screenshotOCR
            ? TranslationPanelMetrics.compactIconHitTarget
            : sourceTextHeaderHeight
    }
    static let sourceEditorMinimumHeight: CGFloat = 48
    static let sourceEditorDefaultHeight: CGFloat = 72
    static let screenshotEditorDefaultHeight: CGFloat = 96
    static let sourceEditorSpacing: CGFloat = 8
    static let languageBarHeight: CGFloat = 44

    static func expandedEditorHeight(
        for source: TranslationInputSource
    ) -> CGFloat {
        source == .screenshotOCR
            ? screenshotEditorDefaultHeight
            : sourceEditorDefaultHeight
    }

    static func editorHeight(
        for source: TranslationInputSource,
        scrollOffset: CGFloat
    ) -> CGFloat {
        max(
            sourceEditorMinimumHeight,
            expandedEditorHeight(for: source)
                - max(0, scrollOffset)
        )
    }

    static func collapseRange(
        for source: TranslationInputSource
    ) -> CGFloat {
        expandedEditorHeight(for: source)
            - sourceEditorMinimumHeight
    }

    static func fixedControlsHeight(
        for source: TranslationInputSource,
        scrollOffset: CGFloat
    ) -> CGFloat {
        sourceSectionHeight(
            for: source,
            scrollOffset: scrollOffset
        )
            + TranslationPanelMetrics.sectionSpacing
            + languageBarHeight
    }

    static func sourceSectionHeight(
        for source: TranslationInputSource,
        scrollOffset: CGFloat
    ) -> CGFloat {
        sourceHeaderHeight(for: source)
            + sourceEditorSpacing
            + editorHeight(
                for: source,
                scrollOffset: scrollOffset
            )
    }

    static func fixedRegionHeight(
        for source: TranslationInputSource,
        scrollOffset: CGFloat
    ) -> CGFloat {
        TranslationPanelMetrics.contentInset
            + fixedControlsHeight(
                for: source,
                scrollOffset: scrollOffset
            )
            + TranslationPanelMetrics.sectionSpacing
    }
}

struct TranslationPanelScrollCoordinator: Equatable {
    private(set) var resultsOffset: CGFloat = 0

    struct Consumption: Equatable {
        let sourceDelta: CGFloat
        let remainingResultsDelta: CGFloat

        var consumedSource: Bool {
            abs(sourceDelta) > 0.01
        }
    }

    /// Consumes wheel distance while the source editor still needs to
    /// collapse, or while it needs to expand again after the result list has
    /// returned to its top. If one wheel event crosses the phase boundary,
    /// only the exact source-collapse distance is consumed and the remainder
    /// is forwarded to the result viewport.
    mutating func consume(
        contentDelta: CGFloat,
        collapseRange: CGFloat,
        resultsAreAtTop: Bool
    ) -> Consumption {
        let boundedRange = max(0, collapseRange)
        guard boundedRange > 0, contentDelta != 0 else {
            return Consumption(
                sourceDelta: 0,
                remainingResultsDelta: contentDelta
            )
        }

        if contentDelta > 0, resultsOffset < boundedRange {
            let sourceDelta = min(
                contentDelta,
                boundedRange - resultsOffset
            )
            resultsOffset += sourceDelta
            return Consumption(
                sourceDelta: sourceDelta,
                remainingResultsDelta: contentDelta - sourceDelta
            )
        }

        if contentDelta < 0,
           resultsAreAtTop,
           resultsOffset > 0 {
            let sourceDelta = max(contentDelta, -resultsOffset)
            resultsOffset += sourceDelta
            return Consumption(
                sourceDelta: sourceDelta,
                remainingResultsDelta: contentDelta - sourceDelta
            )
        }

        return Consumption(
            sourceDelta: 0,
            remainingResultsDelta: contentDelta
        )
    }

    mutating func reset() {
        resultsOffset = 0
    }
}

/// A narrow AppKit bridge used only to arbitrate the two scroll phases. It is
/// not a hit-test overlay: mouse, keyboard, selection, and drag events continue
/// to belong to the SwiftUI result list.
private struct TranslationResultsScrollPhaseBridge:
    NSViewRepresentable
{
    let onScroll:
        (_ contentDelta: CGFloat, _ resultsAreAtTop: Bool)
            -> TranslationPanelScrollCoordinator.Consumption

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.owner = context.coordinator
        context.coordinator.bridgeView = view
        return view
    }

    func updateNSView(
        _ nsView: BridgeView,
        context: Context
    ) {
        context.coordinator.onScroll = onScroll
        context.coordinator.attachIfNeeded()
    }

    static func dismantleNSView(
        _ nsView: BridgeView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
        nsView.owner = nil
    }

    final class BridgeView: NSView {
        weak var owner: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                owner?.detach()
            } else {
                owner?.attachIfNeeded()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var bridgeView: BridgeView?
        var onScroll:
            (_ contentDelta: CGFloat, _ resultsAreAtTop: Bool)
                -> TranslationPanelScrollCoordinator.Consumption
        private var eventMonitor: Any?

        init(
            onScroll:
                @escaping (
                    _ contentDelta: CGFloat,
                    _ resultsAreAtTop: Bool
                ) -> TranslationPanelScrollCoordinator.Consumption
        ) {
            self.onScroll = onScroll
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func attachIfNeeded() {
            guard eventMonitor == nil,
                  bridgeView?.window != nil else {
                return
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let bridgeView,
                  let window = bridgeView.window,
                  event.window === window else {
                return event
            }

            // SwiftUI installs a background representable beside the hosted
            // NSScrollView rather than inside it, so `enclosingScrollView`
            // is intentionally nil here. Gate the event using the bridge's
            // viewport, then resolve the actual scroll view from AppKit's hit
            // view. This also keeps wheel events over the source editor out of
            // the outer collapse state machine.
            let bridgePoint = bridgeView.convert(
                event.locationInWindow,
                from: nil
            )
            guard bridgeView.bounds.contains(bridgePoint),
                  let hitView = window.contentView?.hitTest(
                      event.locationInWindow
                  ),
                  let scrollView = hitView.firstEnclosingScrollView else {
                return event
            }

            let deviceScale: CGFloat =
                event.hasPreciseScrollingDeltas ? 1 : 12
            let contentDelta = -event.scrollingDeltaY * deviceScale
            guard abs(contentDelta) > 0.01 else { return event }

            let visibleOrigin = scrollView.contentView.bounds.origin.y
            let resultsAreAtTop = visibleOrigin <= 0.5
            let consumption = onScroll(
                contentDelta,
                resultsAreAtTop
            )
            guard consumption.consumedSource else {
                return event
            }
            if consumption.remainingResultsDelta > 0.01 {
                scrollResults(
                    by: consumption.remainingResultsDelta,
                    in: scrollView
                )
            }
            return nil
        }

        private func scrollResults(
            by delta: CGFloat,
            in scrollView: NSScrollView
        ) {
            guard let documentView = scrollView.documentView else {
                return
            }
            let clipView = scrollView.contentView
            let maximumY = max(
                0,
                documentView.bounds.height - clipView.bounds.height
            )
            let origin = NSPoint(
                x: clipView.bounds.origin.x,
                y: min(
                    maximumY,
                    max(0, clipView.bounds.origin.y + delta)
                )
            )
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

private extension NSView {
    var firstEnclosingScrollView: NSScrollView? {
        var candidate: NSView? = self
        while let view = candidate {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }
}

/// Keeps the source editor and language controls in a real fixed region above
/// the results viewport. The result list never renders underneath those
/// controls, so no mask or transparent hit shield is required.
struct TranslationPanelContentLayout<
    SourceContent: View,
    LanguageContent: View,
    ResultsContent: View
>: View {
    let inputSource: TranslationInputSource
    private let sourceContent: (CGFloat) -> SourceContent
    private let languageContent: () -> LanguageContent
    private let resultsContent: () -> ResultsContent

    @State private var scrollCoordinator =
        TranslationPanelScrollCoordinator()

    init(
        inputSource: TranslationInputSource,
        @ViewBuilder sourceContent:
            @escaping (CGFloat) -> SourceContent,
        @ViewBuilder languageContent:
            @escaping () -> LanguageContent,
        @ViewBuilder resultsContent:
            @escaping () -> ResultsContent
    ) {
        self.inputSource = inputSource
        self.sourceContent = sourceContent
        self.languageContent = languageContent
        self.resultsContent = resultsContent
    }

    var body: some View {
        VStack(spacing: 0) {
            fixedControls
            resultsViewport
        }
        .accessibilityElement(children: .contain)
        .onChange(of: inputSource) { _, _ in
            scrollCoordinator.reset()
        }
        .onDisappear {
            scrollCoordinator.reset()
        }
    }

    private var fixedControls: some View {
        VStack(
            alignment: .leading,
            spacing: TranslationPanelMetrics.sectionSpacing
        ) {
            sourceContent(sourceEditorHeight)
                .frame(
                    height: TranslationPanelSourceLayout
                        .sourceSectionHeight(
                            for: inputSource,
                            scrollOffset:
                                scrollCoordinator.resultsOffset
                        ),
                    alignment: .top
                )
            languageContent()
                .frame(
                    height:
                        TranslationPanelSourceLayout
                            .languageBarHeight
                )
                .layoutPriority(2)
        }
        .padding(.horizontal, TranslationPanelMetrics.contentInset)
        .padding(.top, TranslationPanelMetrics.contentInset)
        .padding(.bottom, TranslationPanelMetrics.sectionSpacing)
        .frame(
            maxWidth: .infinity,
            minHeight: TranslationPanelSourceLayout.fixedRegionHeight(
                for: inputSource,
                scrollOffset: scrollCoordinator.resultsOffset
            ),
            maxHeight: TranslationPanelSourceLayout.fixedRegionHeight(
                for: inputSource,
                scrollOffset: scrollCoordinator.resultsOffset
            ),
            alignment: .top
        )
        .layoutPriority(1)
        // The result ScrollView has a large intrinsic content height once
        // several services complete. The explicit fixed-region height keeps
        // SwiftUI from satisfying that demand by compressing the language
        // controls; only the results viewport remains flexible.
        .accessibilitySortPriority(2)
    }

    private var resultsViewport: some View {
        ScrollView {
            resultsContent()
            .padding(.horizontal, TranslationPanelMetrics.contentInset)
            .padding(.bottom, TranslationPanelMetrics.contentInset)
        }
        .background {
            TranslationResultsScrollPhaseBridge {
                contentDelta,
                resultsAreAtTop in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                return withTransaction(transaction) {
                    scrollCoordinator.consume(
                        contentDelta: contentDelta,
                        collapseRange:
                            TranslationPanelSourceLayout.collapseRange(
                                for: inputSource
                            ),
                        resultsAreAtTop: resultsAreAtTop
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
    }

    private var sourceEditorHeight: CGFloat {
        TranslationPanelSourceLayout.editorHeight(
            for: inputSource,
            scrollOffset: scrollCoordinator.resultsOffset
        )
    }
}
