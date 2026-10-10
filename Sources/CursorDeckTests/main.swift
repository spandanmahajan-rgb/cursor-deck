// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

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
    case .board:
        fatalError("A pin URL should never resolve to a board")
    case .rateLimited:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live pin check (network condition, not code)")
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
    case .board:
        fatalError("A pin URL should never resolve to a board")
    case .rateLimited:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live story pin check")
    }

    print("✅ testPinterestLiveVideoResolution passed!")
}

func testPinterestBoardURLDetection() {
    print("Running testPinterestBoardURLDetection...")
    let r = PinterestBoardResolver.shared
    let boards: [(String, String, String)] = [
        ("https://www.pinterest.com/thandisibanda1984/sexy-cars/", "thandisibanda1984", "sexy-cars"),
        ("https://in.pinterest.com/someone/brand-refs", "someone", "brand-refs"),
        ("https://www.pinterest.co.uk/someone/type/?invite_code=abc", "someone", "type"),
        ("  https://pinterest.com/someone/motion/  ", "someone", "motion"),
    ]
    for (url, user, slug) in boards {
        guard let ref = r.boardReference(from: url) else { fatalError("Should be a board: \(url)") }
        assert(ref.username == user && ref.slug == slug, "Wrong board parsed from \(url)")
    }
    let notBoards = [
        "https://www.pinterest.com/pin/664281013778109217/",       // a pin
        "https://www.pinterest.com/someone/",                       // a profile
        "https://www.pinterest.com/someone/_saved/",                // profile tab
        "https://www.pinterest.com/someone/boards/",                // profile tab
        "https://www.pinterest.com/search/pins/?q=chairs",          // search
        "https://www.pinterest.com/ideas/chairs/123456/",           // ideas page (3 parts)
        "https://www.pinterest.com/someone/board/section/",         // board section (not supported yet)
        "https://pin.it/7x3FcJ9B0",                                 // short link: resolved later, not here
        "https://example.com/someone/board/",                       // not Pinterest
        "https://notpinterest.com/someone/board/",
    ]
    for url in notBoards { assert(r.boardReference(from: url) == nil, "Should NOT be a board: \(url)") }
    print("✅ testPinterestBoardURLDetection passed!")
}

func testPillNoticeWording() {
    print("Running testPillNoticeWording...")
    let limited = PillNotice.pinterestRateLimited(retryAfter: nil)
    assert(limited.message.contains("limit reached"), "Rate limit must say the limit was reached")
    assert(limited.detail?.contains("few minutes") == true, "Rate limit must say when to retry")
    assert(PillNotice.pinterestRateLimited(retryAfter: 30).detail == "Try again in about a minute.")
    assert(PillNotice.pinterestRateLimited(retryAfter: 150).detail == "Try again in about 3 minutes.")
    let partial = PillNotice.pinterestRateLimited(retryAfter: nil, partial: (12, 48, "Added"))
    assert(partial.detail?.hasPrefix("Added 12 of 48.") == true, "Partial rate limit must report progress")
    assert(PillNotice.boardOffer(name: "Refs", pinCount: 512, cap: 100, addAll: {}, choose: {}).detail?
        .contains("first 100") == true, "Big boards must say only the first 100 are added")
    assert(PillNotice.boardAdded(added: 45, requested: 48, name: "Refs").tone == .warning)
    assert(PillNotice.boardAdded(added: 3, requested: 3, name: "Refs").duration == 2, "Plain confirmation is brief")
    let again = PillNotice.boardAlreadyAdded(name: "Refs", choose: {})
    assert(again.message == "“Refs” is already in the deck" && again.alternateAction != nil && again.primaryAction == nil,
           "Re-copied board: says so, ⌥-click still opens the picker, ⌘-click adds nothing")
    assert(PillNotice.boardAdded(added: 5, requested: 5, name: "Refs", alreadyInDeck: 20).detail == "20 pins were already in the deck.")
    print("✅ testPillNoticeWording passed!")
}

func testBoardPickerSelection() {
    print("Running testBoardPickerSelection...")
    let board = PinterestBoard(id: "1", name: "Test", pinCount: 7, username: "u", slug: "s")
    func pin(_ n: Int) -> PinterestBoardPin {
        let u = URL(string: "https://i.pinimg.com/236x/\(n).jpg")!
        return PinterestBoardPin(id: "\(n)", title: nil, thumbnailURL: u, imageURL: u, videoURL: nil, dominantColor: nil)
    }
    let model = BoardPickerModel(board: board)
    model.appendPage((1...5).map(pin), nextBookmark: "next")
    assert(model.selection.count == 5 && model.allSelected, "Pins start selected")
    assert(model.hasMore, "A bookmark means more pages")
    model.toggle(pin(2))
    assert(!model.selection.contains("2"), "Click deselects")
    model.toggle(pin(4), extendingRange: true)                  // Shift-click: 2...4 take pin 4's new state (off)
    assert(model.selection == ["1", "5"], "Shift-click applies to the range, got \(model.selection.sorted())")
    model.selectNone()
    model.appendPage([pin(6), pin(7), pin(1)], nextBookmark: nil)   // duplicate pin 1 is ignored
    assert(model.pins.count == 7 && model.selection.isEmpty, "After Select None, new pins arrive unselected")
    assert(!model.hasMore, "No bookmark means the board is fully loaded")
    model.selectAll()
    assert(model.selectedPins.map(\.id) == (1...7).map(String.init), "Select All keeps board order")
    model.setPinsInDeck(["3", "6"])
    assert(!model.selection.contains("3") && !model.selection.contains("6"), "Pins already in the deck start unselected")
    model.toggle(pin(3))
    assert(model.selection.contains("3"), "...but can still be chosen on purpose")
    model.appendPage([pin(8)], nextBookmark: nil)
    assert(model.selection.contains("8"), "New pins not in the deck still arrive selected")
    print("✅ testBoardPickerSelection passed!")
}

func testPillNoticeShowsAndHides() {
    print("Running testPillNoticeShowsAndHides...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let panel = CursorHUDPanel(queueManager: queueManager)
    assert(!panel.isVisible, "Empty deck: pill hidden")
    let notice = PillNotice.pinterestRateLimited(retryAfter: nil)
    panel.show(notice)
    assert(panel.isVisible, "A notice shows the pill even with an empty deck")
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))      // let the size animation settle
    let expected = (panel.contentView as! DeckHUDView).preferredSize(for: notice)
    assert(abs(panel.frame.width - expected.width) <= 1 && abs(panel.frame.height - expected.height) <= 1,
           "Pill grows to fit the notice: \(panel.frame.size) vs \(expected)")
    assert(expected.height == 42, "Two-line notice is 42pt tall")
    panel.dismissNotice()
    assert(panel.isVisible, "The pill collapses back to its dot before hiding")
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    assert(!panel.isVisible, "After collapsing, an empty deck hides the pill")
    print("✅ testPillNoticeShowsAndHides passed!")
}

func testPinterestLiveBoard() {
    print("Running testPinterestLiveBoard...")
    let sem = DispatchSemaphore(value: 0)
    var boardResult: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver.shared.fetchBoard(username: "thandisibanda1984", slug: "sexy-cars") { boardResult = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    switch boardResult {
    case .failure(.rateLimited)?:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live board check"); return
    case .failure(let error)?:
        fatalError("Live board lookup failed: \(error)")
    case nil:
        fatalError("Live board lookup timed out")
    case .success(let board)?:
        assert(board.pinCount > 0, "Board should report pins")
        print("   Board “\(board.name)”: about \(board.pinCount) pins")
        var pageResult: Result<(pins: [PinterestBoardPin], nextBookmark: String?), PinterestError>?
        PinterestBoardResolver.shared.fetchPins(of: board, bookmark: nil) { pageResult = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        guard case .success(let page)? = pageResult else {
            if case .failure(.rateLimited)? = pageResult { print("   ⚠️ rate-limited on the pin page; skipping"); return }
            fatalError("Live pin page failed: \(String(describing: pageResult))")
        }
        assert(!page.pins.isEmpty, "First page should have pins")
        assert(page.pins.allSatisfy { $0.thumbnailURL.host?.hasSuffix("pinimg.com") == true }, "Thumbnails come from Pinterest's CDN")
        print("   First page: \(page.pins.count) pins, \(page.pins.filter(\.isVideo).count) with an MP4")
    }
    var missing: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver.shared.fetchBoard(username: "thandisibanda1984", slug: "no-such-board-xyz") { missing = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    if case .failure(.rateLimited)? = missing { print("   ⚠️ rate-limited; skipping not-found check") }
    else { assert(missing == .failure(.notFound), "A missing board must report notFound, got \(String(describing: missing))") }
    print("✅ testPinterestLiveBoard passed!")
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
testPinterestBoardURLDetection()
testPillNoticeWording()
testBoardPickerSelection()
testPillNoticeShowsAndHides()
testPinterestLiveBoard()
print("All verification tests passed successfully! 🚀\n")
