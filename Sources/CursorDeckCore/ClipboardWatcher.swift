import AppKit
import Foundation

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
    public var isPaused: Bool = false

    /// Whether smart filtering for pure vector/layer authoring copies is active
    public var isSmartFilterEnabled: Bool = true

    /// Known internal authoring flavors indicating canvas objects, vectors, or layer copies
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

    /// Supported image extensions when copying files directly
    private let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "svg"
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
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        cancelPendingRetries()
    }

    private func cancelPendingRetries() {
        for item in retryWorkItems {
            item.cancel()
        }
        retryWorkItems.removeAll()
    }

    public func checkForNewClipboardContent() {
        guard !isPaused else { return }

        let currentCount = pasteboard.changeCount
        guard currentCount != lastProcessedChangeCount else { return }

        // Attempt immediate extraction
        if extractAndCaptureImage(for: currentCount) {
            return
        }

        // If not immediately available, schedule rapid asynchronous retries.
        // Modern browsers (Chrome, Arc, Safari, Edge) and Electron apps (Figma, Slack)
        // often increment pasteboard changeCount on clearContents(), but serialize
        // and populate the actual image data asynchronously (15ms - 150ms later).
        cancelPendingRetries()

        let retryDelays: [TimeInterval] = [0.035, 0.080, 0.150, 0.280, 0.450]
        for (index, delay) in retryDelays.enumerated() {
            let isLast = index == retryDelays.count - 1
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard !self.isPaused else { return }
                guard self.pasteboard.changeCount == currentCount else { return }
                guard self.lastProcessedChangeCount != currentCount else { return }

                if self.extractAndCaptureImage(for: currentCount) {
                    self.cancelPendingRetries()
                } else if isLast {
                    // All retries exhausted and no image found — mark as handled (e.g. text/code copy)
                    self.lastProcessedChangeCount = currentCount
                }
            }
            retryWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @discardableResult
    private func extractAndCaptureImage(for changeCount: Int) -> Bool {
        // Ensure the changeCount hasn't changed since this attempt was triggered
        guard pasteboard.changeCount == changeCount else { return false }

        // 0. Ignore CursorDeck's own writes to prevent self-capture loops
        if pasteboard.string(forType: NSPasteboard.PasteboardType("com.cursordeck.internal-marker")) != nil {
            lastProcessedChangeCount = changeCount
            return true
        }

        // Check if types have been declared yet
        guard let types = pasteboard.types, !types.isEmpty else {
            return false
        }

        // 1. Smart Filter: Ignore internal vector/canvas/text copies from creative authoring tools
        if isSmartFilterEnabled {
            let hasEditorSignature = types.contains { t in
                let s = t.rawValue.lowercased()
                return excludedPasteboardSignatures.contains { sig in s.contains(sig) }
            }

            if hasEditorSignature {
                // A. Check if the clipboard contains text (e.g. text selection inside Illustrator or design tool)
                let isTextCopy = types.contains { t in
                    let s = t.rawValue.lowercased()
                    return s.contains("plain-text") || s.contains("stringpboardtype") || s.contains("text/plain") || s.contains("public.rtf")
                }
                if isTextCopy {
                    lastProcessedChangeCount = changeCount
                    return true
                }

                // B. Adobe Illustrator specifically: Illustrator ALWAYS attaches a synthetic fallback TIFF
                // for every single vector shape, path, or text frame. When Smart Filter is ON, reject these internal copies!
                let isIllustrator = types.contains { t in
                    let s = t.rawValue.lowercased()
                    return s.contains("com.adobe.illustrator") || s.contains("com.adobe.agave") || s.contains("adobe illustrator")
                }
                if isIllustrator {
                    // Only accept if it's an actual external image file copied from Finder/disk
                    let isExternalFile = types.contains { $0.rawValue == "NSFilenamesPboardType" }
                    if !isExternalFile {
                        lastProcessedChangeCount = changeCount
                        return true
                    }
                }

                // C. Other authoring tools (Figma, Sketch, InDesign, Blender):
                // Reject internal layer/vector nodes that lack explicit raster image files or PNG data
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

        // 2. Check if pasteboard contains Finder file paths (NSFilenamesPboardType)
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !filenames.isEmpty {
            var captured = false
            for path in filenames {
                let url = URL(fileURLWithPath: path)
                if supportedImageExtensions.contains(url.pathExtension.lowercased()) && !url.path.contains("cursor-deck") {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                }
            }
            if captured {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                return true
            }
        }

        // 3. Check if pasteboard contains file URLs (NSURL)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            var captured = false
            for url in fileURLs {
                if supportedImageExtensions.contains(url.pathExtension.lowercased()) && !url.path.contains("cursor-deck") {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                }
            }
            if captured {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                return true
            }
        }

        // 4. Check for direct PNG image data (most common in browsers, screenshots, Figma exports)
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

        // 5. Check for direct JPEG image data
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

        // 6. Check for TIFF image data (common in Safari and macOS native apps)
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

        // 7. Check for WebP / GIF image data
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

        // 8. Universal fallback: NSImage instantiation from pasteboard
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
}
