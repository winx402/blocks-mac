import AppKit
import BlocksCore
import Foundation

/// App-owned privacy boundary. A Core snapshot token binds a selection; it is
/// never a substitute for the user's one-request approval in this process.
@MainActor
final class ClipboardManagementAccessController {
    typealias Authorize = @MainActor (ClipboardManagementActionInput, ClipboardManagementResult) async -> Bool
    private let summaryAllowed: () -> Bool
    private let authorize: Authorize?
    private let presenter = ClipboardManagementConsentPresenter()
    private var pendingRequest: UUID?

    init(
        summaryAllowed: @escaping () -> Bool = {
            (UserDefaults.standard.object(forKey: "clipboard.agent.summaryAccess") as? Bool) ?? true
        },
        authorize: Authorize? = nil
    ) {
        self.summaryAllowed = summaryAllowed
        self.authorize = authorize
    }

    func execute(
        _ input: ClipboardManagementActionInput,
        perform: @escaping @MainActor (ClipboardManagementActionInput) async throws -> ClipboardManagementResult
    ) async throws -> ClipboardManagementResult {
        try checkCancellation()
        let summaryRead = ["list", "search", "pinboard_list"].contains(input.operation)
        let fullRead = ["show", "export"].contains(input.operation)
        if summaryRead, !summaryAllowed() { throw ClipboardManagementError("summary_access_denied") }

        guard fullRead else {
            var result = try await perform(input)
            result.document = nil
            if summaryRead, !summaryAllowed() { throw ClipboardManagementError("summary_access_denied") }
            // Writes may already be committed: do not convert a successful write
            // to cancellation or denial merely because the preference changed.
            return scrubSummaryIfNeeded(result)
        }

        // Discard caller-supplied tokens even for dry runs.
        let preparation = copy(input, dryRun: true, token: nil)
        if input.dryRun {
            var result = try await performRead(preparation, perform: perform)
            result.document = nil
            result.confirmationToken = nil
            try checkCancellation()
            return scrubSummaryIfNeeded(result)
        }
        guard pendingRequest == nil else { throw ClipboardManagementError("full_content_confirmation_busy") }
        let requestID = UUID()
        pendingRequest = requestID
        defer { if pendingRequest == requestID { pendingRequest = nil } }

        var snapshot = try await performRead(preparation, perform: perform)
        snapshot.document = nil
        guard let token = snapshot.confirmationToken, !token.isEmpty else {
            throw ClipboardManagementError("full_content_snapshot_unavailable")
        }
        snapshot.confirmationToken = nil
        snapshot = scrubSummaryIfNeeded(snapshot)
        try checkCancellation()
        let consent = ClipboardManagementConsentWaiter()
        let approved = try await consent.wait {
            if let authorize = self.authorize { return await authorize(preparation, snapshot) }
            return try await self.presenter.present(preparation, snapshot: snapshot)
        }
        try checkCancellation()
        guard approved else { throw ClipboardManagementError("full_content_access_denied") }
        // Re-execute the exact request with the private preparation token. Core
        // checks its snapshot before reading, including changed group membership.
        var result = try await performRead(copy(input, dryRun: false, token: token), perform: perform)
        result.confirmationToken = nil
        try checkCancellation()
        return scrubSummaryIfNeeded(result)
    }

    /// Final synchronous gate for a result that already passed `execute`.
    /// Call after any asynchronous encoding/preparation, immediately before
    /// delivery; discard any earlier encoded bytes if this sanitizes the result.
    /// This does not grant full-content access or replace the consent flow.
    static func prepareForDelivery(
        _ value: ClipboardManagementResult,
        input: ClipboardManagementActionInput,
        summaryAllowed: Bool
    ) throws -> ClipboardManagementResult {
        if !input.isMutating || input.dryRun, Task.isCancelled {
            throw ClipboardManagementError("full_content_cancelled")
        }
        if ["list", "search", "pinboard_list"].contains(input.operation), !summaryAllowed {
            throw ClipboardManagementError("summary_access_denied")
        }
        var result = value
        let fullRead = ["show", "export"].contains(input.operation)
        if !fullRead || input.dryRun { result.document = nil }
        if fullRead { result.confirmationToken = nil }
        if !summaryAllowed {
            result.records = []
            result.pinboards = []
            result.warnings = []
        }
        // A successful mutation is still committed even if cancellation or
        // summary revocation arrived while the response was being prepared.
        return result
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ClipboardManagementError("full_content_cancelled") }
    }

    private func performRead(
        _ input: ClipboardManagementActionInput,
        perform: @MainActor (ClipboardManagementActionInput) async throws -> ClipboardManagementResult
    ) async throws -> ClipboardManagementResult {
        do { return try await perform(input) }
        catch is CancellationError { throw ClipboardManagementError("full_content_cancelled") }
    }

    private func scrubSummaryIfNeeded(_ value: ClipboardManagementResult) -> ClipboardManagementResult {
        var result = value
        if !summaryAllowed() {
            result.records = []
            result.pinboards = []
            result.warnings = []
        }
        return result
    }

    private func copy(_ input: ClipboardManagementActionInput, dryRun: Bool, token: String?) -> ClipboardManagementActionInput {
        .init(operation: input.operation, document: input.document, dryRun: dryRun,
              recordIDs: input.recordIDs, query: input.query, pinboardID: input.pinboardID,
              tag: input.tag, name: input.name, limit: input.limit, offset: input.offset,
              all: input.all, confirmationToken: token)
    }
}

/// Unstructured authorizers cannot hold a request open indefinitely, even when
/// an injected implementation ignores task cancellation. Late answers are inert.
@MainActor
final class ClipboardManagementConsentWaiter {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func wait(
        timeoutNanoseconds: UInt64 = 45_000_000_000,
        operation: @escaping @MainActor () async throws -> Bool
    ) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(ClipboardManagementError("full_content_cancelled")))
                    return
                }
                work = Task { @MainActor in
                    do { self.finish(.success(try await operation())) }
                    catch { self.finish(.failure(error)) }
                }
                timeout = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: min(timeoutNanoseconds, 45_000_000_000)) }
                    catch { return }
                    self.finish(.failure(ClipboardManagementError("full_content_confirmation_timeout")))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(ClipboardManagementError("full_content_cancelled")))
            }
        }
    }

    private func finish(_ result: Result<Bool, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        work?.cancel(); work = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(with: result)
    }
}

@MainActor
final class ClipboardManagementConsentPresenter {
    typealias WindowProvider = @MainActor () -> NSWindow?
    typealias SheetPresenter = @MainActor (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    typealias SheetDismisser = @MainActor (NSAlert, NSWindow) -> Void
    private struct Active {
        let id: UUID
        let alert: NSAlert
        let window: NSWindow
        let continuation: CheckedContinuation<Bool, Never>
        var closeObserver: NSObjectProtocol?
    }
    private let windowProvider: WindowProvider
    private let sheetPresenter: SheetPresenter
    private let sheetDismisser: SheetDismisser
    private var active: Active?

    init(
        windowProvider: @escaping WindowProvider = {
            let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.windows
            return windows.first {
                $0.isVisible && !$0.isMiniaturized && $0.level == .normal
                    && $0.styleMask.contains(.titled) && $0.attachedSheet == nil
            }
        },
        sheetPresenter: @escaping SheetPresenter = { alert, window, completion in
            alert.beginSheetModal(for: window, completionHandler: completion)
        },
        sheetDismisser: @escaping SheetDismisser = { alert, window in
            if alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
        }
    ) {
        self.windowProvider = windowProvider
        self.sheetPresenter = sheetPresenter
        self.sheetDismisser = sheetDismisser
    }

    func present(_ input: ClipboardManagementActionInput, snapshot: ClipboardManagementResult) async throws -> Bool {
        guard !Task.isCancelled else { return false }
        guard active == nil else { throw ClipboardManagementError("full_content_confirmation_busy") }
        guard let window = windowProvider() else { throw ClipboardManagementError("full_content_requires_visible_window") }
        let id = UUID()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("clipboard.management.consent.title")
        alert.informativeText = L10n.string("clipboard.management.consent.message")
        alert.accessoryView = Self.scopeView(Self.scopeDescription(input, count: snapshot.counts.selected))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.addButton(withTitle: L10n.string("clipboard.management.consent.allowOnce"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                active = Active(id: id, alert: alert, window: window, continuation: continuation)
                active?.closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.finish(id: id, approved: false) }
                }
                sheetPresenter(alert, window) { [weak self] response in
                    Task { @MainActor in self?.finish(id: id, approved: response == .alertSecondButtonReturn) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, approved: false) }
        }
    }

    private func finish(id: UUID, approved: Bool) {
        guard let active, active.id == id else { return }
        self.active = nil
        if let observer = active.closeObserver { NotificationCenter.default.removeObserver(observer) }
        sheetDismisser(active.alert, active.window)
        active.continuation.resume(returning: approved && active.window.isVisible && !active.window.isMiniaturized)
    }

    private static func scopeView(_ text: String) -> NSView {
        // NSAlert owns the fixed title and buttons; only request data scrolls.
        let width = BlocksVisualTokens.Layout.settingsSheetMinimumWidth - BlocksVisualTokens.Spacing.lg * 2
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width,
            height: BlocksVisualTokens.Layout.settingsSheetCompactMinimumHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.string = text
        view.setAccessibilityLabel(text)
        scroll.documentView = view
        return scroll
    }

    static func scopeDescription(_ input: ClipboardManagementActionInput, count: Int) -> String {
        var lines = [L10n.format("clipboard.management.consent.operation", input.operation),
                     L10n.format("clipboard.management.consent.count", String(count))]
        if input.all { lines.append(L10n.string("clipboard.management.consent.all")) }
        if !input.recordIDs.isEmpty {
            lines.append(L10n.format("clipboard.management.consent.ids", String(input.recordIDs.count),
                                    input.recordIDs.prefix(3).map(safeValue).joined(separator: ", ")
                                    + (input.recordIDs.count > 3 ? " …" : "")))
        }
        if let query = input.query { lines.append(L10n.format("clipboard.management.consent.query", safeValue(query))) }
        if let board = input.pinboardID { lines.append(L10n.format("clipboard.management.consent.board", safeValue(board))) }
        if let tag = input.tag { lines.append(L10n.format("clipboard.management.consent.tag", safeValue(tag))) }
        return lines.joined(separator: "\n")
    }

    /// Plain, quoted data: control/bidi formatting cannot impersonate labels or
    /// inject additional instructions. Bound both processing and presentation.
    private static func safeValue(_ value: String) -> String {
        let scalars = value.unicodeScalars.prefix(161)
        let clean = scalars.prefix(160).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || [0x202A...0x202E, 0x2066...0x2069].contains(where: { $0.contains(Int(scalar.value)) }) {
                return " "
            }
            return String(scalar)
        }.joined().replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + clean + (scalars.count > 160 ? "…" : "") + "\""
    }
}
