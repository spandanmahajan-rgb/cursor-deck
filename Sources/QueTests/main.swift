// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AppKit
import ImageIO
import QueCore

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

    // Paused tracking: the pill stays visible but lets every click through; resuming takes clicks again.
    panel.isTrackingPaused = true
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(panel.isVisible && panel.ignoresMouseEvents, "Paused pill stays visible and passes clicks through")
    let pill = panel.contentView as! DeckHUDView
    assert(pill.isPaused, "Paused pill shows the orange dot")
    assert((pill.accessibilityValue() as? String) == "Paused, 1 item", "VoiceOver hears it's paused")
    panel.isSuspended = true; panel.isSuspended = false   // board picker open/close while paused
    assert(panel.ignoresMouseEvents, "Still click-through after the board picker closes while paused")
    panel.isTrackingPaused = false
    assert(!panel.ignoresMouseEvents, "Resumed pill takes clicks again")
    assert(!pill.isPaused && (pill.accessibilityValue() as? String) == "1 item", "Resumed: green dot, plain count")

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

    // No answer = offline or Pinterest is down: a network condition, so it must not block a release.
    guard let result = resolvedResult else {
        print("   ⚠️ Pinterest didn't answer; skipping the live pin checks")
        return
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
        print("   ⚠️ Pinterest didn't answer; skipping the live story pin check")
        return
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
    let prep = PillNotice.boardPreparing(name: "Refs")
    assert(prep.duration == nil && prep.message.hasSuffix("is joining Que"), "⌘-click turns the offer into progress that stays until done")
    assert(PillNotice.boardOnPrivateProfile().message == "This board is on a private profile")
    let again = PillNotice.boardAlreadyAdded(name: "Refs", choose: {})
    assert(again.message == "“Refs” is already in Que" && again.alternateAction != nil && again.primaryAction == nil,
           "Re-copied board: says so, ⌥-click opens the picker, nothing is added again")
    assert(PillNotice.boardAdded(added: 5, requested: 5, name: "Refs", alreadyInDeck: 20).detail == "20 pins were already in Que.")
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
    let expected = (panel.contentView as! DeckHUDView).preferredSize(for: notice)
    // Let the size animation settle (up to 1.5s: it runs slower while the machine is busy).
    let settleBy = Date().addingTimeInterval(1.5)
    while Date() < settleBy && (abs(panel.frame.width - expected.width) > 1 || abs(panel.frame.height - expected.height) > 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    assert(abs(panel.frame.width - expected.width) <= 1 && abs(panel.frame.height - expected.height) <= 1,
           "Pill grows to fit the notice: \(panel.frame.size) vs \(expected)")
    assert(expected.height == 42, "Two-line notice is 42pt tall")
    panel.dismissNotice()
    assert(panel.isVisible, "The pill collapses back to its dot before hiding")
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    assert(!panel.isVisible, "After collapsing, an empty deck hides the pill")
    print("✅ testPillNoticeShowsAndHides passed!")
}

func testScreenshotOverlayDetection() {
    print("Running testScreenshotOverlayDetection...")
    // Seen on macOS 27 while taking ⌘⇧4 / ⌘⇧5 screenshots (window owner, layer)
    assert(CursorHUDPanel.isScreenshotWindow(ownerName: "screencapture", bundleID: nil, layer: 1498), "⌘⇧4 selection overlay")
    assert(CursorHUDPanel.isScreenshotWindow(ownerName: "Bildschirmfoto", bundleID: "com.apple.screencaptureui", layer: 1499),
           "⌘⇧5 toolbar, matched by bundle id whatever the language")
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Screenshot", bundleID: "com.apple.screencaptureui", layer: 24),
           "The post-capture thumbnail (low layer) is not the overlay")
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Google Chrome", bundleID: "com.google.Chrome", layer: 0))
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Dock", bundleID: "com.apple.dock", layer: 20))
    print("✅ testScreenshotOverlayDetection passed!")
}

func testBackgroundImport() {
    print("Running testBackgroundImport...")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-import-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 40x20 image saved as HEIC with "rotate 90°" stored as metadata (like an iPhone photo), plus a TIFF and a PNG.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let heic = dir.appendingPathComponent("photo.heic"), tiff = dir.appendingPathComponent("scan.tiff"), png = dir.appendingPathComponent("plain.png")
    let dest = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, rep.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    assert(CGImageDestinationFinalize(dest), "test HEIC written")
    try! rep.tiffRepresentation!.write(to: tiff)
    try! rep.representation(using: .png, properties: [:])!.write(to: png)

    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    var added: [DeckItem]?
    let returnedAt = CACurrentMediaTime()
    queueManager.addFiles([heic, tiff, png]) { added = $0 }
    assert(added == nil, "Import must not finish synchronously (it runs off the main thread)")
    _ = returnedAt
    let deadline = Date().addingTimeInterval(10)
    while added == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard let items = added else { fatalError("Background import timed out") }
    assert(items.count == 3 && queueManager.count == 3, "All three files added")
    assert(items.map { $0.fileURL.pathExtension } == ["png", "png", "png"], "HEIC and TIFF become PNG; order kept")
    assert(items.map { $0.originalFileName } == ["photo.heic", "scan.tiff", "plain.png"], "Copy order is preserved")
    let first = CGImageSourceCreateWithURL(items[0].fileURL as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
    assert(first?[kCGImagePropertyPixelWidth] as? Int == 20 && first?[kCGImagePropertyPixelHeight] as? Int == 40,
           "Phone-photo rotation is applied (40x20 rotated 90° → 20x40)")
    print("✅ testBackgroundImport passed!")
}

/// Deck preview multi-select: removing several images is one queue change, keeps order, and deletes the files.
func testRemoveSeveralItems() {
    print("Running testRemoveSeveralItems...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let items = (0..<5).compactMap { _ in queueManager.add(imageData: createMockPNGData(), extension: "png") }
    assert(items.count == 5, "Should add 5 items")

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // let the five "added" updates go out first
    var notifications = 0
    queueManager.addObserver { _ in notifications += 1 }
    queueManager.remove(ids: [items[1].id, items[3].id])
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    assert(queueManager.items.map { $0.id } == [items[0].id, items[2].id, items[4].id], "Remaining items keep their order")
    assert(!FileManager.default.fileExists(atPath: items[1].fileURL.path), "Removed file 1 should be deleted")
    assert(!FileManager.default.fileExists(atPath: items[3].fileURL.path), "Removed file 3 should be deleted")
    assert(FileManager.default.fileExists(atPath: items[2].fileURL.path), "Kept file should stay")
    assert(notifications == 1, "One refresh for the whole removal, got \(notifications)")

    queueManager.remove(ids: [UUID()])   // unknown id: no change, no refresh
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    assert(notifications == 1 && queueManager.count == 3, "Unknown ids change nothing")
    print("✅ testRemoveSeveralItems passed!")
}

/// CursorDeck → Que: the bundle renames itself once, and only when it's safe.
func testLegacyAppRename() {
    print("Running testLegacyAppRename...")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("que-rename-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let legacy = dir.appendingPathComponent("CursorDeck.app")
    try? fm.createDirectory(at: legacy.appendingPathComponent("Contents"), withIntermediateDirectories: true)

    assert(LegacyAppRename.targetPath(for: "/Applications/Que.app") == nil, "Que.app is left alone")
    assert(LegacyAppRename.targetPath(for: "/Applications/Other.app") == nil, "Other apps are left alone")
    let renamed = LegacyAppRename.renameIfNeeded(bundlePath: legacy.path)
    assert(renamed == dir.appendingPathComponent("Que.app").path, "CursorDeck.app becomes Que.app")
    assert(fm.fileExists(atPath: dir.appendingPathComponent("Que.app/Contents").path) && !fm.fileExists(atPath: legacy.path),
           "Bundle contents moved")

    // A Que.app already there (e.g. installed from the DMG): never overwrite it.
    try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    assert(LegacyAppRename.renameIfNeeded(bundlePath: legacy.path) == nil, "Existing Que.app is not replaced")
    assert(fm.fileExists(atPath: legacy.path), "CursorDeck.app stays when Que.app exists")
    print("✅ testLegacyAppRename passed!")
}

/// CursorDeck 1.x's Login Item is replaced by Que's, keeping whether it was on.
func testLoginItemMigration() {
    print("Running testLoginItemMigration...")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("que-agents-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = dir.appendingPathComponent("com.cursordeck.app.plist")

    let off = LaunchAtLoginManager(launchAgentsDirectory: dir)
    off.migrateLegacyAgent()
    assert(!off.isEnabled, "No old Login Item: stays off")

    try? "<plist/>".write(to: legacy, atomically: true, encoding: .utf8)
    let on = LaunchAtLoginManager(launchAgentsDirectory: dir)
    on.migrateLegacyAgent()
    assert(on.isEnabled && !fm.fileExists(atPath: legacy.path), "Old Login Item replaced by Que's")
    let plist = NSDictionary(contentsOf: dir.appendingPathComponent("com.que.app.login.plist"))
    assert((plist?["ProgramArguments"] as? [String])?.first == on.appExecutablePath, "Opens Que")
    print("✅ testLoginItemMigration passed!")
}

/// Update dot: the dot-less menu bar mark loads at 1x and 2x, and the dot sits inside the 16pt mark.
func testUpdateDotAssets() {
    print("Running testUpdateDotAssets...")
    let image = QueLogoAsset.menuBarImageWithoutDot
    assert(image.isTemplate && image.representations.map { $0.pixelsWide }.sorted() == [16, 32], "Dot-less mark has 1x and 2x")
    let dot = QueLogoAsset.updateDotRect
    assert(dot.minX >= 0 && dot.maxX <= 16 && dot.minY >= 0 && dot.maxY <= 16.01, "Dot sits inside the 16pt mark")
    print("✅ testUpdateDotAssets passed!")
}

/// The welcome shows for any copy installed by hand (new or returning users), not after updates or on relaunch.
func testWelcomeOnFreshInstalls() {
    print("Running testWelcomeOnFreshInstalls...")
    let suite = "com.que.tests.welcome.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    d.set(1_700_000_000.0, forKey: "CursorDeck_lastBackgroundCheck")   // a returning CursorDeck user

    assert(WelcomeWindowController.shouldShowWelcome(copyID: "100", defaults: d), "Installed from the DMG: welcome")
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "100", defaults: d), "Same copy opened again: no welcome")
    d.set(true, forKey: WelcomeWindowController.updateInProgressKey)
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "200", defaults: d), "New copy from an in-app update: no welcome")
    assert(d.object(forKey: WelcomeWindowController.updateInProgressKey) == nil, "Update note cleared")
    assert(WelcomeWindowController.shouldShowWelcome(copyID: "300", defaults: d), "Deleted and reinstalled: welcome again")
    d.set(true, forKey: WelcomeWindowController.updateInProgressKey)   // an update that failed (old copy reopened)
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "300", defaults: d), "Failed update: no welcome")
    assert(WelcomeWindowController.shouldShowWelcome(copyID: "400", defaults: d), "...and the note doesn't linger")
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: nil, defaults: d), "Development builds: never")
    print("✅ testWelcomeOnFreshInstalls passed!")
}

/// Video → GIF / pin jobs: the ticket ends exactly once, a dropped one counts as failed, and Que stays on screen
/// (as just the dot when empty) while working.
func testWorkingIndicator() {
    print("Running testWorkingIndicator...")
    var outcomes: [WorkTicket.Outcome] = []
    let a = WorkTicket(isVideo: true) { outcome, _ in outcomes.append(outcome) }
    a.finish(.added); a.finish(.failed)
    assert(outcomes == [.added], "A job ends once")
    var dropped: WorkTicket? = WorkTicket(isVideo: false) { outcome, isVideo in
        outcomes.append(outcome); assert(!isVideo)
    }
    _ = dropped; dropped = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    assert(outcomes == [.added, .failed], "A job dropped without ending counts as failed (no stuck dot)")

    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let panel = CursorHUDPanel(queueManager: queueManager)
    panel.isWorking = true
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    assert(panel.isVisible, "Working on an empty Que: still on screen")
    assert(abs(panel.frame.width - 28) <= 1, "...as just the 28pt dot, got \(panel.frame.size)")
    assert((panel.contentView as! DeckHUDView).isWorking, "Dot is in its working state")
    panel.isWorking = false
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    assert(!panel.isVisible, "Done and still empty (e.g. cancelled): hidden again")
    assert(PillNotice.makingGIF().message == "Making a GIF" && PillNotice.makingGIF().detail == "Saving it a spot in Que.", "Wording")
    print("✅ testWorkingIndicator passed!")
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
    // A public board on a PRIVATE profile (a real friend's account): must say "private profile", not "secret or deleted".
    var privateResult: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver().fetchBoard(username: "apurvasavadi03", slug: "prakrutisaar") { privateResult = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    if case .failure(.rateLimited)? = privateResult { print("   ⚠️ rate-limited; skipping private-profile check") }
    else { assert(privateResult == .failure(.privateProfile), "Board on a private profile must report privateProfile, got \(String(describing: privateResult))") }
    print("✅ testPinterestLiveBoard passed!")
}

print("\n--- Running Que Core Verification Tests ---")
func testConcealedClipboardIsSkipped() {
    print("Running testConcealedClipboardIsSkipped...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.que.tests.\(UUID().uuidString)"))
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

/// Every SF Symbol named in Que's code must exist on macOS 13 (Que's minimum): a missing symbol draws nothing, which
/// left Shake to Clear's icon empty for a user on an older macOS. Newer symbols need a runtime fallback (`QueSymbol`).
/// Checked against macOS's own symbol list, from the source files (run from the repo root; skips if either is missing).
func testSymbolsExistOnMacOS13() {
    let plistPath = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
    let sourcesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/QueCore")
    guard let plist = NSDictionary(contentsOfFile: plistPath),
          let symbols = plist["symbols"] as? [String: String],
          let releases = plist["year_to_release"] as? [String: [String: String]],
          let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
          !files.isEmpty else {
        print("⚠️ testSymbolsExistOnMacOS13 skipped (symbol list or sources not found)")
        return
    }
    let pattern = try! NSRegularExpression(pattern: #"(?:systemName|systemSymbolName|symbol): "([a-z0-9.]+)""#)
    var checked = 0
    for file in files where file.pathExtension == "swift" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            if text.contains("// SYMBOL-FALLBACK: \(name)") { continue }   // newer symbol with a checked fallback
            guard let year = symbols[name] else {
                assert(false, "\(file.lastPathComponent): SF Symbol “\(name)” doesn't exist")
                continue
            }
            let macOS = releases[year]?["macOS"] ?? "99"
            let major = Double(macOS) ?? 99
            assert(major <= 13, "\(file.lastPathComponent): SF Symbol “\(name)” needs macOS \(macOS); Que supports 13+. Add a fallback.")
            checked += 1
        }
    }
    assert(checked > 20, "Expected to find Que's symbols in the sources (found \(checked))")
    print("✅ testSymbolsExistOnMacOS13 passed! (\(checked) symbol uses)")
}

func testClearCountBumps() {
    let q = DeckQueueManager()
    defer { q.cleanup() }
    let before = q.clearCount
    q.clear()
    assert(q.clearCount == before + 1, "clear() must bump clearCount so in-flight jobs can drop their results")
    q.cleanup()
}

func testVersionCompare() {
    print("Running testVersionCompare...")
    assert(UpdateManager.compare("2.10.0", "2.9.0") > 0, "Numbers, not text: 2.10 is newer than 2.9")
    assert(UpdateManager.compare("2.6.1", "2.6.0") > 0)
    assert(UpdateManager.compare("2.6.0", "2.7.0") < 0)
    assert(UpdateManager.compare("2.6", "2.6.0") == 0, "Missing parts count as 0")
    assert(UpdateManager.compare("2.6.0", "2.6.0") == 0)
    assert(UpdateManager.compare("2.7.0-beta", "2.6.0") > 0, "A suffix doesn't hide the last number")
    print("✅ testVersionCompare passed!")
}

func testReleaseNotesAsBullets() {
    print("Running testReleaseNotesAsBullets...")
    let bullets = UpdateManager.releaseNoteItems("- Hold ⌥ to call Que over.\n* **Faster** drops\n\n• Shake icon on older macOS")
    assert(bullets == ["Hold ⌥ to call Que over.", "Faster drops", "Shake icon on older macOS"], "Bullet lines come out clean: \(bullets)")
    let paragraph = UpdateManager.releaseNoteItems("Que now works with one key. ⌘ no longer moves Que, so ⌘-click is safe. Icons show on older macOS.")
    assert(paragraph.count == 3, "An old-style paragraph becomes one item per sentence: \(paragraph)")
    let many = UpdateManager.releaseNoteItems((1...12).map { "- Change \($0)" }.joined(separator: "\n"))
    assert(many.count == 8 && many.last == "And a few smaller fixes.", "Long lists are capped")
    assert(UpdateManager.releaseNoteItems("## What's new\n- One").first == "One", "Headings are dropped")
    let view = UpdateManager.releaseNotesView(bullets)
    assert(view.frame.width == 300 && view.frame.height > 40, "The notes view has a real size")
    print("✅ testReleaseNotesAsBullets passed!")
}

/// "Report a Problem…": the form link carries only Que/Mac details and the sanitized text of Que's recent messages.
/// Never the clipboard, links or board names; "What happened?" is left for the user.
func testProblemReport() {
    print("Running testProblemReport...")
    ProblemReport.resetForTesting()
    let now = Date()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("CLIPBOARD-SECRET https://example.com/private", forType: .string)

    for i in 1...12 { ProblemReport.record(PillNotice("Message \(i)"), at: now.addingTimeInterval(-600)) }
    ProblemReport.record(PillNotice("12 pins from “My secret board” joined Que", detail: "See https://pinterest.com/x/y"),
                         at: now.addingTimeInterval(-90))
    let recent = ProblemReport.recentText(now: now)
    let lines = recent.split(separator: "\n").filter { !$0.isEmpty && !$0.hasPrefix("Update log") }
    assert(lines.prefix(10).count == 10 && !recent.contains("Message 3\n") && recent.contains("Message 12"),
           "Keeps only the last 10 messages: \(recent)")
    assert(recent.contains("1 min ago  12 pins from “…” joined Que / See [link]"), "Board names and links removed: \(recent)")
    assert(recent.contains("10 min ago  Message 4"), "Relative times")

    let url = ProblemReport.url(now: now)!.absoluteString
    assert(url.hasPrefix(ProblemReport.formURL + "?usp=pp_url&"), "Opens the published form, pre-filled")
    assert(url.contains(ProblemReport.detailsField + "=Que%20") && url.contains(ProblemReport.recentField + "="),
           "Both Que-filled answers are in the link")
    assert(!url.contains("entry.54490118"), "\"What happened?\" is left for the user")
    let decoded = url.removingPercentEncoding ?? ""
    assert(!decoded.contains("CLIPBOARD-SECRET") && !decoded.contains("example.com") && !decoded.contains("pinterest.com")
           && !decoded.contains("My secret board"), "No clipboard, links or board names in the link")
    assert(!url.contains("+"), "Spaces are encoded as %20 (Google reads + as a space)")
    assert(url.count < 2500, "The link stays a safe length (\(url.count))")

    let details = ProblemReport.details()
    assert(details.hasPrefix("Que \(UpdateManager.currentVersion), macOS ") &&
           (details.hasSuffix("Apple silicon") || details.hasSuffix("Intel")), "Details: \(details)")

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    assert(ProblemReport.failedUpdateLines(log: "a check\nanother check") == nil, "A healthy update log is left out")
    let failed = ProblemReport.failedUpdateLines(log: "check\ndownload FAILED: \(home)/Downloads/x.zip")
    assert(failed?.last == "download FAILED: ~/Downloads/x.zip", "Failed update lines are included, home folder shortened")
    ProblemReport.resetForTesting()
    assert(ProblemReport.recentText(now: now).hasPrefix("No messages yet"), "Empty list says so")
    pasteboard.clearContents()
    print("✅ testProblemReport passed!")
}

testQueueAddAndClear()
testSymbolsExistOnMacOS13()
testClearCountBumps()
testVersionCompare()
testReleaseNotesAsBullets()
testProblemReport()
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
testScreenshotOverlayDetection()
testBackgroundImport()
testRemoveSeveralItems()
testLegacyAppRename()
testLoginItemMigration()
testUpdateDotAssets()
testWelcomeOnFreshInstalls()
testWorkingIndicator()
testPinterestLiveBoard()
print("All verification tests passed successfully! 🚀\n")
