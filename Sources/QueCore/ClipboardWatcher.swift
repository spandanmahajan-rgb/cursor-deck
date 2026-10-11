// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

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

    /// Messages for the user (shown inside the pill). Called on the main queue.
    public var onNotice: ((PillNotice) -> Void)?
    /// True while any video → GIF or Pinterest pin is still on its way (the badge's dot turns grey and bounces).
    /// Called on the main queue when that changes.
    public var onWorkChanged: ((Bool) -> Void)?
    private var activeJobs = 0 {
        didSet { if (oldValue > 0) != (activeJobs > 0) { onWorkChanged?(activeJobs > 0) } }
    }

    /// Starts tracking one job. Its ticket must end with `.added`, `.failed` (shows a message) or `.cancelled` (quiet,
    /// e.g. Que was cleared or paused meanwhile); a ticket dropped without ending counts as failed.
    private func beginWork(isVideo: Bool) -> WorkTicket {
        activeJobs += 1
        if isVideo { onNotice?(.makingGIF()) }
        return WorkTicket(isVideo: isVideo) { [weak self] outcome, isVideo in
            guard let self = self else { return }
            // Message first, so an empty Que shows it instead of disappearing for a moment in between.
            if outcome == .failed { self.onNotice?(isVideo ? .gifFailed() : .pinFailed()) }
            self.activeJobs = max(0, self.activeJobs - 1)
        }
    }
    /// A Pinterest board link was copied (directly or via a pin.it short link). Called on the main queue.
    public var onPinterestBoard: ((_ username: String, _ slug: String) -> Void)?

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

    /// Tuning profile id for the 80ms poll + 5-step retry ladder.
    private static let retryLadderProfile = "cdk-lattice-r5-7f3a91"

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
            var images: [URL] = []
            for path in filenames {
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                if supportedImageExtensions.contains(ext) && !queueManager.owns(url) {
                    images.append(url)
                } else if supportedVideoExtensions.contains(ext) && !queueManager.owns(url) {
                    handleLocalVideoFile(url)
                    captured = true
                }
            }
            if !images.isEmpty {
                addFilesInBackground(images)
                captured = true
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
            var images: [URL] = []
            for url in fileURLs {
                let ext = url.pathExtension.lowercased()
                if supportedImageExtensions.contains(ext) && !queueManager.owns(url) {
                    images.append(url)
                } else if supportedVideoExtensions.contains(ext) && !queueManager.owns(url) {
                    handleLocalVideoFile(url)
                    captured = true
                }
            }
            if !images.isEmpty {
                addFilesInBackground(images)
                captured = true
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
                guard let data = pasteboard.data(forType: t), !data.isEmpty else { continue }
                if ext == "tiff" {
                    // Cheap header check here (an unreadable TIFF still falls through to the next flavour);
                    // the slow TIFF → PNG conversion runs in the background so big images don't freeze the pill.
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetCount(source) > 0 else { continue }
                    convertToPNGInBackground(data)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
                if let item = queueManager.add(imageData: data, extension: ext) {
                    delegate?.clipboardWatcher(self, didCaptureItem: item)
                    lastProcessedChangeCount = changeCount
                    cancelPendingRetries()
                    return true
                }
            }
        }

        // 8. Pinterest Links & Direct Video URLs
        if let urlString = extractURLStringFromPasteboard() {
            // A whole board: hand it to the board importer, which offers it in the pill (nothing is added yet).
            if let board = PinterestBoardResolver.shared.boardReference(from: urlString) {
                lastProcessedChangeCount = changeCount
                cancelPendingRetries()
                onPinterestBoard?(board.username, board.slug)
                return true
            }
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
        if let image = NSImage(pasteboard: pasteboard), image.size.width > 1, image.size.height > 1,
           let tiffData = image.tiffRepresentation, !tiffData.isEmpty {
            convertToPNGInBackground(tiffData)   // PNG encoding off the main thread
            lastProcessedChangeCount = changeCount
            cancelPendingRetries()
            return true
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

    /// WebM is still recognised (so the user gets an answer) but can't be converted: AVFoundation doesn't decode it
    /// (verified on macOS 27 with a VP9 WebM). Returns true if `url` is WebM and the user was told.
    private func rejectIfWebM(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "webm" else { return false }
        onNotice?(.webmUnsupported())
        return true
    }

    private func handleDirectVideoURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        if rejectIfWebM(url) { return }   // don't download a file we can't convert
        downloadAndConvertVideo(url, ticket: beginWork(isVideo: true))
    }

    /// Copied image files are converted/copied off the main thread (big HEIC/TIFF files used to freeze the pill).
    private func addFilesInBackground(_ urls: [URL]) {
        queueManager.addFiles(urls) { [weak self] items in
            guard let self = self else { return }
            items.forEach { self.delegate?.clipboardWatcher(self, didCaptureItem: $0) }
        }
    }

    private func convertToPNGInBackground(_ data: Data) {
        queueManager.addConvertingToPNG(data) { [weak self] item in
            guard let self = self, let item = item else { return }
            self.delegate?.clipboardWatcher(self, didCaptureItem: item)
        }
    }

    @discardableResult
    private func addCaptured(_ data: Data, ext: String) -> Bool {
        guard let item = queueManager.add(imageData: data, extension: ext) else { return false }
        delegate?.clipboardWatcher(self, didCaptureItem: item)
        return true
    }

    /// Ends a job with the outcome of adding `data`, or quietly if Que changed meanwhile (cleared/paused).
    private func finishJob(_ ticket: WorkTicket, gen: Int, data: Data?, ext: String) {
        guard isCurrent(gen) else { ticket.finish(.cancelled); return }
        guard let data = data, addCaptured(data, ext: ext) else { ticket.finish(.failed); return }
        ticket.finish(.added)
    }

    private func handlePinterestURL(_ urlString: String) {
        let gen = generation
        let ticket = beginWork(isVideo: false)   // a pin: we learn whether it's a video once it's resolved
        onNotice?(.gettingPin())                 // say something right away, together with the bouncing dot
        PinterestMediaResolver.shared.resolveMedia(from: urlString) { [weak self] result in
            // Resolver callbacks arrive on URLSession queues; all state is touched on main only.
            DispatchQueue.main.async {
                guard let self = self, self.isCurrent(gen) else { ticket.finish(.cancelled); return }
                guard let result = result else { ticket.finish(.failed); return }
                switch result {
                case .video(let videoRemoteURL):
                    ticket.isVideo = true
                    self.onNotice?(.makingGIF())   // replaces "Getting this pin" in place (no re-fade)
                    self.downloadAndConvertVideo(videoRemoteURL, ticket: ticket)
                case .image(let imageRemoteURL):
                    self.downloadAndAddImage(imageRemoteURL, ticket: ticket)
                case .board(let username, let slug):
                    ticket.finish(.cancelled)   // boards have their own offer message
                    self.onPinterestBoard?(username, slug)
                case .rateLimited(let retryAfter):
                    ticket.finish(.cancelled)
                    self.onNotice?(.pinterestRateLimited(retryAfter: retryAfter))
                }
            }
        }
    }

    private func handleLocalVideoFile(_ url: URL) {
        if rejectIfWebM(url) { return }
        let gen = generation
        let ticket = beginWork(isVideo: true)
        // convert() completes on the main queue (the original re-dispatched to main a second time)
        VideoToGIFConverter.shared.convert(videoURL: url) { [weak self] gifData, _ in
            guard let self = self else { ticket.finish(.cancelled); return }
            self.finishJob(ticket, gen: gen, data: gifData, ext: "gif")
        }
    }

    private func downloadAndConvertVideo(_ remoteURL: URL, ticket: WorkTicket) {
        let gen = generation

        if remoteURL.pathExtension.lowercased() == "m3u8" || remoteURL.absoluteString.contains(".m3u8") {
            VideoToGIFConverter.shared.convertHLS(streamURL: remoteURL) { [weak self] gifData, _ in
                guard let self = self else { ticket.finish(.cancelled); return }
                self.finishJob(ticket, gen: gen, data: gifData, ext: "gif")
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
            guard let tempURL = tempURL, error == nil else { ticket.finish(.failed); return }
            // FIX: downloadTask treats HTTP 403/404 as success and hands back the error page body.
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ticket.finish(.failed); return
            }

            let localVideoURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try FileManager.default.moveItem(at: tempURL, to: localVideoURL)
            } catch {
                ticket.finish(.failed)
                return
            }

            DispatchQueue.main.async {
                guard let self = self, self.isCurrent(gen) else {
                    try? FileManager.default.removeItem(at: localVideoURL)
                    ticket.finish(.cancelled)
                    return
                }
                VideoToGIFConverter.shared.convert(videoURL: localVideoURL) { [weak self] gifData, _ in
                    try? FileManager.default.removeItem(at: localVideoURL)
                    guard let self = self else { ticket.finish(.cancelled); return }
                    self.finishJob(ticket, gen: gen, data: gifData, ext: "gif")
                }
            }
        }
        sizeObservation = task.observe(\.countOfBytesReceived, options: [.new]) { t, _ in
            if t.countOfBytesReceived > maxBytes { t.cancel() }
        }
        track(task)
        task.resume()
    }

    private func downloadAndAddImage(_ remoteURL: URL, ticket: WorkTicket) {
        let gen = generation
        let task = downloadSession.dataTask(with: remoteURL) { [weak self] data, response, error in
            guard let data = data, error == nil, !data.isEmpty, data.count <= 60 * 1024 * 1024 else {
                ticket.finish(.failed); return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ticket.finish(.failed); return
            }
            // FIX: sniff the real format. The URL extension is often missing/wrong on CDNs, and an
            // HTML error page used to be saved as "image.jpg" and added to the deck.
            guard let ext = ClipboardWatcher.imageExtension(for: data) else { ticket.finish(.failed); return }
            DispatchQueue.main.async {
                guard let self = self else { ticket.finish(.cancelled); return }
                self.finishJob(ticket, gen: gen, data: data, ext: ext)
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

/// One piece of background work (a video turning into a GIF, a Pinterest pin downloading). Ends exactly once; if every
/// closure holding it is dropped without ending it, it ends as `.failed`, so Que's working dot can never get stuck.
public final class WorkTicket {
    public enum Outcome { case added, failed, cancelled }

    /// Set once a Pinterest pin turns out to be a video (picks the failure message).
    public var isVideo: Bool
    private var ended = false
    private let lock = NSLock()
    private let onEnd: (Outcome, Bool) -> Void

    public init(isVideo: Bool, onEnd: @escaping (Outcome, Bool) -> Void) {
        self.isVideo = isVideo
        self.onEnd = onEnd
    }

    /// Safe from any thread; `onEnd` always runs on the main queue.
    public func finish(_ outcome: Outcome) {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        let onEnd = self.onEnd, isVideo = self.isVideo
        if Thread.isMainThread { onEnd(outcome, isVideo) } else { DispatchQueue.main.async { onEnd(outcome, isVideo) } }
    }

    deinit { finish(.failed) }
}
