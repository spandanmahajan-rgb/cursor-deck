import AppKit
import Foundation

/// Drag item writer providing matching flavors for Finder, Slides, Keynote, Figma, Photoshop.
///
/// FIX summary vs. original:
///  - No eager decode/re-encode in init(). The original decoded every image, built a full
///    uncompressed TIFF and re-encoded PNG for EVERY item on the main thread when the drag began
///    (hundreds of ms per large image => multi-second beachball on a 20-item deck).
///  - Flavors are declared only if we can really supply them. The original declared .png for GIFs
///    but returned nil, and declared .tiff for GIFs (a single flattened frame) which some receivers
///    prefer over the animated GIF.
///  - JPEGs are handed over as JPEG bytes instead of being re-encoded.
public final class DeckDragItemWriter: NSObject, NSPasteboardWriting {
    public let fileURL: URL
    private let ext: String

    private static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let gifUTI = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let gifMIME = NSPasteboard.PasteboardType("image/gif")
    private static let jpegUTI = NSPasteboard.PasteboardType("public.jpeg")

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.ext = fileURL.pathExtension.lowercased()
        super.init()
    }

    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, Self.legacyFilenames]
        switch ext {
        case "gif":
            // Animated: do NOT offer png/tiff, receivers would flatten it to one frame.
            types += [Self.gifUTI, Self.gifMIME]
        case "png":
            types += [.png, .tiff]
        case "jpg", "jpeg":
            types += [Self.jpegUTI, .tiff]
        default:
            types += [.tiff]
        }
        return types
    }

    public func writingOptions(forType type: NSPasteboard.PasteboardType,
                               pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        return []
    }

    public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            return (fileURL as NSURL).pasteboardPropertyList(forType: .fileURL)
        case Self.legacyFilenames:
            return [fileURL.path]
        case Self.gifUTI, Self.gifMIME, .png, Self.jpegUTI:
            // Raw file bytes, read only when the destination actually asks for them.
            return try? Data(contentsOf: fileURL)
        case .tiff:
            return NSImage(contentsOf: fileURL)?.tiffRepresentation
        default:
            return nil
        }
    }
}
