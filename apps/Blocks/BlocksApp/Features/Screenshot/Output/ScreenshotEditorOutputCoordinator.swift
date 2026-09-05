import AppKit
import BlocksScreenshotCore
import Darwin
import UniformTypeIdentifiers

struct ScreenshotSecureFileWriter: Sendable {
    func write(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let permissions = try destinationPermissions(
            at: destinationURL,
            fileManager: fileManager
        ) ?? 0o600
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".blocks-screenshot-\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ScreenshotSecureFileWriterError.temporaryFileCreationFailed
        }
        var temporaryFileExists = true
        defer {
            if temporaryFileExists {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try data.write(to: temporaryURL)
        try Task.checkCancellation()
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: temporaryURL.path
        )
        guard try posixPermissions(at: temporaryURL, fileManager: fileManager) == permissions else {
            throw ScreenshotSecureFileWriterError.invalidPermissions
        }
        try Task.checkCancellation()

        let renameResult = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw ScreenshotSecureFileWriterError.atomicReplacementFailed(errno)
        }
        temporaryFileExists = false
        guard try posixPermissions(at: destinationURL, fileManager: fileManager) == permissions else {
            throw ScreenshotSecureFileWriterError.invalidPermissions
        }
    }

    private func destinationPermissions(at url: URL, fileManager: FileManager) throws -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try posixPermissions(at: url, fileManager: fileManager)
    }

    private func posixPermissions(at url: URL, fileManager: FileManager) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw ScreenshotSecureFileWriterError.invalidPermissions
        }
        return permissions.intValue & 0o777
    }
}

private enum ScreenshotSecureFileWriterError: Error {
    case temporaryFileCreationFailed
    case invalidPermissions
    case atomicReplacementFailed(Int32)
}

@MainActor
private final class ScreenshotSavePanelCancellation {
    private weak var panel: NSSavePanel?

    init(panel: NSSavePanel) {
        self.panel = panel
    }

    func cancel() {
        panel?.cancelOperation(nil)
    }

    func finish() {
        panel = nil
    }
}

@MainActor
final class ScreenshotEditorOutputCoordinator {
    enum SavePanelResult: Sendable {
        case cancel
        case ok(URL)
    }

    typealias SavePanelPresenter = @MainActor (NSSavePanel, NSWindow) async -> SavePanelResult
    typealias FileWriter = @Sendable (Data, URL) throws -> Void

    enum OutputError: Error {
        case missingPresentationWindow
    }

    private let preferencesStore: ScreenshotPreferencesStore
    private let pasteboardWriter: any ScreenshotPasteboardWriting
    private let fileWriter: FileWriter
    private let presentationWindow: () -> NSWindow?
    private let savePanelPresenter: SavePanelPresenter
    private let serializationGate: ScreenshotOutputSerialGate

    init(
        preferencesStore: ScreenshotPreferencesStore,
        pasteboardWriter: (any ScreenshotPasteboardWriting)? = nil,
        fileWriter: @escaping FileWriter = { data, url in
            try ScreenshotSecureFileWriter().write(data, to: url)
        },
        presentationWindow: @escaping () -> NSWindow? = { nil },
        serializationGate: ScreenshotOutputSerialGate? = nil,
        savePanelPresenter: @escaping SavePanelPresenter = { panel, window in
            await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else {
                        continuation.resume(returning: .cancel)
                        return
                    }
                    continuation.resume(returning: .ok(url))
                }
            }
        }
    ) {
        self.preferencesStore = preferencesStore
        self.pasteboardWriter = pasteboardWriter ?? ScreenshotPasteboardWriter()
        self.fileWriter = fileWriter
        self.presentationWindow = presentationWindow
        self.savePanelPresenter = savePanelPresenter
        self.serializationGate = serializationGate ?? ScreenshotOutputSerialGate()
    }

    func copy(_ image: CGImage) async throws {
        guard await serializationGate.acquire() else { throw CancellationError() }
        defer { serializationGate.release() }
        try Task.checkCancellation()
        try await pasteboardWriter.write(image.nsImage)
    }

    func saveAs(_ image: CGImage) async throws -> URL? {
        let preferences = preferencesStore.preferences
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "blocks-screenshot-\(Int(Date().timeIntervalSince1970)).\(preferences.outputFormat == .jpeg ? "jpg" : "png")"
        guard let window = presentationWindow() else { throw OutputError.missingPresentationWindow }
        let panelCancellation = ScreenshotSavePanelCancellation(panel: panel)
        defer { panelCancellation.finish() }
        let panelResult = await withTaskCancellationHandler {
            await savePanelPresenter(panel, window)
        } onCancel: {
            Task { @MainActor in
                panelCancellation.cancel()
            }
        }
        guard case let .ok(url) = panelResult else { return nil }
        try Task.checkCancellation()
        let usesJPEG = url.pathExtension.lowercased().hasPrefix("jp")
        let jpegQuality = preferences.jpegQuality
        let fileWriter = fileWriter
        let saveWork = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let encoder = ScreenshotImageEncoder()
            let data: Data
            if usesJPEG {
                data = try encoder.jpegData(image, quality: jpegQuality)
            } else {
                data = try encoder.pngData(image)
            }
            try Task.checkCancellation()
            try fileWriter(data, url)
        }
        try await withTaskCancellationHandler(operation: {
            try await saveWork.value
        }, onCancel: {
            saveWork.cancel()
        })
        return url
    }
}

private extension CGImage {
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}
