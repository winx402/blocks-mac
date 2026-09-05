import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Security
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

typealias JSONObject = [String: Any]

struct ProbeMessageError: Error, CustomStringConvertible {
    let description: String
}

final class AsyncResultBox<Value>: @unchecked Sendable {
    var value: Value?
    var error: Error?
}

struct PasteboardFixturePayload {
    let kind: String
    var string: String?
    var rtfData: Data?
    var imageData: Data?
    var urlString: String?
    var fileURLString: String?
}

enum RegionSelectionOutcome {
    case selected(CGRect)
    case cancelled
    case timedOut
    case tooSmall(CGRect)
}

@MainActor
final class RegionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@MainActor
final class RegionSelectionController {
    private let minimumSize: CGFloat = 8
    private var windows: [NSWindow] = []
    private var keyEventMonitors: [Any] = []
    private(set) var outcome: RegionSelectionOutcome?

    func run(timeout: TimeInterval) -> RegionSelectionOutcome {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        showOverlayWindows()
        application.activate(ignoringOtherApps: true)

        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil && Date() < deadline {
            autoreleasepool {
                if let event = application.nextEvent(
                    matching: .any,
                    until: Date(timeIntervalSinceNow: 0.05),
                    inMode: .default,
                    dequeue: true
                ) {
                    application.sendEvent(event)
                }
            }
        }

        if outcome == nil {
            finish(.timedOut)
        }
        return outcome ?? .timedOut
    }

    private func showOverlayWindows() {
        windows = NSScreen.screens.map { screen in
            let window = RegionOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isOpaque = false
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.contentView = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: self)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            return window
        }
        installKeyEventMonitors()
    }

    private func installKeyEventMonitors() {
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }) {
            keyEventMonitors.append(localMonitor)
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.cancel()
                }
            }
        }) {
            keyEventMonitors.append(globalMonitor)
        }
    }

    func completeSelection(globalRect: CGRect) {
        let rect = globalRect.standardized
        if rect.width < minimumSize || rect.height < minimumSize {
            finish(.tooSmall(rect))
            return
        }
        finish(.selected(rect))
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ outcome: RegionSelectionOutcome) {
        guard self.outcome == nil else {
            return
        }
        self.outcome = outcome
        keyEventMonitors.forEach { NSEvent.removeMonitor($0) }
        keyEventMonitors.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

final class RegionSelectionView: NSView {
    private weak var controller: RegionSelectionController?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(frame: NSRect, controller: RegionSelectionController) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller?.cancel()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = event.locationInWindow
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = event.locationInWindow
        guard let window, let dragStart, let dragCurrent else {
            controller?.cancel()
            return
        }
        let localRect = CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
        let globalRect = localRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        controller?.completeSelection(globalRect: globalRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        dirtyRect.fill()

        guard let dragStart, let dragCurrent else {
            drawInstruction()
            return
        }

        let selection = CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        selection.fill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawInstruction() {
        let text = "Drag to select region  |  Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.86)
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        text.draw(at: point, withAttributes: attributes)
    }
}

func sha256Prefix(_ value: String, length: Int = 12) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
}

func sha256Prefix(data: Data, length: Int = 12) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
}

func auditID(probe: String, observations: JSONObject) -> String {
    let raw = "\(probe):\(observations):\(Date().timeIntervalSince1970)"
    return "probe_\(Int(Date().timeIntervalSince1970))_\(sha256Prefix(raw))"
}

func emit(
    ok: Bool,
    probe: String,
    status: String,
    promptRequested: Bool,
    observations: JSONObject = [:],
    warnings: [String] = []
) -> Never {
    let payload: JSONObject = [
        "ok": ok,
        "probe": probe,
        "status": status,
        "prompt_requested": promptRequested,
        "observations": observations,
        "warnings": warnings,
        "audit_id": auditID(probe: probe, observations: observations)
    ]

    do {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(ok ? 0 : 1)
    } catch {
        fputs("{\"ok\":false,\"probe\":\"\(probe)\",\"status\":\"json_encode_failed\"}\n", stderr)
        exit(1)
    }
}

func usage() -> Never {
    emit(
        ok: false,
        probe: "blocks.usage",
        status: "invalid_usage",
        promptRequested: false,
        observations: [
            "commands": [
                "blocks-screen --preflight|--request",
                "blocks-accessibility --check|--prompt",
                "blocks-pasteboard --summary|--include-text-preview|--formats",
                "blocks-pasteboard --fixture-roundtrip --kind text|rtf|image|url|file-url|all",
                "blocks-pasteboard --complex-fixture-roundtrip --kind html|multi|transient|file-list|all",
                "blocks-pasteboard --detection-patterns-fixture",
                "blocks-pasteboard --manual-complex-watch --seconds <n> --profile browser|office|design|password-manager [--exclude-frontmost]",
                "blocks-pasteboard --watch --seconds <n> [--exclude-bundle-id <id>]",
                "blocks-pasteboard --recorder-fixture-run --seconds <n> --store-name <name> --retention-seconds <n> --max-items <n>",
                "blocks-pasteboard --recorder-watch --seconds <n> --store-name <name> [--exclude-bundle-id <id>|--exclude-frontmost]",
                "blocks-pasteboard --recorder-inspect --store-name <name>",
                "blocks-pasteboard --recorder-reset --store-name <name>",
                "blocks-keychain --fixture-roundtrip --delete-after",
                "blocks-hotkey --register-defaults",
                "blocks-selection-copy --manual --send-copy",
                "blocks-capture --list",
                "blocks-capture --boundary-suite --write-png",
                "blocks-capture --display-index <n> [--rect x,y,w,h] --write-png",
                "blocks-capture --interactive-region --write-png [--timeout <seconds>]",
                "blocks-capture --window-index <n> --write-png"
            ]
        ]
    )
}

func pasteboardSummary(includeTextPreview: Bool) -> JSONObject {
    let pasteboard = NSPasteboard.general
    let typeNames = (pasteboard.types ?? []).map { $0.rawValue }.sorted()
    var observations: JSONObject = [
        "change_count": pasteboard.changeCount,
        "item_count": pasteboard.pasteboardItems?.count ?? 0,
        "types": typeNames
    ]

    if includeTextPreview {
        if let text = pasteboard.string(forType: .string) {
            observations["text_present"] = true
            observations["text_characters"] = text.count
            observations["text_sha256_12"] = sha256Prefix(text)
        } else {
            observations["text_present"] = false
            observations["text_characters"] = 0
        }
    }

    return observations
}

func pasteboardTypeNames(_ item: NSPasteboardItem) -> [String] {
    item.types.map { $0.rawValue }.sorted()
}

func dataSummary(_ data: Data) -> JSONObject {
    [
        "bytes": data.count,
        "sha256_12": sha256Prefix(data: data)
    ]
}

func imageDataSummary(_ data: Data, format: String) -> JSONObject {
    var summary = dataSummary(data)
    summary["format"] = format
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        if let width = properties[kCGImagePropertyPixelWidth] as? Int {
            summary["width"] = width
        }
        if let height = properties[kCGImagePropertyPixelHeight] as? Int {
            summary["height"] = height
        }
    }
    return summary
}

func urlSummary(_ raw: String, includeFixtureName: Bool) -> JSONObject {
    var summary: JSONObject = [
        "characters": raw.count,
        "sha256_12": sha256Prefix(raw)
    ]
    if let url = URL(string: raw) {
        summary["scheme"] = url.scheme ?? ""
        if let host = url.host {
            summary["host_characters"] = host.count
            summary["host_sha256_12"] = sha256Prefix(host)
        }
        if includeFixtureName {
            summary["last_path_component"] = url.lastPathComponent
        } else if !url.lastPathComponent.isEmpty {
            summary["last_path_component_characters"] = url.lastPathComponent.count
        }
    }
    return summary
}

func pasteboardItemKind(_ item: NSPasteboardItem) -> String {
    if item.data(forType: .png) != nil || item.data(forType: .tiff) != nil {
        return "image"
    }
    if item.data(forType: .rtf) != nil {
        return "rtf"
    }
    if item.string(forType: .fileURL) != nil {
        return "file-url"
    }
    if item.string(forType: .URL) != nil {
        return "url"
    }
    if item.string(forType: .string) != nil {
        return "text"
    }
    return "unknown"
}

func pasteboardItemRedactedSummary(index: Int, item: NSPasteboardItem, includeFixtureNames: Bool = false) -> JSONObject {
    var summary: JSONObject = [
        "index": index,
        "types": pasteboardTypeNames(item)
    ]

    if let text = item.string(forType: .string) {
        summary["text"] = [
            "characters": text.count,
            "sha256_12": sha256Prefix(text)
        ]
    }
    if let rtf = item.data(forType: .rtf) {
        summary["rtf"] = dataSummary(rtf)
    }
    if let html = item.data(forType: .html) {
        summary["html"] = dataSummary(html)
    }
    if let png = item.data(forType: .png) {
        summary["image"] = imageDataSummary(png, format: "png")
    } else if let tiff = item.data(forType: .tiff) {
        summary["image"] = imageDataSummary(tiff, format: "tiff")
    }
    if let url = item.string(forType: .URL) {
        summary["url"] = urlSummary(url, includeFixtureName: includeFixtureNames)
    }
    if let fileURL = item.string(forType: .fileURL) {
        summary["file_url"] = urlSummary(fileURL, includeFixtureName: includeFixtureNames)
    }

    return summary
}

func pasteboardFormatSnapshot(includeFixtureNames: Bool = false) -> JSONObject {
    let pasteboard = NSPasteboard.general
    let items = pasteboard.pasteboardItems ?? []
    let itemSummaries: [JSONObject] = items.enumerated().map { index, item in
        pasteboardItemRedactedSummary(index: index, item: item, includeFixtureNames: includeFixtureNames)
    }

    return [
        "change_count": pasteboard.changeCount,
        "item_count": items.count,
        "types": (pasteboard.types ?? []).map { $0.rawValue }.sorted(),
        "items": itemSummaries
    ]
}

func canonicalJSONString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return text
}

func fixtureDirectoryURL() -> URL {
    packageRootURL().appendingPathComponent("fixtures", isDirectory: true)
}

func fixtureRelativePath(_ url: URL) -> String {
    "tools/spikes/blocks_macos_probe/fixtures/\(url.lastPathComponent)"
}

func makeFixturePNGData() throws -> Data {
    let width = 64
    let height = 32
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ProbeMessageError(description: "fixture_png_context_failed")
    }

    context.setFillColor(CGColor(red: 0.12, green: 0.26, blue: 0.72, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.94, green: 0.74, blue: 0.22, alpha: 1.0))
    context.fill(CGRect(x: 8, y: 8, width: 48, height: 16))

    guard let image = context.makeImage() else {
        throw ProbeMessageError(description: "fixture_png_image_failed")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw ProbeMessageError(description: "fixture_png_destination_failed")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ProbeMessageError(description: "fixture_png_finalize_failed")
    }
    return data as Data
}

func writeFixtureFile(name: String, data: Data) throws -> URL {
    let directory = fixtureDirectoryURL()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    return url
}

func fixtureRTFData() throws -> Data {
    let text = "Blocks rich text fixture"
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.systemBlue
        ]
    )
    return try attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
}

func writePasteboardFixture(kind: String) throws -> JSONObject {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    var fixture: JSONObject = ["kind": kind]

    switch kind {
    case "text":
        let text = "Blocks clipboard text fixture"
        item.setString(text, forType: .string)
        fixture["text_characters"] = text.count
        fixture["text_sha256_12"] = sha256Prefix(text)
    case "rtf":
        let rtf = try fixtureRTFData()
        let fallback = "Blocks rich text fixture"
        item.setData(rtf, forType: .rtf)
        item.setString(fallback, forType: .string)
        fixture["rtf_bytes"] = rtf.count
        fixture["rtf_sha256_12"] = sha256Prefix(data: rtf)
        fixture["fallback_text_sha256_12"] = sha256Prefix(fallback)
    case "image":
        let png = try makeFixturePNGData()
        let url = try writeFixtureFile(name: "blocks-fixture-image.png", data: png)
        item.setData(png, forType: .png)
        fixture["image"] = imageDataSummary(png, format: "png")
        fixture["relative_path"] = fixtureRelativePath(url)
    case "url":
        let url = "https://example.com/blocks-pasteboard-fixture"
        item.setString(url, forType: .URL)
        item.setString(url, forType: .string)
        fixture["url"] = urlSummary(url, includeFixtureName: true)
    case "file-url":
        let fileURL = try writeFixtureFile(
            name: "blocks-fixture-file.txt",
            data: Data("Blocks fixture file reference\n".utf8)
        )
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.lastPathComponent, forType: .string)
        fixture["file_url"] = urlSummary(fileURL.absoluteString, includeFixtureName: true)
        fixture["relative_path"] = fixtureRelativePath(fileURL)
    default:
        throw ProbeMessageError(description: "unsupported_fixture_kind:\(kind)")
    }

    pasteboard.writeObjects([item])
    fixture["change_count_after_write"] = pasteboard.changeCount
    return fixture
}

func captureFixturePayload(kind: String) throws -> PasteboardFixturePayload {
    guard let item = NSPasteboard.general.pasteboardItems?.first else {
        throw ProbeMessageError(description: "fixture_payload_empty")
    }

    var payload = PasteboardFixturePayload(kind: kind)
    switch kind {
    case "text":
        guard let text = item.string(forType: .string) else {
            throw ProbeMessageError(description: "fixture_text_missing")
        }
        payload.string = text
    case "rtf":
        guard let rtf = item.data(forType: .rtf),
              let text = item.string(forType: .string) else {
            throw ProbeMessageError(description: "fixture_rtf_missing")
        }
        payload.rtfData = rtf
        payload.string = text
    case "image":
        guard let image = item.data(forType: .png) ?? item.data(forType: .tiff) else {
            throw ProbeMessageError(description: "fixture_image_missing")
        }
        payload.imageData = image
    case "url":
        guard let url = item.string(forType: .URL),
              let text = item.string(forType: .string) else {
            throw ProbeMessageError(description: "fixture_url_missing")
        }
        payload.urlString = url
        payload.string = text
    case "file-url":
        guard let fileURL = item.string(forType: .fileURL),
              let text = item.string(forType: .string) else {
            throw ProbeMessageError(description: "fixture_file_url_missing")
        }
        payload.fileURLString = fileURL
        payload.string = text
    default:
        throw ProbeMessageError(description: "unsupported_fixture_kind:\(kind)")
    }
    return payload
}

func restoreFixturePayload(_ payload: PasteboardFixturePayload) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let restored = NSPasteboardItem()

    switch payload.kind {
    case "text":
        guard let text = payload.string else {
            throw ProbeMessageError(description: "restore_text_missing")
        }
        restored.setString(text, forType: .string)
    case "rtf":
        guard let rtf = payload.rtfData,
              let text = payload.string else {
            throw ProbeMessageError(description: "restore_rtf_missing")
        }
        restored.setData(rtf, forType: .rtf)
        restored.setString(text, forType: .string)
    case "image":
        guard let image = payload.imageData else {
            throw ProbeMessageError(description: "restore_image_missing")
        }
        restored.setData(image, forType: .png)
    case "url":
        guard let url = payload.urlString,
              let text = payload.string else {
            throw ProbeMessageError(description: "restore_url_missing")
        }
        restored.setString(url, forType: .URL)
        restored.setString(text, forType: .string)
    case "file-url":
        guard let fileURL = payload.fileURLString,
              let text = payload.string else {
            throw ProbeMessageError(description: "restore_file_url_missing")
        }
        restored.setString(fileURL, forType: .fileURL)
        restored.setString(text, forType: .string)
    default:
        throw ProbeMessageError(description: "unsupported_fixture_kind:\(payload.kind)")
    }

    pasteboard.writeObjects([restored])
}

func roundtripFixture(kind: String) throws -> JSONObject {
    let fixture = try writePasteboardFixture(kind: kind)
    let firstSnapshot = pasteboardFormatSnapshot(includeFixtureNames: true)
    let firstItems = firstSnapshot["items"] as? [JSONObject] ?? []
    let firstSignature = canonicalJSONString(firstItems)
    let payload = try captureFixturePayload(kind: kind)

    try restoreFixturePayload(payload)
    let restoredSnapshot = pasteboardFormatSnapshot(includeFixtureNames: true)
    let restoredItems = restoredSnapshot["items"] as? [JSONObject] ?? []
    let restoredSignature = canonicalJSONString(restoredItems)

    return [
        "kind": kind,
        "fixture": fixture,
        "first_snapshot": firstSnapshot,
        "restored_snapshot": restoredSnapshot,
        "roundtrip_equal": firstSignature == restoredSignature
    ]
}

func validFixtureKinds(from raw: String) -> [String]? {
    let supported = ["text", "rtf", "image", "url", "file-url"]
    if raw == "all" {
        return supported
    }
    return supported.contains(raw) ? [raw] : nil
}

let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let autoGeneratedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
let sourcePasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.source")

func htmlFixtureData() -> Data {
    Data("<p><strong>Blocks</strong> complex fixture</p>".utf8)
}

func copyPasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
    let copy = NSPasteboardItem()
    for type in item.types {
        if let data = item.data(forType: type) {
            copy.setData(data, forType: type)
        } else if let string = item.string(forType: type) {
            copy.setString(string, forType: type)
        }
    }
    return copy
}

func writeComplexPasteboardFixture(kind: String) throws -> (fixture: JSONObject, items: [NSPasteboardItem]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var fixture: JSONObject = ["kind": kind]
    var items: [NSPasteboardItem] = []

    switch kind {
    case "html":
        let item = NSPasteboardItem()
        let html = htmlFixtureData()
        let fallback = "Blocks complex HTML fixture"
        item.setData(html, forType: .html)
        item.setString(fallback, forType: .string)
        fixture["html"] = dataSummary(html)
        fixture["fallback_text"] = [
            "characters": fallback.count,
            "sha256_12": sha256Prefix(fallback)
        ]
        items = [item]
    case "multi":
        let item = NSPasteboardItem()
        let html = htmlFixtureData()
        let rtf = try fixtureRTFData()
        let text = "Blocks multi-format fixture"
        let url = "https://example.com/blocks-multi-format"
        item.setString(text, forType: .string)
        item.setData(html, forType: .html)
        item.setData(rtf, forType: .rtf)
        item.setString(url, forType: .URL)
        fixture["text_sha256_12"] = sha256Prefix(text)
        fixture["html"] = dataSummary(html)
        fixture["rtf"] = dataSummary(rtf)
        fixture["url"] = urlSummary(url, includeFixtureName: true)
        items = [item]
    case "transient":
        let item = NSPasteboardItem()
        let text = "Blocks transient fixture"
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientPasteboardType)
        item.setData(Data(), forType: concealedPasteboardType)
        item.setData(Data(), forType: autoGeneratedPasteboardType)
        item.setString("app.blocks.spikes.fixture", forType: sourcePasteboardType)
        fixture["marker_types"] = [
            transientPasteboardType.rawValue,
            concealedPasteboardType.rawValue,
            autoGeneratedPasteboardType.rawValue,
            sourcePasteboardType.rawValue
        ]
        fixture["text_sha256_12"] = sha256Prefix(text)
        items = [item]
    case "file-list":
        let fileA = try writeFixtureFile(
            name: "blocks-complex-file-a.txt",
            data: Data("Blocks complex file fixture A\n".utf8)
        )
        let fileB = try writeFixtureFile(
            name: "blocks-complex-file-b.txt",
            data: Data("Blocks complex file fixture B\n".utf8)
        )
        items = [fileA, fileB].map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.lastPathComponent, forType: .string)
            return item
        }
        fixture["file_count"] = items.count
        fixture["relative_paths"] = [fixtureRelativePath(fileA), fixtureRelativePath(fileB)]
    default:
        throw ProbeMessageError(description: "unsupported_complex_fixture_kind:\(kind)")
    }

    pasteboard.writeObjects(items)
    fixture["change_count_after_write"] = pasteboard.changeCount
    fixture["item_count"] = items.count
    return (fixture, items)
}

func validComplexFixtureKinds(from raw: String) -> [String]? {
    let supported = ["html", "multi", "transient", "file-list"]
    if raw == "all" {
        return supported
    }
    return supported.contains(raw) ? [raw] : nil
}

func roundtripComplexFixture(kind: String) throws -> JSONObject {
    let written = try writeComplexPasteboardFixture(kind: kind)
    let firstSnapshot = pasteboardFormatSnapshot(includeFixtureNames: true)
    let firstSignature = canonicalJSONString(firstSnapshot["items"] as? [JSONObject] ?? [])

    let restoredItems = written.items.map { copyPasteboardItem($0) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(restoredItems)
    let restoredSnapshot = pasteboardFormatSnapshot(includeFixtureNames: true)
    let restoredSignature = canonicalJSONString(restoredSnapshot["items"] as? [JSONObject] ?? [])

    return [
        "kind": kind,
        "fixture": written.fixture,
        "first_snapshot": firstSnapshot,
        "restored_snapshot": restoredSnapshot,
        "roundtrip_equal": firstSignature == restoredSignature
    ]
}

func runComplexFixtureRoundtrip(args: [String]) -> Never {
    guard let rawKind = argumentValue("--kind", in: args),
          let kinds = validComplexFixtureKinds(from: rawKind) else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_complex_fixture_kind",
            promptRequested: false,
            observations: ["supported_kinds": ["html", "multi", "transient", "file-list", "all"]]
        )
    }

    do {
        let results = try kinds.map { try roundtripComplexFixture(kind: $0) }
        let allEqual = results.allSatisfy { ($0["roundtrip_equal"] as? Bool) == true }
        emit(
            ok: allEqual,
            probe: "blocks.pasteboard",
            status: allEqual ? "complex_fixture_roundtrip_passed" : "complex_fixture_roundtrip_mismatch",
            promptRequested: false,
            observations: [
                "kinds": kinds,
                "results": results,
                "current_clipboard_contains_last_fixture": true
            ],
            warnings: [
                "This probe overwrites the current pasteboard with low-sensitive fixture data and does not preserve previous pasteboard content.",
                "Transient and concealed marker types are represented as low-sensitive fixture markers only."
            ]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "complex_fixture_roundtrip_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

func runDetectionPatternsFixture() -> Never {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    let fixture = "https://example.com/p2k-search?q=blocks contact@example.com"
    item.setString(fixture, forType: .string)
    pasteboard.writeObjects([item])

    let patternNames = [
        "probable_web_url",
        "probable_web_search",
        "email_address",
        "link"
    ]
    let sdkSupportsDetectionPatterns: Bool
    if #available(macOS 15.4, *) {
        sdkSupportsDetectionPatterns = true
    } else {
        sdkSupportsDetectionPatterns = false
    }

    emit(
        ok: true,
        probe: "blocks.pasteboard",
        status: "detection_patterns_not_covered",
        promptRequested: false,
        observations: [
            "fixture": [
                "characters": fixture.count,
                "sha256_12": sha256Prefix(fixture)
            ],
            "pattern_names": patternNames,
            "sdk_supports_detection_patterns": sdkSupportsDetectionPatterns,
            "not_covered_reason": "Swift refined NSPasteboard detection-pattern API symbol names need a separate compile spike before runtime use."
        ],
        warnings: [
            "The command writes only a low-sensitive fixture and does not emit raw pasteboard content.",
            "Detection-pattern runtime invocation is intentionally marked not covered rather than guessed from raw content."
        ]
    )
}

func validManualComplexProfile(_ raw: String) -> Bool {
    ["browser", "office", "design", "password-manager"].contains(raw)
}

func runManualComplexWatch(args: [String]) -> Never {
    guard let seconds = parseIntArgument("--seconds", in: args), seconds > 0, seconds <= 120 else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_manual_complex_watch_seconds",
            promptRequested: false,
            observations: ["allowed_range_seconds": "1...120"]
        )
    }
    guard let profile = argumentValue("--profile", in: args), validManualComplexProfile(profile) else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_manual_complex_profile",
            promptRequested: false,
            observations: ["supported_profiles": ["browser", "office", "design", "password-manager"]]
        )
    }

    let initialFrontmost = frontmostApplicationSummary()
    let excludeBundleID = args.contains("--exclude-frontmost") ? initialFrontmost["bundle_id"] as? String : nil
    let pasteboard = NSPasteboard.general
    let startedAt = Date()
    let startedChangeCount = pasteboard.changeCount
    var lastChangeCount = startedChangeCount
    var events: [JSONObject] = []

    while Date().timeIntervalSince(startedAt) < Double(seconds) {
        usleep(250_000)
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else {
            continue
        }

        let app = frontmostApplicationSummary()
        let bundleID = app["bundle_id"] as? String
        let excluded = excludeBundleID != nil && excludeBundleID == bundleID
        var event: JSONObject = [
            "change_count": currentChangeCount,
            "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "profile": profile,
            "source_app": app,
            "excluded": excluded
        ]
        if excluded {
            event["snapshot_skipped"] = true
            event["skip_reason"] = "excluded_frontmost_bundle_id"
        } else {
            event["snapshot"] = pasteboardFormatSnapshot()
        }
        events.append(event)
        lastChangeCount = currentChangeCount
    }

    let status = events.isEmpty ? "manual_complex_watch_not_covered" : "manual_complex_watch_completed"
    var observations: JSONObject = [
        "profile": profile,
        "seconds": seconds,
        "started_change_count": startedChangeCount,
        "ended_change_count": pasteboard.changeCount,
        "exclude_bundle_id": excludeBundleID ?? "",
        "initial_frontmost_app": initialFrontmost,
        "event_count": events.count,
        "events": events
    ]
    if events.isEmpty {
        observations["not_covered_reason"] = "no_manual_sample_observed"
    }

    emit(
        ok: true,
        probe: "blocks.pasteboard",
        status: status,
        promptRequested: false,
        observations: observations,
        warnings: [
            "Use only low-sensitive dummy samples for manual browser, office, design, or password-manager profile checks.",
            "Snapshots contain redacted metadata only; raw content is not emitted."
        ]
    )
}

func frontmostApplicationSummary() -> JSONObject {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return ["available": false, "source_app_is_candidate": true]
    }
    return [
        "available": true,
        "bundle_id": app.bundleIdentifier ?? "",
        "name": app.localizedName ?? "",
        "pid": Int(app.processIdentifier),
        "source_app_is_candidate": true
    ]
}

let recorderSchemaVersion = "0.1.0"

func isoTimestamp(_ date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

func dateFromISOTimestamp(_ raw: String) -> Date? {
    ISO8601DateFormatter().date(from: raw)
}

func recorderDirectoryURL() -> URL {
    packageRootURL().appendingPathComponent("recorder", isDirectory: true)
}

func recorderRelativePath(_ url: URL) -> String {
    "tools/spikes/blocks_macos_probe/recorder/\(url.lastPathComponent)"
}

func isValidRecorderStoreName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64 else {
        return false
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return name.rangeOfCharacter(from: allowed.inverted) == nil
}

func recorderStoreURL(name: String) throws -> URL {
    guard isValidRecorderStoreName(name) else {
        throw ProbeMessageError(description: "invalid_store_name")
    }
    return recorderDirectoryURL().appendingPathComponent("\(name).json")
}

func defaultRecorderStore(name: String) -> JSONObject {
    [
        "schema_version": recorderSchemaVersion,
        "store_name": name,
        "created_at": isoTimestamp(),
        "records": [],
        "skipped_events": []
    ]
}

func loadRecorderStore(name: String) throws -> JSONObject {
    let url = try recorderStoreURL(name: name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return defaultRecorderStore(name: name)
    }
    let data = try Data(contentsOf: url)
    guard var store = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
        throw ProbeMessageError(description: "recorder_store_invalid_json")
    }
    if store["schema_version"] as? String != recorderSchemaVersion {
        throw ProbeMessageError(description: "recorder_store_schema_mismatch")
    }
    store["records"] = store["records"] as? [JSONObject] ?? []
    store["skipped_events"] = store["skipped_events"] as? [JSONObject] ?? []
    return store
}

func saveRecorderStore(_ store: JSONObject, name: String) throws -> URL {
    let directory = recorderDirectoryURL()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = try recorderStoreURL(name: name)
    let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    return url
}

func resetRecorderStore(name: String) throws -> Bool {
    let url = try recorderStoreURL(name: name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return false
    }
    try FileManager.default.removeItem(at: url)
    return true
}

func recorderRecords(from store: JSONObject) -> [JSONObject] {
    store["records"] as? [JSONObject] ?? []
}

func recorderSkippedEvents(from store: JSONObject) -> [JSONObject] {
    store["skipped_events"] as? [JSONObject] ?? []
}

func recordWithoutPayload(_ record: JSONObject) -> JSONObject {
    var redacted = record
    redacted.removeValue(forKey: "fixture_payload")
    return redacted
}

func redactedRecorderStoreSummary(_ store: JSONObject, storeURL: URL) -> JSONObject {
    let records = recorderRecords(from: store)
    let skipped = recorderSkippedEvents(from: store)
    return [
        "schema_version": store["schema_version"] as? String ?? "",
        "store_name": store["store_name"] as? String ?? "",
        "store_relative_path": recorderRelativePath(storeURL),
        "record_count": records.count,
        "skipped_event_count": skipped.count,
        "records": records.map { recordWithoutPayload($0) },
        "skipped_events": skipped
    ]
}

func recorderSignature(kind: String, types: [String], summary: JSONObject) -> String {
    let raw = canonicalJSONString([
        "kind": kind,
        "types": types,
        "summary": summary
    ])
    return sha256Prefix(raw)
}

func recorderFixturePayload(_ payload: PasteboardFixturePayload) -> JSONObject {
    var body: JSONObject = ["kind": payload.kind]
    if let string = payload.string {
        body["string"] = string
    }
    if let rtfData = payload.rtfData {
        body["rtf_base64"] = rtfData.base64EncodedString()
    }
    if let imageData = payload.imageData {
        body["image_base64"] = imageData.base64EncodedString()
    }
    if let urlString = payload.urlString {
        body["url_string"] = urlString
    }
    if let fileURLString = payload.fileURLString {
        body["file_url_string"] = fileURLString
    }
    return body
}

func pasteboardFixturePayload(from body: JSONObject) -> PasteboardFixturePayload? {
    guard let kind = body["kind"] as? String else {
        return nil
    }
    var payload = PasteboardFixturePayload(kind: kind)
    payload.string = body["string"] as? String
    if let rawRTF = body["rtf_base64"] as? String {
        payload.rtfData = Data(base64Encoded: rawRTF)
    }
    if let rawImage = body["image_base64"] as? String {
        payload.imageData = Data(base64Encoded: rawImage)
    }
    payload.urlString = body["url_string"] as? String
    payload.fileURLString = body["file_url_string"] as? String
    return payload
}

func recorderRecord(
    item: NSPasteboardItem,
    changeCount: Int,
    sourceApp: JSONObject,
    fixtureOwned: Bool,
    pinned: Bool,
    fixturePayload: JSONObject? = nil,
    createdAt: Date = Date()
) -> JSONObject {
    let types = pasteboardTypeNames(item)
    let kind = pasteboardItemKind(item)
    let summary = pasteboardItemRedactedSummary(index: 0, item: item, includeFixtureNames: fixtureOwned)
    let signature = recorderSignature(kind: kind, types: types, summary: summary)
    var record: JSONObject = [
        "id": "rec_\(Int(createdAt.timeIntervalSince1970))_\(signature)",
        "created_at": isoTimestamp(createdAt),
        "change_count": changeCount,
        "kind": kind,
        "types": types,
        "source_app": sourceApp,
        "signature_sha256_12": signature,
        "fixture_owned": fixtureOwned,
        "pinned": pinned,
        "restorable": fixturePayload != nil,
        "summary": summary
    ]
    if let fixturePayload {
        record["fixture_payload"] = fixturePayload
    }
    return record
}

func appendRecorderRecord(_ record: JSONObject, to records: inout [JSONObject]) -> Bool {
    let signature = record["signature_sha256_12"] as? String
    let duplicate = records.contains { existing in
        (existing["signature_sha256_12"] as? String) == signature
    }
    if duplicate {
        return false
    }
    records.append(record)
    return true
}

func staleRecorderRecord(id: String, pinned: Bool, retentionSeconds: Int) -> JSONObject {
    let createdAt = Date().addingTimeInterval(-Double(retentionSeconds + 60))
    let signature = sha256Prefix(id)
    return [
        "id": "rec_\(id)_\(signature)",
        "created_at": isoTimestamp(createdAt),
        "change_count": -1,
        "kind": "text",
        "types": [NSPasteboard.PasteboardType.string.rawValue],
        "source_app": [
            "available": false,
            "source_app_is_candidate": true
        ],
        "signature_sha256_12": signature,
        "fixture_owned": true,
        "pinned": pinned,
        "restorable": false,
        "summary": [
            "synthetic": id,
            "redacted": true
        ]
    ]
}

func applyRecorderRetention(records: [JSONObject], retentionSeconds: Int, maxItems: Int) -> (records: [JSONObject], expiredRemoved: Int, maxItemsRemoved: Int) {
    let now = Date()
    var expiredRemoved = 0
    let retainedByAge = records.filter { record in
        let pinned = record["pinned"] as? Bool ?? false
        guard !pinned,
              let rawCreatedAt = record["created_at"] as? String,
              let createdAt = dateFromISOTimestamp(rawCreatedAt) else {
            return true
        }
        let expired = now.timeIntervalSince(createdAt) > Double(retentionSeconds)
        if expired {
            expiredRemoved += 1
        }
        return !expired
    }

    guard retainedByAge.count > maxItems else {
        return (retainedByAge, expiredRemoved, 0)
    }

    let pinnedRecords = retainedByAge.filter { ($0["pinned"] as? Bool) == true }
    let unpinnedRecords = retainedByAge
        .filter { ($0["pinned"] as? Bool) != true }
        .sorted {
            let lhs = dateFromISOTimestamp($0["created_at"] as? String ?? "") ?? Date.distantPast
            let rhs = dateFromISOTimestamp($1["created_at"] as? String ?? "") ?? Date.distantPast
            return lhs > rhs
        }
    let allowedUnpinned = max(0, maxItems - pinnedRecords.count)
    let keptUnpinned = Array(unpinnedRecords.prefix(allowedUnpinned))
    let removedByMaxItems = max(0, unpinnedRecords.count - keptUnpinned.count)

    let finalRecords = (pinnedRecords + keptUnpinned).sorted {
        let lhs = dateFromISOTimestamp($0["created_at"] as? String ?? "") ?? Date.distantPast
        let rhs = dateFromISOTimestamp($1["created_at"] as? String ?? "") ?? Date.distantPast
        return lhs < rhs
    }
    return (finalRecords, expiredRemoved, removedByMaxItems)
}

func searchRecorderRecords(_ records: [JSONObject], query: String) -> [JSONObject] {
    let lowered = query.lowercased()
    return records.filter { record in
        canonicalJSONString(recordWithoutPayload(record)).lowercased().contains(lowered)
    }
}

func verifyRecorderRestore(from records: [JSONObject]) -> Bool {
    guard let record = records.first(where: { ($0["restorable"] as? Bool) == true }),
          let payloadBody = record["fixture_payload"] as? JSONObject,
          let payload = pasteboardFixturePayload(from: payloadBody) else {
        return false
    }

    do {
        try restoreFixturePayload(payload)
        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            return false
        }
        let restoredRecord = recorderRecord(
            item: item,
            changeCount: NSPasteboard.general.changeCount,
            sourceApp: frontmostApplicationSummary(),
            fixtureOwned: true,
            pinned: false,
            fixturePayload: payloadBody
        )
        return (restoredRecord["signature_sha256_12"] as? String) == (record["signature_sha256_12"] as? String)
    } catch {
        return false
    }
}

func recorderStoreNameOrEmit(args: [String]) -> String {
    guard let name = argumentValue("--store-name", in: args), isValidRecorderStoreName(name) else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_recorder_store_name",
            promptRequested: false,
            observations: ["allowed": "1...64 chars, A-Z, a-z, 0-9, dot, underscore or hyphen"]
        )
    }
    return name
}

func recorderSecondsOrEmit(args: [String], maximum: Int = 120) -> Int {
    guard let seconds = parseIntArgument("--seconds", in: args), seconds > 0, seconds <= maximum else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_recorder_seconds",
            promptRequested: false,
            observations: ["allowed_range_seconds": "1...\(maximum)"]
        )
    }
    return seconds
}

func runRecorderFixture(args: [String]) -> Never {
    let storeName = recorderStoreNameOrEmit(args: args)
    let seconds = recorderSecondsOrEmit(args: args)
    guard let retentionSeconds = parseIntArgument("--retention-seconds", in: args), retentionSeconds >= 0 else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_retention_seconds",
            promptRequested: false,
            observations: ["allowed_range_seconds": "0..."]
        )
    }
    guard let maxItems = parseIntArgument("--max-items", in: args), maxItems > 0 else {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_max_items",
            promptRequested: false,
            observations: ["allowed_range": "1..."]
        )
    }

    do {
        _ = try resetRecorderStore(name: storeName)
        var store = defaultRecorderStore(name: storeName)
        var records: [JSONObject] = []
        var storedCount = 0
        var duplicateSkippedCount = 0
        let fixtureKinds = ["text", "rtf", "image", "url", "file-url", "text"]
        let interval = Double(seconds) / Double(fixtureKinds.count)

        for kind in fixtureKinds {
            _ = try writePasteboardFixture(kind: kind)
            let fixturePayload = recorderFixturePayload(try captureFixturePayload(kind: kind))
            guard let item = NSPasteboard.general.pasteboardItems?.first else {
                throw ProbeMessageError(description: "recorder_fixture_item_missing")
            }
            let record = recorderRecord(
                item: item,
                changeCount: NSPasteboard.general.changeCount,
                sourceApp: frontmostApplicationSummary(),
                fixtureOwned: true,
                pinned: false,
                fixturePayload: fixturePayload
            )
            if appendRecorderRecord(record, to: &records) {
                storedCount += 1
            } else {
                duplicateSkippedCount += 1
            }
            usleep(useconds_t(max(0.1, interval) * 1_000_000))
        }

        records.append(staleRecorderRecord(id: "expired_unpinned_fixture", pinned: false, retentionSeconds: retentionSeconds))
        records.append(staleRecorderRecord(id: "expired_pinned_fixture", pinned: true, retentionSeconds: retentionSeconds))
        let cleanup = applyRecorderRetention(records: records, retentionSeconds: retentionSeconds, maxItems: maxItems)
        let finalRecords = cleanup.records
        let searchHits = searchRecorderRecords(finalRecords, query: "text")
        let restoreVerified = verifyRecorderRestore(from: finalRecords)
        let pinnedPreserved = finalRecords.contains { ($0["id"] as? String)?.contains("expired_pinned_fixture") == true }

        store["records"] = finalRecords
        store["skipped_events"] = []
        let storeURL = try saveRecorderStore(store, name: storeName)
        let ok = storedCount > 0 &&
            duplicateSkippedCount > 0 &&
            !searchHits.isEmpty &&
            cleanup.expiredRemoved > 0 &&
            pinnedPreserved &&
            restoreVerified

        emit(
            ok: ok,
            probe: "blocks.pasteboard",
            status: ok ? "recorder_fixture_passed" : "recorder_fixture_failed",
            promptRequested: false,
            observations: [
                "store_name": storeName,
                "store_relative_path": recorderRelativePath(storeURL),
                "seconds_requested": seconds,
                "retention_seconds": retentionSeconds,
                "max_items": maxItems,
                "stored_count": storedCount,
                "duplicate_skipped_count": duplicateSkippedCount,
                "expired_removed_count": cleanup.expiredRemoved,
                "max_items_removed_count": cleanup.maxItemsRemoved,
                "pinned_preserved": pinnedPreserved,
                "search_query": "text",
                "search_hit_count": searchHits.count,
                "restore_verified": restoreVerified,
                "store": redactedRecorderStoreSummary(store, storeURL: storeURL)
            ],
            warnings: [
                "This fixture run overwrites the current pasteboard with low-sensitive fixture data.",
                "Fixture payloads are stored only in the ignored local recorder directory and are redacted from probe output."
            ]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "recorder_fixture_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

func runRecorderWatch(args: [String]) -> Never {
    let storeName = recorderStoreNameOrEmit(args: args)
    let seconds = recorderSecondsOrEmit(args: args)
    if args.contains("--exclude-frontmost") && argumentValue("--exclude-bundle-id", in: args) != nil {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "invalid_recorder_exclusion",
            promptRequested: false,
            observations: ["reason": "Use either --exclude-frontmost or --exclude-bundle-id, not both."]
        )
    }

    do {
        var store = try loadRecorderStore(name: storeName)
        var records = recorderRecords(from: store)
        var skippedEvents = recorderSkippedEvents(from: store)
        let initialFrontmost = frontmostApplicationSummary()
        let excludeBundleID = argumentValue("--exclude-bundle-id", in: args)
            ?? (args.contains("--exclude-frontmost") ? initialFrontmost["bundle_id"] as? String : nil)
        let pasteboard = NSPasteboard.general
        let startedAt = Date()
        let startedChangeCount = pasteboard.changeCount
        var lastChangeCount = startedChangeCount
        var events: [JSONObject] = []
        var storedCount = 0
        var duplicateSkippedCount = 0
        var skippedCount = 0

        while Date().timeIntervalSince(startedAt) < Double(seconds) {
            usleep(250_000)
            let currentChangeCount = pasteboard.changeCount
            guard currentChangeCount != lastChangeCount else {
                continue
            }

            let app = frontmostApplicationSummary()
            let bundleID = app["bundle_id"] as? String
            let excluded = excludeBundleID != nil && excludeBundleID == bundleID
            var event: JSONObject = [
                "change_count": currentChangeCount,
                "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                "source_app": app,
                "excluded": excluded
            ]

            if excluded {
                skippedCount += 1
                event["snapshot_skipped"] = true
                event["skip_reason"] = "excluded_bundle_id"
                skippedEvents.append(event)
            } else if let item = pasteboard.pasteboardItems?.first {
                let record = recorderRecord(
                    item: item,
                    changeCount: currentChangeCount,
                    sourceApp: app,
                    fixtureOwned: false,
                    pinned: false
                )
                if appendRecorderRecord(record, to: &records) {
                    storedCount += 1
                    event["record"] = recordWithoutPayload(record)
                } else {
                    duplicateSkippedCount += 1
                    event["duplicate_skipped"] = true
                }
            } else {
                event["snapshot_skipped"] = true
                event["skip_reason"] = "empty_pasteboard_items"
            }

            events.append(event)
            lastChangeCount = currentChangeCount
        }

        store["records"] = records
        store["skipped_events"] = skippedEvents
        let storeURL = try saveRecorderStore(store, name: storeName)
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "recorder_watch_completed",
            promptRequested: false,
            observations: [
                "store_name": storeName,
                "store_relative_path": recorderRelativePath(storeURL),
                "seconds": seconds,
                "started_change_count": startedChangeCount,
                "ended_change_count": pasteboard.changeCount,
                "exclude_bundle_id": excludeBundleID ?? "",
                "initial_frontmost_app": initialFrontmost,
                "event_count": events.count,
                "stored_count": storedCount,
                "duplicate_skipped_count": duplicateSkippedCount,
                "skipped_count": skippedCount,
                "events": events
            ],
            warnings: [
                "Real pasteboard events are stored as redacted metadata only; raw content and restorable payloads are not stored.",
                "source_app is only a P2 candidate based on the frontmost application observed near changeCount updates."
            ]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "recorder_watch_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

func runRecorderInspect(args: [String]) -> Never {
    let storeName = recorderStoreNameOrEmit(args: args)
    do {
        let store = try loadRecorderStore(name: storeName)
        let storeURL = try recorderStoreURL(name: storeName)
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "recorder_store_redacted",
            promptRequested: false,
            observations: redactedRecorderStoreSummary(store, storeURL: storeURL),
            warnings: ["Fixture payloads, if present in the ignored local store, are redacted from inspect output."]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "recorder_inspect_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

func runRecorderReset(args: [String]) -> Never {
    let storeName = recorderStoreNameOrEmit(args: args)
    do {
        let removed = try resetRecorderStore(name: storeName)
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: removed ? "recorder_store_removed" : "recorder_store_absent",
            promptRequested: false,
            observations: [
                "store_name": storeName,
                "removed": removed
            ]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.pasteboard",
            status: "recorder_reset_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

let keychainFixtureService = "app.blocks.provider.p2e"
let keychainFixtureAccount = "mock-api:p2e-dummy"
let keychainFixtureSecretV1 = "blocks-p2e-dummy-secret-v1"
let keychainFixtureSecretV2 = "blocks-p2e-dummy-secret-v2"

func osStatusName(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess:
        return "errSecSuccess"
    case errSecItemNotFound:
        return "errSecItemNotFound"
    case errSecDuplicateItem:
        return "errSecDuplicateItem"
    case errSecAuthFailed:
        return "errSecAuthFailed"
    case errSecInteractionNotAllowed:
        return "errSecInteractionNotAllowed"
    default:
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus(\(status))"
    }
}

func osStatusSummary(_ status: OSStatus) -> JSONObject {
    [
        "code": status,
        "name": osStatusName(status),
        "ok": status == errSecSuccess
    ]
}

func secretSummary(_ value: String) -> JSONObject {
    let data = Data(value.utf8)
    return [
        "characters": value.count,
        "bytes": data.count,
        "sha256_12": sha256Prefix(data: data)
    ]
}

func keychainBaseQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainFixtureService,
        kSecAttrAccount as String: keychainFixtureAccount
    ]
}

func keychainReadSecretSummary() -> (status: OSStatus, summary: JSONObject) {
    var query = keychainBaseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        return (status, [:])
    }

    return (
        status,
        [
            "bytes": data.count,
            "sha256_12": sha256Prefix(data: data),
            "utf8_decodable": String(data: data, encoding: .utf8) != nil
        ]
    )
}

func runKeychainFixtureRoundtrip() -> Never {
    let deleteQuery = keychainBaseQuery()
    let preDeleteStatus = SecItemDelete(deleteQuery as CFDictionary)

    var addQuery = keychainBaseQuery()
    addQuery[kSecValueData as String] = Data(keychainFixtureSecretV1.utf8)
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

    let readAfterAdd = keychainReadSecretSummary()

    let updateAttributes: [String: Any] = [
        kSecValueData as String: Data(keychainFixtureSecretV2.utf8)
    ]
    let updateStatus = SecItemUpdate(keychainBaseQuery() as CFDictionary, updateAttributes as CFDictionary)

    let readAfterUpdate = keychainReadSecretSummary()
    let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
    let readAfterDelete = keychainReadSecretSummary()

    let expectedReadV1 = secretSummary(keychainFixtureSecretV1)
    let expectedReadV2 = secretSummary(keychainFixtureSecretV2)
    let readAddMatches = (readAfterAdd.summary["sha256_12"] as? String) == (expectedReadV1["sha256_12"] as? String)
    let readUpdateMatches = (readAfterUpdate.summary["sha256_12"] as? String) == (expectedReadV2["sha256_12"] as? String)
    let cleanedUp = readAfterDelete.status == errSecItemNotFound
    let preDeleteAllowed = preDeleteStatus == errSecSuccess || preDeleteStatus == errSecItemNotFound

    let steps: [JSONObject] = [
        [
            "step": "pre_delete_existing_fixture",
            "status": osStatusSummary(preDeleteStatus),
            "accepted": preDeleteAllowed
        ],
        [
            "step": "add_fixture_secret",
            "status": osStatusSummary(addStatus),
            "expected_secret": expectedReadV1
        ],
        [
            "step": "read_after_add",
            "status": osStatusSummary(readAfterAdd.status),
            "secret": readAfterAdd.summary,
            "matches_expected": readAddMatches
        ],
        [
            "step": "update_fixture_secret",
            "status": osStatusSummary(updateStatus),
            "expected_secret": expectedReadV2
        ],
        [
            "step": "read_after_update",
            "status": osStatusSummary(readAfterUpdate.status),
            "secret": readAfterUpdate.summary,
            "matches_expected": readUpdateMatches
        ],
        [
            "step": "delete_fixture_secret",
            "status": osStatusSummary(deleteStatus)
        ],
        [
            "step": "read_after_delete",
            "status": osStatusSummary(readAfterDelete.status),
            "missing_expected": cleanedUp
        ]
    ]

    let ok = preDeleteAllowed &&
        addStatus == errSecSuccess &&
        readAfterAdd.status == errSecSuccess &&
        readAddMatches &&
        updateStatus == errSecSuccess &&
        readAfterUpdate.status == errSecSuccess &&
        readUpdateMatches &&
        deleteStatus == errSecSuccess &&
        cleanedUp

    emit(
        ok: ok,
        probe: "blocks.keychain",
        status: ok ? "fixture_roundtrip_passed" : "fixture_roundtrip_failed",
        promptRequested: false,
        observations: [
            "service": keychainFixtureService,
            "account": keychainFixtureAccount,
            "steps": steps,
            "cleanup_verified": cleanedUp
        ],
        warnings: [
            "Only fixed low-sensitive dummy secrets are used.",
            "Secret values are never emitted; output contains length and short hashes only."
        ]
    )
}

func runKeychain(args: [String]) -> Never {
    if args.contains("--fixture-roundtrip") {
        guard args.contains("--delete-after") else {
            emit(
                ok: false,
                probe: "blocks.keychain",
                status: "missing_delete_after",
                promptRequested: false,
                warnings: ["P2-E requires --delete-after so the Keychain fixture is cleaned up in the same command."]
            )
        }
        runKeychainFixtureRoundtrip()
    }

    usage()
}

func runScreen(args: [String]) -> Never {
    if args.contains("--preflight") {
        let authorized = CGPreflightScreenCaptureAccess()
        emit(
            ok: true,
            probe: "blocks.screen",
            status: authorized ? "authorized" : "not_authorized",
            promptRequested: false,
            observations: ["authorized": authorized]
        )
    }

    if args.contains("--request") {
        let authorized = CGRequestScreenCaptureAccess()
        emit(
            ok: true,
            probe: "blocks.screen",
            status: authorized ? "authorized" : "not_authorized_or_pending",
            promptRequested: true,
            observations: ["authorized": authorized],
            warnings: authorized ? [] : ["User approval may require System Settings and app restart before later probes succeed."]
        )
    }

    usage()
}

func runAccessibility(args: [String]) -> Never {
    if args.contains("--check") {
        let trusted = AXIsProcessTrusted()
        emit(
            ok: true,
            probe: "blocks.accessibility",
            status: trusted ? "trusted" : "not_trusted",
            promptRequested: false,
            observations: ["trusted": trusted]
        )
    }

    if args.contains("--prompt") {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        emit(
            ok: true,
            probe: "blocks.accessibility",
            status: trusted ? "trusted" : "not_trusted_or_pending",
            promptRequested: true,
            observations: ["trusted": trusted],
            warnings: trusted ? [] : ["User approval may require System Settings and relaunch before later probes succeed."]
        )
    }

    usage()
}

func runPasteboard(args: [String]) -> Never {
    if args.contains("--recorder-fixture-run") {
        runRecorderFixture(args: args)
    }

    if args.contains("--recorder-watch") {
        runRecorderWatch(args: args)
    }

    if args.contains("--recorder-inspect") {
        runRecorderInspect(args: args)
    }

    if args.contains("--recorder-reset") {
        runRecorderReset(args: args)
    }

    if args.contains("--complex-fixture-roundtrip") {
        runComplexFixtureRoundtrip(args: args)
    }

    if args.contains("--detection-patterns-fixture") {
        runDetectionPatternsFixture()
    }

    if args.contains("--manual-complex-watch") {
        runManualComplexWatch(args: args)
    }

    if args.contains("--formats") {
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "formats_redacted",
            promptRequested: false,
            observations: pasteboardFormatSnapshot(),
            warnings: ["Only lengths, types, dimensions and short hashes are emitted; raw pasteboard content is omitted."]
        )
    }

    if args.contains("--fixture-roundtrip") {
        guard let rawKind = argumentValue("--kind", in: args),
              let kinds = validFixtureKinds(from: rawKind) else {
            emit(
                ok: false,
                probe: "blocks.pasteboard",
                status: "invalid_fixture_kind",
                promptRequested: false,
                observations: ["supported_kinds": ["text", "rtf", "image", "url", "file-url", "all"]]
            )
        }

        do {
            let results = try kinds.map { try roundtripFixture(kind: $0) }
            let allEqual = results.allSatisfy { ($0["roundtrip_equal"] as? Bool) == true }
            emit(
                ok: allEqual,
                probe: "blocks.pasteboard",
                status: allEqual ? "fixture_roundtrip_passed" : "fixture_roundtrip_mismatch",
                promptRequested: false,
                observations: [
                    "kinds": kinds,
                    "results": results,
                    "current_clipboard_contains_last_fixture": true
                ],
                warnings: [
                    "This probe overwrites the current pasteboard with low-sensitive fixture data and does not preserve the previous pasteboard content."
                ]
            )
        } catch {
            emit(
                ok: false,
                probe: "blocks.pasteboard",
                status: "fixture_roundtrip_failed",
                promptRequested: false,
                observations: ["error": errorSummary(error)]
            )
        }
    }

    if args.contains("--watch") {
        guard let seconds = parseIntArgument("--seconds", in: args), seconds > 0, seconds <= 60 else {
            emit(
                ok: false,
                probe: "blocks.pasteboard",
                status: "invalid_watch_seconds",
                promptRequested: false,
                observations: ["allowed_range_seconds": "1...60"]
            )
        }

        let excludedBundleID = argumentValue("--exclude-bundle-id", in: args)
        let pasteboard = NSPasteboard.general
        let startedAt = Date()
        let startedChangeCount = pasteboard.changeCount
        var lastChangeCount = startedChangeCount
        var events: [JSONObject] = []

        while Date().timeIntervalSince(startedAt) < Double(seconds) {
            usleep(250_000)
            let currentChangeCount = pasteboard.changeCount
            guard currentChangeCount != lastChangeCount else {
                continue
            }

            let app = frontmostApplicationSummary()
            let bundleID = app["bundle_id"] as? String
            let excluded = excludedBundleID != nil && excludedBundleID == bundleID
            var event: JSONObject = [
                "change_count": currentChangeCount,
                "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                "source_app": app,
                "excluded": excluded
            ]

            if excluded {
                event["snapshot_skipped"] = true
            } else {
                event["snapshot"] = pasteboardFormatSnapshot()
            }

            events.append(event)
            lastChangeCount = currentChangeCount
        }

        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "watch_completed",
            promptRequested: false,
            observations: [
                "seconds": seconds,
                "started_change_count": startedChangeCount,
                "ended_change_count": pasteboard.changeCount,
                "exclude_bundle_id": excludedBundleID ?? "",
                "event_count": events.count,
                "events": events
            ],
            warnings: ["source_app is only a P2 candidate based on the frontmost application observed near changeCount updates."]
        )
    }

    if args.contains("--summary") {
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "summary_only",
            promptRequested: false,
            observations: pasteboardSummary(includeTextPreview: false)
        )
    }

    if args.contains("--include-text-preview") {
        emit(
            ok: true,
            probe: "blocks.pasteboard",
            status: "text_preview_redacted",
            promptRequested: false,
            observations: pasteboardSummary(includeTextPreview: true),
            warnings: ["Text content was read only to calculate length and a short hash; raw content is not emitted."]
        )
    }

    usage()
}

func fourCharCode(_ value: String) -> OSType {
    var result: UInt32 = 0
    for byte in value.utf8.prefix(4) {
        result = (result << 8) + UInt32(byte)
    }
    return result
}

func registerAndReleaseHotKey(keyCode: Int, id: UInt32, label: String) -> JSONObject {
    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: fourCharCode("JDTP"), id: id)
    let status = RegisterEventHotKey(
        UInt32(keyCode),
        UInt32(optionKey),
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &hotKeyRef
    )

    var unregistered = false
    if let hotKeyRef {
        UnregisterEventHotKey(hotKeyRef)
        unregistered = true
    }

    return [
        "label": label,
        "key_code": keyCode,
        "modifiers": "option",
        "os_status": status,
        "registered": status == noErr,
        "released": unregistered
    ]
}

func runHotKey(args: [String]) -> Never {
    if args.contains("--register-defaults") {
        let results = [
            registerAndReleaseHotKey(keyCode: kVK_ANSI_A, id: 1, label: "Option+A"),
            registerAndReleaseHotKey(keyCode: kVK_ANSI_V, id: 2, label: "Option+V")
        ]
        let failed = results.contains { ($0["registered"] as? Bool) != true }
        emit(
            ok: true,
            probe: "blocks.hotkey",
            status: failed ? "registration_failed_or_conflicted" : "registered_and_released",
            promptRequested: false,
            observations: ["hotkeys": results],
            warnings: failed ? ["Non-zero OSStatus may indicate conflict or unsupported registration context."] : []
        )
    }

    usage()
}

func sendCopyShortcut() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
        return
    }
    let keyCode = CGKeyCode(kVK_ANSI_C)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

func runSelectionCopy(args: [String]) -> Never {
    guard args.contains("--manual"), args.contains("--send-copy") else {
        usage()
    }

    let trusted = AXIsProcessTrusted()
    let before = NSPasteboard.general.changeCount
    if !trusted {
        emit(
            ok: true,
            probe: "blocks.selection_copy",
            status: "needs_accessibility",
            promptRequested: false,
            observations: [
                "accessibility_trusted": false,
                "pasteboard_change_count_before": before
            ],
            warnings: ["Grant Accessibility before running the manual selected-text copy probe."]
        )
    }

    sendCopyShortcut()
    usleep(250_000)

    var observations = pasteboardSummary(includeTextPreview: true)
    observations["accessibility_trusted"] = trusted
    observations["pasteboard_change_count_before"] = before
    observations["pasteboard_changed"] = (observations["change_count"] as? Int ?? before) != before

    emit(
        ok: true,
        probe: "blocks.selection_copy",
        status: "copy_sent_redacted",
        promptRequested: false,
        observations: observations,
        warnings: ["Command+C was sent to the foreground app; emitted output omits raw selected text."]
    )
}

func argumentValue(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func parseIntArgument(_ name: String, in args: [String]) -> Int? {
    guard let raw = argumentValue(name, in: args) else {
        return nil
    }
    return Int(raw)
}

func parseRectArgument(_ raw: String) -> CGRect? {
    let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4,
          let x = parts[0],
          let y = parts[1],
          let width = parts[2],
          let height = parts[3],
          width > 0,
          height > 0 else {
        return nil
    }
    return CGRect(x: x, y: y, width: width, height: height)
}

func rectSummary(_ rect: CGRect) -> JSONObject {
    [
        "x": Int(rect.origin.x.rounded()),
        "y": Int(rect.origin.y.rounded()),
        "width": Int(rect.width.rounded()),
        "height": Int(rect.height.rounded())
    ]
}

func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    return CGDirectDisplayID(number.uint32Value)
}

func nsscreenSummary(index: Int, screen: NSScreen) -> JSONObject {
    var summary: JSONObject = [
        "index": index,
        "frame": rectSummary(screen.frame),
        "visible_frame": rectSummary(screen.visibleFrame),
        "scale": screen.backingScaleFactor
    ]
    if let displayID = screenDisplayID(screen) {
        summary["display_id"] = Int64(displayID)
    }
    return summary
}

func nsscreenSummaries() -> [JSONObject] {
    NSScreen.screens.enumerated().map { nsscreenSummary(index: $0.offset, screen: $0.element) }
}

func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else {
        return 0
    }
    return intersection.width * intersection.height
}

func screensIntersecting(_ rect: CGRect) -> [(index: Int, screen: NSScreen, area: CGFloat)] {
    NSScreen.screens.enumerated()
        .map { (index: $0.offset, screen: $0.element, area: intersectionArea(rect, $0.element.frame)) }
        .filter { $0.area > 1 }
        .sorted { $0.area > $1.area }
}

func screenCaptureDisplay(displayID: CGDirectDisplayID, in content: SCShareableContent) -> (index: Int, display: SCDisplay)? {
    content.displays.enumerated()
        .first { $0.element.displayID == displayID }
        .map { (index: $0.offset, display: $0.element) }
}

func displaySourceRect(appKitGlobalRect: CGRect, screen: NSScreen) -> CGRect {
    let standardized = appKitGlobalRect.standardized
    let screenFrame = screen.frame
    return CGRect(
        x: standardized.minX - screenFrame.minX,
        y: screenFrame.maxY - standardized.maxY,
        width: standardized.width,
        height: standardized.height
    )
}

func errorSummary(_ error: Error) -> JSONObject {
    let nsError = error as NSError
    return [
        "message": String(describing: error),
        "domain": nsError.domain,
        "code": nsError.code
    ]
}

func packageRootURL() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    url.deleteLastPathComponent()
    url.deleteLastPathComponent()
    return url
}

func capturesDirectoryURL() -> URL {
    packageRootURL().appendingPathComponent("captures", isDirectory: true)
}

func writePNG(_ image: CGImage, label: String) throws -> JSONObject {
    let directory = capturesDirectoryURL()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let suffix = sha256Prefix(UUID().uuidString, length: 8)
    let filename = "\(label)-\(Int(Date().timeIntervalSince1970))-\(suffix).png"
    let url = directory.appendingPathComponent(filename)

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw ProbeMessageError(description: "png_destination_create_failed")
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ProbeMessageError(description: "png_destination_finalize_failed")
    }

    let data = try Data(contentsOf: url)
    return [
        "relative_path": "tools/spikes/blocks_macos_probe/captures/\(filename)",
        "width": image.width,
        "height": image.height,
        "bytes": data.count,
        "sha256_12": sha256Prefix(data: data)
    ]
}

func loadShareableContent() throws -> SCShareableContent {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<SCShareableContent>()

    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        box.value = content
        box.error = error
        semaphore.signal()
    }
    semaphore.wait()

    if let error = box.error {
        throw error
    }
    guard let content = box.value else {
        throw ProbeMessageError(description: "shareable_content_empty")
    }
    return content
}

func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) throws -> CGImage {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<CGImage>()

    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        box.value = image
        box.error = error
        semaphore.signal()
    }
    semaphore.wait()

    if let error = box.error {
        throw error
    }
    guard let image = box.value else {
        throw ProbeMessageError(description: "capture_image_empty")
    }
    return image
}

func pixelDimension(points: CGFloat, scale: Float) -> Int {
    max(1, Int((points * CGFloat(scale)).rounded()))
}

func displaySummary(index: Int, display: SCDisplay) -> JSONObject {
    [
        "index": index,
        "display_id": Int64(display.displayID),
        "width": display.width,
        "height": display.height,
        "frame": rectSummary(display.frame)
    ]
}

func windowCandidates(from windows: [SCWindow]) -> [SCWindow] {
    let primary = windows.filter {
        $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 1 && $0.frame.height >= 1
    }
    if !primary.isEmpty {
        return primary
    }
    return windows.filter {
        $0.isOnScreen && $0.frame.width >= 1 && $0.frame.height >= 1
    }
}

func windowSummary(index: Int, window: SCWindow) -> JSONObject {
    [
        "index": index,
        "window_id": Int64(window.windowID),
        "app_name": window.owningApplication?.applicationName ?? "",
        "title_length": window.title?.count ?? 0,
        "width": Int(window.frame.width.rounded()),
        "height": Int(window.frame.height.rounded()),
        "frame": rectSummary(window.frame),
        "window_layer": window.windowLayer,
        "on_screen": window.isOnScreen,
        "active": window.isActive
    ]
}

func bestDisplay(for window: SCWindow, displays: [SCDisplay]) -> (index: Int, display: SCDisplay)? {
    displays.enumerated()
        .map { (index: $0.offset, display: $0.element, area: intersectionArea(window.frame, $0.element.frame)) }
        .filter { $0.area > 0 }
        .sorted { $0.area > $1.area }
        .first
        .map { (index: $0.index, display: $0.display) }
}

func displayLocalRect(windowFrame: CGRect, displayFrame: CGRect) -> CGRect {
    CGRect(
        x: windowFrame.origin.x - displayFrame.origin.x,
        y: windowFrame.origin.y - displayFrame.origin.y,
        width: windowFrame.width,
        height: windowFrame.height
    )
}

func baseCaptureConfiguration(filter: SCContentFilter, widthPoints: CGFloat, heightPoints: CGFloat) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = pixelDimension(points: widthPoints, scale: filter.pointPixelScale)
    configuration.height = pixelDimension(points: heightPoints, scale: filter.pointPixelScale)
    configuration.showsCursor = false
    return configuration
}

func emitCaptureNotAuthorized() -> Never {
    emit(
        ok: false,
        probe: "blocks.capture",
        status: "not_authorized",
        promptRequested: false,
        observations: [
            "authorized": false,
            "guidance": "Grant Screen Recording permission in System Settings > Privacy & Security before running screenshot capture."
        ],
        warnings: ["Screen Recording permission is required before real screenshot capture can run."]
    )
}

func runCaptureList() -> Never {
    guard CGPreflightScreenCaptureAccess() else {
        emitCaptureNotAuthorized()
    }

    do {
        let content = try loadShareableContent()
        let displays = content.displays.enumerated().map { displaySummary(index: $0.offset, display: $0.element) }
        let windows = windowCandidates(from: content.windows)
        let sampleLimit = 50
        let windowSample = windows.prefix(sampleLimit).enumerated().map {
            windowSummary(index: $0.offset, window: $0.element)
        }
        let truncated = windows.count > sampleLimit

        emit(
            ok: true,
            probe: "blocks.capture",
            status: "listed",
            promptRequested: false,
            observations: [
                "authorized": true,
                "display_count": content.displays.count,
                "nsscreen_count": NSScreen.screens.count,
                "window_total_count": content.windows.count,
                "window_candidate_count": windows.count,
                "window_sample_count": windowSample.count,
                "windows_truncated": truncated,
                "displays": displays,
                "nsscreens": nsscreenSummaries(),
                "windows": windowSample
            ],
            warnings: truncated ? ["Window list was truncated to avoid noisy probe output."] : []
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "list_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

func runDisplayCapture(args: [String], content: SCShareableContent, displayIndex: Int) -> Never {
    guard args.contains("--write-png") else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "missing_write_png",
            promptRequested: false,
            warnings: ["P2-C writes only to the ignored local captures directory; pass --write-png explicitly."]
        )
    }
    guard content.displays.indices.contains(displayIndex) else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "invalid_display_index",
            promptRequested: false,
            observations: [
                "display_index": displayIndex,
                "display_count": content.displays.count
            ]
        )
    }

    let display = content.displays[displayIndex]
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let rect: CGRect?
    if let rawRect = argumentValue("--rect", in: args) {
        guard let parsedRect = parseRectArgument(rawRect) else {
            emit(
                ok: false,
                probe: "blocks.capture",
                status: "invalid_rect",
                promptRequested: false,
                observations: ["rect": rawRect]
            )
        }
        rect = parsedRect
    } else {
        rect = nil
    }

    let widthPoints = rect?.width ?? CGFloat(display.width)
    let heightPoints = rect?.height ?? CGFloat(display.height)
    let configuration = baseCaptureConfiguration(filter: filter, widthPoints: widthPoints, heightPoints: heightPoints)
    if let rect {
        configuration.sourceRect = rect
    }

    do {
        let image = try captureImage(filter: filter, configuration: configuration)
        let imageSummary = try writePNG(image, label: rect == nil ? "display-\(displayIndex)" : "rect-display-\(displayIndex)")
        var observations: JSONObject = [
            "mode": rect == nil ? "display" : "rect",
            "display": displaySummary(index: displayIndex, display: display),
            "image": imageSummary,
            "point_pixel_scale": filter.pointPixelScale
        ]
        if let rect {
            observations["rect"] = rectSummary(rect)
        }
        emit(
            ok: true,
            probe: "blocks.capture",
            status: rect == nil ? "captured_display" : "captured_rect",
            promptRequested: false,
            observations: observations,
            warnings: ["PNG was written only to the ignored local captures directory; raw image data is not emitted."]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: rect == nil ? "display_capture_failed" : "rect_capture_failed",
            promptRequested: false,
            observations: [
                "display": displaySummary(index: displayIndex, display: display),
                "error": errorSummary(error)
            ]
        )
    }
}

func runWindowCapture(args: [String], content: SCShareableContent, windowIndex: Int) -> Never {
    guard args.contains("--write-png") else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "missing_write_png",
            promptRequested: false,
            warnings: ["P2-C writes only to the ignored local captures directory; pass --write-png explicitly."]
        )
    }

    let windows = windowCandidates(from: content.windows)
    guard !windows.isEmpty else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "no_candidate_window",
            promptRequested: false,
            observations: [
                "window_total_count": content.windows.count,
                "window_candidate_count": 0
            ],
            warnings: ["No on-screen candidate window with a non-zero frame was available."]
        )
    }
    guard windows.indices.contains(windowIndex) else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "invalid_window_index",
            promptRequested: false,
            observations: [
                "window_index": windowIndex,
                "window_candidate_count": windows.count
            ]
        )
    }

    let window = windows[windowIndex]
    guard let displayMatch = bestDisplay(for: window, displays: content.displays) else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "window_display_not_found",
            promptRequested: false,
            observations: [
                "window": windowSummary(index: windowIndex, window: window),
                "display_count": content.displays.count
            ],
            warnings: ["The selected window did not intersect any enumerated display."]
        )
    }

    let filter = SCContentFilter(display: displayMatch.display, including: [window])
    let localRect = displayLocalRect(windowFrame: window.frame, displayFrame: displayMatch.display.frame)
    let configuration = baseCaptureConfiguration(filter: filter, widthPoints: localRect.width, heightPoints: localRect.height)
    configuration.sourceRect = localRect

    do {
        let image = try captureImage(filter: filter, configuration: configuration)
        let imageSummary = try writePNG(image, label: "window-\(windowIndex)")
        emit(
            ok: true,
            probe: "blocks.capture",
            status: "captured_window",
            promptRequested: false,
            observations: [
                "mode": "window",
                "window": windowSummary(index: windowIndex, window: window),
                "display": displaySummary(index: displayMatch.index, display: displayMatch.display),
                "image": imageSummary,
                "source_rect": rectSummary(localRect),
                "point_pixel_scale": filter.pointPixelScale
            ],
            warnings: ["PNG was written only to the ignored local captures directory; raw image data is not emitted."]
        )
    } catch {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "window_capture_failed",
            promptRequested: false,
            observations: [
                "window": windowSummary(index: windowIndex, window: window),
                "error": errorSummary(error)
            ]
        )
    }
}

func captureDisplayCase(
    content: SCShareableContent,
    displayIndex: Int,
    rect: CGRect?,
    label: String
) -> JSONObject {
    guard content.displays.indices.contains(displayIndex) else {
        return [
            "ok": false,
            "status": "invalid_display_index",
            "display_index": displayIndex,
            "display_count": content.displays.count
        ]
    }

    let display = content.displays[displayIndex]
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let widthPoints = rect?.width ?? CGFloat(display.width)
    let heightPoints = rect?.height ?? CGFloat(display.height)
    let configuration = baseCaptureConfiguration(filter: filter, widthPoints: widthPoints, heightPoints: heightPoints)
    if let rect {
        configuration.sourceRect = rect
    }

    do {
        let image = try captureImage(filter: filter, configuration: configuration)
        var result: JSONObject = [
            "ok": true,
            "status": rect == nil ? "captured_display" : "captured_rect",
            "display": displaySummary(index: displayIndex, display: display),
            "image": try writePNG(image, label: label),
            "point_pixel_scale": filter.pointPixelScale
        ]
        if let rect {
            result["rect"] = rectSummary(rect)
        }
        return result
    } catch {
        return [
            "ok": false,
            "status": rect == nil ? "display_capture_failed" : "rect_capture_failed",
            "display": displaySummary(index: displayIndex, display: display),
            "error": errorSummary(error)
        ]
    }
}

func captureWindowCase(content: SCShareableContent, windowIndex: Int) -> JSONObject {
    let windows = windowCandidates(from: content.windows)
    guard !windows.isEmpty else {
        return [
            "ok": true,
            "status": "no_candidate_window",
            "window_total_count": content.windows.count,
            "window_candidate_count": 0
        ]
    }
    guard windows.indices.contains(windowIndex) else {
        return [
            "ok": false,
            "status": "invalid_window_index",
            "window_index": windowIndex,
            "window_candidate_count": windows.count
        ]
    }

    let window = windows[windowIndex]
    guard let displayMatch = bestDisplay(for: window, displays: content.displays) else {
        return [
            "ok": false,
            "status": "window_display_not_found",
            "window": windowSummary(index: windowIndex, window: window),
            "display_count": content.displays.count
        ]
    }

    let filter = SCContentFilter(display: displayMatch.display, including: [window])
    let localRect = displayLocalRect(windowFrame: window.frame, displayFrame: displayMatch.display.frame)
    let configuration = baseCaptureConfiguration(filter: filter, widthPoints: localRect.width, heightPoints: localRect.height)
    configuration.sourceRect = localRect

    do {
        let image = try captureImage(filter: filter, configuration: configuration)
        return [
            "ok": true,
            "status": "captured_window",
            "window": windowSummary(index: windowIndex, window: window),
            "display": displaySummary(index: displayMatch.index, display: displayMatch.display),
            "source_rect": rectSummary(localRect),
            "image": try writePNG(image, label: "boundary-window-\(windowIndex)"),
            "point_pixel_scale": filter.pointPixelScale
        ]
    } catch {
        return [
            "ok": false,
            "status": "window_capture_failed",
            "window": windowSummary(index: windowIndex, window: window),
            "error": errorSummary(error)
        ]
    }
}

func displayScreenMappings(content: SCShareableContent) -> [JSONObject] {
    NSScreen.screens.enumerated().map { index, screen in
        let displayID = screenDisplayID(screen)
        let match = displayID.flatMap { screenCaptureDisplay(displayID: $0, in: content) }
        var mapping = nsscreenSummary(index: index, screen: screen)
        mapping["matched_sc_display"] = match.map { displaySummary(index: $0.index, display: $0.display) } ?? [:]
        mapping["matched"] = match != nil
        return mapping
    }
}

func edgeRect(for display: SCDisplay) -> CGRect {
    let displayWidth = CGFloat(display.width)
    let displayHeight = CGFloat(display.height)
    let width = min(CGFloat(320), max(CGFloat(64), displayWidth / 4))
    let height = min(CGFloat(240), max(CGFloat(64), displayHeight / 4))
    return CGRect(
        x: max(0, displayWidth - width),
        y: max(0, displayHeight - height),
        width: width,
        height: height
    )
}

func runCaptureBoundarySuite(args: [String], content: SCShareableContent) -> Never {
    guard args.contains("--write-png") else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "missing_write_png",
            promptRequested: false,
            warnings: ["P2-K writes only to the ignored local captures directory; pass --write-png explicitly."]
        )
    }
    guard !content.displays.isEmpty else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "no_displays",
            promptRequested: false,
            observations: ["nsscreen_count": NSScreen.screens.count]
        )
    }

    let display = content.displays[0]
    let fullDisplay = captureDisplayCase(content: content, displayIndex: 0, rect: nil, label: "boundary-display-0")
    let edge = edgeRect(for: display)
    let edgeCapture = captureDisplayCase(content: content, displayIndex: 0, rect: edge, label: "boundary-edge-display-0")
    let window = captureWindowCase(content: content, windowIndex: 0)
    let mapping = displayScreenMappings(content: content)
    let multiDisplayCovered = content.displays.count > 1 && NSScreen.screens.count > 1

    let requiredCasesOK = [fullDisplay, edgeCapture].allSatisfy { ($0["ok"] as? Bool) == true }
    var observations: JSONObject = [
        "authorized": true,
        "display_count": content.displays.count,
        "nsscreen_count": NSScreen.screens.count,
        "nsscreen_display_mappings": mapping,
        "cases": [
            "display": fullDisplay,
            "edge_rect": edgeCapture,
            "window": window
        ],
        "cross_display_selection_policy": "unsupported_in_p2k_do_not_crop_or_merge"
    ]
    if !multiDisplayCovered {
        observations["multi_display_status"] = "multi_display_not_covered"
        observations["not_covered_reason"] = "current_machine_has_single_visible_display"
    } else {
        observations["multi_display_status"] = "mapping_observed"
    }

    emit(
        ok: requiredCasesOK,
        probe: "blocks.capture",
        status: requiredCasesOK ? "boundary_suite_completed" : "boundary_suite_failed",
        promptRequested: false,
        observations: observations,
        warnings: [
            "PNG files were written only to the ignored local captures directory; raw image data is not emitted.",
            "Cross-display region capture remains unsupported in this spike."
        ]
    )
}

func parseTimeout(args: [String], defaultValue: TimeInterval) -> TimeInterval {
    guard let raw = argumentValue("--timeout", in: args),
          let value = TimeInterval(raw),
          value > 0 else {
        return defaultValue
    }
    return min(value, 300)
}

func runInteractiveRegionCapture(args: [String], content: SCShareableContent) -> Never {
    guard args.contains("--write-png") else {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "missing_write_png",
            promptRequested: false,
            warnings: ["P2-F writes only to the ignored local captures directory; pass --write-png explicitly."]
        )
    }

    let timeout = parseTimeout(args: args, defaultValue: 30)
    let selection = MainActor.assumeIsolated {
        RegionSelectionController().run(timeout: timeout)
    }

    switch selection {
    case .cancelled:
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "cancelled",
            promptRequested: false,
            observations: [
                "timeout_seconds": timeout,
                "nsscreen_count": NSScreen.screens.count
            ],
            warnings: ["Interactive region selection was cancelled; no PNG was written."]
        )
    case .timedOut:
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "timed_out",
            promptRequested: false,
            observations: [
                "timeout_seconds": timeout,
                "nsscreen_count": NSScreen.screens.count
            ],
            warnings: ["Interactive region selection timed out; no PNG was written."]
        )
    case .tooSmall(let rect):
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "selection_too_small",
            promptRequested: false,
            observations: [
                "global_rect": rectSummary(rect),
                "minimum_points": 8,
                "nsscreen_count": NSScreen.screens.count
            ],
            warnings: ["Selected region was below the minimum 8x8 point size; no PNG was written."]
        )
    case .selected(let globalRect):
        let screens = screensIntersecting(globalRect)
        guard !screens.isEmpty else {
            emit(
                ok: false,
                probe: "blocks.capture",
                status: "selection_screen_not_found",
                promptRequested: false,
                observations: [
                    "global_rect": rectSummary(globalRect),
                    "nsscreen_count": NSScreen.screens.count,
                    "nsscreens": nsscreenSummaries()
                ],
                warnings: ["Selected region did not intersect a known NSScreen; no PNG was written."]
            )
        }
        guard screens.count == 1 else {
            emit(
                ok: false,
                probe: "blocks.capture",
                status: "cross_display_selection_unsupported",
                promptRequested: false,
                observations: [
                    "global_rect": rectSummary(globalRect),
                    "intersecting_screen_count": screens.count,
                    "nsscreens": screens.map { nsscreenSummary(index: $0.index, screen: $0.screen) }
                ],
                warnings: ["P2-F does not split one region across multiple displays; no PNG was written."]
            )
        }

        let screenMatch = screens[0]
        guard let displayID = screenDisplayID(screenMatch.screen),
              let displayMatch = screenCaptureDisplay(displayID: displayID, in: content) else {
            emit(
                ok: false,
                probe: "blocks.capture",
                status: "selection_display_not_found",
                promptRequested: false,
                observations: [
                    "global_rect": rectSummary(globalRect),
                    "nsscreen": nsscreenSummary(index: screenMatch.index, screen: screenMatch.screen),
                    "display_count": content.displays.count
                ],
                warnings: ["The selected NSScreen could not be mapped to a ScreenCaptureKit display; no PNG was written."]
            )
        }

        let sourceRect = displaySourceRect(appKitGlobalRect: globalRect, screen: screenMatch.screen)
        let filter = SCContentFilter(display: displayMatch.display, excludingWindows: [])
        let configuration = baseCaptureConfiguration(
            filter: filter,
            widthPoints: sourceRect.width,
            heightPoints: sourceRect.height
        )
        configuration.sourceRect = sourceRect

        do {
            let image = try captureImage(filter: filter, configuration: configuration)
            let imageSummary = try writePNG(image, label: "interactive-region-display-\(displayMatch.index)")
            emit(
                ok: true,
                probe: "blocks.capture",
                status: "captured_interactive_region",
                promptRequested: false,
                observations: [
                    "mode": "interactive_region",
                    "global_rect": rectSummary(globalRect),
                    "display_local_rect": rectSummary(sourceRect),
                    "nsscreen": nsscreenSummary(index: screenMatch.index, screen: screenMatch.screen),
                    "display": displaySummary(index: displayMatch.index, display: displayMatch.display),
                    "display_count": content.displays.count,
                    "nsscreen_count": NSScreen.screens.count,
                    "point_pixel_scale": filter.pointPixelScale,
                    "timeout_seconds": timeout,
                    "image": imageSummary
                ],
                warnings: ["PNG was written only to the ignored local captures directory; raw image data is not emitted."]
            )
        } catch {
            emit(
                ok: false,
                probe: "blocks.capture",
                status: "interactive_region_capture_failed",
                promptRequested: false,
                observations: [
                    "global_rect": rectSummary(globalRect),
                    "display_local_rect": rectSummary(sourceRect),
                    "display": displaySummary(index: displayMatch.index, display: displayMatch.display),
                    "error": errorSummary(error)
                ]
            )
        }
    }
}

func runCapture(args: [String]) -> Never {
    if args.contains("--list") {
        runCaptureList()
    }

    guard CGPreflightScreenCaptureAccess() else {
        emitCaptureNotAuthorized()
    }

    do {
        let content = try loadShareableContent()
        let displayIndex = parseIntArgument("--display-index", in: args)
        let windowIndex = parseIntArgument("--window-index", in: args)

        if args.contains("--boundary-suite"), displayIndex == nil, windowIndex == nil {
            runCaptureBoundarySuite(args: args, content: content)
        }
        if args.contains("--interactive-region"), displayIndex == nil, windowIndex == nil {
            runInteractiveRegionCapture(args: args, content: content)
        }
        if let displayIndex, windowIndex == nil {
            runDisplayCapture(args: args, content: content, displayIndex: displayIndex)
        }
        if let windowIndex, displayIndex == nil {
            runWindowCapture(args: args, content: content, windowIndex: windowIndex)
        }

        usage()
    } catch {
        emit(
            ok: false,
            probe: "blocks.capture",
            status: "shareable_content_failed",
            promptRequested: false,
            observations: ["error": errorSummary(error)]
        )
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    usage()
}
let commandArgs = Array(args.dropFirst())

switch command {
case "blocks-screen":
    runScreen(args: commandArgs)
case "blocks-accessibility":
    runAccessibility(args: commandArgs)
case "blocks-pasteboard":
    runPasteboard(args: commandArgs)
case "blocks-keychain":
    runKeychain(args: commandArgs)
case "blocks-hotkey":
    runHotKey(args: commandArgs)
case "blocks-selection-copy":
    runSelectionCopy(args: commandArgs)
case "blocks-capture":
    runCapture(args: commandArgs)
default:
    usage()
}
