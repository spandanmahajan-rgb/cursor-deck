import Foundation
import AppKit
import CursorDeckCore

func createMockPNGData() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 20,
        pixelsHigh: 20,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 20 * 4,
        bitsPerPixel: 32
    )!
    
    // Fill with solid color pixels
    if let data = rep.bitmapData {
        for i in 0..<(20 * 20 * 4) {
            data[i] = (i % 4 == 3) ? 255 : UInt8((i * 13) % 256)
        }
    }
    
    return rep.representation(using: .png, properties: [:])!
}

func testQueueAddAndClear() {
    print("Running testQueueAddAndClear...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    assert(queueManager.count == 0, "Queue should initially be empty")
    assert(queueManager.isEmpty, "Queue isEmpty should be true")

    let pngData = createMockPNGData()

    guard let item1 = queueManager.add(imageData: pngData, extension: "png") else {
        fatalError("Failed to add item 1")
    }
    assert(queueManager.count == 1, "Queue count should be 1")
    assert(FileManager.default.fileExists(atPath: item1.fileURL.path), "File should exist on disk")

    guard let item2 = queueManager.add(imageData: pngData, extension: "png") else {
        fatalError("Failed to add item 2")
    }
    assert(queueManager.count == 2, "Queue count should be 2")
    assert(FileManager.default.fileExists(atPath: item2.fileURL.path), "Item 2 should exist on disk")

    queueManager.clear()
    assert(queueManager.count == 0, "Queue should be empty after clear")
    assert(queueManager.isEmpty, "Queue isEmpty should be true after clear")
    print("✅ testQueueAddAndClear passed!")
}

func testPasteboardWriterPayload() {
    print("Running testPasteboardWriterPayload...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    let pngData = createMockPNGData()

    _ = queueManager.add(imageData: pngData, extension: "png")
    _ = queueManager.add(imageData: pngData, extension: "png")

    assert(queueManager.count == 2, "Queue count must be 2")

    let written = PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
    assert(written, "PasteboardWriter should succeed")

    let pb = NSPasteboard.general
    let items = pb.pasteboardItems
    assert(items?.count == 2, "Pasteboard should contain 2 items")

    if let filenames = pb.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
        assert(filenames.count == 2, "Legacy filenames array should contain 2 items")
    } else {
        fatalError("NSFilenamesPboardType property missing")
    }

    print("✅ testPasteboardWriterPayload passed!")
}

func testDragPasteboard() {
    print("Running testDragPasteboard...")
    let tempURL = URL(fileURLWithPath: "/tmp/cursor_deck_test_drag.png")
    try? createMockPNGData().write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let pboard = NSPasteboard(name: .drag)
    pboard.clearContents()

    let writer = DeckDragItemWriter(fileURL: tempURL)
    pboard.writeObjects([writer])

    print("--- Drag Pasteboard with DeckDragItemWriter ---")
    print("Types on drag pasteboard:", pboard.types?.map(\.rawValue) ?? [])
    for pbType in pboard.types ?? [] {
        let prop = pboard.propertyList(forType: pbType)
        let data = pboard.data(forType: pbType)
        let str = pboard.string(forType: pbType)
        print("  Type: \(pbType.rawValue)")
        print("    string: \(str ?? "nil")")
        print("    propertyList: \(String(describing: prop).prefix(100))")
        print("    data length: \(data?.count ?? 0)")
    }

    // Now test with multiple NSURLs directly
    let tempURL2 = URL(fileURLWithPath: "/tmp/cursor_deck_test_drag2.png")
    try? createMockPNGData().write(to: tempURL2)
    defer { try? FileManager.default.removeItem(at: tempURL2) }

    pboard.clearContents()
    pboard.writeObjects([tempURL as NSURL, tempURL2 as NSURL])
    print("\n--- Drag Pasteboard with 2 NSURLs ---")
    print("Pasteboard items count:", pboard.pasteboardItems?.count ?? 0)
    print("Types on drag pasteboard:", pboard.types?.map(\.rawValue) ?? [])
    if let filenames = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
        print("NSFilenamesPboardType paths count:", filenames.count, "paths:", filenames)
    }

    // Inspect deck_icon_original.png
    let iconURL = URL(fileURLWithPath: "deck_icon_original.png")
    if let img = NSImage(contentsOf: iconURL),
       let rep = img.representations.first as? NSBitmapImageRep {
        print("\n--- Inspecting deck_icon_original.png ---")
        print("Dimensions:", rep.pixelsWide, "x", rep.pixelsHigh)
        // Sample several pixels
        for (x, y) in [(512, 510), (100, 100), (20, 20), (120, 300), (500, 950)] {
            if let c = rep.colorAt(x: x, y: y) {
                print("  Pixel (\(x), \(y)): R=\(c.redComponent), G=\(c.greenComponent), B=\(c.blueComponent), A=\(c.alphaComponent)")
            }
        }
    }
}

func testHUDPanelLifecycle() {
    print("Running testHUDPanelLifecycle...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    let panel = CursorHUDPanel(queueManager: queueManager)
    panel.startTracking()
    defer { panel.stopTracking() }

    assert(!panel.isVisible, "Panel should be hidden when queue is empty")

    let pngData = createMockPNGData()
    _ = queueManager.add(imageData: pngData, extension: "png")

    // Pump main runloop briefly to process observer
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    print("   Panel isVisible after item add:", panel.isVisible)
    print("   Panel frame:", panel.frame)
    print("   Panel level:", panel.level.rawValue)
    print("   Panel isFloatingPanel:", panel.isFloatingPanel)

    assert(panel.isVisible, "Panel should become visible when item is added")

    queueManager.clear()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    assert(!panel.isVisible, "Panel should hide when queue is cleared")
    print("✅ testHUDPanelLifecycle passed!")
}

print("\n--- Running CursorDeck Core Verification Tests ---")
testQueueAddAndClear()
testPasteboardWriterPayload()
testDragPasteboard()
testHUDPanelLifecycle()
print("All verification tests passed successfully! 🚀\n")
