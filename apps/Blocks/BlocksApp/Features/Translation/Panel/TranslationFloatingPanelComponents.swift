import AppKit
import AVFoundation
import BlocksCore
import OSLog
import SwiftUI

private let translationOrderDragLogger = Logger(
    subsystem: "app.blocks.app",
    category: "translation-order-drag"
)

struct TranslationResultRecoveryOptions: Equatable {
    let shouldDownloadLanguage: Bool
    let shouldOpenSettings: Bool
    let canRetry: Bool
}

enum TranslationResultRecoveryPolicy {
    private static let settingsErrorCodes: Set<String> = [
        "apple_translation_requires_macos_15",
        "translation_service_unavailable",
        "plugin_not_approved",
        "plugin_disabled",
        "plugin_package_changed",
        "package_hash_mismatch",
        "plugin_capability_unavailable",
        "capability_unavailable",
        "network_policy_denied",
        "missing_configuration",
        "confirmation_required",
        "missing_secret",
        "invalid_base_url",
        "unauthorized",
        "forbidden",
        "unsupported_capability",
    ]

    private static let retryableAppleSettingsErrorCodes: Set<String> = [
        "apple_language_not_ready",
        "apple_translation_runtime_unavailable",
        "apple_translation_preparation_failed",
    ]

    private static let nonRetryableErrorCodes: Set<String> =
        settingsErrorCodes.union([
            "apple_language_download_required",
            "translation_source_language_unsupported",
            "translation_target_language_unsupported",
            "translation_language_pair_unsupported",
            "translation_response_language_mismatch",
            "apple_language_pair_unsupported",
            "source_language_undetermined",
            "empty_source_text",
            "translation_input_too_large",
            "request_too_large",
            "network_request_invalid",
            "network_http_client_error",
        ])

    static func resolve(
        errorCode: String?
    ) -> TranslationResultRecoveryOptions {
        guard let errorCode else {
            return TranslationResultRecoveryOptions(
                shouldDownloadLanguage: false,
                shouldOpenSettings: false,
                canRetry: true
            )
        }
        if errorCode == "apple_language_download_required" {
            return TranslationResultRecoveryOptions(
                shouldDownloadLanguage: true,
                shouldOpenSettings: false,
                canRetry: false
            )
        }
        return TranslationResultRecoveryOptions(
            shouldDownloadLanguage: false,
            shouldOpenSettings:
                settingsErrorCodes.contains(errorCode)
                || retryableAppleSettingsErrorCodes.contains(errorCode),
            canRetry:
                retryableAppleSettingsErrorCodes.contains(errorCode)
                || !nonRetryableErrorCodes.contains(errorCode)
        )
    }

    static func shouldOpenSettings(errorCode: String?) -> Bool {
        resolve(errorCode: errorCode).shouldOpenSettings
    }

    static func isRetryable(errorCode: String?) -> Bool {
        resolve(errorCode: errorCode).canRetry
    }
}

@MainActor
enum TranslationAccessibilityAnnouncer {
    static func announce(_ message: String) {
        guard !message.isEmpty, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct TranslationServiceName: View {
    let name: String
    let font: Font

    var body: some View {
        Text(name)
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
            .help(name)
            .accessibilityLabel(name)
    }
}

struct TranslationServiceOrderDragPayload:
    Codable,
    Equatable,
    Sendable
{
    static let pasteboardType = NSPasteboard.PasteboardType(
        "app.blocks.translation.service-order"
    )

    let serviceID: String

    func encodedData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(
        from pasteboard: NSPasteboard
    ) -> TranslationServiceOrderDragPayload? {
        guard let data = pasteboard.data(
            forType: pasteboardType
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(
            TranslationServiceOrderDragPayload.self,
            from: data
        )
    }
}

/// Keeps the SwiftUI insertion state synchronized with one native AppKit
/// dragging session. AppKit destinations own hit testing and commit the drop;
/// the coordinator only publishes visual state and enforces one commit.
@MainActor
final class TranslationServiceOrderDragCoordinator:
    ObservableObject
{
    @Published private(set) var activeServiceID: String?
    @Published private(set) var target:
        TranslationResultOrderDragTarget?

    private var generation: UInt64 = 0
    private var sessionServiceID: String?
    private var committedGeneration: UInt64?

    @discardableResult
    func begin(serviceID: String) -> UInt64 {
        generation &+= 1
        sessionServiceID = serviceID
        activeServiceID = serviceID
        target = nil
        committedGeneration = nil
        return generation
    }

    func endSession() {
        sessionServiceID = nil
        activeServiceID = nil
        target = nil
    }

    func updateTarget(_ proposedTarget: TranslationResultOrderDragTarget?) {
        guard let proposedTarget else {
            target = nil
            return
        }
        guard proposedTarget.sourceServiceID == sessionServiceID,
              proposedTarget.sourceServiceID != proposedTarget.destinationServiceID else {
            target = nil
            return
        }
        target = proposedTarget
    }

    @discardableResult
    func commit(
        payloadServiceID: String,
        target proposedTarget: TranslationResultOrderDragTarget,
        action: (TranslationResultOrderDragTarget) -> Void
    ) -> Bool {
        let didCommit = commitValidated(
            payloadServiceID: payloadServiceID,
            target: proposedTarget,
            generation: generation,
            action: action
        )
        translationOrderDragLogger.debug(
            "drop result source=\(payloadServiceID, privacy: .public) destination=\(proposedTarget.destinationServiceID, privacy: .public) placement=\(String(describing: proposedTarget.placement), privacy: .public) committed=\(didCommit, privacy: .public)"
        )
        return didCommit
    }

    @discardableResult
    private func commitValidated(
        payloadServiceID: String,
        target proposedTarget: TranslationResultOrderDragTarget,
        generation proposedGeneration: UInt64,
        action: (TranslationResultOrderDragTarget) -> Void
    ) -> Bool {
        guard proposedGeneration == generation,
              committedGeneration != proposedGeneration,
              payloadServiceID == sessionServiceID,
              payloadServiceID == proposedTarget.sourceServiceID,
              payloadServiceID != proposedTarget.destinationServiceID else {
            return false
        }
        committedGeneration = proposedGeneration
        action(proposedTarget)
        endSession()
        return true
    }
}

struct TranslationServiceOrderDragSource: View {
    let serviceID: String
    let displayName: String
    let accessibilityName: String
    @ObservedObject var coordinator:
        TranslationServiceOrderDragCoordinator
    let onPerformDrop: (TranslationResultOrderDragTarget) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 16)

                if !displayName.isEmpty {
                    TranslationServiceName(
                        name: displayName,
                        font: .subheadline.weight(.semibold)
                    )
                }
            }
            .accessibilityHidden(true)

            TranslationServiceOrderNativeDragSource(
                serviceID: serviceID,
                displayName: displayName,
                accessibilityName: accessibilityName,
                coordinator: coordinator,
                onPerformDrop: onPerformDrop,
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(
                TranslationServiceOrderAccessibilityActions(
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    onMoveUp: onMoveUp,
                    onMoveDown: onMoveDown
                )
            )
        }
        .frame(
            minHeight: TranslationPanelMetrics.compactIconHitTarget,
            alignment: .leading
        )
        .contentShape(Rectangle())
    }
}

struct TranslationServiceOrderNativeDragSource: NSViewRepresentable {
    let serviceID: String
    let displayName: String
    let accessibilityName: String
    let coordinator: TranslationServiceOrderDragCoordinator
    let onPerformDrop: (TranslationResultOrderDragTarget) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragSourceView) {
        view.serviceID = serviceID
        view.displayName = displayName
        view.accessibilityName = accessibilityName
        view.dragCoordinator = coordinator
        view.onPerformDrop = onPerformDrop
        view.canMoveUp = canMoveUp
        view.canMoveDown = canMoveDown
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.refreshAccessibilityConfiguration()
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var serviceID = ""
        var displayName = ""
        var accessibilityName = ""
        weak var dragCoordinator: TranslationServiceOrderDragCoordinator?
        var onPerformDrop: ((TranslationResultOrderDragTarget) -> Void)?
        var canMoveUp = false
        var canMoveDown = false
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?
        private var mouseDownLocation: NSPoint?
        private var draggingSessionStarted = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([
                TranslationServiceOrderDragPayload.pasteboardType,
            ])
            focusRingType = .exterior
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override var focusRingMaskBounds: NSRect {
            bounds.insetBy(dx: 2, dy: 2)
        }

        override func drawFocusRingMask() {
            NSBezierPath(
                roundedRect: focusRingMaskBounds,
                xRadius: BlocksVisualTokens.CornerRadius.control,
                yRadius: BlocksVisualTokens.CornerRadius.control
            ).fill()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            mouseDownLocation = convert(event.locationInWindow, from: nil)
            draggingSessionStarted = false
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126:
                guard canMoveUp else { return }
                onMoveUp?()
            case 125:
                guard canMoveDown else { return }
                onMoveDown?()
            default:
                super.keyDown(with: event)
            }
        }

        func refreshAccessibilityConfiguration() {
            setAccessibilityLabel(accessibilityName)
            setAccessibilityHelp(
                L10n.string("translation.services.resultOrder.dragHint")
            )
            var actions: [NSAccessibilityCustomAction] = []
            if canMoveUp {
                actions.append(
                    NSAccessibilityCustomAction(
                        name: L10n.string("translation.services.moveUp")
                    ) { [weak self] in
                        guard let self, self.canMoveUp else { return false }
                        self.onMoveUp?()
                        return true
                    }
                )
            }
            if canMoveDown {
                actions.append(
                    NSAccessibilityCustomAction(
                        name: L10n.string("translation.services.moveDown")
                    ) { [weak self] in
                        guard let self, self.canMoveDown else { return false }
                        self.onMoveDown?()
                        return true
                    }
                )
            }
            setAccessibilityCustomActions(actions)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !draggingSessionStarted,
                  let mouseDownLocation,
                  let dragCoordinator,
                  let data = TranslationServiceOrderDragPayload(
                    serviceID: serviceID
                  ).encodedData() else {
                return
            }
            let currentLocation = convert(event.locationInWindow, from: nil)
            guard hypot(
                currentLocation.x - mouseDownLocation.x,
                currentLocation.y - mouseDownLocation.y
            ) >= 3 else {
                return
            }

            let pasteboardItem = NSPasteboardItem()
            let wrotePrivatePayload = pasteboardItem.setData(
                data,
                forType: TranslationServiceOrderDragPayload.pasteboardType
            )
            pasteboardItem.setString(
                serviceID,
                forType: .string
            )
            guard wrotePrivatePayload else {
                return
            }
            let draggingItem = NSDraggingItem(
                pasteboardWriter: pasteboardItem
            )
            let preview = dragPreviewImage()
            draggingItem.setDraggingFrame(
                NSRect(
                    x: max(0, currentLocation.x - preview.size.width / 2),
                    y: max(0, currentLocation.y - preview.size.height / 2),
                    width: preview.size.width,
                    height: preview.size.height
                ),
                contents: preview
            )
            draggingSessionStarted = true
            dragCoordinator.begin(serviceID: serviceID)
            translationOrderDragLogger.debug(
                "source began service=\(self.serviceID, privacy: .public)"
            )
            beginDraggingSession(
                with: [draggingItem],
                event: event,
                source: self
            )
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .move
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            draggingSessionStarted = false
            mouseDownLocation = nil
            translationOrderDragLogger.debug(
                "source ended service=\(self.serviceID, privacy: .public) point=\(NSStringFromPoint(screenPoint), privacy: .public) operation=\(operation.rawValue)"
            )
            dragCoordinator?.endSession()
        }

        override func draggingEntered(
            _ sender: any NSDraggingInfo
        ) -> NSDragOperation {
            updateDestination(sender)
        }

        override func draggingUpdated(
            _ sender: any NSDraggingInfo
        ) -> NSDragOperation {
            updateDestination(sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            guard dragCoordinator?.target?.destinationServiceID == serviceID else {
                return
            }
            dragCoordinator?.updateTarget(nil)
        }

        override func prepareForDragOperation(
            _ sender: any NSDraggingInfo
        ) -> Bool {
            proposedTarget(sender) != nil
        }

        override func performDragOperation(
            _ sender: any NSDraggingInfo
        ) -> Bool {
            guard let payload = TranslationServiceOrderDragPayload.decode(
                from: sender.draggingPasteboard
            ), let target = proposedTarget(sender),
                  let onPerformDrop else {
                return false
            }
            return dragCoordinator?.commit(
                payloadServiceID: payload.serviceID,
                target: target,
                action: onPerformDrop
            ) ?? false
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            dragCoordinator?.updateTarget(nil)
        }

        @discardableResult
        func updateDestination(
            pasteboard: NSPasteboard,
            locationInView: NSPoint
        ) -> NSDragOperation {
            guard let target = proposedTarget(
                pasteboard: pasteboard,
                locationInView: locationInView
            ) else {
                dragCoordinator?.updateTarget(nil)
                return []
            }
            dragCoordinator?.updateTarget(target)
            return .move
        }

        @discardableResult
        func performDrop(
            pasteboard: NSPasteboard,
            locationInView: NSPoint
        ) -> Bool {
            guard let payload = TranslationServiceOrderDragPayload.decode(
                from: pasteboard
            ), let target = proposedTarget(
                pasteboard: pasteboard,
                locationInView: locationInView
            ), let onPerformDrop else {
                return false
            }
            return dragCoordinator?.commit(
                payloadServiceID: payload.serviceID,
                target: target,
                action: onPerformDrop
            ) ?? false
        }

        private func updateDestination(
            _ sender: any NSDraggingInfo
        ) -> NSDragOperation {
            updateDestination(
                pasteboard: sender.draggingPasteboard,
                locationInView: convert(sender.draggingLocation, from: nil)
            )
        }

        private func proposedTarget(
            _ sender: any NSDraggingInfo
        ) -> TranslationResultOrderDragTarget? {
            proposedTarget(
                pasteboard: sender.draggingPasteboard,
                locationInView: convert(sender.draggingLocation, from: nil)
            )
        }

        private func proposedTarget(
            pasteboard: NSPasteboard,
            locationInView: NSPoint
        ) -> TranslationResultOrderDragTarget? {
            guard bounds.contains(locationInView),
                  let payload = TranslationServiceOrderDragPayload.decode(
                    from: pasteboard
                  ), payload.serviceID == dragCoordinator?.activeServiceID,
                  payload.serviceID != serviceID else {
                return nil
            }
            return TranslationResultOrderDragTarget(
                sourceServiceID: payload.serviceID,
                destinationServiceID: serviceID,
                placement: locationInView.y <= bounds.midY
                    ? .before
                    : .after
            )
        }

        private func dragPreviewImage() -> NSImage {
            let size = NSSize(
                width: min(max(bounds.width, 120), 260),
                height: 32
            )
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.windowBackgroundColor
                .withAlphaComponent(0.96)
                .setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: size),
                xRadius: BlocksVisualTokens.CornerRadius.control,
                yRadius: BlocksVisualTokens.CornerRadius.control
            ).fill()
            NSString(string: displayName).draw(
                in: NSRect(x: 10, y: 7, width: size.width - 20, height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            image.unlockFocus()
            return image
        }
    }
}

struct TranslationResultOrderDragTarget: Equatable {
    let sourceServiceID: String
    let destinationServiceID: String
    let placement: TranslationServiceOrderPlacement
}

struct TranslationServiceOrderAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp, canMoveDown {
            content
                .accessibilityAction(
                    named: L10n.string(
                        "translation.services.moveUp"
                    ),
                    onMoveUp
                )
                .accessibilityAction(
                    named: L10n.string(
                        "translation.services.moveDown"
                    ),
                    onMoveDown
                )
        } else if canMoveUp {
            content.accessibilityAction(
                named: L10n.string(
                    "translation.services.moveUp"
                ),
                onMoveUp
            )
        } else if canMoveDown {
            content.accessibilityAction(
                named: L10n.string(
                    "translation.services.moveDown"
                ),
                onMoveDown
            )
        } else {
            content
        }
    }
}

enum TranslationResultHeaderAction: Hashable {
    case copy
    case speak
    case cancel
    case diagnostics
    case expand
}

enum TranslationResultHeaderActionLayout {
    static let maximumSlotCount = 4

    static var spacing: CGFloat {
        BlocksCompactActionGroupLayout.spacing(for: .micro)
    }

    static var reservedWidth: CGFloat {
        BlocksCompactActionGroupLayout.reservedWidth(
            density: .micro,
            slotCount: maximumSlotCount
        )
    }

    static func actions(
        state: TranslationResultState,
        isSuccessful: Bool,
        hasDiagnostics: Bool
    ) -> [TranslationResultHeaderAction] {
        var actions: [TranslationResultHeaderAction] = []
        if isSuccessful {
            actions.append(contentsOf: [.copy, .speak])
        } else if state == .waiting
            || state == .running
            || state == .streaming {
            actions.append(.cancel)
        }
        if hasDiagnostics {
            actions.append(.diagnostics)
        }
        actions.append(.expand)
        return actions
    }
}

enum TranslationResultHeaderStatusLayout {
    static let hitTarget: CGFloat =
        TranslationPanelMetrics.compactIconHitTarget
    static let visualSize: CGFloat = 20

    static func showsStateTitle(
        for state: TranslationResultState
    ) -> Bool {
        switch state {
        case .waiting, .running, .streaming:
            true
        case .succeeded, .failed, .cancelled:
            false
        }
    }

    static func showsRetryControl(
        for state: TranslationResultState
    ) -> Bool {
        state == .failed
    }

    static func usesPrimaryText(
        increasesContrast: Bool
    ) -> Bool {
        increasesContrast
    }
}

struct TranslationResultCard: View {
    let result: TranslationResultSnapshot
    let isCollapsed: Bool
    let isSpeaking: Bool
    let isPreparingLanguage: Bool
    let canRetry: Bool
    let onToggleCollapsed: () -> Void
    let onCopy: @MainActor () async -> Bool
    let onSpeak: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onPrepareAppleLanguage: (() -> Void)?
    let onOpenSettings: (() -> Void)?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onPerformDrop:
        (TranslationResultOrderDragTarget) -> Void
    @ObservedObject var dragCoordinator:
        TranslationServiceOrderDragCoordinator
    let activeDropPlacement:
        TranslationServiceOrderPlacement?
    let isBeingDragged: Bool
    var pluginDetail: AnyView? = nil

    @State private var diagnosticsExpanded = false
    @State private var didAnnounceInitialTerminalState = false
    @State private var copySucceeded = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: BlocksVisualTokens.Spacing.sm
        ) {
            header

            if !isCollapsed {
                resultBody
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 20,
                        alignment: .topLeading
                    )
                if let pluginDetail {
                    pluginDetail
                }
                diagnostics
            }
        }
        .padding(BlocksVisualTokens.Spacing.md)
        .blocksSurface(
            .section,
            cornerRadius: BlocksVisualTokens.CornerRadius.section,
            isActive: isBeingDragged
        )
        .opacity(isBeingDragged ? 0.82 : 1)
        .overlay(alignment: .top) {
            dropIndicator(for: .before)
        }
        .overlay(alignment: .bottom) {
            dropIndicator(for: .after)
        }
        .contextMenu {
            Button(
                L10n.string("translation.services.moveUp"),
                action: onMoveUp
            )
            .disabled(!canMoveUp)
            Button(
                L10n.string("translation.services.moveDown"),
                action: onMoveDown
            )
            .disabled(!canMoveDown)
        }
        // Collapsing a card and revealing its diagnostics are discrete
        // hierarchy changes, so they use the shared reveal timing. Dragging
        // and service reordering remain animation-free direct manipulation.
        .blocksAnimation(.reveal, value: isCollapsed)
        .blocksAnimation(.reveal, value: diagnosticsExpanded)
        .onChange(of: result.state) { _, state in
            announceTerminalState(state)
            if state != .succeeded {
                resetCopyFeedback()
            }
        }
        .onAppear {
            guard !didAnnounceInitialTerminalState else { return }
            didAnnounceInitialTerminalState = true
            announceTerminalState(result.state)
        }
        .onChange(of: result.id) { _, _ in
            resetCopyFeedback()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.xs) {
            resultStatusControl
                .blocksAnimation(
                    .selection,
                    value: result.state
                )

            TranslationServiceOrderDragSource(
                serviceID: result.service.id,
                displayName: result.service.displayName,
                accessibilityName: L10n.format(
                    "translation.result.serviceState",
                    result.service.displayName,
                    stateTitle
                ),
                coordinator: dragCoordinator,
                onPerformDrop: onPerformDrop,
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown
            )
            .frame(
                minWidth: 72,
                maxWidth: .infinity,
                minHeight:
                    TranslationPanelMetrics.compactIconHitTarget,
                maxHeight:
                    TranslationPanelMetrics.compactIconHitTarget,
                alignment: .leading
            )
            .accessibilityIdentifier(
                "translation.panel.result.\(result.service.id)"
            )

            if TranslationResultHeaderStatusLayout
                .showsStateTitle(for: result.state) {
                Text(stateTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stateTextColor)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Spacer(minLength: BlocksVisualTokens.Spacing.xs)
            headerActions
        }
    }

    @ViewBuilder
    private var resultStatusControl: some View {
        if isActive {
            ProgressView()
                .controlSize(.small)
                .frame(
                    width:
                        TranslationResultHeaderStatusLayout
                            .visualSize,
                    height:
                        TranslationResultHeaderStatusLayout
                            .visualSize
                )
                .frame(
                    width:
                        TranslationResultHeaderStatusLayout
                            .hitTarget,
                    height:
                        TranslationResultHeaderStatusLayout
                            .hitTarget
                )
                .accessibilityLabel(stateTitle)
        } else if TranslationResultHeaderStatusLayout
            .showsRetryControl(for: result.state),
                  canRetry {
            BlocksCompactIconButton(
                systemImage: "arrow.clockwise",
                label: L10n.format(
                    "translation.result.retryService",
                    result.service.displayName
                ),
                emphasis: .accent,
                density: .micro,
                action: onRetry
            )
            .accessibilityHint(result.errorMessage ?? stateTitle)
        } else {
            Image(systemName: stateSystemImage)
                .foregroundStyle(stateColor)
                .frame(
                    width:
                        TranslationResultHeaderStatusLayout
                            .visualSize,
                    height:
                        TranslationResultHeaderStatusLayout
                            .visualSize
                )
                .frame(
                    width:
                        TranslationResultHeaderStatusLayout
                            .hitTarget,
                    height:
                        TranslationResultHeaderStatusLayout
                            .hitTarget
                )
                .accessibilityHidden(true)
        }
    }

    private var headerActions: some View {
        BlocksCompactActionGroup(
            density: .micro,
            reservedSlotCount:
                TranslationResultHeaderActionLayout
                    .maximumSlotCount
        ) {
            ForEach(headerActionIDs, id: \.self) { action in
                headerAction(action)
            }
        }
    }

    private var headerActionIDs: [TranslationResultHeaderAction] {
        TranslationResultHeaderActionLayout.actions(
            state: result.state,
            isSuccessful: result.isSuccessful,
            hasDiagnostics: hasDiagnostics
        )
    }

    @ViewBuilder
    private func headerAction(
        _ action: TranslationResultHeaderAction
    ) -> some View {
        switch action {
        case .copy:
            BlocksCompactIconButton(
                systemImage:
                    copySucceeded
                        ? "checkmark"
                        : "doc.on.doc",
                label: L10n.string("common.copy"),
                emphasis: copySucceeded ? .success : .standard,
                density: .micro,
                action: copyResult
            )
            .accessibilityValue(
                copySucceeded
                    ? L10n.string("translation.notification.copied")
                    : ""
            )
        case .speak:
            BlocksCompactIconButton(
                systemImage: isSpeaking
                    ? "speaker.slash.fill"
                    : "speaker.wave.2",
                label: L10n.string(
                    isSpeaking
                        ? "translation.result.stopSpeaking"
                        : "translation.result.speak"
                ),
                isSelected: isSpeaking,
                density: .micro,
                action: onSpeak
            )
        case .cancel:
            BlocksCompactIconButton(
                systemImage: "xmark",
                label: L10n.string("common.cancel"),
                density: .micro,
                action: onCancel
            )
        case .diagnostics:
            BlocksCompactIconButton(
                systemImage:
                    diagnosticsExpanded
                        ? "info.circle.fill"
                        : "info.circle",
                label: L10n.string(
                    "translation.panel.diagnostics"
                ),
                isSelected: diagnosticsExpanded,
                density: .micro
            ) {
                diagnosticsExpanded.toggle()
            }
        case .expand:
            BlocksCompactIconButton(
                systemImage:
                    isCollapsed
                        ? "chevron.down"
                        : "chevron.up",
                label:
                    isCollapsed
                        ? L10n.string("common.expand")
                        : L10n.string("common.collapse"),
                density: .micro,
                action: onToggleCollapsed
            )
        }
    }

    private func copyResult() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            guard await onCopy(), !Task.isCancelled else {
                return
            }
            copySucceeded = true
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copySucceeded = false
            copyFeedbackTask = nil
        }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copySucceeded = false
    }

    @ViewBuilder
    private var resultBody: some View {
        if result.isSuccessful || result.state == .streaming {
            Text(result.translatedText)
                .font(.system(size: 16))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if result.state == .failed {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    TranslationErrorPresentation.message(
                        code: result.errorCode,
                        fallback: result.errorMessage
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let onPrepareAppleLanguage {
                        Button(
                            L10n.string(
                                isPreparingLanguage
                                    ? "translation.result.preparingLanguage"
                                    : "translation.result.downloadLanguage"
                            ),
                            action: onPrepareAppleLanguage
                        )
                        .disabled(isPreparingLanguage)
                        if isPreparingLanguage {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    if let onOpenSettings {
                        Button(
                            L10n.string("translation.result.openSettings"),
                            action: onOpenSettings
                        )
                    }
                }
            }
        } else if result.state == .cancelled {
            Text(L10n.string("translation.result.cancelled"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if hasDiagnostics && diagnosticsExpanded {
            VStack(alignment: .leading, spacing: 5) {
                if let value = result.diagnostics {
                    diagnosticRow(
                        "translation.panel.diagnostics.route",
                        value.route
                    )
                    diagnosticRow(
                        "translation.panel.diagnostics.status",
                        value.status
                    )
                    diagnosticRow(
                        "translation.panel.diagnostics.duration",
                        TranslationLocalizedFormat.duration(
                            milliseconds: value.durationMS
                        )
                    )
                    diagnosticRow(
                        "translation.panel.diagnostics.auditID",
                        ProviderAuditID.display(value.auditID)
                    )
                }
                if let errorCode = result.errorCode {
                    diagnosticRow(
                        "translation.panel.diagnostics.errorCode",
                        errorCode
                    )
                }
                ForEach(
                    Array(result.warnings.enumerated()),
                    id: \.offset
                ) { _, warning in
                    diagnosticRow(
                        "translation.panel.diagnostics.warning",
                        warning
                    )
                }
            }
            .font(.caption)
            .padding(.top, 2)
        }
    }

    private var hasDiagnostics: Bool {
        result.diagnostics != nil
            || result.errorCode != nil
            || !result.warnings.isEmpty
    }

    private var isActive: Bool {
        result.state == .waiting
            || result.state == .running
            || result.state == .streaming
    }

    @ViewBuilder
    private func dropIndicator(
        for placement: TranslationServiceOrderPlacement
    ) -> some View {
        if activeDropPlacement == placement {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
        }
    }

    private func diagnosticRow(
        _ titleKey: String,
        _ value: String
    ) -> some View {
        LabeledContent(L10n.string(titleKey)) {
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateTitle: String {
        if isActive,
           let sourceMessage = result.sourceStatus?.message?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
           !sourceMessage.isEmpty {
            return sourceMessage
        }
        return L10n.string(
            "translation.result.state.\(result.state.rawValue)"
        )
    }

    private var stateSystemImage: String {
        switch result.state {
        case .waiting, .running, .streaming: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        }
    }

    private var stateColor: Color {
        switch result.state {
        case .succeeded:
            Color(nsColor: .systemGreen)
        case .failed:
            Color(nsColor: .systemOrange)
        case .cancelled: .secondary
        case .waiting, .running, .streaming: .accentColor
        }
    }

    private var stateTextColor: Color {
        TranslationResultHeaderStatusLayout.usesPrimaryText(
            increasesContrast:
                colorSchemeContrast == .increased
        )
            ? .primary
            : .secondary
    }

    private func announceTerminalState(_ state: TranslationResultState) {
        guard state == .succeeded
                || state == .failed
                || state == .cancelled else {
            return
        }
        TranslationAccessibilityAnnouncer.announce(
            L10n.format(
                "translation.result.stateAnnouncement",
                result.service.displayName,
                stateTitle
            )
        )
    }
}

@MainActor
final class TranslationSpeechController:
    NSObject,
    ObservableObject,
    @preconcurrency AVSpeechSynthesizerDelegate
{
    @Published private(set) var activeResultID: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(resultID: String) -> Bool {
        activeResultID == resultID && synthesizer.isSpeaking
    }

    func toggleSpeaking(
        resultID: String,
        text: String,
        language: TranslationLanguageTag
    ) {
        if isSpeaking(resultID: resultID) {
            stop()
            return
        }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = TranslationSpeechLanguageResolver.voice(
            for: language
        )
        activeResultID = resultID
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        activeResultID = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishIfCurrent(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finishIfCurrent(utterance)
    }

    private func finishIfCurrent(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeResultID = nil
        activeUtterance = nil
    }
}
