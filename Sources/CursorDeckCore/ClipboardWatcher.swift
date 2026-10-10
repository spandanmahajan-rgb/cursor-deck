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

    private static let rawImageFlavors: [([NSPasteboard.PasteboardType], String)] = [
        ([.png, .init("image/png"), .init("public.png")], "png"),
        ([.init("public.jpeg"), .init("image/jpeg"), .init("image/jpg")], "jpg"),
        ([.tiff, .init("public.tiff")], "tiff"),
        ([.init("org.webmproject.webp"), .init("image/webp")], "webp"),
        ([.init("com.compuserve.gif"), .init("image/gif")], "gif"),
    ]

    private static let secretMarkerTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",          // older 1Password builds
    ]

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

        // AUDIT: password managers (1Password, Bitwarden, Keychain…) tag copies as concealed/transient per
        // nspasteboard.org, meaning "never record this". Skip them so e.g. a vault's ID scan or 2FA QR code
        // never lands in the deck or on disk. Applies even with Smart Filter off.
        if types.contains(where: { Self.secretMarkerTypes.contains($0.rawValue) }) {
            lastProcessedChangeCount = changeCount
            return true
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

        // 4-7. Raw image data, in priority order: PNG, JPEG, TIFF (stored as PNG), WebP, GIF
        for (types, ext) in Self.rawImageFlavors {
            for t in types {
                guard var data = pasteboard.data(forType: t), !data.isEmpty else { continue }
                if ext == "tiff" {
                    guard let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else { continue }
                    data = png
                }
                if let item = queueManager.add(imageData: data, extension: ext == "tiff" ? "png" : ext) {
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
