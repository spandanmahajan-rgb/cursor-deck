import AppKit
import Foundation

public final class PasteboardWriter {
    public static let shared = PasteboardWriter()

    public init() {}

    /// Writes all accumulated items onto the general pasteboard simultaneously.
    /// Writes BOTH native NSURL file objects AND NSPasteboardItem instances.
    @discardableResult
    public func writeToPasteboard(items: [DeckItem]) -> Bool {
        guard !items.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 1. Array of file NSURLs (how Finder and native macOS file drops work)
        let fileURLs: [NSURL] = items.map { $0.fileURL as NSURL }
        let success = pasteboard.writeObjects(fileURLs)

        // 2. Also register legacy NSFilenamesPboardType
        let paths = items.map { $0.fileURL.path }
        pasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        // 3. Register internal marker so ClipboardWatcher knows CursorDeck wrote this
        pasteboard.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))

        return success
    }

    /// Sets the pasteboard to a single item and triggers Cmd+V paste
    public func writeSingleItem(item: DeckItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var written = false
        if let data = try? Data(contentsOf: item.fileURL) {
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.fileURL.absoluteString, forType: .fileURL)
            let ext = item.fileURL.pathExtension.lowercased()
            if ext == "png" {
                pbItem.setData(data, forType: .png)
            } else if ext == "jpg" || ext == "jpeg" {
                pbItem.setData(data, forType: .init("public.jpeg"))
            } else {
                pbItem.setData(data, forType: .tiff)
            }
            pbItem.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
            written = pasteboard.writeObjects([pbItem])
        } else {
            written = pasteboard.writeObjects([item.fileURL as NSURL])
            pasteboard.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
        }

        return written
    }

    /// Simulates Cmd + V keypress event via CGEvent
    public func simulatePasteEvent() {
        let vKeyCode: CGKeyCode = 9 // Virtual key code for 'V'
        
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(25_000) // 25ms pause
        keyUp.post(tap: .cghidEventTap)
    }

    /// Executes a sequential burst drop:
    /// Iterates through each accumulated item in order, writes it to NSPasteboard,
    /// and fires a Cmd+V paste event with a delay between drops.
    /// This allows web apps (Google Slides, Miro, Figma in browser) that only accept 1 image
    /// per paste event to receive EVERY accumulated image on the canvas!
    public func burstPasteSequentially(items: [DeckItem], delayBetweenMs: UInt32 = 250, completion: (() -> Void)? = nil) {
        guard !items.isEmpty else {
            completion?()
            return
        }

        DispatchQueue.global(qos: .userInteractive).async {
            for (index, item) in items.enumerated() {
                DispatchQueue.main.sync {
                    self.writeSingleItem(item: item)
                }
                
                // Allow OS pasteboard buffer to settle
                usleep(50_000) // 50ms
                
                // Fire synthetic paste
                self.simulatePasteEvent()
                
                // Pause between items so web editor can finish processing and placing the image
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
