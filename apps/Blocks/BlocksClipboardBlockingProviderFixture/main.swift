import AppKit
import Darwin
import Foundation

final class BlockingStringProvider: NSObject, NSPasteboardItemDataProvider {
    private let blocker = DispatchSemaphore(value: 0)

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        blocker.wait()
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: BlocksClipboardBlockingProviderFixture <uuid-pasteboard-name>\n", stderr)
    exit(EXIT_FAILURE)
}

let rawPasteboardName = CommandLine.arguments[1]
guard UUID(uuidString: rawPasteboardName) != nil else {
    fputs("pasteboard name must be a UUID\n", stderr)
    exit(EXIT_FAILURE)
}

let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: rawPasteboardName))
let provider = BlockingStringProvider()
let item = NSPasteboardItem()
item.setDataProvider(provider, forTypes: [.string])

pasteboard.clearContents()
guard pasteboard.writeObjects([item]) else {
    fputs("failed to publish blocking pasteboard item\n", stderr)
    exit(EXIT_FAILURE)
}

print("READY \(pasteboard.changeCount)")
fflush(stdout)
RunLoop.main.run()
