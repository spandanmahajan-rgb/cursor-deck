# CursorDeck — Complete Standalone Code Audit & Optimization Package (v1.1.8)

> **Instructions for Claude**:
> You are acting as a Principal macOS AppKit & Systems Swift Engineer.
> This single file contains **all project context, architecture guidelines, and the complete source code** of all 19 core Swift files of **CursorDeck (v1.1.8)**.
> You do **not** need external repository access—everything is contained below.
>
> Please conduct a thorough, line-by-line review across all included source files to identify:
> 1. **Code Bloat & Redundancy**: Dead code, unused helper methods/types, duplicated logic, or unnecessary complexity.
> 2. **Memory Leaks & Retain Cycles**: Strong reference cycles in closures (`[weak self]`), `NSEvent` global/local click monitors, `CVPixelBuffer`/`CGImage` autorelease buffers in video processing, and `DispatchSource` cancellation.
> 3. **Thread Safety & Race Conditions**: Concurrency hazards between background tasks, clipboard polling ladders, `DeckQueueManager`, and main-thread UI operations.
> 4. **Modern macOS API & Performance Cleanups**: Deprecation fixes (e.g. `AVURLAsset.duration` in macOS 13+), WindowServer multi-display edge cases, battery impact (ensuring 0% CPU and sleeping timers when idle).
> 5. **Actionable Fixes & Diffs**: Provide clean, concrete, drop-in replacement code snippets or diffs for your recommendations.

---

## 1. Project Overview & Architectural Invariants

* **What CursorDeck Is**: A native macOS menu bar utility acting as a visual accumulator attached to the cursor (`[ N ⧉ ]`). Designers and researchers copy images or Pinterest video links (`⌘C`), take screenshots (`⌘⇧4`), accumulate them in a liquid frosted-glass pill following the cursor, and burst-drop them onto Google Slides, Keynote, Figma, or chat (WhatsApp/Slack).
* **Stack**: 100% Native Swift (Swift 6.1.2) + AppKit + SwiftUI. Universal Binary (Apple Silicon + Intel).
* **Strict Invariant 1 — ZERO System Permissions**: The app MUST NOT request Accessibility (`AXUIElement`), Screen Recording, or Input Monitoring permissions. All mouse tracking, clipboard sensing, and screenshot ingestion must remain non-intrusive via public AppKit APIs.
* **Strict Invariant 2 — Zero-Password In-Place Updates**: Updates MUST NOT trigger admin password / Touch ID prompts in `/Applications`. Auto-updates use in-place `.zip` swapping.
* **Strict Invariant 3 — Popover Geometry**: The menu bar popover is a borderless, arrowless floating `NSPanel` (`DeckControlCenterPanel`) with fixed 256×350 pt size across both Controls and How-To-Use tabs.

---

## 2. Complete Source Code Files

### File: `Sources/CursorDeckApp/main.swift`

```swift
import Foundation
import AppKit
import CursorDeckCore

// Configure NSApplication as a background Agent (LSUIElement: true, zero dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Ensure Launch at Startup is active by default when installed in /Applications
if Bundle.main.bundlePath.hasPrefix("/Applications") && !LaunchAtLoginManager.shared.isEnabled {
    LaunchAtLoginManager.shared.installLaunchAgent()
}

let queueManager = DeckQueueManager()
let clipboardWatcher = ClipboardWatcher(queueManager: queueManager)
let screenshotWatcher = ScreenshotWatcher(queueManager: queueManager)
let hudPanel = CursorHUDPanel(queueManager: queueManager)
let menuBarManager = MenuBarManager(
    queueManager: queueManager,
    clipboardWatcher: clipboardWatcher,
    screenshotWatcher: screenshotWatcher,
    hudPanel: hudPanel
)

clipboardWatcher.start()
screenshotWatcher.start()
hudPanel.startTracking()

// Quiet background update check 4 seconds after launch
DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
    UpdateManager.shared.checkForUpdates(userInitiated: false)
}

// Keep app event loop running
app.run()

```

---

### File: `Sources/CursorDeckCore/DeckItem.swift`

```swift
import Foundation

public enum DeckItemType: String, Codable {
    case image
    case fileURL
}

public struct DeckItem: Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let type: DeckItemType
    public let fileURL: URL
    public let originalFileName: String?
    public let dataSize: Int

    public init(id: UUID = UUID(), createdAt: Date = Date(), type: DeckItemType, fileURL: URL, originalFileName: String? = nil, dataSize: Int) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.fileURL = fileURL
        self.originalFileName = originalFileName
        self.dataSize = dataSize
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckQueueManager.swift`

```swift
import Foundation
import AppKit

public final class DeckQueueManager {
    public private(set) var items: [DeckItem] = []
    public private(set) var sessionDirectory: URL

    public var count: Int {
        return items.count
    }

    public var isEmpty: Bool {
        return items.isEmpty
    }

    public var onChange: (([DeckItem]) -> Void)? {
        didSet {
            notifyObservers()
        }
    }

    private var observers: [UUID: ([DeckItem]) -> Void] = [:]

    @discardableResult
    public func addObserver(_ observer: @escaping ([DeckItem]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        let currentItems = items
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onChange?(currentItems)
            for (_, observer) in self.observers {
                observer(currentItems)
            }
        }
    }

    public init(sessionBaseDirectory: URL? = nil) {
        let base = sessionBaseDirectory ?? URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)
        let sessionId = UUID().uuidString
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
    }

    deinit {
        cleanup()
    }

    /// Returns true if the file was created or owned by CursorDeck, preventing self-capture loops
    public func owns(_ url: URL) -> Bool {
        return url.path.hasPrefix(sessionDirectory.path) || url.path.contains("cursor-deck")
    }

    @discardableResult
    public func add(imageData: Data, extension fileExt: String = "png", originalName: String? = nil) -> DeckItem? {
        guard !imageData.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let itemId = UUID()
        let filename = originalName ?? "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(fileExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: targetURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
            let item = DeckItem(
                id: itemId,
                type: .image,
                fileURL: targetURL,
                originalFileName: originalName,
                dataSize: imageData.count
            )
            items.append(item)
            notifyObservers()
            return item
        } catch {
            print("[DeckQueueManager] Failed to write item: \(error)")
            return nil
        }
    }

    @discardableResult
    public func add(existingFileURL: URL) -> DeckItem? {
        let itemId = UUID()
        let ext = existingFileURL.pathExtension.lowercased()
        
        // Google Slides and web canvas editors strictly require PNG/JPEG/GIF/WEBP.
        // If the source file is HEIC, TIFF, or non-standard, convert it to high-res standard PNG!
        if ext == "heic" || ext == "tiff" || ext == "tif" || ext == "bmp" {
            if let image = NSImage(contentsOf: existingFileURL),
               let tiffData = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]) {
                let filename = "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).png"
                let targetURL = sessionDirectory.appendingPathComponent(filename)
                do {
                    try pngData.write(to: targetURL, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
                    let item = DeckItem(
                        id: itemId,
                        type: .image,
                        fileURL: targetURL,
                        originalFileName: existingFileURL.lastPathComponent,
                        dataSize: pngData.count
                    )
                    items.append(item)
                    notifyObservers()
                    return item
                } catch {
                    print("[DeckQueueManager] Failed to convert/write converted PNG: \(error)")
                }
            }
        }

        // Standard copy for directly supported image formats (png, jpg, jpeg, gif, webp, svg)
        let safeExt = ext.isEmpty ? "png" : ext
        let filename = "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(safeExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: existingFileURL, to: targetURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
            let item = DeckItem(
                id: itemId,
                type: .fileURL,
                fileURL: targetURL,
                originalFileName: existingFileURL.lastPathComponent,
                dataSize: fileSize
            )
            items.append(item)
            notifyObservers()
            return item
        } catch {
            print("[DeckQueueManager] Failed to copy item from \(existingFileURL): \(error)")
            return nil
        }
    }

    public func removeLast() -> DeckItem? {
        guard let item = items.popLast() else { return nil }
        try? FileManager.default.removeItem(at: item.fileURL)
        notifyObservers()
        return item
    }

    @discardableResult
    public func remove(id: UUID) -> DeckItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        try? FileManager.default.removeItem(at: item.fileURL)
        notifyObservers()
        return item
    }

    public func clear() {
        let oldSessionDirectory = self.sessionDirectory
        items.removeAll()
        
        let sessionId = UUID().uuidString
        let base = URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        
        notifyObservers()

        // Keep previously dropped files on disk for 60 seconds so destination apps
        // (WhatsApp, Google Slides, Chrome, Finder) can asynchronously read and upload them!
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60.0) {
            try? FileManager.default.removeItem(at: oldSessionDirectory)
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}

```

---

### File: `Sources/CursorDeckCore/ClipboardWatcher.swift`

```swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol ClipboardWatcherDelegate: AnyObject {
    func clipboardWatcher(_ watcher: ClipboardWatcher, didCaptureItem item: DeckItem)
}

public final class ClipboardWatcher {
    private let pasteboard: NSPasteboard
    private var lastProcessedChangeCount: Int = -1
    private var timer: Timer?
    private var retryWorkItems: [DispatchWorkItem] = []
    private let queueManager: DeckQueueManager
    public weak var delegate: ClipboardWatcherDelegate?

    public var isWatching: Bool {
        return timer != nil
    }

    /// Whether tracking is paused by the user
    public var isPaused: Bool = false {
        didSet {
            guard isPaused, !oldValue else { return }
            // FIX: pausing invalidates everything in flight (retries, downloads, conversions,
            // Pinterest lookups). The original only dropped results that happened to finish
            // while still paused; a pause+resume in quick succession let stale results through.
            generation &+= 1
            cancelPendingRetries()
            cancelInFlightDownloads()
        }
    }

    /// Bumped on pause/stop. Async work captures it at start and is discarded if it changed.
    private var generation = 0
    private var pendingRetryChangeCount: Int = -1
    private var inFlightTasks: [URLSessionTask] = []

    private lazy var downloadSession: URLSession = {
        // FIX: URLSession.shared has a 7-day resource timeout and no size awareness.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    /// Whether smart filtering for pure vector/layer authoring copies is active
    public var isSmartFilterEnabled: Bool = true

    private let excludedPasteboardSignatures: [String] = [
        "com.adobe.illustrator",
        "adobe illustrator",
        "com.adobe.agave",
        "com.adobe.photoshop",
        "com.adobe.indesign",
        "application/vnd.figma.fig-kiwi",
        "figma/data",
        "com.bohemiancoding.sketch.layer",
        "com.bohemiancoding.sketch",
        "com.apple.iwork.tsd.clipboard",
        "com.seriflabs.affinity",
        "org.blender"
    ]

    private let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "svg"
    ]

    private let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm"
    ]

    public init(queueManager: DeckQueueManager, pasteboard: NSPasteboard = .general) {
        self.queueManager = queueManager
        self.pasteboard = pasteboard
        self.lastProcessedChangeCount = pasteboard.changeCount
    }

    public func start(pollingInterval: TimeInterval = 0.08) {
        guard timer == nil else { return }
        lastProcessedChangeCount = pasteboard.changeCount

        let t = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.checkForNewClipboardContent()
        }
        t.tolerance = pollingInterval * 0.25   // FIX: lets macOS coalesce wakeups (energy)
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
        cancelPendingRetries()
        cancelInFlightDownloads()
    }

    private func cancelPendingRetries() {
        for item in retryWorkItems {
            item.cancel()
        }
        retryWorkItems.removeAll()
        pendingRetryChangeCount = -1
    }

    private func isCurrent(_ gen: Int) -> Bool {
        return !isPaused && gen == generation
    }

    private func track(_ task: URLSessionTask) {
        inFlightTasks.removeAll { $0.state == .completed }
        inFlightTasks.append(task)
    }

    private func cancelInFlightDownloads() {
        inFlightTasks.forEach { $0.cancel() }
        inFlightTasks.removeAll()
    }

    public func checkForNewClipboardContent() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastProcessedChangeCount else { return }

        guard !isPaused else {
            lastProcessedChangeCount = currentCount
            return
        }

        // FIX (retry storm): the original re-entered here on EVERY 80ms poll while
        // lastProcessedChangeCount was unchanged. Each pass cancelled the pending retries and
        // rescheduled all five, so the 150/280/450ms retries never fired, the "give up" branch
        // was never reached, and any non-image copy (plain text!) made the watcher re-scan the
        // pasteboard 12x/second until the next copy. One retry chain per changeCount now.
        if currentCount == pendingRetryChangeCount { return }

        if extractAndCaptureImage(for: currentCount) {
            return
        }

        cancelPendingRetries()
        pendingRetryChangeCount = currentCount

        let retryDelays: [TimeInterval] = [0.035, 0.080, 0.150, 0.280, 0.450]
        for (index, delay) in retryDelays.enumerated() {
            let isLast = index == retryDelays.count - 1
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard !self.isPaused else { return }
                guard self.pasteboard.changeCount == currentCount else {
                    self.pendingRetryChangeCount = -1   // pasteboard moved on; next poll handles it
                    return
                }
                guard self.lastProcessedChangeCount != currentCount else { return }

                if self.extractAndCaptureImage(for: currentCount) {
                    self.cancelPendingRetries()
                } else if isLast {
                    self.lastProcessedChangeCount = currentCount
                    self.pendingRetryChangeCount = -1
                }
            }
            retryWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @discardableResult
    private func extractAndCaptureImage(for changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }

        if pasteboard.string(forType: NSPasteboard.PasteboardType("com.cursordeck.internal-marker")) != nil {
            lastProcessedChangeCount = changeCount
            return true
        }

        guard let types = pasteboard.types, !types.isEmpty else {
            return false
        }

        if isSmartFilterEnabled {
            let hasEditorSignature = types.contains { t in
                let s = t.rawValue.lowercased()
                return excludedPasteboardSignatures.contains { sig in s.contains(sig) }
            }

            if hasEditorSignature {
                let isTextCopy = types.contains { t in
                    let s = t.rawValue.lowercased()
                    return s.contains("plain-text") || s.contains("stringpboardtype") || s.contains("text/plain") || s.contains("public.rtf")
                }
                if isTextCopy {
                    lastProcessedChangeCount = changeCount
                    return true
                }

                let isIllustrator = types.contains { t in
                    let s = t.rawValue.lowercased()
                    return s.contains("com.adobe.illustrator") || s.contains("com.adobe.agave") || s.contains("adobe illustrator")
                }
                if isIllustrator {
                    let isExternalFile = types.contains { $0.rawValue == "NSFilenamesPboardType" }
                    if !isExternalFile {
                        lastProcessedChangeCount = changeCount
                        return true
                    }
                }

                let hasExplicitRasterImage = types.contains { t in
                    let s = t.rawValue.lowercased()
                    return s == "public.png" || s == "image/png" || s == "public.jpeg" || s == "image/jpeg" || s == "nsfilenamespboardtype"
                }
                if !hasExplicitRasterImage {
                    lastProcessedChangeCount = changeCount
                    return true
                }
            }
        }

        // 2. Finder file paths (NSFilenamesPboardType)
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !filenames.isEmpty {
            var captured = false
            for path in filenames {
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                if supportedImageExtensions.contains(ext) && !queueManager.owns(url) {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                } else if supportedVideoExtensions.contains(ext) && !queueManager.owns(url) {
                    handleLocalVideoFile(url)
                    captured = true
                }
            }
            if captured {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                return true
            }
        }

        // 3. File URLs (NSURL)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            var captured = false
            for url in fileURLs {
                let ext = url.pathExtension.lowercased()
                if supportedImageExtensions.contains(ext) && !queueManager.owns(url) {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                } else if supportedVideoExtensions.contains(ext) && !queueManager.owns(url) {
                    handleLocalVideoFile(url)
                    captured = true
                }
            }
            if captured {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                return true
            }
        }

        // 4. PNG image data
        let pngTypes = [
            NSPasteboard.PasteboardType.png,
            NSPasteboard.PasteboardType("image/png"),
            NSPasteboard.PasteboardType("public.png")
        ]
        for t in pngTypes {
            if let pngData = pasteboard.data(forType: t), !pngData.isEmpty {
                if let item = queueManager.add(imageData: pngData, extension: "png") {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        // 5. JPEG image data
        let jpegTypes = [
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("image/jpeg"),
            NSPasteboard.PasteboardType("image/jpg")
        ]
        for t in jpegTypes {
            if let jpegData = pasteboard.data(forType: t), !jpegData.isEmpty {
                if let item = queueManager.add(imageData: jpegData, extension: "jpg") {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        // 6. TIFF image data
        let tiffTypes = [
            NSPasteboard.PasteboardType.tiff,
            NSPasteboard.PasteboardType("public.tiff")
        ]
        for t in tiffTypes {
            if let tiffData = pasteboard.data(forType: t), !tiffData.isEmpty {
                if let imageRep = NSBitmapImageRep(data: tiffData),
                   let convertedPng = imageRep.representation(using: .png, properties: [:]),
                   !convertedPng.isEmpty {
                    if let item = queueManager.add(imageData: convertedPng, extension: "png") {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        lastProcessedChangeCount = changeCount
                        cancelPendingRetries()
                        return true
                    }
                }
            }
        }

        // 7. WebP / GIF image data
        let webpTypes = [
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("image/webp")
        ]
        for t in webpTypes {
            if let webpData = pasteboard.data(forType: t), !webpData.isEmpty {
                if let item = queueManager.add(imageData: webpData, extension: "webp") {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        let gifTypes = [
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("image/gif")
        ]
        for t in gifTypes {
            if let gifData = pasteboard.data(forType: t), !gifData.isEmpty {
                if let item = queueManager.add(imageData: gifData, extension: "gif") {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        // 8. Pinterest Links & Direct Video URLs
        if let urlString = extractURLStringFromPasteboard() {
            if PinterestMediaResolver.shared.isPinterestURL(urlString) {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                handlePinterestURL(urlString)
                return true
            } else if isDirectVideoURL(urlString) {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                handleDirectVideoURL(urlString)
                return true
            }
        }

        // 9. Universal fallback: NSImage instantiation
        if let image = NSImage(pasteboard: pasteboard), image.size.width > 1, image.size.height > 1 {
            if let tiffData = image.tiffRepresentation,
               let imageRep = NSBitmapImageRep(data: tiffData),
               let convertedPng = imageRep.representation(using: .png, properties: [:]),
               !convertedPng.isEmpty {
                if let item = queueManager.add(imageData: convertedPng, extension: "png") {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        return false
    }

    private func extractURLStringFromPasteboard() -> String? {
        if let str = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty,
           str.hasPrefix("http://") || str.hasPrefix("https://") {
            return str
        }
        if let str = pasteboard.string(forType: .init("public.url"))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty,
           str.hasPrefix("http://") || str.hasPrefix("https://") {
            return str
        }
        return nil
    }

    private func isDirectVideoURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext)
    }

    private func handleDirectVideoURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        downloadAndConvertVideo(url)
    }

    private func addCaptured(_ data: Data, ext: String) {
        if let item = queueManager.add(imageData: data, extension: ext) {
            delegate?.clipboardWatcher(self, didCaptureItem: item)
        }
    }

    private func handlePinterestURL(_ urlString: String) {
        let gen = generation
        PinterestMediaResolver.shared.resolveMedia(from: urlString) { [weak self] result in
            // Resolver callbacks arrive on URLSession queues; all state is touched on main only.
            DispatchQueue.main.async {
                guard let self = self, self.isCurrent(gen), let result = result else { return }
                switch result {
                case .video(let videoRemoteURL):
                    self.downloadAndConvertVideo(videoRemoteURL)
                case .image(let imageRemoteURL):
                    self.downloadAndAddImage(imageRemoteURL)
                }
            }
        }
    }

    private func handleLocalVideoFile(_ url: URL) {
        let gen = generation
        // convert() completes on the main queue (the original re-dispatched to main a second time)
        VideoToGIFConverter.shared.convert(videoURL: url) { [weak self] gifData, _ in
            guard let self = self, self.isCurrent(gen), let gifData = gifData else { return }
            self.addCaptured(gifData, ext: "gif")
        }
    }

    private func downloadAndConvertVideo(_ remoteURL: URL) {
        let gen = generation

        if remoteURL.pathExtension.lowercased() == "m3u8" || remoteURL.absoluteString.contains(".m3u8") {
            VideoToGIFConverter.shared.convertHLS(streamURL: remoteURL) { [weak self] gifData, _ in
                guard let self = self, self.isCurrent(gen), let gifData = gifData else { return }
                self.addCaptured(gifData, ext: "gif")
            }
            return
        }

        // FIX: cap the download. A copied link to a multi-GB .mp4 was downloaded in full
        // just to read 4 seconds of it.
        let maxBytes: Int64 = 150 * 1024 * 1024
        var sizeObservation: NSKeyValueObservation?

        let task = downloadSession.downloadTask(with: remoteURL) { [weak self] tempURL, response, error in
            sizeObservation?.invalidate()
            sizeObservation = nil

            // On any early return the system deletes tempURL for us (no orphan).
            guard let tempURL = tempURL, error == nil else { return }
            // FIX: downloadTask treats HTTP 403/404 as success and hands back the error page body.
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }

            let localVideoURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try FileManager.default.moveItem(at: tempURL, to: localVideoURL)
            } catch {
                return
            }

            DispatchQueue.main.async {
                guard let self = self, self.isCurrent(gen) else {
                    try? FileManager.default.removeItem(at: localVideoURL)
                    return
                }
                VideoToGIFConverter.shared.convert(videoURL: localVideoURL) { [weak self] gifData, _ in
                    try? FileManager.default.removeItem(at: localVideoURL)
                    guard let self = self, self.isCurrent(gen), let gifData = gifData else { return }
                    self.addCaptured(gifData, ext: "gif")
                }
            }
        }
        sizeObservation = task.observe(\.countOfBytesReceived, options: [.new]) { t, _ in
            if t.countOfBytesReceived > maxBytes { t.cancel() }
        }
        track(task)
        task.resume()
    }

    private func downloadAndAddImage(_ remoteURL: URL) {
        let gen = generation
        let task = downloadSession.dataTask(with: remoteURL) { [weak self] data, response, error in
            guard let data = data, error == nil, !data.isEmpty, data.count <= 60 * 1024 * 1024 else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            // FIX: sniff the real format. The URL extension is often missing/wrong on CDNs, and an
            // HTML error page used to be saved as "image.jpg" and added to the deck.
            guard let ext = ClipboardWatcher.imageExtension(for: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.isCurrent(gen) else { return }
                self.addCaptured(data, ext: ext)
            }
        }
        track(task)
        task.resume()
    }

    private static func imageExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }
        return UTType(uti as String)?.preferredFilenameExtension
    }
}

```

---

### File: `Sources/CursorDeckCore/ScreenshotWatcher.swift`

```swift
import AppKit
import Foundation

/// Automatically monitors the macOS screenshot directory (default: ~/Desktop)
/// for newly taken screenshots (Cmd+Shift+4, Cmd+Shift+3, Cmd+Shift+5)
/// and seamlessly adds them into the CursorDeck queue.
public final class ScreenshotWatcher {
    private let queueManager: DeckQueueManager
    private var source: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var processedFilePaths: Set<String> = []
    private var watchedDirectoryURL: URL
    private let monitorQueue = DispatchQueue(label: "com.cursordeck.screenshotwatcher", qos: .utility)

    /// Whether screenshot auto-collection is enabled
    public var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    /// Whether tracking is paused by the user
    public var isPaused: Bool = false

    /// Common localized and third-party screenshot filename prefixes
    private let screenshotPrefixes: [String] = [
        "screenshot",
        "screen shot",
        "cleanshot",
        "shottr",
        "capture d’écran",
        "capture d'ecran",
        "bildschirmfoto",
        "captura de pantalla",
        "schermopname"
    ]

    private let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "tiff"
    ]

    public init(queueManager: DeckQueueManager) {
        self.queueManager = queueManager
        self.watchedDirectoryURL = Self.resolveScreenshotDirectory()

        // Seed existing files on startup so we only capture NEW screenshots taken while running
        seedExistingFiles()
    }

    deinit {
        stop()
    }

    /// Resolves the user's screenshot destination folder from macOS defaults (defaults to ~/Desktop)
    public static func resolveScreenshotDirectory() -> URL {
        if let customLocation = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !customLocation.isEmpty {
            let expanded = NSString(string: customLocation).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Standard macOS default is ~/Desktop
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Desktop").expandingTildeInPath, isDirectory: true)
    }

    private func seedExistingFiles() {
        let path = watchedDirectoryURL.path
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for file in existing {
                processedFilePaths.insert(path + "/" + file)
            }
        }
    }

    public func start() {
        guard source == nil else { return }

        self.watchedDirectoryURL = Self.resolveScreenshotDirectory()
        let path = watchedDirectoryURL.path

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("[ScreenshotWatcher] Failed to open directory for monitoring: \(path)")
            return
        }

        self.directoryFileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: monitorQueue
        )

        src.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }

        src.setCancelHandler { [weak self] in
            if let fd = self?.directoryFileDescriptor, fd >= 0 {
                close(fd)
                self?.directoryFileDescriptor = -1
            }
        }

        src.resume()
        self.source = src
        print("[ScreenshotWatcher] Monitoring screenshots in: \(path)")
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func handleDirectoryChange() {
        guard isEnabled else { return }

        let dirPath = watchedDirectoryURL.path
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

        let now = Date()

        for filename in files {
            let fullPath = dirPath + "/" + filename
            guard !processedFilePaths.contains(fullPath) else { continue }

            let url = URL(fileURLWithPath: fullPath)
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let lowerName = filename.lowercased()
            let isScreenshotName = screenshotPrefixes.contains { lowerName.hasPrefix($0) }

            // If tracking is paused, mark file processed so it's never captured now or later
            if isPaused {
                processedFilePaths.insert(fullPath)
                continue
            }

            // Check file attributes
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let creationDate = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date,
                  let fileSize = attrs[.size] as? Int, fileSize > 100 else {
                continue
            }

            // Only consider files created within the last 15 seconds
            let age = now.timeIntervalSince(creationDate)
            guard age >= 0 && age < 15.0 else {
                processedFilePaths.insert(fullPath)
                continue
            }

            if isScreenshotName {
                processedFilePaths.insert(fullPath)

                // Wait 200ms to allow macOS screenshot utility to finish flushing file to disk
                monitorQueue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self = self else { return }
                    // Re-verify file exists and has size
                    guard let updatedAttrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                          let updatedSize = updatedAttrs[.size] as? Int, updatedSize > 500 else {
                        return
                    }

                    DispatchQueue.main.async {
                        guard !self.isPaused else { return }
                        print("[ScreenshotWatcher] Captured new screenshot: \(filename) (\(updatedSize) bytes)")
                        self.queueManager.add(existingFileURL: url)
                    }
                }
            }
        }
    }
}

```

---

### File: `Sources/CursorDeckCore/CursorHUDPanel.swift`

```swift
import AppKit
import Foundation

public final class CursorHUDPanel: NSPanel, DeckHUDViewDelegate {
    public let queueManager: DeckQueueManager
    public let shakeDetector = ShakeDetector()
    public let previewPanel = DeckPreviewPanel()

    private let hudView: DeckHUDView
    private var trackingTimer: Timer?
    private var previousCount: Int = 0
    private var wasCommandHeld = false
    private var isDragging = false
    private var isDismissing = false

    private let badgeHeight: CGFloat = 28.0

    private var badgeWidth: CGFloat {
        return queueManager.count > 9 ? 66.0 : 58.0
    }

    public init(queueManager: DeckQueueManager) {
        self.queueManager = queueManager
        let initialWidth: CGFloat = 58.0
        let rect = NSRect(x: 100, y: 100, width: initialWidth, height: badgeHeight)

        self.hudView = DeckHUDView(frame: NSRect(origin: .zero, size: rect.size))

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false          // Never auto-hide on app switch
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        hudView.queueManager = queueManager
        hudView.delegate = self
        contentView = hudView

        // Wire up Shake gesture: Discard ENTIRE deck (Clear All)
        shakeDetector.onShakeDetected = { [weak self] in
            guard let self = self, !self.queueManager.isEmpty, !self.isDragging, !self.isDismissing else { return }
            if self.previewPanel.isVisible {
                self.previewPanel.close()
            }
            self.isDismissing = true
            self.hudView.triggerDismissPuffAnimation {
                self.queueManager.clear()
                self.isDismissing = false
                self.refreshHUD()
            }
        }

        queueManager.addObserver { [weak self] _ in
            guard let self = self else { return }
            // Keep an open preview in sync (new copy, ✕ delete, deck cleared)
            if self.previewPanel.isVisible { self.previewPanel.refresh() }
            self.refreshHUD()
        }

        // Re-surface the pill whenever the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.queueManager.isEmpty, !self.isDragging, !self.isDismissing else { return }
            if !self.previewPanel.isVisible {
                self.orderFrontRegardless()
            }
        }

        refreshHUD()
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    public func startTracking(interval: TimeInterval = 0.016) {
        guard trackingTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.trackingTimer = timer
    }

    public func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePosition() {
        // Hide only when deck is truly empty and no drag is in flight
        guard !queueManager.isEmpty else {
            if isVisible && !isDragging { orderOut(nil) }
            return
        }

        guard !isDragging, !isDismissing else { return }

        // While the preview grid is open, let it auto-dismiss if the cursor wanders off
        if previewPanel.isVisible {
            previewPanel.tick()
            return
        }

        // Freeze panel while mouse button is pressed down so clicks don't jitter
        if NSEvent.pressedMouseButtons != 0 {
            return
        }

        let mousePos = NSEvent.mouseLocation
        let currentOrigin = frame.origin
        let currentW = badgeWidth
        let currentH = badgeHeight

        // Feed horizontal movement into ShakeDetector to detect rapid cursor shake
        shakeDetector.observe(x: mousePos.x)

        // Find current display frame (taking Dock and Menu Bar into account)
        let screen = NSScreen.screens.first { NSMouseInRect(mousePos, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // MARK: - Screen Edge Clamping & Flip
        var targetX: CGFloat
        var targetY: CGFloat

        // ⌘ or ⌥ pulls the pill under the pointer like a magnet.
        // ⌘ + drag = burst-drop, ⌥ + click = open preview grid.
        let heldFlags = CGEventSource.flagsState(.hidSystemState)
        let isMagnetHeld = heldFlags.contains(.maskCommand) || heldFlags.contains(.maskAlternate)

        if isMagnetHeld {
            // Magnet Snap: centered under pointer, clamped safely to screen edges
            targetX = mousePos.x - currentW / 2
            targetY = mousePos.y - currentH / 2
            targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))
            targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

            let factor: CGFloat = wasCommandHeld ? 0.85 : 0.92
            let dx = (targetX - currentOrigin.x) * factor
            let dy = (targetY - currentOrigin.y) * factor
            setFrameOrigin(NSPoint(x: currentOrigin.x + dx, y: currentOrigin.y + dy))
            wasCommandHeld = true
            return
        }

        wasCommandHeld = false

        // Free-Flow Mode:
        // Horizontal: Default +22 to right; if near right edge, flip to left (-currentW - 14)
        if mousePos.x + 22 + currentW > bounds.maxX - 6 {
            targetX = mousePos.x - currentW - 14
        } else {
            targetX = mousePos.x + 22
        }
        targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))

        // Vertical: Default -currentH - 10; if near bottom edge (or Dock), flip above (+14)
        if mousePos.y - currentH - 10 < bounds.minY + 6 {
            targetY = mousePos.y + 14
        } else {
            targetY = mousePos.y - currentH - 10
        }
        targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

        if !isVisible {
            setFrameOrigin(NSPoint(x: targetX, y: targetY))
            orderFrontRegardless()
            return
        }

        // Fluid spring interpolation towards edge-aware target
        let dx = (targetX - currentOrigin.x) * 0.35
        let dy = (targetY - currentOrigin.y) * 0.35
        setFrameOrigin(NSPoint(x: currentOrigin.x + dx, y: currentOrigin.y + dy))
    }

    public func refreshHUD() {
        guard !isDragging, !isDismissing else { return }

        let count = queueManager.count
        let hasNewItems = count > previousCount
        previousCount = count

        hudView.updateCount(count, animateGlow: hasNewItems)

        let targetWidth = badgeWidth
        if frame.width != targetWidth {
            let origin = frame.origin
            setFrame(NSRect(x: origin.x, y: origin.y, width: targetWidth, height: badgeHeight), display: true)
            hudView.frame = NSRect(origin: .zero, size: CGSize(width: targetWidth, height: badgeHeight))
        }

        if count > 0 {
            if !isVisible && !previewPanel.isVisible {
                let mousePos = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: mousePos.x + 22, y: mousePos.y - badgeHeight - 10))
                orderFrontRegardless()
            }
        } else {
            orderOut(nil)
        }
    }

    // MARK: - DeckHUDViewDelegate

    public func deckHUDViewWillBeginDragging(_ view: DeckHUDView) {
        if previewPanel.isVisible {
            previewPanel.close()
        }
        isDragging = true
        setFrameOrigin(NSPoint(x: -500, y: -500))
    }

    public func deckHUDViewDidCompleteDrop(_ view: DeckHUDView) {
        isDragging = false
        queueManager.clear()
    }

    public func deckHUDViewDidCancelDrop(_ view: DeckHUDView) {
        isDragging = false
        refreshHUD()
    }

    public func deckHUDViewDidRequestClear(_ view: DeckHUDView) {
        queueManager.clear()
        refreshHUD()
    }

    public func deckHUDViewDidRequestPreview(_ view: DeckHUDView) {
        togglePreview()
    }

    public func togglePreview() {
        if previewPanel.isVisible {
            previewPanel.close()
            return
        }
        guard !queueManager.isEmpty, !isDragging, !isDismissing else { return }

        // Morph effect: The pill seamlessly blossoms into the preview deck.
        // We hide the pill so there is NEVER a second deck beside it!
        let pillRect = self.frame
        self.alphaValue = 0.0

        previewPanel.open(from: pillRect, queueManager: queueManager) { [weak self] in
            guard let self = self else { return }
            self.alphaValue = 1.0
            self.updatePosition()
        }
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckHUDView.swift`

```swift
import AppKit
import Foundation

public protocol DeckHUDViewDelegate: AnyObject {
    func deckHUDViewDidRequestClear(_ view: DeckHUDView)
    func deckHUDViewDidCompleteDrop(_ view: DeckHUDView)
    func deckHUDViewDidCancelDrop(_ view: DeckHUDView)
    func deckHUDViewWillBeginDragging(_ view: DeckHUDView)
    func deckHUDViewDidRequestPreview(_ view: DeckHUDView)
}

public final class DeckHUDView: NSView, NSDraggingSource {
    public weak var delegate: DeckHUDViewDelegate?
    public var queueManager: DeckQueueManager?

    public static let pillHeight: CGFloat = 28.0

    // Native Liquid Glass Visual Effect View
    private let visualEffectView = NSVisualEffectView()

    // Subviews
    private let dotView = NSView()
    private let countLabel = NSTextField(labelWithString: "0")
    private let iconImageView = NSImageView()
    private var isShowingUndoFeedback: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = 14

        // 1. Native macOS Liquid Glass Material (Frosted Translucent Blur)
        // NOTE: .withinWindow instead of .behindWindow — .behindWindow requires a composited
        // window behind it to sample from. During app-switch animations macOS briefly has
        // no eligible window, causing the pill to go fully transparent (the "vanish" glitch).
        // .withinWindow always renders consistently regardless of what app is focused.
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.frame = bounds
        addSubview(visualEffectView, positioned: .below, relativeTo: nil)

        // 2. Specular glass rim border and dark glass tint
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        layer?.borderWidth = 1.0

        // 3. Ambient glass drop shadow matching exact capsule curve
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.38
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8

        // 4. Emerald active dot
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.0
        dotView.layer?.backgroundColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // 5. High-legibility count typography
        countLabel.wantsLayer = true
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        countLabel.textColor = .white
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // 6. Solid Deck Logo icon (subtle, secondary accent)
        iconImageView.image = DeckLogoAsset.pillImage
        iconImageView.contentTintColor = NSColor(white: 0.72, alpha: 0.88)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            countLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconImageView.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 10),
            iconImageView.heightAnchor.constraint(equalToConstant: 10)
        ])
    }

    public override func layout() {
        super.layout()
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        visualEffectView.layer?.cornerRadius = radius
        visualEffectView.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    public func updateCount(_ count: Int, animateGlow: Bool = false) {
        if !isShowingUndoFeedback {
            countLabel.stringValue = "\(count)"
        }
        needsDisplay = true

        if animateGlow && count > 0 {
            triggerCaptureGlowAnimation()
        }
    }

    /// Shows tactile pop feedback when the last item is discarded via Option + Shake gesture
    public func showRemovedLastFeedback(remainingCount: Int) {
        isShowingUndoFeedback = true

        // 1. Amber/Coral pulse on border and scale bounce
        if let layer = layer {
            let borderPulse = CAKeyframeAnimation(keyPath: "borderColor")
            borderPulse.values = [
                NSColor(white: 1.0, alpha: 0.28).cgColor,
                NSColor(red: 1.0, green: 0.45, blue: 0.20, alpha: 0.95).cgColor,
                NSColor(white: 1.0, alpha: 0.28).cgColor
            ]
            borderPulse.keyTimes = [0.0, 0.35, 1.0]
            borderPulse.duration = 0.45
            borderPulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(borderPulse, forKey: "borderPulseUndo")

            let bounceAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            bounceAnim.values = [1.0, 1.12, 1.0]
            bounceAnim.keyTimes = [0.0, 0.30, 1.0]
            bounceAnim.duration = 0.35
            bounceAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(bounceAnim, forKey: "pillBounceUndo")
        }

        // 2. Dot temporarily flashes amber/coral
        if let dotLayer = dotView.layer {
            let dotAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
            dotAnim.values = [
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor,
                NSColor(red: 1.0, green: 0.40, blue: 0.20, alpha: 1.0).cgColor,
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
            ]
            dotAnim.keyTimes = [0.0, 0.35, 1.0]
            dotAnim.duration = 0.50
            dotAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dotLayer.add(dotAnim, forKey: "dotUndoFlash")
        }

        // 3. Count label temporarily displays "⌫" with pop animation
        countLabel.stringValue = "⌫"
        if let countLayer = countLabel.layer {
            let popAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            popAnim.values = [1.0, 1.25, 1.0]
            popAnim.keyTimes = [0.0, 0.35, 1.0]
            popAnim.duration = 0.40
            popAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            countLayer.add(popAnim, forKey: "popUndo")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self else { return }
            self.isShowingUndoFeedback = false
            self.countLabel.stringValue = "\(remainingCount)"
        }
    }

    /// Solid shape illumination glow through native Liquid Glass
    public func triggerCaptureGlowAnimation() {
        guard let layer = self.layer else { return }

        // 1. Solid Shape Background Glow: glass tint illuminates with rich emerald
        let bgGlow = CAKeyframeAnimation(keyPath: "backgroundColor")
        bgGlow.values = [
            NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor,
            NSColor(red: 0.12, green: 0.44, blue: 0.22, alpha: 0.88).cgColor, // Luminous emerald glass fill
            NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor
        ]
        bgGlow.keyTimes = [0.0, 0.30, 1.0]
        bgGlow.duration = 0.60
        bgGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bgGlow, forKey: "bgGlow")

        // 2. Radiant Glass Rim Glow
        let borderGlow = CAKeyframeAnimation(keyPath: "borderColor")
        borderGlow.values = [
            NSColor(white: 1.0, alpha: 0.28).cgColor,
            NSColor(red: 0.30, green: 0.95, blue: 0.50, alpha: 0.95).cgColor,
            NSColor(white: 1.0, alpha: 0.28).cgColor
        ]
        borderGlow.keyTimes = [0.0, 0.30, 1.0]
        borderGlow.duration = 0.60
        borderGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(borderGlow, forKey: "borderGlow")

        // 3. Dot Flash
        if let dotLayer = dotView.layer {
            let dotAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
            dotAnim.values = [
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor,
                NSColor(red: 0.65, green: 1.0, blue: 0.75, alpha: 1.0).cgColor,
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
            ]
            dotAnim.keyTimes = [0.0, 0.30, 1.0]
            dotAnim.duration = 0.60
            dotAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dotLayer.add(dotAnim, forKey: "dotFlash")
        }

        // 4. Subtle Count Pop
        if let countLayer = countLabel.layer {
            let popAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            popAnim.values = [1.0, 1.22, 1.0]
            popAnim.keyTimes = [0.0, 0.35, 1.0]
            popAnim.duration = 0.40
            popAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            countLayer.add(popAnim, forKey: "pop")
        }
    }

    /// Delightful puff/dissolve animation when discarded via Shake-to-Clear gesture
    public func triggerDismissPuffAnimation(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.alphaValue = 1.0
            completion()
        })
    }

    private var dragStartScreenPoint: NSPoint = .zero
    private var isDraggingSessionActive = false

    // MARK: - Drag & Drop and Click Handling

    private var clickHadOption = false

    public override func mouseDown(with event: NSEvent) {
        guard let items = queueManager?.items, !items.isEmpty else { return }
        dragStartScreenPoint = NSEvent.mouseLocation
        isDraggingSessionActive = false
        // Remember ⌥ at press time (user may release it before mouse-up)
        clickHadOption = event.modifierFlags.contains(.option)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let items = queueManager?.items, !items.isEmpty, !isDraggingSessionActive else { return }

        let currentScreenPoint = NSEvent.mouseLocation
        let dist = hypot(currentScreenPoint.x - dragStartScreenPoint.x, currentScreenPoint.y - dragStartScreenPoint.y)

        // When ⌘/⌥ is held (the only way to catch the pill), allow a generous 20pt
        // threshold so trackpad clicks and resting fingers don't start an accidental drag.
        let flags = CGEventSource.flagsState(.hidSystemState)
        let isModifierHeld = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
            || flags.contains(.maskCommand) || flags.contains(.maskAlternate)
        let threshold: CGFloat = isModifierHeld ? 20.0 : 4.0

        guard dist > threshold else { return }

        isDraggingSessionActive = true
        startDragSession(with: event, items: items)
    }

    public override func mouseUp(with event: NSEvent) {
        // If a drag session was active, AppKit handles session end via draggingSession(_:endedAt:operation:)
        guard !isDraggingSessionActive else { return }
        guard let items = queueManager?.items, !items.isEmpty else { return }

        // ⌥ + click (no drag) → toggle the preview grid instead of copying the batch
        if clickHadOption {
            clickHadOption = false
            delegate?.deckHUDViewDidRequestPreview(self)
            return
        }

        // Quick click without holding!
        // 1. Arm clipboard with full batch
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Show green ✓ pop on pill
        showCopiedFeedback()
    }

    private func startDragSession(with event: NSEvent, items: [DeckItem]) {
        // 1. Arm system clipboard with full batch payload
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Build one NSDraggingItem per queued image using native NSURL.
        // NSURL natively provides:
        //   • public.file-url
        //   • CorePasteboardFlavorType 0x6675726C
        //   • NSFilenamesPboardType
        //   • Apple URL pasteboard type
        let draggingItems: [NSDraggingItem] = items.enumerated().map { idx, item in
            let dragItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)

            // Use the actual image as the drag thumbnail (64pt square, stacked)
            let thumbSize: CGFloat = 64
            let thumb: NSImage
            if let loaded = NSImage(contentsOf: item.fileURL) {
                thumb = loaded
            } else {
                thumb = NSWorkspace.shared.icon(forFile: item.fileURL.path)
            }
            // Slight offset per item so the stack is visible
            let offset = CGFloat(idx) * 4
            dragItem.setDraggingFrame(
                NSRect(x: offset, y: -offset, width: thumbSize, height: thumbSize),
                contents: thumb
            )
            return dragItem
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack

        // 3. Register global NSFilenamesPboardType paths array on dragging pasteboard (critical for WhatsApp/Catalyst)
        let paths = items.map { $0.fileURL.path }
        session.draggingPasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        // Park badge off-screen so it doesn't block the drag target
        delegate?.deckHUDViewWillBeginDragging(self)
    }

    // MARK: - NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Strictly return .copy so that even when Command (⌘) is held, macOS and target apps
        // (Google Slides, Chrome, Figma, WhatsApp) do not attempt an illegal .move operation,
        // allowing Cmd+drag+drop to complete natively!
        return .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSessionActive = false
        let isAccepted = operation != []
        let logMsg = "[CursorDeck] Drag ended at \(screenPoint), operation raw=\(operation.rawValue), accepted=\(isAccepted)\n"
        print(logMsg)
        appendDragLog(logMsg)

        if isAccepted {
            print("[CursorDeck] Drop ACCEPTED ✓ operation=\(operation.rawValue)")
            delegate?.deckHUDViewDidCompleteDrop(self)
        } else {
            print("[CursorDeck] Drop not accepted natively (raw=\(operation.rawValue))")
            delegate?.deckHUDViewDidCancelDrop(self)
        }
    }

    /// Shows instant feedback on the pill when clicked to copy
    public func showCopiedFeedback() {
        triggerCaptureGlowAnimation()
        let previousCount = countLabel.stringValue
        countLabel.stringValue = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.countLabel.stringValue = previousCount
        }
    }

    private func appendDragLog(_ message: String) {
        let path = "/private/tmp/cursor-deck.log"
        guard let data = message.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckPreviewPanel.swift`

```swift
import AppKit
import Foundation

/// Fluid frosted-glass grid showing everything in the deck.
/// The pill seamlessly expands into this preview deck, and collapses back when dismissed.
/// Closes on: ⌥ + click, clicking outside, cursor wandering away (>90pt), or deck emptying.
public final class DeckPreviewPanel: NSPanel {
    private let glassView = NSVisualEffectView()
    private let contentContainer = NSView()
    private weak var queueManager: DeckQueueManager?

    public var onClose: (() -> Void)?
    private var clickOutsideMonitor: Any?
    private var isClosing = false
    private var openedAt: TimeInterval = 0

    private let thumbnailSize: CGFloat = 58.0
    private let gutter: CGFloat = 8.0
    private let padding: CGFloat = 8.0
    private let dismissDistance: CGFloat = 90.0

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        setupGlassSurface()
    }

    deinit { removeClickOutsideMonitor() }

    private func setupGlassSurface() {
        glassView.material = .hudWindow
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 16.0
        glassView.layer?.masksToBounds = true
        glassView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        glassView.layer?.borderWidth = 1.0
        glassView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.62).cgColor
        contentView = glassView

        contentContainer.wantsLayer = true
        contentContainer.autoresizingMask = []
        contentContainer.frame = glassView.bounds
        glassView.addSubview(contentContainer)
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && event.modifierFlags.contains(.option) {
            close()
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Layout helpers

    private func gridMetrics(for count: Int) -> (columns: Int, size: NSSize) {
        let columns: Int
        switch count {
        case ...2:  columns = max(count, 1)
        case ...4:  columns = 2
        case ...9:  columns = 3
        case ...16: columns = 4
        case ...30: columns = 6
        default:    columns = 8
        }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let w = CGFloat(columns) * thumbnailSize + CGFloat(columns - 1) * gutter + padding * 2
        let h = CGFloat(rows) * thumbnailSize + CGFloat(rows - 1) * gutter + padding * 2
        return (columns, NSSize(width: w, height: h))
    }

    private func visibleBounds(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    // MARK: - Open / Morph / Refresh / Close

    /// Opens by smoothly expanding directly from the pill's origin frame into the full grid deck.
    public func open(from sourceRect: NSRect, queueManager: DeckQueueManager, onClose: (() -> Void)? = nil) {
        guard !queueManager.isEmpty else { return }
        self.queueManager = queueManager
        self.onClose = onClose
        isClosing = false
        openedAt = CACurrentMediaTime()

        let targetSize = gridMetrics(for: queueManager.count).size
        let bounds = visibleBounds(containing: NSPoint(x: sourceRect.midX, y: sourceRect.midY))

        // Center horizontally on the pill, clamped to screen bounds
        var targetX = sourceRect.midX - targetSize.width / 2
        targetX = max(bounds.minX + 8, min(targetX, bounds.maxX - targetSize.width - 8))

        // Blossom downwards from pill's top edge; if hitting bottom, expand upwards
        var targetY = sourceRect.maxY - targetSize.height
        if targetY < bounds.minY + 8 {
            targetY = sourceRect.minY
        }
        targetY = max(bounds.minY + 8, min(targetY, bounds.maxY - targetSize.height - 8))

        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize)

        // 1. Initial State: Identical to the pill footprint
        setFrame(sourceRect, display: true)
        glassView.layer?.cornerRadius = 14.0
        alphaValue = 1.0
        contentContainer.alphaValue = 0.0
        contentContainer.frame = NSRect(origin: .zero, size: targetSize)

        rebuildGrid()
        orderFrontRegardless()
        installClickOutsideMonitor()

        // 2. Swift, fluid expansion animation: morph from pill into deck
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            self.animator().setFrame(targetFrame, display: true)
            self.contentContainer.animator().alphaValue = 1.0
        }

        // Corner radius morph (14pt capsule -> 16pt card)
        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = 14.0
        radiusAnim.toValue = 16.0
        radiusAnim.duration = 0.20
        radiusAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
        glassView.layer?.add(radiusAnim, forKey: "expandRadius")
        glassView.layer?.cornerRadius = 16.0
    }

    /// Re-syncs the grid with the queue (new copy, ✕ delete, clear). Closes if the deck is empty.
    public func refresh() {
        guard isVisible, !isClosing else { return }
        guard let qm = queueManager, !qm.isEmpty else {
            close()
            return
        }

        let size = gridMetrics(for: qm.count).size
        let bounds = visibleBounds(containing: NSPoint(x: frame.midX, y: frame.midY))
        var x = frame.minX
        var y = frame.maxY - size.height
        x = max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8))
        y = max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8))
        let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(targetFrame, display: true)
        }

        contentContainer.frame = NSRect(origin: .zero, size: targetFrame.size)
        rebuildGrid()
    }

    private func rebuildGrid() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let queueManager = queueManager, !queueManager.isEmpty else {
            close()
            return
        }

        let items = queueManager.items
        let (columns, _) = gridMetrics(for: items.count)
        let rows = Int(ceil(Double(items.count) / Double(columns)))

        for (index, item) in items.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = padding + CGFloat(col) * (thumbnailSize + gutter)
            // Cocoa y-axis points up, so row 0 is at the top
            let y = padding + CGFloat(rows - 1 - row) * (thumbnailSize + gutter)

            let cell = PreviewThumbnailCell(
                item: item,
                frame: NSRect(x: x, y: y, width: thumbnailSize, height: thumbnailSize)
            )
            // Deleting only mutates the queue; the queue observer calls refresh() once.
            cell.onDelete = { [weak self] deleted in
                self?.queueManager?.remove(id: deleted.id)
            }
            contentContainer.addSubview(cell)
        }
    }

    /// Called every ~16ms from CursorHUDPanel's tracking timer: dismiss if the cursor wanders off.
    public func tick() {
        guard isVisible, !isClosing else { return }
        if CACurrentMediaTime() - openedAt < 0.35 { return }
        let mouse = NSEvent.mouseLocation
        if !frame.insetBy(dx: -dismissDistance, dy: -dismissDistance).contains(mouse) {
            close()
        }
    }

    public override func close() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeClickOutsideMonitor()

        // Collapse smoothly back toward center
        let collapseRect = NSRect(
            x: frame.midX - 29,
            y: frame.midY - 14,
            width: 58,
            height: 28
        )

        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = 16.0
        radiusAnim.toValue = 14.0
        radiusAnim.duration = 0.14
        radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        glassView.layer?.add(radiusAnim, forKey: "collapseRadius")
        glassView.layer?.cornerRadius = 14.0

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
            self.animator().setFrame(collapseRect, display: true)
            self.contentContainer.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.orderOut(nil)
            self.alphaValue = 1.0
            self.contentContainer.alphaValue = 1.0
            self.isClosing = false
            let cb = self.onClose
            self.onClose = nil
            cb?()
        })
    }

    // MARK: - Click-outside

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self else { return }
            if CACurrentMediaTime() - self.openedAt < 0.15 { return }
            self.close()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - Thumbnail cell

/// NSButton that fires on the first click even though the panel never becomes key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PreviewThumbnailCell: NSView {
    let item: DeckItem
    var onDelete: ((DeckItem) -> Void)?

    private let imageView = NSImageView()
    private let deleteButton = FirstMouseButton()
    private var trackingArea: NSTrackingArea?

    init(item: DeckItem, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8.0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.65).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        layer?.borderWidth = 0.5

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: item.fileURL)
            ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
        addSubview(imageView)

        let btn: CGFloat = 16.0
        deleteButton.frame = NSRect(x: bounds.width - btn - 3, y: bounds.height - btn - 3, width: btn, height: btn)
        deleteButton.isBordered = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = btn / 2
        deleteButton.layer?.backgroundColor = NSColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 0.90).cgColor
        deleteButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 9, weight: .bold)
            ]
        )
        deleteButton.alphaValue = 0.0
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        addSubview(deleteButton)
    }

    @objc private func deleteClicked() { onDelete?(item) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; deleteButton.animator().alphaValue = 1.0 }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; deleteButton.animator().alphaValue = 0.0 }
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckDragItemWriter.swift`

```swift
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

```

---

### File: `Sources/CursorDeckCore/PasteboardWriter.swift`

```swift
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

```

---

### File: `Sources/CursorDeckCore/PinterestMediaResolver.swift`

```swift
import Foundation

public enum PinterestMediaResult {
    case video(URL)
    case image(URL)
}

/// Resolves Pinterest pin links (including pin.it short links and localized URLs)
/// to direct video streams (MP4/HLS) or fallback images.
///
/// NOTE: this uses Pinterest's unofficial web endpoint. It can change or rate-limit without
/// notice, so failures are logged (status code + reason) instead of silently returning nil.
public final class PinterestMediaResolver {
    public static let shared = PinterestMediaResolver()

    private let session: URLSession
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private static let pinIdRegex = try! NSRegularExpression(pattern: #"/pin/(?:[^/]*-)?(\d{6,})"#)

    /// Output GIFs are <= 500px, so prefer the smallest MP4 rendition that is still >= this width.
    private let targetWidth = 500

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 40.0   // FIX: per-request timeout alone never bounds a trickling response
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL recognition

    /// FIX: host-based check. The original used substring checks, so "https://hairpin.it/..." matched
    /// "pin.it/" and any pinterest URL containing "id=" (e.g. "...&guid=1234567") was treated as a pin.
    private func isPinterestHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        if h == "pin.it" { return true }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        if labels[labels.count - 2] == "pinterest" { return true }                       // pinterest.com, in.pinterest.com
        if labels.count >= 3, ["co", "com", "org", "net"].contains(labels[labels.count - 2]),
           labels[labels.count - 3] == "pinterest" { return true }                         // pinterest.co.uk, pinterest.com.au
        return false
    }

    private func firstURL(in string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), u.host != nil { return u }
        // "https://pin.it/abc some trailing text"
        if let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
           let u = URL(string: String(token)), u.host != nil { return u }
        return nil
    }

    /// Checks if a string is a Pinterest pin URL (or pin.it short link).
    public func isPinterestURL(_ string: String) -> Bool {
        guard let url = firstURL(in: string), isPinterestHost(url.host) else { return false }
        if url.host?.lowercased() == "pin.it" { return true }
        return url.path.contains("/pin/")
    }

    /// Extracts the numeric Pin ID from canonical, slugged or localized pin URLs.
    /// Only `/pin/...` paths count: boards, search pages and profiles return nil.
    public func extractPinId(from urlString: String) -> String? {
        guard let url = firstURL(in: urlString), isPinterestHost(url.host) else { return nil }
        let path = url.path
        let range = NSRange(path.startIndex..., in: path)
        guard let match = Self.pinIdRegex.firstMatch(in: path, range: range),
              let idRange = Range(match.range(at: 1), in: path) else { return nil }
        return String(path[idRange])
    }

    // MARK: - Public entry point

    /// Resolves a Pinterest link to direct media. Completion may be called on an arbitrary queue or main queue.
    public func resolveMedia(from urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        let done: (PinterestMediaResult?) -> Void = { result in
            completion(result)
        }

        guard let url = firstURL(in: urlString) else {
            done(nil)
            return
        }

        if url.host?.lowercased() == "pin.it" {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            // FIX: we only need the redirect target; ask for 1 byte instead of downloading the whole page.
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")

            session.dataTask(with: req) { [weak self] _, response, error in
                guard let self = self, let finalURL = response?.url?.absoluteString else {
                    print("[Pinterest] pin.it redirect failed: \(error?.localizedDescription ?? "no response")")
                    done(nil)
                    return
                }
                self.extractFromCanonicalPinURL(finalURL, completion: done)
            }.resume()
        } else {
            extractFromCanonicalPinURL(url.absoluteString, completion: done)
        }
    }

    // MARK: - Pin resource

    private func extractFromCanonicalPinURL(_ urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        guard let pinId = extractPinId(from: urlString) else {
            print("[Pinterest] no pin id in \(urlString)")
            completion(nil)
            return
        }

        var components = URLComponents(string: "https://www.pinterest.com/resource/PinResource/get/")!
        let dataDict: [String: Any] = [
            "options": ["id": pinId, "field_set_key": "unauth_react_main_pin"],
            "context": [String: Any]()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dataDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "source_url", value: "/pin/\(pinId)/"),
            URLQueryItem(name: "data", value: jsonString)
        ]
        guard let requestURL = components.url else {
            completion(nil)
            return
        }

        var request = URLRequest(url: requestURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("www/[username].js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            // FIX: surface why a lookup failed (403/429 rate limit vs. payload change vs. offline).
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[Pinterest] PinResource HTTP \(http.statusCode) for pin \(pinId)")
                completion(nil)
                return
            }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resourceResponse = json["resource_response"] as? [String: Any],
                  let pinData = resourceResponse["data"] as? [String: Any] else {
                print("[Pinterest] PinResource unreadable for pin \(pinId): \(error?.localizedDescription ?? "unexpected JSON")")
                completion(nil)
                return
            }
            self.processPinData(pinData, pinId: pinId, completion: completion)
        }.resume()
    }

    // MARK: - Stream selection

    private struct StreamCandidate {
        let url: String
        let width: Int
    }

    private func candidates(from videoList: [String: Any]) -> [StreamCandidate] {
        var out: [StreamCandidate] = []
        // FIX: sorted keys. Iterating the dictionary directly made the chosen rendition random per launch.
        for key in videoList.keys.sorted() {
            guard let info = videoList[key] as? [String: Any],
                  let u = info["url"] as? String, !u.isEmpty else { continue }
            let width = (info["width"] as? NSNumber)?.intValue ?? 0
            out.append(StreamCandidate(url: u, width: width))
        }
        return out
    }

    /// MP4s first (smallest rendition that still covers the GIF width), then HLS.
    /// FIX: non-media URLs (e.g. `embed.src`, an HTML embed page) are dropped. The original could
    /// return one as ".video", download an HTML page named .mp4, and fail silently in the converter.
    private func orderedStreamURLs(_ all: [StreamCandidate]) -> [String] {
        func score(_ w: Int) -> Int {
            if w == 0 { return Int.max }
            return w >= targetWidth ? (w - targetWidth) : (100_000 + (targetWidth - w))
        }
        let mp4 = all.filter { $0.url.contains(".mp4") }.sorted { score($0.width) < score($1.width) }
        let hls = all.filter { $0.url.contains(".m3u8") && !$0.url.contains(".mp4") }
        var seen = Set<String>()
        return (mp4 + hls).map { $0.url }.filter { seen.insert($0).inserted }
    }

    private func processPinData(_ pinData: [String: Any], pinId: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        var all: [StreamCandidate] = []

        // 1. Direct videos dict
        if let videos = pinData["videos"] as? [String: Any],
           let videoList = videos["video_list"] as? [String: Any] {
            all += candidates(from: videoList)
        }

        // 2. Story / Idea Pin pages & blocks
        if let story = pinData["story_pin_data"] as? [String: Any],
           let pages = story["pages"] as? [[String: Any]] {
            for page in pages {
                for block in (page["blocks"] as? [[String: Any]]) ?? [] {
                    if let video = block["video"] as? [String: Any],
                       let videoList = video["video_list"] as? [String: Any] {
                        all += candidates(from: videoList)
                    }
                }
            }
        }

        // 3. Carousel data
        if let carousel = pinData["carousel_data"] as? [String: Any],
           let slots = carousel["carousel_slots"] as? [[String: Any]] {
            for slot in slots {
                if let videos = slot["videos"] as? [String: Any],
                   let videoList = videos["video_list"] as? [String: Any] {
                    all += candidates(from: videoList)
                }
            }
        }

        let streams = orderedStreamURLs(all)
        let isVideoPin = (pinData["is_video"] as? Bool == true) ||
                         (pinData["is_playable"] as? Bool == true) ||
                         !streams.isEmpty

        if !streams.isEmpty {
            resolveBestVideoStream(from: streams) { [weak self] resolvedURL in
                if let resolvedURL = resolvedURL {
                    completion(.video(resolvedURL))
                } else if !isVideoPin {
                    self?.fallbackToImage(pinData: pinData, completion: completion)
                } else {
                    completion(nil)
                }
            }
            return
        }

        if isVideoPin {
            scrapeHTMLForVideo(pinId: pinId) { scrapedURL in
                completion(scrapedURL.map { .video($0) })
            }
            return
        }

        fallbackToImage(pinData: pinData, completion: completion)
    }

    /// Direct MP4 if present, otherwise try to derive an MP4 from the HLS URL, otherwise use HLS.
    private func resolveBestVideoStream(from streams: [String], completion: @escaping (URL?) -> Void) {
        for stream in streams where stream.contains(".mp4") {
            if let u = URL(string: stream) {
                completion(u)
                return
            }
        }

        for stream in streams where stream.contains(".m3u8") {
            checkAvailableURLs(generateMP4Candidates(from: stream)) { validURL in
                if let validURL = validURL {
                    completion(validURL)
                } else {
                    completion(URL(string: stream))   // raw HLS -> VideoToGIFConverter.convertHLS
                }
            }
            return
        }

        completion(nil)
    }

    private func generateMP4Candidates(from m3u8URL: String) -> [String] {
        var candidates: [String] = []

        let c1 = m3u8URL
            .replacingOccurrences(of: "/hls/", with: "/720p/")
            .replacingOccurrences(of: "_mobile.m3u8", with: ".mp4")
            .replacingOccurrences(of: ".m3u8", with: ".mp4")
        candidates.append(c1)

        let c2 = m3u8URL
            .replacingOccurrences(of: "/v2/hls/", with: "/720p/")
            .replacingOccurrences(of: "_mobile.m3u8", with: ".mp4")
            .replacingOccurrences(of: ".m3u8", with: ".mp4")
        if c2 != c1 { candidates.append(c2) }

        let c3 = m3u8URL
            .replacingOccurrences(of: "/hls/", with: "/expMp4/")
            .replacingOccurrences(of: "_mobile.m3u8", with: "_t1.mp4")
            .replacingOccurrences(of: ".m3u8", with: "_t1.mp4")
        if c3 != c1 && c3 != c2 { candidates.append(c3) }

        return candidates
    }

    /// FIX: probe all candidates in parallel and keep the first (by priority) that exists.
    /// The original probed sequentially with 3s timeouts (up to ~9s before falling back to HLS) and
    /// used HEAD, which some CDN configurations reject even for valid files; a 1-byte ranged GET is
    /// treated as the more reliable probe. Never blocks the calling thread.
    private func checkAvailableURLs(_ candidates: [String], completion: @escaping (URL?) -> Void) {
        let urls = candidates.compactMap { URL(string: $0) }
        guard !urls.isEmpty else {
            completion(nil)
            return
        }

        var ok = [Bool](repeating: false, count: urls.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, url) in urls.enumerated() {
            group.enter()
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            req.timeoutInterval = 4.0
            session.dataTask(with: req) { _, response, _ in
                if let http = response as? HTTPURLResponse, (200...206).contains(http.statusCode) {
                    lock.lock(); ok[index] = true; lock.unlock()
                }
                group.leave()
            }.resume()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            lock.lock()
            let firstValid = ok.firstIndex(of: true).map { urls[$0] }
            lock.unlock()
            completion(firstValid)
        }
    }

    // MARK: - HTML fallback

    private func scrapeHTMLForVideo(pinId: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: "https://www.pinterest.com/pin/\(pinId)/") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self, let data = data, var html = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[Pinterest] pin page HTTP \(http.statusCode) for pin \(pinId)")
                completion(nil)
                return
            }

            // FIX: JSON embedded in <script> tags may escape slashes; undo that before matching.
            html = html.replacingOccurrences(of: "\\u002F", with: "/").replacingOccurrences(of: "\\/", with: "/")

            let pattern = #"https://[^"'\s\\]*pinimg\.com/videos/[^"'\s\\]*\.(?:mp4|m3u8)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                completion(nil)
                return
            }
            let ns = html as NSString
            var found: [String] = []
            for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range)
                if !found.contains(s) { found.append(s) }
            }
            guard !found.isEmpty else {
                completion(nil)
                return
            }
            let ordered = self.orderedStreamURLs(found.map { StreamCandidate(url: $0, width: 0) })
            self.resolveBestVideoStream(from: ordered, completion: completion)
        }.resume()
    }

    // MARK: - Image fallback

    private func fallbackToImage(pinData: [String: Any], completion: @escaping (PinterestMediaResult?) -> Void) {
        if let images = pinData["images"] as? [String: Any] {
            for sizeKey in ["orig", "736x", "474x"] {
                if let imgInfo = images[sizeKey] as? [String: Any],
                   let u = imgInfo["url"] as? String,
                   let imageURL = URL(string: u) {
                    completion(.image(imageURL))
                    return
                }
            }
        }
        completion(nil)
    }
}

```

---

### File: `Sources/CursorDeckCore/VideoToGIFConverter.swift`

```swift
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CoreVideo
import VideoToolbox
import UniformTypeIdentifiers

/// Converts videos into lightweight, slide-friendly animated GIFs.
public final class VideoToGIFConverter {
    public static let shared = VideoToGIFConverter()

    private let conversionQueue = DispatchQueue(label: "com.cursordeck.gifconverter", qos: .userInitiated)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init() {}

    // MARK: - Local file -> GIF

    /// Converts a local video file into an animated GIF Data in the background.
    /// `completion` is always called on the main queue.
    public func convert(
        videoURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        conversionQueue.async {
            let asset = AVURLAsset(url: videoURL)
            let durationSeconds = CMTimeGetSeconds(asset.duration)
            guard durationSeconds > 0 && !durationSeconds.isNaN else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            let loopDuration = min(durationSeconds, maxDuration)
            let totalFrames = max(1, Int(loopDuration * fps))
            let frameDuration = 1.0 / fps

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
            // FIX: .zero tolerance forces an exact-frame seek (decode from the previous keyframe)
            // for every one of ~56 frames, which is very slow and pointless for a 14fps GIF.
            // Half a frame interval of slack lets the decoder reuse nearby frames.
            let tolerance = CMTime(seconds: frameDuration / 2.0, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            var frames: [CGImage] = []
            frames.reserveCapacity(totalFrames)
            for i in 0..<totalFrames {
                let time = CMTime(seconds: Double(i) * frameDuration, preferredTimescale: 600)
                // FIX: autoreleasepool keeps peak memory flat across the loop.
                autoreleasepool {
                    if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                        frames.append(image)
                    }
                }
            }

            guard !frames.isEmpty,
                  let finalData = self.encodeImagesToGIF(frames: frames, delays: nil, fps: fps, maxWidth: maxWidth) else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            DispatchQueue.main.async {
                completion(finalData, finalData.count)
            }
        }
    }

    // MARK: - HLS stream -> GIF

    /// Converts an HLS (.m3u8) stream into an animated GIF Data (real-time capture, so it takes
    /// about `maxDuration` seconds). `completion` is always called on the main queue.
    public func convertHLS(
        streamURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        // FIX: callers invoke this from URLSession callback threads. Timer.scheduledTimer there
        // attaches to a runloop nobody runs (it only worked because of the extra RunLoop.main.add).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.convertHLS(streamURL: streamURL, maxDuration: maxDuration, fps: fps,
                                 maxWidth: maxWidth, completion: completion)
            }
            return
        }

        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true   // FIX: the original played the video's audio out loud while converting

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player.play()

        let frameInterval = 1.0 / fps
        let targetFrameCount = max(1, Int(maxDuration * fps))
        let deadline = CACurrentMediaTime() + max(12.0, maxDuration * 3.0)

        var frames: [CGImage] = []
        var stamps: [Double] = []              // media time of each captured frame
        var lastCaptured = -Double.infinity

        let timer = Timer(timeInterval: frameInterval / 2.0, repeats: true) { [weak self] t in
            let failed = item.status == .failed          // FIX: fail fast instead of waiting out the deadline
            let mediaTime = item.currentTime()
            let seconds = CMTimeGetSeconds(mediaTime)

            // FIX: sample on *media* time, not wall-clock ticks. A stalled main runloop or a
            // buffering stream used to produce duplicated/missing frames and a sped-up GIF.
            if !failed, seconds.isFinite, seconds - lastCaptured >= frameInterval * 0.95,
               output.hasNewPixelBuffer(forItemTime: mediaTime),
               let buffer = output.copyPixelBuffer(forItemTime: mediaTime, itemTimeForDisplay: nil) {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cg)
                // FIX: downscale into our own bitmap immediately. (a) Native 720p/1080p frames
                // were kept in `frames` (~3.7-8 MB each, up to ~450 MB for 56 frames);
                // (b) the VT-created CGImage can keep the CVPixelBuffer alive, starving the
                // output's buffer pool.
                if let cg = cg, let small = self?.scaledCopy(cg, maxDimension: maxWidth) {
                    frames.append(small)
                    stamps.append(seconds)
                    lastCaptured = seconds
                }
            }

            guard frames.count >= targetFrameCount || failed || CACurrentMediaTime() > deadline else { return }

            t.invalidate()
            item.remove(output)
            player.pause()
            player.replaceCurrentItem(with: nil)   // release the HLS connection + buffers right away

            guard let self = self, !frames.isEmpty else {
                completion(nil, 0)
                return
            }

            // Per-frame delays from real timestamps so playback speed matches the source.
            var delays: [Double] = []
            for i in 0..<stamps.count {
                delays.append(i + 1 < stamps.count ? stamps[i + 1] - stamps[i] : frameInterval)
            }
            let captured = frames
            frames.removeAll()

            self.conversionQueue.async {
                let gifData = self.encodeImagesToGIF(frames: captured, delays: delays, fps: fps, maxWidth: maxWidth)
                DispatchQueue.main.async {
                    completion(gifData, gifData?.count ?? 0)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Encoding

    /// Draws `image` into a fresh 8-bit sRGB bitmap that fits inside `maxDimension` x `maxDimension`.
    /// FIX: the original built its CGContext from the *source* frame's bitsPerComponent / colorSpace /
    /// bitmapInfo, which can fail for video-derived images (then it silently kept the full-size
    /// frame), and left wide-gamut video colors untagged for GIF (visible color shift in Slides).
    private func scaledCopy(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w0 = CGFloat(image.width), h0 = CGFloat(image.height)
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w0, h0))
        let w = max(1, Int((w0 * scale).rounded()))
        let h = max(1, Int((h0 * scale).rounded()))

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.sRGB, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Assembles frames into a looping GIF. `delays` (seconds per frame) is optional; nil = uniform 1/fps.
    private func encodeImagesToGIF(frames: [CGImage], delays: [Double]?, fps: Double, maxWidth: CGFloat) -> Data? {
        guard !frames.isEmpty else { return nil }

        let gifData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            gifData as CFMutableData,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0 // Infinite loop
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let uniformDelay = 1.0 / fps
        for (i, frame) in frames.enumerated() {
            // GIF delays are centiseconds; browsers/Slides clamp < 2cs, so don't go below that.
            let delay = max(0.02, delays?[i] ?? uniformDelay)
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay
                ]
            ]
            let finalImage = scaledCopy(frame, maxDimension: maxWidth) ?? frame
            CGImageDestinationAddImage(destination, finalImage, frameProperties as CFDictionary)
        }

        let success = CGImageDestinationFinalize(destination)
        return (success && gifData.length > 0) ? (gifData as Data) : nil
    }
}

```

---

### File: `Sources/CursorDeckCore/ShakeDetector.swift`

```swift
import AppKit
import Foundation

/// Detects a rapid back-and-forth shake of the mouse pointer to discard/clear the entire active deck.
public final class ShakeDetector {
    public var isEnabled: Bool = true
    public var onShakeDetected: (() -> Void)?

    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    private var cooldownUntil: TimeInterval = 0

    private let minReversals: Int = 4
    private let minTravelDistance: CGFloat = 320.0
    private let windowDuration: TimeInterval = 0.42
    private let cooldownDuration: TimeInterval = 0.80
    private let minDeltaToCount: CGFloat = 3.0

    public init() {}

    public func observe(x: CGFloat) {
        guard isEnabled else { return }

        let now = CACurrentMediaTime()
        if now < cooldownUntil { return }

        // Remove samples outside sliding window
        let cutoff = now - windowDuration
        while let oldest = samples.first, oldest.t < cutoff {
            samples.removeFirst()
        }
        samples.append((x: x, t: now))

        guard samples.count >= 6 else { return }

        var reversals = 0
        var travel: CGFloat = 0.0
        var lastDirection = 0

        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            if abs(dx) < minDeltaToCount { continue }
            let dir = dx > 0 ? 1 : -1
            if lastDirection != 0 && dir != lastDirection {
                reversals += 1
            }
            lastDirection = dir
            travel += abs(dx)
        }

        if reversals >= minReversals && travel >= minTravelDistance {
            cooldownUntil = now + cooldownDuration
            samples.removeAll()
            onShakeDetected?()
        }
    }

    public func reset() {
        samples.removeAll()
    }
}

```

---

### File: `Sources/CursorDeckCore/MenuBarManager.swift`

```swift
import AppKit
import Foundation
import SwiftUI

public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private let queueManager: DeckQueueManager
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?

    private var panel: DeckControlCenterPanel?
    private var controlCenterState: DeckControlCenterState?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var lastDismissTimestamp: TimeInterval = 0

    public init(
        queueManager: DeckQueueManager,
        clipboardWatcher: ClipboardWatcher? = nil,
        screenshotWatcher: ScreenshotWatcher? = nil,
        hudPanel: CursorHUDPanel? = nil
    ) {
        self.queueManager = queueManager
        self.clipboardWatcher = clipboardWatcher
        self.screenshotWatcher = screenshotWatcher
        self.hudPanel = hudPanel
        super.init()
        setupStatusBar()
    }

    deinit {
        removeClickOutsideMonitors()
    }

    private func setupStatusBar() {
        // Create status bar item in macOS menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = DeckLogoAsset.menuBarImage
            button.imagePosition = .imageOnly
            button.toolTip = "Cursor Deck (Visual Accumulator)"
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let state = DeckControlCenterState(
            queueManager: queueManager,
            clipboardWatcher: clipboardWatcher,
            screenshotWatcher: screenshotWatcher,
            hudPanel: hudPanel
        )
        self.controlCenterState = state

        let panel = DeckControlCenterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 350)
        )
        panel.onEscPressed = { [weak self] in
            self?.closePanel()
        }

        let hostingView = NSHostingView(
            rootView: DeckControlCenterView(
                state: state,
                onDismiss: { [weak self] in
                    self?.closePanel()
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 256, height: 350)
        panel.contentView = hostingView
        self.panel = panel

        updateStatusItemBadge()

        queueManager.addObserver { [weak self] _ in
            self?.updateStatusItemBadge()
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            closePanel()
            showContextMenu(sender)
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastDismissTimestamp < 0.25 {
                return
            }
            togglePanel(sender)
        }
    }

    public func togglePanel(_ sender: NSStatusBarButton) {
        guard let panel = panel else { return }
        if panel.isVisible {
            closePanel()
        } else {
            openPanel(sender)
        }
    }

    public func openPanel(_ sender: NSStatusBarButton) {
        guard let panel = panel, let buttonWindow = sender.window else { return }
        
        controlCenterState?.refresh()
        
        let buttonScreenRect = buttonWindow.convertToScreen(sender.bounds)
        let panelSize = NSSize(width: 256, height: 350)
        
        var originX = buttonScreenRect.midX - (panelSize.width / 2.0)
        
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            if originX + panelSize.width > screenFrame.maxX - 8 {
                originX = screenFrame.maxX - panelSize.width - 8
            }
            if originX < screenFrame.minX + 8 {
                originX = screenFrame.minX + 8
            }
        }
        
        let originY = buttonScreenRect.minY - panelSize.height - 4
        
        panel.setFrame(NSRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        
        setupClickOutsideMonitors()
    }

    public func closePanel() {
        guard let panel = panel, panel.isVisible else { return }
        removeClickOutsideMonitors()
        lastDismissTimestamp = Date().timeIntervalSinceReferenceDate
        panel.orderOut(nil)
    }

    private func setupClickOutsideMonitors() {
        removeClickOutsideMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            
            if let button = self.statusItem?.button, let buttonWindow = button.window {
                let mouseLoc = NSEvent.mouseLocation
                let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                if buttonScreenRect.contains(mouseLoc) {
                    self.closePanel()
                    return
                }
            }
            
            let mouseLoc = NSEvent.mouseLocation
            if !panel.frame.contains(mouseLoc) {
                self.closePanel()
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            
            if event.window != panel {
                if let button = self.statusItem?.button, let buttonWindow = button.window {
                    let mouseLoc = NSEvent.mouseLocation
                    let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                    if buttonScreenRect.contains(mouseLoc) {
                        self.closePanel()
                        return event
                    }
                }
                self.closePanel()
            }
            return event
        }
    }

    private func removeClickOutsideMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let count = queueManager.count
        let isPaused = clipboardWatcher?.isPaused ?? false

        let headerItem = NSMenuItem(title: "Cursor Deck: \(count) item\(count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy Batch to Clipboard", action: #selector(copyBatch), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = count > 0
        menu.addItem(copyItem)

        let clearItem = NSMenuItem(title: "Clear Deck", action: #selector(clearDeck), keyEquivalent: "k")
        clearItem.target = self
        clearItem.isEnabled = count > 0
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(
            title: isPaused ? "▶ Resume Tracking" : "⏸ Pause Tracking",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Cursor Deck", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil // reset so left-click reopens popover
    }

    public func updateMenu() {
        updateStatusItemBadge()
        controlCenterState?.refresh()
    }

    public func updateStatusItemBadge() {
        guard let button = statusItem?.button else { return }
        let count = queueManager.count
        let isPaused = clipboardWatcher?.isPaused ?? false
        button.image = DeckLogoAsset.menuBarImage
        if isPaused {
            button.imagePosition = .imageLeft
            button.title = " ⏸"
        } else if count > 0 {
            button.imagePosition = .imageLeft
            button.title = " \(count)"
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    @objc public func copyBatch() {
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
    }

    @objc public func clearDeck() {
        queueManager.clear()
        updateStatusItemBadge()
    }

    @objc public func togglePause() {
        let isNowPaused = !(clipboardWatcher?.isPaused ?? false)
        clipboardWatcher?.isPaused = isNowPaused
        screenshotWatcher?.isPaused = isNowPaused
        updateStatusItemBadge()
        controlCenterState?.refresh()
    }

    @objc public func toggleSmartFilter() {
        if let watcher = clipboardWatcher {
            watcher.isSmartFilterEnabled = !watcher.isSmartFilterEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleScreenshotWatcher() {
        if let watcher = screenshotWatcher {
            watcher.isEnabled = !watcher.isEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleShakeToClear() {
        if let panel = hudPanel {
            panel.shakeDetector.isEnabled = !panel.shakeDetector.isEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleLaunchAtLogin() {
        let current = LaunchAtLoginManager.shared.isEnabled
        LaunchAtLoginManager.shared.setEnabled(!current)
        controlCenterState?.refresh()
    }

    @objc public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckControlCenterPanel.swift`

```swift
import AppKit
import Foundation

/// Borderless, arrowless floating panel for the CursorDeck menu bar Control Center.
/// Replaces NSPopover to provide a clean, modern macOS system dropdown without triangular nibs.
public final class DeckControlCenterPanel: NSPanel {
    public var onEscPressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.animationBehavior = .utilityWindow
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
    }

    public override var canBecomeKey: Bool {
        return true
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscPressed?()
    }
}

```

---

### File: `Sources/CursorDeckCore/DeckControlCenterView.swift`

```swift
import AppKit
import Foundation
import SwiftUI

// MARK: - Control Center Switch (Native macOS 30x17 Capsule)

public struct ControlCenterSwitch: View {
    public let isOn: Bool

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: 30, height: 17)

            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .padding(2)
                .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 0.5)
        }
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

// MARK: - Observable State Model

public final class DeckControlCenterState: ObservableObject {
    @Published public var itemCount: Int = 0
    @Published public var isTrackingPaused: Bool = false
    @Published public var isSmartFilterEnabled: Bool = true
    @Published public var isScreenshotWatcherEnabled: Bool = true
    @Published public var isShakeClearEnabled: Bool = true
    @Published public var isLaunchAtLoginEnabled: Bool = false
    @Published public var isCopiedFeedback: Bool = false

    private weak var queueManager: DeckQueueManager?
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?
    private var observerToken: UUID?

    public init(
        queueManager: DeckQueueManager? = nil,
        clipboardWatcher: ClipboardWatcher? = nil,
        screenshotWatcher: ScreenshotWatcher? = nil,
        hudPanel: CursorHUDPanel? = nil
    ) {
        self.queueManager = queueManager
        self.clipboardWatcher = clipboardWatcher
        self.screenshotWatcher = screenshotWatcher
        self.hudPanel = hudPanel
        refresh()

        self.observerToken = queueManager?.addObserver { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    public func refresh() {
        self.itemCount = queueManager?.count ?? 0
        self.isTrackingPaused = clipboardWatcher?.isPaused ?? false
        self.isSmartFilterEnabled = clipboardWatcher?.isSmartFilterEnabled ?? true
        self.isScreenshotWatcherEnabled = screenshotWatcher?.isEnabled ?? true
        self.isShakeClearEnabled = hudPanel?.shakeDetector.isEnabled ?? true
        self.isLaunchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
    }

    public func toggleTracking() {
        let newPaused = !isTrackingPaused
        clipboardWatcher?.isPaused = newPaused
        screenshotWatcher?.isPaused = newPaused
        isTrackingPaused = newPaused
    }

    public func toggleSmartFilter() {
        let newFilter = !isSmartFilterEnabled
        clipboardWatcher?.isSmartFilterEnabled = newFilter
        isSmartFilterEnabled = newFilter
    }

    public func toggleScreenshots() {
        let newScreenshots = !isScreenshotWatcherEnabled
        screenshotWatcher?.isEnabled = newScreenshots
        isScreenshotWatcherEnabled = newScreenshots
    }

    public func toggleShakeClear() {
        let newShake = !isShakeClearEnabled
        hudPanel?.shakeDetector.isEnabled = newShake
        isShakeClearEnabled = newShake
    }

    public func toggleLaunchAtLogin() {
        let newLaunch = !isLaunchAtLoginEnabled
        LaunchAtLoginManager.shared.setEnabled(newLaunch)
        isLaunchAtLoginEnabled = newLaunch
    }

    public func copyAll() {
        guard let queueManager = queueManager, !queueManager.isEmpty else { return }
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            withAnimation(.easeInOut(duration: 0.15)) {
                self?.isCopiedFeedback = false
            }
        }
    }

    public func clearDeck() {
        queueManager?.clear()
        refresh()
    }

    public func openGrid(onDismiss: (() -> Void)? = nil) {
        onDismiss?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.hudPanel?.togglePreview()
        }
    }

    public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Native macOS Dropdown Style Popover (Matched to System Wi-Fi Dropdown & Golden Gate Tokens)

public enum PopoverPage {
    case controls
    case howToUse
}

public struct DeckControlCenterView: View {
    @ObservedObject public var state: DeckControlCenterState
    public var onDismiss: (() -> Void)?

    @State public var currentPage: PopoverPage
    @State private var hoveredRow: String? = nil
    @State private var hoveredAction: String? = nil
    @State private var isHowToUseHovered: Bool = false

    public init(
        state: DeckControlCenterState,
        onDismiss: (() -> Void)? = nil,
        initialPage: PopoverPage = .controls
    ) {
        self.state = state
        self.onDismiss = onDismiss
        self._currentPage = State(initialValue: initialPage)
    }

    public var body: some View {
        ZStack {
            if currentPage == .controls {
                controlsPage
                    .frame(width: 256, height: 350)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            } else {
                howToUsePage
                    .frame(width: 256, height: 350)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
            }
        }
        .frame(width: 256, height: 350)
        .clipped()
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: currentPage)
        .background(Material.ultraThin)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Controls Page (Default Popover View)

    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. MASTER HEADER (Matches "Wi-Fi [Toggle]" row in macOS)
            masterHeaderRow
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            dividerView

            // 2. CAPTURE PREFERENCES SECTION (Liquid Glass Circular Badges with Switches)
            sectionHeader("Preferences")
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 3)

            VStack(spacing: 2) {
                // Smart Filter
                listToggleRow(
                    id: "filter",
                    symbol: "line.3.horizontal.decrease",
                    title: "Smart Filter",
                    isOn: state.isSmartFilterEnabled,
                    action: { state.toggleSmartFilter() }
                )

                // Screenshots
                listToggleRow(
                    id: "screenshots",
                    symbol: "camera.viewfinder",
                    title: "Screenshots",
                    isOn: state.isScreenshotWatcherEnabled,
                    action: { state.toggleScreenshots() }
                )

                // Shake Clear
                listToggleRow(
                    id: "shake",
                    symbol: "pointer.arrow.motionlines",
                    title: "Shake to Clear",
                    isOn: state.isShakeClearEnabled,
                    action: { state.toggleShakeClear() }
                )
            }
            .padding(.horizontal, 8)

            dividerView
                .padding(.top, 6)

            // 3. DECK ACTIONS (Horizontal Action Row)
            sectionHeader("Actions")
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 5)

            deckActionsRow
                .padding(.horizontal, 10)

            dividerView
                .padding(.top, 7)

            // 4. SYSTEM PREFERENCE (Launch at Login)
            VStack(spacing: 2) {
                listToggleRow(
                    id: "launch",
                    symbol: "power",
                    title: "Launch at Login",
                    isOn: state.isLaunchAtLoginEnabled,
                    action: { state.toggleLaunchAtLogin() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            dividerView
                .padding(.top, 6)

            // 5. UTILITY FOOTER (Updates, Quit, and How to Use)
            utilityFooter
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Master Header (Title + Master Tracking Toggle)

    private var masterHeaderRow: some View {
        Button(action: {
            state.toggleTracking()
        }) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CursorDeck")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundColor(.primary)

                    Text(statusSubtitle)
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(.secondary)
                }

                Spacer()

                ControlCenterSwitch(isOn: !state.isTrackingPaused)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusSubtitle: String {
        if state.isTrackingPaused {
            return "Tracking is paused"
        } else if state.itemCount == 0 {
            return "Nothing in the deck"
        } else if state.itemCount == 1 {
            return "1 item ready"
        } else {
            return "\(state.itemCount) items ready"
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .default))
            .foregroundColor(.secondary)
    }

    // MARK: - Native List Toggle Row (Matches Wi-Fi list row with Golden Gate Liquid Glass badge)

    private func listToggleRow(
        id: String,
        symbol: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRow == id

        return Button(action: action) {
            HStack(spacing: 9) {
                // Liquid Glass circular icon badge
                ZStack {
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 26, height: 26)

                    // Specular highlight rim from Liquid Glass - Small token
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.35 : 0.16),
                                    Color.white.opacity(isOn ? 0.08 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                        .frame(width: 26, height: 26)

                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundColor(isOn ? .white : Color.secondary)
                }

                // Row title
                Text(title)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.primary)

                Spacer()

                // Native switch toggle
                ControlCenterSwitch(isOn: isOn)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredRow = inside ? id : nil
            }
        }
    }

    // MARK: - Deck Actions Row (Liquid Glass compact action buttons)

    private var deckActionsRow: some View {
        HStack(spacing: 6) {
            actionButton(
                id: "copy",
                symbol: state.isCopiedFeedback ? "checkmark" : "doc.on.doc",
                label: state.isCopiedFeedback ? "Copied" : "Copy All",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                action: { state.copyAll() }
            )

            actionButton(
                id: "grid",
                symbol: "square.grid.2x2",
                label: "Grid",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                action: { state.openGrid(onDismiss: onDismiss) }
            )

            actionButton(
                id: "clear",
                symbol: "trash",
                label: "Clear",
                isDestructive: true,
                isEnabled: state.itemCount > 0,
                action: { state.clearDeck() }
            )
        }
        .frame(height: 32)
    }

    private func actionButton(
        id: String,
        symbol: String,
        label: String,
        isDestructive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction == id

        let normalBg = Color.primary.opacity(0.05)
        let hoverBg = isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.09)
        let currentBg = isHovered ? hoverBg : normalBg

        let fgColor: Color
        if !isEnabled {
            fgColor = Color.secondary.opacity(0.4)
        } else if isDestructive && isHovered {
            fgColor = Color.red
        } else {
            fgColor = Color.primary
        }

        return Button(action: {
            if isEnabled { action() }
        }) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(fgColor)

                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(fgColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(currentBg)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.10 : 0.05), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredAction = inside ? id : nil
            }
        }
    }

    // MARK: - Utility Footer

    private var utilityFooter: some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: {
                    onDismiss?()
                    state.checkForUpdates()
                }) {
                    Text("Check for Updates...")
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    state.quitApp()
                }) {
                    Text("Quit")
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    currentPage = .howToUse
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("How to Use")
                        .font(.system(size: 11.5, weight: .medium, design: .default))
                        .foregroundColor(.primary.opacity(0.9))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(isHowToUseHovered ? Color.primary.opacity(0.065) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHowToUseHovered = inside
                }
            }
        }
    }

    // MARK: - How to Use Page (Slide-over view with clear instructions & hotkeys)

    private var howToUsePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Back button
            HStack {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        currentPage = .controls
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.001))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("How to Use")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundColor(.primary)

                Spacer()

                // Invisible spacer for centered title alignment
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .opacity(0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 11)
            .padding(.bottom, 9)

            dividerView

            // Scrollable Instructions List (Visible scrollbar, generous breathing room)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    // SECTION 1: CORE ACTIONS
                    sectionHeader("Core Actions & Gestures")
                        .padding(.top, 4)

                    instructionRow(
                        symbol: "doc.on.doc",
                        title: "Collect Images",
                        badge: "⌘ C",
                        description: "Right-click any image & copy (or press ⌘C) to start building your deck."
                    )

                    instructionRow(
                        symbol: "camera.viewfinder",
                        title: "Screenshots",
                        badge: "⌘ ⇧ 4",
                        description: "Screenshots join the pill directly without cluttering your desktop."
                    )

                    instructionRow(
                        symbol: "film.stack",
                        title: "Pinterest to GIF",
                        badge: "URL",
                        description: "Copy a Pinterest video URL; auto-converts to a looping GIF (up to 4s)."
                    )

                    instructionRow(
                        symbol: "arrow.down.doc",
                        title: "Drop on Slides",
                        badge: "⌘ + Drag",
                        description: "Hold ⌘ to snap pill, drag to canvas, release ⌘. Drop on green + icon."
                    )

                    instructionRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: "Copy for Chat",
                        badge: "⌘ + Click",
                        description: "⌘ + Click the pill to arm clipboard, then press ⌘V in WhatsApp or chat."
                    )

                    instructionRow(
                        symbol: "square.grid.2x2",
                        title: "Preview Grid",
                        badge: "⌥ + Click",
                        description: "Option + Click pill to inspect images or delete individual items (✕)."
                    )

                    instructionRow(
                        symbol: "pointer.arrow.motionlines",
                        title: "Shake to Clear",
                        badge: "Shake",
                        description: "Rapidly shake cursor back & forth to empty the entire deck."
                    )

                    dividerView
                        .padding(.vertical, 3)

                    // SECTION 2: SETTINGS & CONTROLS
                    sectionHeader("Settings & Controls")

                    instructionRow(
                        symbol: "power",
                        title: "CursorDeck Switch",
                        badge: nil,
                        description: "Master toggle to pause or resume tracking whenever you need."
                    )

                    instructionRow(
                        symbol: "line.3.horizontal.decrease",
                        title: "Smart Filter",
                        badge: nil,
                        description: "Ignores internal shape copies from Figma, Photoshop & Illustrator."
                    )

                    instructionRow(
                        symbol: "camera.viewfinder",
                        title: "Screenshots",
                        badge: nil,
                        description: "Toggles whether desktop screenshots are automatically collected."
                    )

                    instructionRow(
                        symbol: "pointer.arrow.motionlines",
                        title: "Shake to Clear",
                        badge: nil,
                        description: "Enables or disables rapid cursor shake gesture discard."
                    )

                    instructionRow(
                        symbol: "power.circle",
                        title: "Launch at Login",
                        badge: nil,
                        description: "Runs CursorDeck silently in menu bar on Mac startup."
                    )

                    instructionRow(
                        symbol: "slider.horizontal.3",
                        title: "Action Bar",
                        badge: nil,
                        description: "Quick buttons for Copy All, Grid Preview, and Clear."
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
    }

    private func instructionRow(
        symbol: String,
        title: String,
        badge: String?,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Liquid Glass icon badge (Golden Gate token style)
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 25, height: 25)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .frame(width: 25, height: 25)

                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(Color.secondary)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(alignment: .center, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let badge = badge {
                        KeycapBadgeView(badge)
                    }
                }

                Text(description)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 2.5)
    }

    // MARK: - Divider

    private var dividerView: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

// MARK: - Keycap Badge View (Mac HIG breathable keycaps)

public struct KeycapBadgeView: View {
    public let badge: String

    public init(_ badge: String) {
        self.badge = badge
    }

    public var body: some View {
        HStack(spacing: 2.5) {
            ForEach(tokens(for: badge), id: \.self) { token in
                if token == "+" {
                    Text("+")
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.8))
                } else {
                    Text(token)
                        .font(.system(size: token.count == 1 ? 10.5 : 9.5, weight: .medium, design: .default))
                        .foregroundColor(.primary.opacity(0.88))
                        .padding(.horizontal, token.count == 1 ? 4.5 : 5.5)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
            }
        }
    }

    private func tokens(for string: String) -> [String] {
        switch string {
        case "⌘ C":
            return ["⌘", "C"]
        case "⌘ ⇧ 4":
            return ["⌘", "⇧", "4"]
        case "⌘ + Drag":
            return ["⌘", "+", "Drag"]
        case "⌘ + Click":
            return ["⌘", "+", "Click"]
        case "⌥ + Click":
            return ["⌥", "+", "Click"]
        default:
            return [string]
        }
    }
}


```

---

### File: `Sources/CursorDeckCore/DeckLogoAsset.swift`

```swift
import AppKit
import Foundation

/// Official brand logo icon for CursorDeck (two solid stacked cards).
public enum DeckLogoAsset {
    /// 64x64 Retina PNG asset (transparent background, transparent separator gap, solid white cards)
    private static let base64Data = """
    iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAQKADAAQAAAABAAAAQAAAAABGUUKwAAADzUlEQVR4Ae2byWsUQRTG01GJuK8oLgfxIhKiHlQ8CBo8RAWFgEHwIAmoBw8iATFevHiSXETNwfUPMLcoEiWIiiseokluLigYwSVRE4JRk/H3TaaG7pCe7onRme7qB99Uddernvd99bq6GqqdkgBLpVLLcVkL1oAasAAMgf9tk/jDN+Aa6ATtjuN8pvw3BvEtoBn0gGK0boK6AComVAEuOA9cAkMgCtZHkCfBlPEI4bg7cRGlezPY4D4fkbriruW26M8n3qwAkJ9Lx1awPp8LFJmv5od9iPArbFyTXY6nqY+H/A/69YIBkAKFslL+uBIcAufCBpEWgNHfTIfasJ3w0+x7I4PnlB+BhCikAMrm6WAmCG0mA47QQ4+ZINMoS93zpNm70c4IGeYao7tN5HEvcX3J54IOQS+hQxeYE9Cxg/aD/MFj40ffddSrgCbNpWAaKLQpC/uA1gwPQCsxv6Ic2yCxEwTZfRwWmytQ3whawE9Q7PaVALVeWGHi95Q0NAQw6KR9kelE/RgYCOhTjM1aOFUbHtmSk205ou2nLbsmoN6YwzcKTcpYz2SvR4dmTj9r4v55qkY6aqKs93OMyHmtFpvgstXEKwH8Hl2aTc/IkQ7lFKdUj4FNhYNEmC0uEsDPrjP67zONJyhn+DlG8PwqYq5T3LkEaJEDSmn23KV6zKwObmV+AmhVpxWerBLkmifSThH8WU3M5X4C6P7/lCE1nveDKOgh7hV+AmjJqyyQLRspYvlb4yfAMHTN06EsltRHSFX5CRBjzl5qiQBePew7SjLAvjH3Mk4ywKuHfUdJBtg35l7GSQZ49bDvKMkA+8bcyzjJAK8e9h0lGWDfmHsZJxng1cO+oyQD7BtzL+MkA9DDahFEXttJrDUJcNta9hCXAC9sF6AdAbTR0UorZRPEB5jfspI9pM0TQFthftsoQloAsuAR5C9aK0CG+HHKh5m6QynE3swtUEIWfIftHqBs0MZI7aaKvWUFEFNE6KbYDi6D+SDuNmh2i2eJIsI3DurZQWV2fuf1BUb2QtGoXPVkgDtmhBjKHL90n49Zvc1XABdRMzG6TsWiqk1g7WEEuIujFktxMw3s60ABuBV6cLwSN/bwOQu34VDPeiZEPRGegJUxEULfO+3WPBeYASKMo3aOHgDaQBl106c0h0VeREIJIEc63KHYD6L8WBT5ari8pUxbaAHkTUd9nbkDmI3UOh0Vu0mg2+Cg1/+/M+aEWeAo6ADDoFhtkMDugb1gzMEONQn6ycVF9b6gT+s3gQawEBSDdRFEI3gGuhj1lF9QfwCap18iPJ/dqgAAAABJRU5ErkJggg==
    """

    /// Master template image decoded from PNG data
    public static let masterImage: NSImage = {
        guard let data = Data(base64Encoded: base64Data),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        img.isTemplate = true
        return img
    }()

    /// Sized specifically for macOS system menu bar (15x15 pt, standard optical weight)
    public static var menuBarImage: NSImage {
        guard let data = Data(base64Encoded: base64Data),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        img.size = NSSize(width: 15, height: 15)
        img.isTemplate = true
        return img
    }

    /// Sized specifically for floating cursor pill (10x10 pt, subtle and balanced)
    public static var pillImage: NSImage {
        guard let data = Data(base64Encoded: base64Data),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        img.size = NSSize(width: 10, height: 10)
        img.isTemplate = true
        return img
    }
}

```

---

### File: `Sources/CursorDeckCore/LaunchAtLoginManager.swift`

```swift
import Foundation

public final class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()

    private let agentLabel = "com.cursordeck.app"
    private var plistURL: URL {
        let libraryDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return libraryDir.appendingPathComponent("\(agentLabel).plist")
    }

    public var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func setEnabled(_ enable: Bool) {
        if enable {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    public func installLaunchAgent() {
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let appPath = "/Applications/CursorDeck.app/Contents/MacOS/CursorDeckApp"
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    public func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}

```

---

### File: `Sources/CursorDeckCore/UpdateManager.swift`

```swift
import AppKit
import Foundation

/// Manages checking for GitHub Releases, downloading, and auto-updating CursorDeck in-place.
public final class UpdateManager {
    public static let shared = UpdateManager()

    public static let currentVersion = "1.1.8"
    public static let repoOwner = "spandanmahajan-rgb"
    public static let repoName = "cursor-deck"

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

    private var isChecking = false

    private init() {}

    /// Checks GitHub for new releases.
    /// - Parameter userInitiated: If true, shows an alert when already up-to-date or on error. If false, fails silently.
    public func checkForUpdates(userInitiated: Bool) {
        if !userInitiated {
            // Background check: throttle to at most once every 24 hours
            let lastCheck = UserDefaults.standard.double(forKey: "CursorDeck_lastBackgroundCheck")
            let now = Date().timeIntervalSince1970
            if now - lastCheck < 86400 {
                return
            }
        }

        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("CursorDeck-App", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if !userInitiated {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CursorDeck_lastBackgroundCheck")
                }

                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if userInitiated {
                        self.showAlert(
                            title: "Check for Updates",
                            message: "Unable to check for updates right now. Please check your internet connection.",
                            button: "OK"
                        )
                    }
                    return
                }

                self.handleReleaseResponse(json, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleReleaseResponse(_ json: [String: Any], userInitiated: Bool) {
        guard let tagName = json["tag_name"] as? String else {
            if userInitiated {
                showAlert(title: "CursorDeck", message: "No release information found.", button: "OK")
            }
            return
        }

        let cleanRemoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let cleanCurrentVersion = UpdateManager.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let isNewer = compareVersions(cleanRemoteVersion, cleanCurrentVersion) > 0

        if !isNewer {
            if userInitiated {
                showAlert(
                    title: "You're Up to Date!",
                    message: "CursorDeck \(cleanCurrentVersion) is currently the newest version available.",
                    button: "OK"
                )
            }
            return
        }

        // If background check, check if user previously clicked "Later" for this specific version
        if !userInitiated {
            if let snoozed = UserDefaults.standard.string(forKey: "CursorDeck_snoozedVersion"),
               snoozed == cleanRemoteVersion {
                return
            }
        }

        // Newer version found!
        let body = (json["body"] as? String) ?? "A new update for CursorDeck is available."
        let htmlURL = (json["html_url"] as? String) ?? "https://github.com/\(UpdateManager.repoOwner)/\(UpdateManager.repoName)/releases"

        // Search for downloadable zip (preferred for seamless passwordless in-place update) or pkg
        var downloadURL: URL?
        var isZip = true

        if let assets = json["assets"] as? [[String: Any]] {
            // First check for ZIP for silent, passwordless auto-update
            for asset in assets {
                if let name = asset["name"] as? String,
                   let downloadString = asset["browser_download_url"] as? String,
                   let url = URL(string: downloadString),
                   name.lowercased().hasSuffix(".zip") {
                    downloadURL = url
                    isZip = true
                    break
                }
            }

            // Fallback to PKG if ZIP not present
            if downloadURL == nil {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       let downloadString = asset["browser_download_url"] as? String,
                       let url = URL(string: downloadString),
                       name.lowercased().hasSuffix(".pkg") {
                        downloadURL = url
                        isZip = false
                        break
                    }
                }
            }
        }

        promptUserToUpdate(
            remoteVersion: cleanRemoteVersion,
            releaseNotes: body,
            downloadURL: downloadURL,
            fallbackWebURL: URL(string: htmlURL)!,
            isZip: isZip
        )
    }

    private func promptUserToUpdate(
        remoteVersion: String,
        releaseNotes: String,
        downloadURL: URL?,
        fallbackWebURL: URL,
        isZip: Bool
    ) {
        let alert = NSAlert()
        alert.messageText = "CursorDeck \(remoteVersion) Available"
        alert.informativeText = "A newer version of CursorDeck is available (you currently have \(UpdateManager.currentVersion)).\n\nRelease Notes:\n\(releaseNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.removeObject(forKey: "CursorDeck_snoozedVersion")
            if let downloadURL = downloadURL {
                performDownloadAndInstall(from: downloadURL, isZip: isZip, remoteVersion: remoteVersion)
            } else {
                NSWorkspace.shared.open(fallbackWebURL)
            }
        } else {
            // User clicked "Later": snooze this version for background checks
            UserDefaults.standard.set(remoteVersion, forKey: "CursorDeck_snoozedVersion")
        }
    }

    private func performDownloadAndInstall(from url: URL, isZip: Bool, remoteVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Downloading Update..."
        alert.informativeText = "CursorDeck \(remoteVersion) is downloading in the background. Once ready, the installer will launch automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        URLSession.shared.downloadTask(with: url) { [weak self] tempFileUrl, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                guard let tempFileUrl = tempFileUrl, error == nil else {
                    self.showAlert(
                        title: "Update Failed",
                        message: "The download could not be completed: \(error?.localizedDescription ?? "Unknown error")",
                        button: "OK"
                    )
                    return
                }

                if isZip {
                    self.installZipUpdate(downloadedFile: tempFileUrl)
                } else {
                    self.installPkgUpdate(downloadedFile: tempFileUrl)
                }
            }
        }.resume()
    }

    private func installZipUpdate(downloadedFile: URL) {
        let tempExtractDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CursorDeckUpdate_\(UUID().uuidString)")

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", downloadedFile.path, tempExtractDir.path]

        do {
            try ditto.run()
            ditto.waitUntilExit()

            let appPath = tempExtractDir.appendingPathComponent("CursorDeck.app").path
            guard FileManager.default.fileExists(atPath: appPath) else {
                showAlert(title: "Update Failed", message: "The update archive did not contain CursorDeck.app.", button: "OK")
                return
            }

            let destinationPath = Bundle.main.bundlePath.hasPrefix("/Applications") ? Bundle.main.bundlePath : "/Applications/CursorDeck.app"
            let currentPID = ProcessInfo.processInfo.processIdentifier

            let isDestinationWritable = FileManager.default.isWritableFile(atPath: destinationPath)

            if !isDestinationWritable {
                // Requires admin privileges to overwrite root-owned /Applications bundle
                let script = "rm -rf '\(destinationPath)' && cp -R '\(appPath)' '\(destinationPath)' && xattr -cr '\(destinationPath)' && open '\(destinationPath)'"
                let appleScriptSource = "do shell script \"\(script)\" with administrator privileges"
                var errorDict: NSDictionary?
                if let appleScript = NSAppleScript(source: appleScriptSource) {
                    appleScript.executeAndReturnError(&errorDict)
                    if errorDict == nil {
                        NSApplication.shared.terminate(nil)
                        return
                    }
                }
            }

            // Standard non-privileged swap script waiting for PID exit
            let swapScript = """
            while kill -0 \(currentPID) 2>/dev/null; do
                sleep 0.1
            done
            rm -rf "\(destinationPath)"
            cp -R "\(appPath)" "\(destinationPath)"
            xattr -cr "\(destinationPath)" 2>/dev/null || true
            open "\(destinationPath)"
            rm -rf "\(tempExtractDir.path)"
            """

            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", swapScript]
            try relauncher.run()

            NSApplication.shared.terminate(nil)
        } catch {
            showAlert(title: "Update Error", message: "Failed to extract and install update: \(error.localizedDescription)", button: "OK")
        }
    }

    private func installPkgUpdate(downloadedFile: URL) {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CursorDeck-Installer.pkg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: downloadedFile, to: dest)
            NSWorkspace.shared.open(dest)
            NSApplication.shared.terminate(nil)
        } catch {
            showAlert(title: "Update Error", message: "Failed to launch package installer: \(error.localizedDescription)", button: "OK")
        }
    }

    private func showAlert(title: String, message: String, button: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: button)
        alert.runModal()
    }

    /// Compares two semver strings (e.g., "1.1.0" vs "1.0.0"). Returns >0 if v1 > v2, <0 if v1 < v2, 0 if equal.
    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let p1 = v1.split(separator: ".").compactMap { Int($0) }
        let p2 = v2.split(separator: ".").compactMap { Int($0) }

        let count = max(p1.count, p2.count)
        for i in 0..<count {
            let num1 = i < p1.count ? p1[i] : 0
            let num2 = i < p2.count ? p2[i] : 0
            if num1 != num2 {
                return num1 > num2 ? 1 : -1
            }
        }
        return 0
    }
}

```

---


---

## 3. Desired Audit Output Format

Please organize your audit findings into the following sections:

### Section 1: Executive Audit Summary
- **Overall Codebase Health Rating** (1 to 10).
- Key highlights of what is done well.
- Primary issues categorized by severity (**Critical**, **High**, **Medium**, **Low/Polishing**).

### Section 2: Code Bloat & Redundancy Analysis
- Specific dead code, unused methods, unnecessary abstractions, or duplicate helpers to delete.

### Section 3: Memory & Resource Leak Vulnerabilities
- Identified retain cycles, unreleased event monitors, un-autoreleased buffers, or missing cleanup routines.
- Concrete code fixes for each.

### Section 4: Concurrency, Threading & Race Conditions
- Thread safety analysis across `DeckQueueManager`, `ClipboardWatcher`, and `UpdateManager`.
- Concrete synchronization improvements.

### Section 5: Modernization & API Cleanups
- Deprecation removals (`load(.duration)` in `VideoToGIFConverter`).
- Swift 6 strict concurrency readiness.

### Section 6: Ready-to-Apply Diffs
- Provide exact unified git diffs or clean code replacements for the most impactful fixes.
