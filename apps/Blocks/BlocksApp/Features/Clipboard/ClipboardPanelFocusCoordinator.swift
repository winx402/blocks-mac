import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI

enum ClipboardPanelFocusSurface: String, Equatable {
    case parent
    case detail
    case external
}

enum ClipboardPanelFocusTarget: Equatable {
    case search
    case records(recordID: String)
    case detailRead(recordID: String)
    case detailEdit(recordID: String)
    case inactive

    var recordID: String? {
        switch self {
        case let .records(recordID), let .detailRead(recordID), let .detailEdit(recordID):
            return recordID
        case .search, .inactive:
            return nil
        }
    }

    var diagnosticName: String {
        switch self {
        case .search:
            return "search"
        case let .records(recordID):
            return "records:\(recordID.suffix(8))"
        case let .detailRead(recordID):
            return "detail-read:\(recordID.suffix(8))"
        case let .detailEdit(recordID):
            return "detail-edit:\(recordID.suffix(8))"
        case .inactive:
            return "inactive"
        }
    }
}

enum ClipboardPanelFocusReason: String {
    case panelOpened = "panel-opened"
    case panelRefocused = "panel-refocused"
    case searchClicked = "search-clicked"
    case recordSelected = "record-selected"
    case keyboardNavigation = "keyboard-navigation"
    case detailPresented = "detail-presented"
    case detailEditingBegan = "detail-editing-began"
    case detailEditingEnded = "detail-editing-ended"
    case detailDismissed = "detail-dismissed"
    case pinnedPanelReleased = "pinned-panel-released"
    case panelClosed = "panel-closed"
    case keyWindowChanged = "key-window-changed"
}

@MainActor
final class ClipboardPanelFocusCoordinator: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-focus"
    )

    @Published private(set) var target: ClipboardPanelFocusTarget = .inactive
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var keySurface: ClipboardPanelFocusSurface = .external

    private weak var parentWindow: NSWindow?
    private weak var detailWindow: NSWindow?
    private var returnTarget: ClipboardPanelFocusTarget?
    private var sessionID: UUID?

    var activeSessionID: UUID? {
        sessionID
    }

    func beginSession(sessionID: UUID) {
        self.sessionID = sessionID
        returnTarget = nil
        keySurface = .external
        request(.search, reason: .panelOpened)
    }

    func registerParentWindow(_ window: NSWindow) {
        parentWindow = window
        logWindow(stage: "parent-registered", window: window)
    }

    func registerDetailWindow(_ window: NSWindow) {
        detailWindow = window
        logWindow(stage: "detail-registered", window: window)
    }

    func unregisterDetailWindow(_ window: NSWindow) {
        guard detailWindow === window else { return }
        detailWindow = nil
        if keySurface == .detail {
            keySurface = parentWindow?.isKeyWindow == true ? .parent : .external
        }
        Self.logger.info(
            "stage=detail-unregistered session=\(self.sessionID?.uuidString ?? "none", privacy: .public) target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
        )
    }

    func focusSearch(reason: ClipboardPanelFocusReason = .searchClicked) {
        guard hasActiveSession(stage: "focus-search") else { return }
        returnTarget = nil
        request(.search, reason: reason)
    }

    func focusRecord(
        _ recordID: String,
        reason: ClipboardPanelFocusReason = .recordSelected
    ) {
        guard hasActiveSession(stage: "focus-record") else { return }
        returnTarget = .records(recordID: recordID)
        request(.records(recordID: recordID), reason: reason)
    }

    func presentDetail(recordID: String) {
        guard hasActiveSession(stage: "present-detail") else { return }
        if target == .detailRead(recordID: recordID) {
            return
        }
        if case .detailEdit(recordID) = target {
            return
        }
        if case .records = target {
            returnTarget = target
        } else if returnTarget == nil {
            returnTarget = .records(recordID: recordID)
        }
        request(.detailRead(recordID: recordID), reason: .detailPresented)
    }

    func beginDetailEditing(recordID: String) {
        guard hasActiveSession(stage: "begin-detail-editing") else { return }
        if returnTarget == nil {
            returnTarget = .records(recordID: recordID)
        }
        request(.detailEdit(recordID: recordID), reason: .detailEditingBegan)
    }

    func finishDetailEditing(recordID: String) {
        guard hasActiveSession(stage: "finish-detail-editing") else { return }
        let destination = validatedReturnTarget(fallbackRecordID: recordID)
        request(destination, reason: .detailEditingEnded)
        restoreParentWindow(reason: .detailEditingEnded)
    }

    func dismissDetail(recordID: String?) {
        guard hasActiveSession(stage: "dismiss-detail") else { return }
        let detailOwnedFocus: Bool = switch target {
        case .detailRead, .detailEdit:
            true
        case .search, .records, .inactive:
            false
        }
        // Detail loading and dirty-navigation resolution are asynchronous. A
        // late "detail closed" callback must not overwrite a newer user focus
        // choice such as the search field or filter menus.
        guard detailOwnedFocus else {
            returnTarget = nil
            return
        }
        let destination = validatedReturnTarget(fallbackRecordID: recordID)
        returnTarget = nil
        guard target != destination else {
            return
        }
        request(destination, reason: .detailDismissed)
        restoreParentWindow(reason: .detailDismissed)
    }

    func releasePinnedPanel() {
        guard hasActiveSession(stage: "release-pinned-panel") else { return }
        request(.inactive, reason: .pinnedPanelReleased)
    }

    func endSession() {
        request(.inactive, reason: .panelClosed)
        parentWindow = nil
        detailWindow = nil
        returnTarget = nil
        sessionID = nil
        keySurface = .external
    }

    func windowBecameKey(_ surface: ClipboardPanelFocusSurface, window: NSWindow) {
        guard sessionID != nil,
              owns(window: window, for: surface) else {
            logIgnoredWindowCallback(stage: "window-became-key-ignored", surface: surface, window: window)
            return
        }
        keySurface = surface
        generation &+= 1
        logWindow(stage: "window-became-key", window: window)
    }

    func windowResignedKey(_ surface: ClipboardPanelFocusSurface, window: NSWindow) {
        guard let callbackSessionID = sessionID,
              owns(window: window, for: surface) else {
            logIgnoredWindowCallback(stage: "window-resigned-key-ignored", surface: surface, window: window)
            return
        }
        logWindow(stage: "window-resigned-key", window: window)
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self,
                  self.sessionID == callbackSessionID,
                  let window,
                  self.owns(window: window, for: surface) else {
                return
            }
            if self.detailWindow?.isKeyWindow == true {
                self.keySurface = .detail
            } else if self.parentWindow?.isKeyWindow == true {
                self.keySurface = .parent
            } else {
                self.keySurface = .external
            }
            self.generation &+= 1
            Self.logger.info(
                "stage=key-surface-resolved session=\(self.sessionID?.uuidString ?? "none", privacy: .public) source=\(surface.rawValue, privacy: .public) window=\(window.title, privacy: .public) keySurface=\(self.keySurface.rawValue, privacy: .public) target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
            )
        }
    }

    func isRecordFocused(_ recordID: String) -> Bool {
        guard case let .records(focusedRecordID) = target else {
            return false
        }
        return focusedRecordID == recordID
    }

    func accepts(generation: UInt64) -> Bool {
        self.generation == generation
    }

    var currentFirstResponder: NSResponder? {
        if detailWindow?.isKeyWindow == true {
            return detailWindow?.firstResponder
        }
        if parentWindow?.isKeyWindow == true {
            return parentWindow?.firstResponder
        }
        return detailWindow?.firstResponder ?? parentWindow?.firstResponder
    }

    func hasSearchTextInputFirstResponder(for event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder ?? currentFirstResponder
        guard let editor = responder as? NSTextView,
              editor.isFieldEditor else {
            return false
        }

        var candidate: NSResponder? = editor
        for _ in 0..<16 {
            guard let current = candidate else {
                return false
            }
            if let textField = current as? NSTextField,
               textField.placeholderString == L10n.string("clipboard.searchPlaceholder") {
                return true
            }
            candidate = current.nextResponder
        }
        return false
    }

    func hasRecordFocusAnchorFirstResponder(for event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder ?? currentFirstResponder
        return responder is ClipboardPanelRecordFocusAnchorView
    }

    func restoreKeyWindowForCurrentTarget() {
        let preferredWindow: NSWindow? = switch target {
        case .detailRead, .detailEdit:
            detailWindow
        case .search, .records, .inactive:
            parentWindow
        }
        guard let preferredWindow, preferredWindow.isVisible else {
            return
        }
        preferredWindow.makeKeyAndOrderFront(nil)
    }

    func reportEndpointResult(
        surface: ClipboardPanelFocusSurface,
        expectedTarget: ClipboardPanelFocusTarget,
        generation: UInt64,
        applied: Bool,
        failureReason: String? = nil
    ) {
        let window = surface == .detail ? detailWindow : parentWindow
        let actualResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        Self.logger.info(
            "stage=endpoint-result session=\(self.sessionID?.uuidString ?? "none", privacy: .public) surface=\(surface.rawValue, privacy: .public) expected=\(expectedTarget.diagnosticName, privacy: .public) actual=\(self.target.diagnosticName, privacy: .public) key=\(window?.isKeyWindow == true, privacy: .public) firstResponder=\(actualResponder, privacy: .public) requestGeneration=\(generation) currentGeneration=\(self.generation) applied=\(applied, privacy: .public) failure=\(failureReason ?? "none", privacy: .public)"
        )
    }

    private func request(
        _ target: ClipboardPanelFocusTarget,
        reason: ClipboardPanelFocusReason
    ) {
        let previous = self.target
        self.target = target
        generation &+= 1
        let actualWindow = detailWindow?.isKeyWindow == true ? detailWindow : parentWindow
        let actualResponder = actualWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        Self.logger.info(
            "stage=request session=\(self.sessionID?.uuidString ?? "none", privacy: .public) from=\(previous.diagnosticName, privacy: .public) to=\(target.diagnosticName, privacy: .public) reason=\(reason.rawValue, privacy: .public) keySurface=\(self.keySurface.rawValue, privacy: .public) firstResponder=\(actualResponder, privacy: .public) generation=\(self.generation)"
        )
    }

    private func validatedReturnTarget(
        fallbackRecordID: String?
    ) -> ClipboardPanelFocusTarget {
        if case let .records(recordID) = returnTarget {
            return .records(recordID: recordID)
        }
        if let fallbackRecordID {
            return .records(recordID: fallbackRecordID)
        }
        return .search
    }

    private func hasActiveSession(stage: String) -> Bool {
        guard sessionID != nil else {
            Self.logger.debug(
                "stage=\(stage, privacy: .public)-ignored reason=no-active-session target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
            )
            return false
        }
        return true
    }

    private func restoreParentWindow(reason: ClipboardPanelFocusReason) {
        guard let parentWindow, parentWindow.isVisible else {
            Self.logger.error(
                "stage=parent-restore-failed session=\(self.sessionID?.uuidString ?? "none", privacy: .public) reason=\(reason.rawValue, privacy: .public) target=\(self.target.diagnosticName, privacy: .public)"
            )
            return
        }
        parentWindow.makeKey()
        Self.logger.info(
            "stage=parent-restored session=\(self.sessionID?.uuidString ?? "none", privacy: .public) reason=\(reason.rawValue, privacy: .public) firstResponder=\(String(describing: parentWindow.firstResponder.map { type(of: $0) }), privacy: .public) target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
        )
    }

    private func logWindow(stage: String, window: NSWindow) {
        Self.logger.info(
            "stage=\(stage, privacy: .public) session=\(self.sessionID?.uuidString ?? "none", privacy: .public) title=\(window.title, privacy: .public) key=\(window.isKeyWindow, privacy: .public) firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }), privacy: .public) target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
        )
    }

    private func owns(window: NSWindow, for surface: ClipboardPanelFocusSurface) -> Bool {
        switch surface {
        case .parent:
            parentWindow === window
        case .detail:
            detailWindow === window
        case .external:
            false
        }
    }

    private func logIgnoredWindowCallback(
        stage: String,
        surface: ClipboardPanelFocusSurface,
        window: NSWindow
    ) {
        Self.logger.debug(
            "stage=\(stage, privacy: .public) session=\(self.sessionID?.uuidString ?? "none", privacy: .public) surface=\(surface.rawValue, privacy: .public) title=\(window.title, privacy: .public) target=\(self.target.diagnosticName, privacy: .public) generation=\(self.generation)"
        )
    }
}

enum ClipboardPanelKeyboardCommand: Equatable {
    case navigate(delta: Int)
    case pasteSelected
    case deleteSelected
    case escape
    case quickPaste(index: Int)
    case saveDetail
}

enum ClipboardPanelEscapeStep: Equatable {
    case exitDetailEdit
    case closeDetail
    case clearSearch
    case clearFilters
    case releasePanel
}

struct ClipboardPanelEscapeContext: Equatable {
    let focusTarget: ClipboardPanelFocusTarget
    let hasPresentedDetail: Bool
    let hasSearchQuery: Bool
    let hasActiveFilters: Bool
}

struct ClipboardPanelEscapeResolver {
    static func step(for context: ClipboardPanelEscapeContext) -> ClipboardPanelEscapeStep {
        if case .detailEdit = context.focusTarget {
            return .exitDetailEdit
        }
        if context.hasPresentedDetail {
            return .closeDetail
        }
        if context.hasSearchQuery {
            return .clearSearch
        }
        if context.hasActiveFilters {
            return .clearFilters
        }
        return .releasePanel
    }
}

@MainActor
final class ClipboardPanelKeyboardCommandRouter {
    private let focusCoordinator: ClipboardPanelFocusCoordinator
    private var position: FloatingPanelPosition = .bottom
    private var handler: ((ClipboardPanelKeyboardCommand) -> Void)?

    init(focusCoordinator: ClipboardPanelFocusCoordinator) {
        self.focusCoordinator = focusCoordinator
    }

    func configure(
        position: FloatingPanelPosition,
        handler: @escaping (ClipboardPanelKeyboardCommand) -> Void
    ) {
        self.position = position
        self.handler = handler
    }

    func reset() {
        handler = nil
    }

    func route(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let command = command(for: event) else {
            return false
        }
        handler?(command)
        return handler != nil
    }

    private func command(for event: NSEvent) -> ClipboardPanelKeyboardCommand? {
        if isComposingText(in: event),
           !event.modifierFlags.contains(.command) {
            return nil
        }

        if let quickPasteIndex = quickPasteIndex(for: event) {
            return .quickPaste(index: quickPasteIndex)
        }

        if Int(event.keyCode) == kVK_Escape {
            return .escape
        }

        switch focusCoordinator.target {
        case .search:
            guard focusCoordinator.hasSearchTextInputFirstResponder(for: event) else {
                return nil
            }
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                return .navigate(delta: -1)
            case kVK_DownArrow:
                return .navigate(delta: 1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return .pasteSelected
            default:
                return nil
            }
        case .records:
            guard focusCoordinator.hasRecordFocusAnchorFirstResponder(for: event) else {
                return nil
            }
            switch Int(event.keyCode) {
            case kVK_LeftArrow where position == .bottom:
                return .navigate(delta: -1)
            case kVK_RightArrow where position == .bottom:
                return .navigate(delta: 1)
            case kVK_UpArrow where position != .bottom:
                return .navigate(delta: -1)
            case kVK_DownArrow where position != .bottom:
                return .navigate(delta: 1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return .pasteSelected
            case kVK_Delete, kVK_ForwardDelete:
                return .deleteSelected
            default:
                return nil
            }
        case .detailEdit:
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == [.command],
               [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
                return .saveDetail
            }
            return nil
        case .detailRead, .inactive:
            return nil
        }
    }

    private func isComposingText(in event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder ?? focusCoordinator.currentFirstResponder
        return (responder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func quickPasteIndex(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == [.command] else {
            return nil
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_1, kVK_ANSI_Keypad1:
            return 1
        case kVK_ANSI_2, kVK_ANSI_Keypad2:
            return 2
        case kVK_ANSI_3, kVK_ANSI_Keypad3:
            return 3
        case kVK_ANSI_4, kVK_ANSI_Keypad4:
            return 4
        case kVK_ANSI_5, kVK_ANSI_Keypad5:
            return 5
        case kVK_ANSI_6, kVK_ANSI_Keypad6:
            return 6
        case kVK_ANSI_7, kVK_ANSI_Keypad7:
            return 7
        case kVK_ANSI_8, kVK_ANSI_Keypad8:
            return 8
        case kVK_ANSI_9, kVK_ANSI_Keypad9:
            return 9
        default:
            return nil
        }
    }
}

struct ClipboardPanelRecordFocusAnchor: NSViewRepresentable {
    @ObservedObject var focusCoordinator: ClipboardPanelFocusCoordinator

    func makeNSView(context: Context) -> ClipboardPanelRecordFocusAnchorView {
        ClipboardPanelRecordFocusAnchorView(focusCoordinator: focusCoordinator)
    }

    func updateNSView(
        _ nsView: ClipboardPanelRecordFocusAnchorView,
        context: Context
    ) {
        nsView.focusCoordinator = focusCoordinator
        nsView.applyFocusRequest(generation: focusCoordinator.generation)
    }
}

final class ClipboardPanelRecordFocusAnchorView: NSView {
    private struct RequestIdentity: Hashable {
        let coordinator: ObjectIdentifier
        let generation: UInt64
    }

    weak var focusCoordinator: ClipboardPanelFocusCoordinator? {
        didSet {
            if oldValue !== focusCoordinator {
                appliedCoordinator = nil
                appliedGeneration = nil
            }
        }
    }
    private weak var appliedCoordinator: ClipboardPanelFocusCoordinator?
    private var appliedGeneration: UInt64?
    private var inFlightRequests: Set<RequestIdentity> = []

    init(focusCoordinator: ClipboardPanelFocusCoordinator) {
        self.focusCoordinator = focusCoordinator
        super.init(frame: .zero)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @MainActor
    func applyFocusRequest(generation: UInt64) {
        guard let focusCoordinator,
              appliedCoordinator !== focusCoordinator || appliedGeneration != generation else {
            return
        }
        guard focusCoordinator.accepts(generation: generation) else {
            focusCoordinator.reportEndpointResult(
                surface: .parent,
                expectedTarget: focusCoordinator.target,
                generation: generation,
                applied: false,
                failureReason: "stale-generation"
            )
            return
        }
        guard case .records = focusCoordinator.target else {
            return
        }
        guard window?.isKeyWindow == true else {
            focusCoordinator.reportEndpointResult(
                surface: .parent,
                expectedTarget: focusCoordinator.target,
                generation: generation,
                applied: false,
                failureReason: "parent-not-key"
            )
            return
        }
        let request = RequestIdentity(
            coordinator: ObjectIdentifier(focusCoordinator),
            generation: generation
        )
        // AppKit can synchronously re-enter a representable while changing
        // responders. In-flight deduplication is not a success acknowledgement.
        guard inFlightRequests.insert(request).inserted else { return }
        defer { inFlightRequests.remove(request) }
        let expectedTarget = focusCoordinator.target
        let applied = window?.makeFirstResponder(self) == true
        if applied,
           self.focusCoordinator === focusCoordinator,
           focusCoordinator.accepts(generation: generation) {
            appliedCoordinator = focusCoordinator
            appliedGeneration = generation
        }
        focusCoordinator.reportEndpointResult(
            surface: .parent,
            expectedTarget: expectedTarget,
            generation: generation,
            applied: applied,
            failureReason: applied ? nil : "make-first-responder-rejected"
        )
    }
}
