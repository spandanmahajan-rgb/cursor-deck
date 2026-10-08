import AppKit
import Foundation
import UniformTypeIdentifiers

/// Universal drag item writer.
///
/// Provides the exact same pasteboard payload as dragging files out of Finder:
///   • public.file-url          (native NSURL — primary, always present)
///   • NSFilenamesPboardType    (legacy file paths array — Catalyst / older Electron)
///   • public.png               (raw PNG bytes — web canvas / chat image paste)
///   • public.tiff              (TIFF bytes — legacy Mac apps)
///
/// This mimics what Photos.app and Preview.app place on the dragging pasteboard.
public final class DeckDragItemWriter: NSObject, NSPasteboardWriting {
    public let fileURL: URL
    private let cachedPNGData: Data?
    private let cachedGIFData: Data?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let ext = fileURL.pathExtension.lowercased()
        if ext == "gif" {
            self.cachedGIFData = try? Data(contentsOf: fileURL)
            self.cachedPNGData = nil
        } else {
            self.cachedGIFData = nil
            // Cache PNG bytes upfront so pasteboardPropertyList never blocks the drag loop
            if let img = NSImage(contentsOf: fileURL),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                self.cachedPNGData = rep.representation(using: .png, properties: [:])
            } else {
                self.cachedPNGData = try? Data(contentsOf: fileURL)
            }
        }
        super.init()
    }

    // MARK: - NSPasteboardWriting

    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,                            // public.file-url
            .init(rawValue: "NSFilenamesPboardType") // Legacy Carbon paths — critical for Catalyst/WhatsApp
        ]
        if fileURL.pathExtension.lowercased() == "gif" {
            types.append(.init(rawValue: "com.compuserve.gif"))
            types.append(.init(rawValue: "image/gif"))
        }
        types.append(.png)                       // public.png — in-memory image bytes
        types.append(.tiff)                      // public.tiff — legacy QuickTime apps
        return types
    }

    public func writingOptions(forType type: NSPasteboard.PasteboardType,
                               pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        // Provide all types immediately (no lazy promise) so apps that read at drop-time get data instantly
        return []
    }

    public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            // NSURL's native implementation writes the canonical public.file-url string
            return (fileURL as NSURL).pasteboardPropertyList(forType: .fileURL)

        case .init(rawValue: "NSFilenamesPboardType"):
            // Carbon-era file paths array — required by WhatsApp (Catalyst) and many Electron apps
            return [fileURL.path]

        case .init(rawValue: "com.compuserve.gif"), .init(rawValue: "image/gif"):
            return cachedGIFData

        case .png:
            return cachedPNGData

        case .tiff:
            return NSImage(contentsOf: fileURL)?.tiffRepresentation

        default:
            return nil
        }
    }
}
