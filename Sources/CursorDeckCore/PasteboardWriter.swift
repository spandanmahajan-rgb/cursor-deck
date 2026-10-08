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

    public func writeSingleItem(item: DeckItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var written = false
        if let data = try? Data(contentsOf: item.fileURL) {
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.fileURL.absoluteString, forType: .fileURL)
            let ext = item.fileURL.pathExtension.lowercased()
            // FIX: the original fell through to `.tiff` for every other extension (webp, heic, svg...),
            // labelling non-TIFF bytes as TIFF => corrupt/blank paste. Only label bytes we know.
            switch ext {
            case "png":
                pbItem.setData(data, forType: .png)
            case "jpg", "jpeg":
                pbItem.setData(data, forType: .init("public.jpeg"))
            case "gif":
                pbItem.setData(data, forType: .init("com.compuserve.gif"))
                pbItem.setData(data, forType: .init("image/gif"))
            default:
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pbItem.setData(tiff, forType: .tiff)
                }
                // otherwise: file URL flavor only
            }
            pbItem.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
            written = pasteboard.writeObjects([pbItem])
        } else {
            written = pasteboard.writeObjects([item.fileURL as NSURL])
            pasteboard.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
        }

        return written
    }

    public func simulatePasteEvent() {
        let vKeyCode: CGKeyCode = 9 // Virtual key code for 'V'
        
        // FIX: private source so a physically held ⌥/⇧/⌘ doesn't merge into the synthetic
        // keystroke (⌘⌥V = "Paste and Match Style" etc. in many apps).
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(25_000)
        keyUp.post(tap: .cghidEventTap)
    }

    public func burstPasteSequentially(items: [DeckItem], delayBetweenMs: UInt32 = 250, completion: (() -> Void)? = nil) {
        guard !items.isEmpty else {
            completion?()
            return
        }

        // FIX: without this permission CGEvent.post is silently dropped and the burst "pastes" nothing.
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }

        DispatchQueue.global(qos: .userInteractive).async {
            for (index, item) in items.enumerated() {
                _ = DispatchQueue.main.sync {
                    self.writeSingleItem(item: item)
                }
                
                usleep(50_000)
                self.simulatePasteEvent()
                
                if index < items.count - 1 {
                    usleep(delayBetweenMs * 1000)
                }
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }
}
