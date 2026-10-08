import Foundation
import AppKit
import CursorDeckCore

// Ensure AppKit NSApplication environment is initialized
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Runs quietly in background, zero dock clutter

print("""
======================================================
  CURSOR DECK (Native macOS Visual Accumulator & HUD)
======================================================
  ✨ Status: Live Clipboard Accumulator & Magnet HUD Active!
  
  How to use:
    1. Browse anywhere and copy images (Cmd+C).
    2. Watch the floating [ N ⧉ ] badge track near your cursor.
    3. Hold CMD (⌘) to magnetically snap the badge to your pointer,
       then click & drag it into Google Slides, Figma, or Keynote!
    4. All accumulated images drop simultaneously into the canvas!
  
  Terminal Controls:
    [c] + Enter : Copy batch files to system pasteboard
    [x] + Enter : Clear Deck
    [l] + Enter : List items
    [q] + Enter : Quit
======================================================
""")

let queueManager = DeckQueueManager()
let clipboardWatcher = ClipboardWatcher(queueManager: queueManager)
let hudPanel = CursorHUDPanel(queueManager: queueManager)

class SimpleWatcherDelegate: ClipboardWatcherDelegate {
    func clipboardWatcher(_ watcher: ClipboardWatcher, didCaptureItem item: DeckItem) {
        let sizeKB = String(format: "%.1f", Double(item.dataSize) / 1024.0)
        print("\n✨ [Deck Updated] +1 Item added! Current Deck Count: [ \(queueManager.count) ⧉ ]")
        print("   -> File: \(item.fileURL.lastPathComponent) (\(sizeKB) KB)")
        print("> ", terminator: "")
        fflush(stdout)
    }
}

let delegate = SimpleWatcherDelegate()
clipboardWatcher.delegate = delegate
clipboardWatcher.start()
hudPanel.startTracking()

print("Status: Accumulator and Cursor HUD are running.\n> ", terminator: "")
fflush(stdout)

// Start background thread to handle CLI inputs while RunLoop runs on main
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        switch trimmed {
        case "c":
            if queueManager.isEmpty {
                print("⚠️  Deck is empty! Copy some images first.")
            } else {
                let count = queueManager.count
                PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
                print("🚀 Native file-URL batch payload of \(count) items written to NSPasteboard.general!")
            }
        case "x":
            DispatchQueue.main.async {
                queueManager.clear()
            }
            print("🧹 Deck cleared. Current count: 0")
        case "l":
            print("\n--- Current Deck Items (\(queueManager.count)) ---")
            if queueManager.isEmpty {
                print(" (No items)")
            } else {
                for (index, item) in queueManager.items.enumerated() {
                    let sizeKB = String(format: "%.1f", Double(item.dataSize) / 1024.0)
                    print(" [\(index + 1)] \(item.fileURL.lastPathComponent) - \(sizeKB) KB")
                }
            }
            print("----------------------------------")
        case "q":
            print("👋 Exiting Cursor Deck...")
            exit(0)
        default:
            print("Commands: [c] copy batch to clipboard, [x] clear, [l] list, [q] quit")
        }
        print("> ", terminator: "")
        fflush(stdout)
    }
}

// Run AppKit main event loop
app.run()
