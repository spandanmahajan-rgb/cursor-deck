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
    let tempURL2 = URL(fileURLWithPath: "/tmp/cursor_deck_test_drag2.png")
    try? createMockPNGData().write(to: tempURL)
    try? createMockPNGData().write(to: tempURL2)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL2)
    }

    // Same payload DeckHUDView builds for a drag: one NSURL per item.
    let pboard = NSPasteboard(name: .drag)
    pboard.clearContents()
    pboard.writeObjects([tempURL as NSURL, tempURL2 as NSURL])
    assert(pboard.pasteboardItems?.count == 2, "Drag pasteboard should carry one item per deck image")
    let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    assert(urls.map(\.path) == [tempURL.path, tempURL2.path], "Drag pasteboard should list the deck files in order")
    print("✅ testDragPasteboard passed!")
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

func testPinterestMediaResolverURLDetection() {
    print("Running testPinterestMediaResolverURLDetection...")
    let resolver = PinterestMediaResolver.shared
    assert(resolver.isPinterestURL("https://pin.it/7x3FcJ9B0"), "pin.it should be recognized")
    assert(resolver.isPinterestURL("https://www.pinterest.com/pin/664281013778109217/"), "canonical pin URL should be recognized")
    assert(resolver.isPinterestURL("https://in.pinterest.com/pin/12345/"), "localized pin URL should be recognized")
    assert(!resolver.isPinterestURL("https://google.com"), "google should not be recognized")
    assert(!resolver.isPinterestURL("https://github.com/pin"), "github should not be recognized")

    // Test robust Pin ID extraction
    let id1 = resolver.extractPinId(from: "https://www.pinterest.com/pin/664281013778109217/")
    assert(id1 == "664281013778109217", "Should extract id from canonical URL")

    let id2 = resolver.extractPinId(from: "https://www.pinterest.com/pin/venus-motion-design-664281013778109217/")
    assert(id2 == "664281013778109217", "Should extract id from slugged single dash URL")

    let id3 = resolver.extractPinId(from: "https://www.pinterest.com/pin/origami--664281013778109217/?invite_code=xyz")
    assert(id3 == "664281013778109217", "Should extract id with double dash and query params")

    let id4 = resolver.extractPinId(from: "https://in.pinterest.com/pin/664281013778109217/sent/?invite_code=abc")
    assert(id4 == "664281013778109217", "Should extract id with subpaths")
    print("✅ testPinterestMediaResolverURLDetection passed!")
}

func testPinterestLiveVideoResolution() {
    print("Running testPinterestLiveVideoResolution...")
    let semaphore = DispatchSemaphore(value: 0)
    var resolvedResult: PinterestMediaResult?

    PinterestMediaResolver.shared.resolveMedia(from: "https://www.pinterest.com/pin/664281013778109217/") { res in
        resolvedResult = res
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + 10.0)

    guard let result = resolvedResult else {
        fatalError("Pinterest media resolution timed out or failed")
    }

    switch result {
    case .video(let videoURL):
        print("   Direct video pin resolved to stream URL:", videoURL)
        assert(videoURL.absoluteString.contains("pinimg.com/videos/"), "Must be a direct Pinterest CDN video URL")
    case .image(let imageURL):
        fatalError("Video pin should NEVER resolve to an image: \(imageURL)")
    }

    // Also test Story Pin resolution (pin with HLS / Idea pin)
    let sem2 = DispatchSemaphore(value: 0)
    var storyResult: PinterestMediaResult?
    PinterestMediaResolver.shared.resolveMedia(from: "https://www.pinterest.com/pin/593912269657451880/") { res in
        storyResult = res
        sem2.signal()
    }
    _ = sem2.wait(timeout: .now() + 10.0)
    guard let sRes = storyResult else {
        fatalError("Story pin media resolution failed")
    }
    switch sRes {
    case .video(let videoURL):
        print("   Story/Idea video pin resolved to stream URL:", videoURL)
        assert(videoURL.absoluteString.contains("pinimg.com/videos/"), "Must be a valid video stream")
    case .image(let imageURL):
        fatalError("Story video pin should NEVER resolve to an image: \(imageURL)")
    }

    print("✅ testPinterestLiveVideoResolution passed!")
}

print("\n--- Running CursorDeck Core Verification Tests ---")
func testConcealedClipboardIsSkipped() {
    print("Running testConcealedClipboardIsSkipped...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.cursordeck.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let watcher = ClipboardWatcher(queueManager: queueManager, pasteboard: pasteboard)
    let pngData = createMockPNGData()

    // Control: a plain image copy is captured.
    pasteboard.clearContents()
    pasteboard.setData(pngData, forType: .png)
    watcher.checkForNewClipboardContent()
    assert(queueManager.count == 1, "Plain image copy should be captured")

    // Same image tagged as concealed (password manager) must be ignored.
    pasteboard.clearContents()
    pasteboard.setData(pngData, forType: .png)
    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    watcher.checkForNewClipboardContent()
    assert(queueManager.count == 1, "Concealed copy must not enter the deck")
    print("✅ testConcealedClipboardIsSkipped passed!")
}

testQueueAddAndClear()
testConcealedClipboardIsSkipped()
testPasteboardWriterPayload()
testDragPasteboard()
testHUDPanelLifecycle()
testPinterestMediaResolverURLDetection()
testPinterestLiveVideoResolution()
print("All verification tests passed successfully! 🚀\n")
