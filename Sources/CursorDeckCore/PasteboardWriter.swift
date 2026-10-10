import AppKit
import Foundation

public final class PasteboardWriter {
    public static let shared = PasteboardWriter()

    public init() {}

    @discardableResult
    public func writeToPasteboard(items: [DeckItem]) -> Bool {
        guard !items.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let fileURLs: [NSURL] = items.map { $0.fileURL as NSURL }
        let success = pasteboard.writeObjects(fileURLs)

        let paths = items.map { $0.fileURL.path }
        pasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        pasteboard.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
        return success
    }
}
