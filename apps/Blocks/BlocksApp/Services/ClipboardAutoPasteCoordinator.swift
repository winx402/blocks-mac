import ApplicationServices
import AppKit
import BlocksCore
import OSLog

enum ClipboardPasteTargetEligibility {
    private static let frontmostOverlayBundleIdentifiers: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
    ]

    static func eligibleApplication(
        _ application: NSRunningApplication?
    ) -> NSRunningApplication? {
        guard let application = eligibleApplicationWithoutWindowCheck(application),
              hasVisibleApplicationWindow(
                  processIdentifier: application.processIdentifier
              ) else {
            return nil
        }
        return application
    }

    static func frontmostVisibleEligibleApplication(
        windowInfo: [[String: Any]]? = nil
    ) -> NSRunningApplication? {
        let resolvedWindowInfo: [[String: Any]]
        if let windowInfo {
            resolvedWindowInfo = windowInfo
        } else {
            resolvedWindowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        }
        var visitedProcessIdentifiers: Set<pid_t> = []
        for window in resolvedWindowInfo {
            guard isVisibleLayerZeroWindow(window),
                  let processIdentifier = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  visitedProcessIdentifiers.insert(processIdentifier).inserted,
                  let application = eligibleApplicationWithoutWindowCheck(
                      NSRunningApplication(processIdentifier: processIdentifier)
                  ) else {
                continue
            }
            return application
        }
        return nil
    }

    static func shouldUseVisibleWindowFallback(
        after reportedApplication: NSRunningApplication?
    ) -> Bool {
        guard let reportedApplication else {
            return true
        }
        guard let bundleIdentifier = reportedApplication.bundleIdentifier else {
            return false
        }
        return frontmostOverlayBundleIdentifiers.contains(bundleIdentifier)
    }

    static func hasVisibleApplicationWindow(
        processIdentifier: pid_t,
        windowInfo: [[String: Any]]
    ) -> Bool {
        windowInfo.contains { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
                && isVisibleLayerZeroWindow(window)
        }
    }

    static func hasVisibleApplicationWindow(processIdentifier: pid_t) -> Bool {
        guard let rawWindowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return hasVisibleApplicationWindow(
            processIdentifier: processIdentifier,
            windowInfo: rawWindowInfo
        )
    }

    static func frontmostVisibleWindowID(
        processIdentifier: pid_t,
        windowInfo: [[String: Any]]? = nil
    ) -> CGWindowID? {
        let windows = windowInfo ?? (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? [])
        return windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
                && isVisibleLayerZeroWindow($0)
        }).flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    private static func eligibleApplicationWithoutWindowCheck(
        _ application: NSRunningApplication?
    ) -> NSRunningApplication? {
        guard let application,
              !application.isTerminated,
              application.activationPolicy == .regular,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              bundleIdentifier != "com.apple.SystemSettings",
              bundleIdentifier != "com.apple.systempreferences" else {
            return nil
        }
        return application
    }

    private static func isVisibleLayerZeroWindow(_ window: [String: Any]) -> Bool {
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
            return false
        }
        return width >= 40 && height >= 24
    }
}

enum ClipboardAutoPasteError: Error, Equatable {
    case featureDisabled
    case recordNotFound
    case recordNotRestorable
    case payloadUnavailable
    case unsupportedPayload
    case accessibilityPermissionRequired
    case targetApplicationUnavailable
    case targetApplicationNotFrontmost
    case pasteEventFailed
    case pasteboardWriteFailed
    case pasteboardChanged
}

struct ClipboardAutoPastePartialFailure: Error, Equatable {
    let reason: ClipboardAutoPasteError
    let pasteboardLease: ClipboardPasteboardWriteLease

    var pasteboardChangeCountAfterWrite: Int {
        pasteboardLease.changeCount
    }
}

struct ClipboardAutoPasteCopyResult: Equatable, Sendable {
    let pasteboardLease: ClipboardPasteboardWriteLease
    let mayContinueAutomaticPaste: Bool
}

struct ClipboardPasteboardWriteOrigin: Codable, Equatable {
    static let pasteboardType = NSPasteboard.PasteboardType("app.blocks.clipboard.write-origin")

    let operationID: UUID
    let recordID: String
    let signatureSHA256: String

    var encodedValue: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ value: String?) -> Self? {
        guard let value,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum ClipboardPasteAttemptState: String, Equatable {
    case prepared
    case pasteboardWritten
    case pasteCommandSent
    case failed
}

struct ClipboardTargetFrontmostStability {
    let requiredConsecutiveMatches: Int
    private(set) var consecutiveMatches = 0

    mutating func observe(expectedTargetIsFrontmost: Bool) -> Bool {
        guard expectedTargetIsFrontmost else {
            consecutiveMatches = 0
            return false
        }
        consecutiveMatches += 1
        return consecutiveMatches >= requiredConsecutiveMatches
    }
}

enum ClipboardPasteFailureReason: String, Equatable {
    case notAuthorized
    case targetApplicationUnavailable
    case targetApplicationTerminated
    case targetApplicationNotFrontmost
    case eventCreationFailed
    case recordNotRestorable
    case payloadUnavailable
    case unsupportedPayload
    case pasteboardWriteFailed
    case pasteboardChanged
}

struct ClipboardPasteTarget: Hashable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let launchDate: Date?

    init(_ application: NSRunningApplication) {
        bundleIdentifier = application.bundleIdentifier
        processIdentifier = application.processIdentifier
        launchDate = application.launchDate
    }

    init(bundleIdentifier: String?, processIdentifier: pid_t, launchDate: Date?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
    }

    var runningApplication: NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier == bundleIdentifier,
              let launchDate,
              application.launchDate == launchDate,
              !application.isTerminated else {
            return nil
        }
        return application
    }
}

struct ClipboardPasteFocusIdentity: Equatable {
    let role: String
    let subrole: String?
    let identifier: String?
    let domIdentifier: String?
    let chromeAXNodeID: String?

    init(
        role: String,
        subrole: String?,
        identifier: String?,
        domIdentifier: String?,
        chromeAXNodeID: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.chromeAXNodeID = chromeAXNodeID
    }

    var hasStableIdentifier: Bool {
        normalized(domIdentifier) != nil
            || normalized(identifier) != nil
            || normalized(chromeAXNodeID) != nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClipboardPasteFocusSnapshot {
    let target: ClipboardPasteTarget
    /// Window-server routing identity. AX availability is separate evidence,
    /// not a prerequisite for a user-requested paste into this window.
    let windowID: CGWindowID?
    let focusedWindow: AXUIElement?
    let focusedElement: AXUIElement?
    let focusedSemantics: ClipboardAXEditableSemantics?
    let focusedIdentity: ClipboardPasteFocusIdentity?

    init(
        target: ClipboardPasteTarget,
        focusedWindow: AXUIElement? = nil,
        focusedElement: AXUIElement? = nil,
        focusedSemantics: ClipboardAXEditableSemantics? = nil,
        focusedIdentity: ClipboardPasteFocusIdentity? = nil,
        windowID: CGWindowID? = nil
    ) {
        self.target = target
        self.windowID = windowID
        self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement
        self.focusedSemantics = focusedSemantics
        self.focusedIdentity = focusedIdentity
    }

    var runningApplication: NSRunningApplication? {
        target.runningApplication
    }
}

typealias ClipboardPasteTargetContext = ClipboardPasteFocusSnapshot

struct ClipboardPasteAttempt: Equatable {
    let recordID: String
    let targetBundleID: String?
    let targetPID: pid_t?
    let pasteboardChangeCountBefore: Int
    var state: ClipboardPasteAttemptState
    var failureReason: ClipboardPasteFailureReason?
}

enum ClipboardPasteboardRepresentation: Equatable {
    case string(String)
    case data(Data)
    case propertyList([String])
}

struct ClipboardPasteboardWriteItem: Equatable {
    let representations: [NSPasteboard.PasteboardType: ClipboardPasteboardRepresentation]
    let semanticFileURL: URL?

    init(
        representations: [NSPasteboard.PasteboardType: ClipboardPasteboardRepresentation],
        semanticFileURL: URL? = nil
    ) {
        self.representations = representations
        self.semanticFileURL = semanticFileURL
    }
}

@MainActor
protocol ClipboardPasteboardWriting: AnyObject {
    var changeCount: Int { get }
    func writeItems(_ items: [ClipboardPasteboardWriteItem]) -> Bool
}

@MainActor
final class ClipboardPasteboardChangeSuppressor {
    static let shared = ClipboardPasteboardChangeSuppressor()

    private var pendingChangeCounts: Set<Int> = []

    func suppress(_ changeCounts: [Int]) {
        pendingChangeCounts.formUnion(changeCounts.filter { $0 > 0 })
        if pendingChangeCounts.count > 24 {
            pendingChangeCounts = Set(pendingChangeCounts.sorted().suffix(12))
        }
    }

    func consume(_ changeCount: Int) -> Bool {
        pendingChangeCounts.remove(changeCount) != nil
    }
}

struct ClipboardAXEditableSemantics: Equatable {
    let role: String
    let enabled: Bool?
    let explicitlyEditable: Bool
    let valueSettable: Bool
    let selectedTextSettable: Bool
    let focusedSettable: Bool
    let hasTextContentModel: Bool
    let hasTextSelectionModel: Bool
    let hasWebAreaAncestor: Bool
    let hasStableWebNodeIdentity: Bool

    init(
        role: String,
        enabled: Bool?,
        explicitlyEditable: Bool,
        valueSettable: Bool,
        selectedTextSettable: Bool,
        focusedSettable: Bool = false,
        hasTextContentModel: Bool = false,
        hasTextSelectionModel: Bool = false,
        hasWebAreaAncestor: Bool = false,
        hasStableWebNodeIdentity: Bool = false
    ) {
        self.role = role
        self.enabled = enabled
        self.explicitlyEditable = explicitlyEditable
        self.valueSettable = valueSettable
        self.selectedTextSettable = selectedTextSettable
        self.focusedSettable = focusedSettable
        self.hasTextContentModel = hasTextContentModel
        self.hasTextSelectionModel = hasTextSelectionModel
        self.hasWebAreaAncestor = hasWebAreaAncestor
        self.hasStableWebNodeIdentity = hasStableWebNodeIdentity
    }

    var acceptsPaste: Bool {
        acceptsPaste(allowUnknownRole: false)
    }

    func acceptsPaste(allowUnknownRole: Bool) -> Bool {
        guard enabled != false else {
            return false
        }
        let supportsTextMutation = valueSettable || selectedTextSettable
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView":
            return explicitlyEditable || supportsTextMutation
        case "AXWebArea":
            return explicitlyEditable || (valueSettable && selectedTextSettable)
        default:
            return allowUnknownRole
                && role == "AXGroup"
                && focusedSettable
                && hasTextContentModel
                && hasTextSelectionModel
                && hasWebAreaAncestor
                && hasStableWebNodeIdentity
        }
    }
}

@MainActor
final class DirectClipboardPasteboard: ClipboardPasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func writeItems(_ items: [ClipboardPasteboardWriteItem]) -> Bool {
        var pasteboardItems: [NSPasteboardWriting] = []
        for writeItem in items {
            if let fileURL = writeItem.semanticFileURL {
                guard writeItem.representations.isEmpty,
                      fileURL.isFileURL else {
                    return false
                }
                pasteboardItems.append(fileURL as NSURL)
                continue
            }
            guard !writeItem.representations.isEmpty else {
                return false
            }
            let item = NSPasteboardItem()
            for (type, representation) in writeItem.representations {
                let representationSet: Bool
                switch representation {
                case let .string(value):
                    representationSet = item.setString(value, forType: type)
                case let .data(value):
                    representationSet = item.setData(value, forType: type)
                case let .propertyList(value):
                    representationSet = item.setPropertyList(value, forType: type)
                }
                guard representationSet else {
                    return false
                }
            }
            pasteboardItems.append(item)
        }

        pasteboard.clearContents()
        guard !pasteboardItems.isEmpty else {
            return true
        }
        guard pasteboard.writeObjects(pasteboardItems) else {
            return false
        }
        return true
    }
}

@MainActor
final class ClipboardPasteboardWriter {
    private enum Backend {
        case broker(any ClipboardBrokerServing)
        case direct(
            pasteboard: any ClipboardPasteboardWriting,
            changeSuppressor: ClipboardPasteboardChangeSuppressor
        )
    }

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "ClipboardWrite"
    )

    private let backend: Backend

    init(
        pasteboard: ClipboardPasteboardWriting,
        changeSuppressor: ClipboardPasteboardChangeSuppressor? = nil
    ) {
        backend = .direct(
            pasteboard: pasteboard,
            changeSuppressor: changeSuppressor ?? .shared
        )
    }

    init(broker: any ClipboardBrokerServing = ClipboardBrokerClient.shared) {
        backend = .broker(broker)
    }

    func write(
        payload: ClipboardRecorderPayload,
        expectedChangeCount: Int? = nil,
        origin: ClipboardPasteboardWriteOrigin? = nil,
        operationAllowed: @escaping () -> Bool = { true },
        requiresPreparedAuthorization: Bool = false,
        recordCommitGate: ClipboardRecordCommitGate? = nil
    ) async throws -> ClipboardPasteboardWriteLease {
        let items = try await makeItems(payload: payload, origin: origin)
        return try await performWrite(
            items,
            expectedChangeCount: expectedChangeCount,
            operationAllowed: operationAllowed,
            requiresPreparedAuthorization: requiresPreparedAuthorization,
            recordCommitGate: recordCommitGate
        )
    }

    func writePlainText(
        _ text: String,
        origin: ClipboardPasteboardWriteOrigin? = nil,
        operationAllowed: @escaping () -> Bool = { true },
        requiresPreparedAuthorization: Bool = false,
        recordCommitGate: ClipboardRecordCommitGate? = nil
    ) async throws -> ClipboardPasteboardWriteLease {
        var representations: [NSPasteboard.PasteboardType: ClipboardPasteboardRepresentation] = [
            .string: .string(text)
        ]
        if let origin, let encodedValue = origin.encodedValue {
            representations[ClipboardPasteboardWriteOrigin.pasteboardType] = .string(encodedValue)
        }
        return try await performWrite([
            ClipboardPasteboardWriteItem(representations: representations)
        ],
        expectedChangeCount: nil,
        operationAllowed: operationAllowed,
        requiresPreparedAuthorization: requiresPreparedAuthorization,
        recordCommitGate: recordCommitGate)
    }

    func writePreparedItems(
        _ items: [ClipboardPasteboardWriteItem],
        operationAllowed: @escaping () -> Bool = { true },
        requiresPreparedAuthorization: Bool = false
    ) async throws -> ClipboardPasteboardWriteLease {
        try await performWrite(
            items,
            expectedChangeCount: nil,
            operationAllowed: operationAllowed,
            requiresPreparedAuthorization: requiresPreparedAuthorization,
            recordCommitGate: nil
        )
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        switch backend {
        case let .broker(broker):
            return await broker.validate(lease)
        case let .direct(pasteboard, _):
            return lease.brokerGeneration == 0
                && pasteboard.changeCount == lease.changeCount
        }
    }

    func baseline() async throws -> Int {
        switch backend {
        case let .broker(broker):
            return try await broker.baseline()
        case let .direct(pasteboard, _):
            return pasteboard.changeCount
        }
    }

    private func makeItems(
        payload: ClipboardRecorderPayload,
        origin: ClipboardPasteboardWriteOrigin?
    ) async throws -> [ClipboardPasteboardWriteItem] {
        var representations: [NSPasteboard.PasteboardType: ClipboardPasteboardRepresentation]
        switch payload.kind {
        case .text:
            guard let text = payload.text else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            representations = [.string: .string(text)]
        case .richText:
            guard let text = payload.text,
                  let rtfData = payload.rtfData else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            representations = [
                .string: .string(text),
                .rtf: .data(rtfData),
            ]
        case .image:
            guard let pngData = payload.pngData else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            representations = [
                NSPasteboard.PasteboardType("public.png"): .data(pngData)
            ]
        case .url:
            guard let urlString = payload.urlString else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            representations = [
                .string: .string(urlString),
                NSPasteboard.PasteboardType("public.url"): .string(urlString),
            ]
        case .fileURL:
            guard let urlString = payload.urlString else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            let fileURL: URL
            if let parsedURL = URL(string: urlString), parsedURL.isFileURL {
                fileURL = parsedURL
            } else if let path = payload.text, path.hasPrefix("/") {
                // Preserve records captured by older builds that stored the
                // absolute path separately from a non-normalized URL string.
                fileURL = URL(fileURLWithPath: path)
            } else {
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            let fileIsRestorable = await Task.detached(priority: .userInitiated) {
                let values = try? fileURL.resourceValues(forKeys: [
                    .isReadableKey,
                    .isRegularFileKey,
                ])
                return values?.isReadable == true
                    && values?.isRegularFile == true
            }.value
            try Task.checkCancellation()
            guard fileIsRestorable else {
                // A native NSURL write can report success even when the source
                // disappeared, while publishing no cross-process item. Reject
                // stale history before either backend mutates the pasteboard.
                throw ClipboardAutoPasteError.payloadUnavailable
            }
            // AppKit must publish a native NSURL. A hand-authored
            // `public.file-url` string can be dropped or downgraded to plain
            // text at the sandbox/general-pasteboard boundary. The Broker's
            // change-count suppression remains the self-write marker for this
            // semantic item, so do not add a second metadata item.
            return [ClipboardPasteboardWriteItem(
                representations: [:],
                semanticFileURL: fileURL
            )]
        case .mixed, .unknown:
            throw ClipboardAutoPasteError.unsupportedPayload
        }
        if let origin, let encodedValue = origin.encodedValue {
            representations[ClipboardPasteboardWriteOrigin.pasteboardType] = .string(encodedValue)
        }
        return [ClipboardPasteboardWriteItem(representations: representations)]
    }

    private func performWrite(
        _ items: [ClipboardPasteboardWriteItem],
        expectedChangeCount: Int?,
        operationAllowed: @escaping () -> Bool,
        requiresPreparedAuthorization: Bool,
        recordCommitGate: ClipboardRecordCommitGate?
    ) async throws -> ClipboardPasteboardWriteLease {
        let representationCount = items.reduce(0) {
            $0 + $1.representations.count + ($1.semanticFileURL == nil ? 0 : 1)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.logger.info(
            "event=write-start items=\(items.count, privacy: .public) representations=\(representationCount, privacy: .public) expectedChangeCount=\(expectedChangeCount ?? -1, privacy: .public)"
        )
        do {
            let lease: ClipboardPasteboardWriteLease
            switch backend {
            case let .broker(broker):
                let request = makeBrokerWriteRequest(
                    items,
                    expectedChangeCount: expectedChangeCount
                )
                if requiresPreparedAuthorization,
                   await broker.supportsPreparedWrites() {
                    let preparedLease = try await broker.prepare(request)
                    let commitPermit = await recordCommitGate?.acquire()
                    if recordCommitGate != nil, commitPermit == nil {
                        try? await broker.cancel(preparedLease)
                        throw ClipboardAutoPasteError.featureDisabled
                    }
                    guard !Task.isCancelled, operationAllowed() else {
                        // Commit may already have won only if a cancellation
                        // raced this task at the Broker boundary. The caller
                        // still receives the local authorization failure.
                        try? await broker.cancel(preparedLease)
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                        throw ClipboardAutoPasteError.featureDisabled
                    }
                    do {
                        lease = try await broker.commit(preparedLease)
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                    } catch {
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                        throw error
                    }
                } else {
                    let commitPermit = await recordCommitGate?.acquire()
                    if recordCommitGate != nil, commitPermit == nil {
                        throw ClipboardAutoPasteError.featureDisabled
                    }
                    guard !Task.isCancelled, operationAllowed() else {
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                        throw ClipboardAutoPasteError.featureDisabled
                    }
                    do {
                        lease = try await broker.write(request)
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                    } catch {
                        if let commitPermit, let recordCommitGate {
                            await recordCommitGate.release(commitPermit)
                        }
                        throw error
                    }
                }
            case let .direct(pasteboard, changeSuppressor):
                let commitPermit = await recordCommitGate?.acquire()
                if recordCommitGate != nil, commitPermit == nil {
                    throw ClipboardAutoPasteError.featureDisabled
                }
                do {
                    lease = try performDirectWrite(
                        items,
                        expectedChangeCount: expectedChangeCount,
                        pasteboard: pasteboard,
                        changeSuppressor: changeSuppressor,
                        operationAllowed: operationAllowed
                    )
                    if let commitPermit, let recordCommitGate {
                        await recordCommitGate.release(commitPermit)
                    }
                } catch {
                    if let commitPermit, let recordCommitGate {
                        await recordCommitGate.release(commitPermit)
                    }
                    throw error
                }
            }
            let elapsedMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            Self.logger.info(
                "event=write-finished items=\(items.count, privacy: .public) representations=\(representationCount, privacy: .public) afterChangeCount=\(lease.changeCount, privacy: .public) generation=\(lease.brokerGeneration, privacy: .public) elapsedMS=\(elapsedMilliseconds, privacy: .public)"
            )
            return lease
        } catch ClipboardBrokerClientError.writeChanged {
            throw ClipboardAutoPasteError.pasteboardChanged
        } catch ClipboardBrokerClientError.writeFailed {
            throw ClipboardAutoPasteError.pasteboardWriteFailed
        } catch let error as ClipboardAutoPasteError {
            throw error
        } catch {
            let elapsedMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            Self.logger.error(
                "event=write-failed items=\(items.count, privacy: .public) representations=\(representationCount, privacy: .public) elapsedMS=\(elapsedMilliseconds, privacy: .public)"
            )
            throw ClipboardAutoPasteError.pasteboardWriteFailed
        }
    }

    private func performDirectWrite(
        _ items: [ClipboardPasteboardWriteItem],
        expectedChangeCount: Int?,
        pasteboard: any ClipboardPasteboardWriting,
        changeSuppressor: ClipboardPasteboardChangeSuppressor,
        operationAllowed: () -> Bool
    ) throws -> ClipboardPasteboardWriteLease {
        let originalChangeCount = pasteboard.changeCount
        if let expectedChangeCount, originalChangeCount != expectedChangeCount {
            throw ClipboardAutoPasteError.pasteboardChanged
        }
        // This is intentionally adjacent to the synchronous AppKit mutation.
        // Tests use the direct backend, so it must share the production
        // authorization boundary rather than checking only before preparation.
        guard !Task.isCancelled, operationAllowed() else {
            throw ClipboardAutoPasteError.featureDisabled
        }
        let succeeded = pasteboard.writeItems(items)
        let finalChangeCount = pasteboard.changeCount
        let changedCounts = Self.changedCounts(
            after: originalChangeCount,
            through: finalChangeCount
        )
        changeSuppressor.suppress(changedCounts)
        guard succeeded else {
            throw ClipboardAutoPasteError.pasteboardWriteFailed
        }
        return ClipboardPasteboardWriteLease(changeCount: finalChangeCount)
    }

    private func makeBrokerWriteRequest(
        _ items: [ClipboardPasteboardWriteItem],
        expectedChangeCount: Int?
    ) -> ClipboardBrokerWriteRequest {
        let brokerItems = items.map { item in
            ClipboardBrokerWriteItem(representations: item.representations.map {
                pasteboardType,
                representation in
                let value: ClipboardBrokerWriteRepresentation
                switch representation {
                case let .string(string):
                    value = .string(string)
                case let .data(data):
                    // Staging is intentionally deferred to ClipboardBrokerClient.
                    // This keeps all payload file I/O off the App's MainActor and
                    // lets an explicit write preempt a blocked passive request
                    // before any staging work starts.
                    value = .data(.inline(data))
                case let .propertyList(strings):
                    value = .stringList(strings)
                }
                return ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: pasteboardType.rawValue,
                    value: value
                )
            }, semanticFileURLString: item.semanticFileURL?.absoluteString)
        }
        return ClipboardBrokerWriteRequest(
            items: brokerItems,
            expectedChangeCount: expectedChangeCount
        )
    }

    private static func changedCounts(after original: Int, through final: Int) -> [Int] {
        guard final > original else { return [] }
        // A system write can advance more than once because clear and write are
        // separate AppKit mutations. Consume the complete bounded self-write.
        let lower = max(original + 1, final - 23)
        return Array(lower...final)
    }
}

@MainActor
final class ClipboardAutoPasteCoordinator {
    private static let pasteFallbackMaxWait: TimeInterval = 0.35
    private static let pasteFallbackRetryInterval: TimeInterval = 0.035
    private static let logger = Logger(subsystem: "app.blocks.app", category: "clipboard-paste")
    private let pasteboardWriter: ClipboardPasteboardWriter
    private let frontmostApplicationProvider: @MainActor () -> NSRunningApplication?
    private let focusSnapshotProvider: @MainActor (NSRunningApplication) -> ClipboardPasteTargetContext
    private let eventPostingAccess: @MainActor (Bool) -> Bool
    private static let optionalHelperClient = SelectionHelperClient()
    private let optionalTargetInspection: @MainActor (ClipboardPasteTargetContext) async -> SelectionHelperPasteTargetEditability
    private let pasteShortcutFactory: @MainActor () throws -> (keyDown: CGEvent, keyUp: CGEvent)
    private let pasteShortcutPoster: @MainActor ((keyDown: CGEvent, keyUp: CGEvent)) -> Void

    init(
        broker: (any ClipboardBrokerServing)? = nil,
        pasteboard: ClipboardPasteboardWriting? = nil,
        changeSuppressor: ClipboardPasteboardChangeSuppressor? = nil,
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = {
            ClipboardPasteTargetEligibility.eligibleApplication(
                NSWorkspace.shared.frontmostApplication
            )
        },
        focusSnapshot: @escaping @MainActor (NSRunningApplication) -> ClipboardPasteTargetContext = {
            ClipboardAutoPasteCoordinator.capturePasteTargetContext(application: $0)
        },
        eventPostingAccess: @escaping @MainActor (Bool) -> Bool = {
            ClipboardAutoPasteCoordinator.systemEventPostingAccess(prompt: $0)
        },
        optionalTargetInspection: @escaping @MainActor (ClipboardPasteTargetContext) async -> SelectionHelperPasteTargetEditability = { context in
            guard DistributionChannel.current.supportsSelectionHelper,
                  let bundle = context.target.bundleIdentifier else { return .unknown }
            let request = SelectionHelperPasteTargetRequest(
                requestID: UUID().uuidString,
                targetPID: context.target.processIdentifier,
                targetBundleIdentifier: bundle
            )
            guard let result = await ClipboardAutoPasteCoordinator.optionalHelperClient
                .inspectPasteTargetIfAvailable(request: request, timeout: 0.15),
                  result.requestID == request.requestID,
                  result.targetPID == request.targetPID,
                  result.targetBundleIdentifier == request.targetBundleIdentifier else { return .unknown }
            return result.editability
        },
        pasteShortcutFactory: @escaping @MainActor () throws -> (keyDown: CGEvent, keyUp: CGEvent) = {
            try ClipboardAutoPasteCoordinator.makePasteShortcut()
        },
        pasteShortcutPoster: @escaping @MainActor ((keyDown: CGEvent, keyUp: CGEvent)) -> Void = {
            ClipboardAutoPasteCoordinator.postPasteShortcut($0)
        }
    ) {
        if let pasteboard {
            pasteboardWriter = ClipboardPasteboardWriter(
                pasteboard: pasteboard,
                changeSuppressor: changeSuppressor
            )
        } else {
            pasteboardWriter = ClipboardPasteboardWriter(
                broker: broker ?? ClipboardBrokerClient.shared
            )
        }
        frontmostApplicationProvider = frontmostApplication
        focusSnapshotProvider = focusSnapshot
        self.eventPostingAccess = eventPostingAccess
        self.optionalTargetInspection = optionalTargetInspection
        self.pasteShortcutFactory = pasteShortcutFactory
        self.pasteShortcutPoster = pasteShortcutPoster
    }

    struct PasteResult: Equatable {
        let pasteboardChangeCountAfterWrite: Int
        let commandPosted: Bool
    }

    static func capturePasteTargetContext(application: NSRunningApplication) -> ClipboardPasteTargetContext {
        let target = ClipboardPasteTarget(application)
        let windowID = ClipboardPasteTargetEligibility.frontmostVisibleWindowID(
            processIdentifier: application.processIdentifier
        )
        logger.info("capture target=\(target.bundleIdentifier ?? "unknown", privacy: .public) route=window-preserving windowID=\(windowID ?? 0) launchIdentity=\(target.launchDate != nil)")
        return ClipboardPasteFocusSnapshot(target: target, windowID: windowID)
    }

    func copyToPasteboard(
        record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?,
        expectedPasteboardChangeCount: Int,
        operationID: UUID,
        operationAllowed: @escaping () -> Bool = { true },
        recordCommitGate: ClipboardRecordCommitGate? = nil
    ) async throws -> ClipboardAutoPasteCopyResult {
        guard operationAllowed() else {
            throw ClipboardAutoPasteError.featureDisabled
        }
        guard record.restorable else {
            throw ClipboardAutoPasteError.recordNotRestorable
        }
        guard let payload else {
            throw ClipboardAutoPasteError.payloadUnavailable
        }
        let pasteboardLease = try await pasteboardWriter.write(
            payload: payload,
            expectedChangeCount: expectedPasteboardChangeCount,
            origin: ClipboardPasteboardWriteOrigin(
                operationID: operationID,
                recordID: record.id,
                signatureSHA256: record.signatureSHA256
            ),
            operationAllowed: operationAllowed,
            requiresPreparedAuthorization: true,
            recordCommitGate: recordCommitGate
        )
        // A Broker commit can complete after its awaiting task is cancelled.
        // Return that physical truth, but never grant automatic-paste
        // permission unless the caller remains current at this boundary.
        return ClipboardAutoPasteCopyResult(
            pasteboardLease: pasteboardLease,
            mayContinueAutomaticPaste: !Task.isCancelled && operationAllowed()
        )
    }

    func dispatchPaste(
        targetContext: ClipboardPasteTargetContext?,
        pasteboardLease: ClipboardPasteboardWriteLease,
        promptForAccessibility: Bool = true,
        operationAllowed: @escaping () -> Bool = { true }
    ) async throws -> PasteResult {
        guard !Task.isCancelled, operationAllowed() else {
            throw partialFailure(.featureDisabled, lease: pasteboardLease)
        }
        try await ensurePasteboardOwnership(pasteboardLease)
        guard !Task.isCancelled, operationAllowed() else {
            throw partialFailure(.featureDisabled, lease: pasteboardLease)
        }
        guard let targetContext,
              let targetApplication = targetContext.runningApplication else {
            Self.logger.info("paste cancelled stage=target-unavailable-after-copy")
            throw partialFailure(.targetApplicationUnavailable, lease: pasteboardLease)
        }
        let target = targetContext.target
        guard targetIdentityMatches(targetApplication, expected: target) else {
            throw partialFailure(.targetApplicationUnavailable, lease: pasteboardLease)
        }
        guard eventPostingAccess(promptForAccessibility) else {
            Self.logger.info("paste cancelled stage=accessibility-denied-after-copy target=\(target.bundleIdentifier ?? "unknown", privacy: .public)")
            throw partialFailure(.accessibilityPermissionRequired, lease: pasteboardLease)
        }
        guard await waitForStableTargetFrontmost(targetApplication, expected: target) else {
            Self.logger.info(
                "paste cancelled stage=target-not-frontmost target=\(target.bundleIdentifier ?? "unknown", privacy: .public) windowID=\(targetContext.windowID ?? 0)"
            )
            throw partialFailure(.targetApplicationNotFrontmost, lease: pasteboardLease)
        }
        Self.logger.info(
            "paste route=window-preserving target=\(target.bundleIdentifier ?? "unknown", privacy: .public) windowID=\(targetContext.windowID ?? 0)"
        )
        guard focusStillMatchesCapturedTarget(targetContext, targetApplication: targetApplication, expected: target) else {
            throw partialFailure(.targetApplicationUnavailable, lease: pasteboardLease)
        }
        let inspection = await optionalTargetInspection(targetContext)
        if inspection == .nonEditable {
            Self.logger.info("paste cancelled stage=helper-confirmed-noneditable")
            throw partialFailure(.targetApplicationUnavailable, lease: pasteboardLease)
        }
        guard operationAllowed() else {
            throw partialFailure(.featureDisabled, lease: pasteboardLease)
        }
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 35_000_000)
        } catch {
            throw ClipboardAutoPastePartialFailure(
                reason: .featureDisabled,
                pasteboardLease: pasteboardLease
            )
        }
        guard !Task.isCancelled, operationAllowed() else {
            throw ClipboardAutoPastePartialFailure(
                reason: .featureDisabled,
                pasteboardLease: pasteboardLease
            )
        }
        try await ensurePasteboardOwnership(pasteboardLease)
        guard targetIdentityMatches(targetApplication, expected: target),
              frontmostApplicationProvider().map({
                  targetIdentityMatches($0, expected: target)
              }) == true else {
            throw ClipboardAutoPastePartialFailure(
                reason: .targetApplicationNotFrontmost,
                pasteboardLease: pasteboardLease
            )
        }
        let pasteShortcut: (keyDown: CGEvent, keyUp: CGEvent)
        do {
            pasteShortcut = try pasteShortcutFactory()
        } catch {
            throw ClipboardAutoPastePartialFailure(
                reason: .pasteEventFailed,
                pasteboardLease: pasteboardLease
            )
        }
        let isOperationAllowed = operationAllowed()
        guard eventPostingAccess(false) else {
            throw partialFailure(.accessibilityPermissionRequired, lease: pasteboardLease)
        }
        guard isOperationAllowed,
              focusStillMatchesCapturedTarget(
                  targetContext,
                  targetApplication: targetApplication,
                  expected: target
              ) else {
            let reason: ClipboardAutoPasteError = isOperationAllowed
                ? .targetApplicationUnavailable
                : .featureDisabled
            throw ClipboardAutoPastePartialFailure(
                reason: reason,
                pasteboardLease: pasteboardLease
            )
        }
        // The focus provider can synchronously observe a cancellation or an
        // authorization revocation. Keep this immediately adjacent to the
        // event post so no stale decision can send Cmd+V.
        guard !Task.isCancelled, operationAllowed() else {
            throw ClipboardAutoPastePartialFailure(
                reason: .featureDisabled,
                pasteboardLease: pasteboardLease
            )
        }
        pasteShortcutPoster(pasteShortcut)
        Self.logger.info(
            "paste command-posted route=session-event-tap target=\(target.bundleIdentifier ?? "unknown", privacy: .public) targetPID=\(target.processIdentifier)"
        )
        return PasteResult(pasteboardChangeCountAfterWrite: pasteboardLease.changeCount, commandPosted: true)
    }

    private func partialFailure(
        _ reason: ClipboardAutoPasteError,
        lease: ClipboardPasteboardWriteLease
    ) -> ClipboardAutoPastePartialFailure {
        ClipboardAutoPastePartialFailure(
            reason: reason,
            pasteboardLease: lease
        )
    }

    func writePlainText(
        _ text: String,
        origin: ClipboardPasteboardWriteOrigin? = nil,
        operationAllowed: @escaping () -> Bool = { true },
        requiresPreparedAuthorization: Bool = false,
        recordCommitGate: ClipboardRecordCommitGate? = nil
    ) async throws -> ClipboardPasteboardWriteLease {
        try await pasteboardWriter.writePlainText(
            text,
            origin: origin,
            operationAllowed: operationAllowed,
            requiresPreparedAuthorization: requiresPreparedAuthorization,
            recordCommitGate: recordCommitGate
        )
    }

    func currentPasteboardChangeCount() async throws -> Int {
        do {
            return try await pasteboardWriter.baseline()
        } catch {
            throw ClipboardAutoPasteError.pasteboardWriteFailed
        }
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        await pasteboardWriter.validate(lease)
    }

    private func waitForStableTargetFrontmost(
        _ targetApplication: NSRunningApplication,
        expected target: ClipboardPasteTarget
    ) async -> Bool {
        var stability = ClipboardTargetFrontmostStability(requiredConsecutiveMatches: 2)
        let deadline = Date().addingTimeInterval(Self.pasteFallbackMaxWait)
        repeat {
            guard !Task.isCancelled,
                  targetIdentityMatches(targetApplication, expected: target) else {
                return false
            }
            let frontmostApplication = frontmostApplicationProvider()
            let isExpectedTarget = frontmostApplication.map {
                targetIdentityMatches($0, expected: target)
            } == true
            if stability.observe(expectedTargetIsFrontmost: isExpectedTarget) {
                return true
            }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.pasteFallbackRetryInterval * 1_000_000_000)
                )
            } catch {
                return false
            }
        } while Date() < deadline
        return false
    }

    private func targetIdentityMatches(
        _ targetApplication: NSRunningApplication,
        expected target: ClipboardPasteTarget
    ) -> Bool {
        guard targetApplication.processIdentifier == target.processIdentifier,
              targetApplication.bundleIdentifier == target.bundleIdentifier,
              !targetApplication.isTerminated,
              targetApplication.launchDate == target.launchDate,
              let runningApplication = target.runningApplication else {
            return false
        }
        return runningApplication.processIdentifier == target.processIdentifier
            && runningApplication.bundleIdentifier == target.bundleIdentifier
    }

    /// Paste into the current caret in the captured window. AX objects may be
    /// absent or recreated; process lifetime and window identity must match.
    private func focusStillMatchesCapturedTarget(
        _ captured: ClipboardPasteTargetContext,
        targetApplication: NSRunningApplication,
        expected target: ClipboardPasteTarget
    ) -> Bool {
        guard targetIdentityMatches(targetApplication, expected: target),
              frontmostApplicationProvider().map({
                  targetIdentityMatches($0, expected: target)
              }) == true,
              let capturedWindow = captured.windowID, capturedWindow != 0 else {
            Self.logger.info("paste cancelled stage=routing-target-unverifiable")
            return false
        }
        let current = focusSnapshotProvider(targetApplication)
        guard current.target == target,
              current.windowID == capturedWindow else {
            Self.logger.info("paste cancelled stage=target-window-changed expectedWindow=\(capturedWindow) actualWindow=\(current.windowID ?? 0)")
            return false
        }
        return true
    }

    private func ensurePasteboardOwnership(
        _ lease: ClipboardPasteboardWriteLease
    ) async throws {
        guard await pasteboardWriter.validate(lease) else {
            Self.logger.info(
                "paste aborted stage=pasteboard-changed expected=\(lease.changeCount) generation=\(lease.brokerGeneration)"
            )
            throw ClipboardAutoPastePartialFailure(
                reason: .pasteboardChanged,
                pasteboardLease: lease
            )
        }
    }

    var hasEventPostingAccess: Bool { eventPostingAccess(false) }

    private static func systemEventPostingAccess(prompt: Bool) -> Bool {
        if CGPreflightPostEventAccess() { return true }
        guard prompt else { return false }
        return CGRequestPostEventAccess()
    }

    private static func makePasteShortcut() throws -> (keyDown: CGEvent, keyUp: CGEvent) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw ClipboardAutoPasteError.pasteEventFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return (keyDown, keyUp)
    }

    private static func postPasteShortcut(
        _ pasteShortcut: (keyDown: CGEvent, keyUp: CGEvent)
    ) {
        pasteShortcut.keyDown.post(tap: .cgSessionEventTap)
        pasteShortcut.keyUp.post(tap: .cgSessionEventTap)
    }

}
