# CursorDeck — Comprehensive Code Review & Optimization Audit (v1.1.1)

> **Instructions for Claude**:
> Please review this macOS Swift codebase for **bugs, concurrency race conditions, memory leaks, performance bottlenecks, and slide compatibility**. Provide concrete, actionable fixes and code improvements.

---

## 1. Project Context & Architecture

**CursorDeck** is a lightweight, zero-latency macOS menu-bar utility written in Swift and AppKit. It turns the cursor into an image and video collection "deck":
1. **Accumulation**: Users copy images (screenshots, browser images, Figma frames) or Pinterest video links / local video files (`.mp4`, `.mov`).
2. **Dynamic HUD**: A translucent floating capsule pill ("Liquid Glass") tracks the cursor in real-time, displaying the count of accumulated items.
3. **Slide-Friendly GIF Conversion**: Pinterest video links and local video files are automatically transcoded into lightweight, slide-optimized looping GIFs (500px, 14 FPS, ≤4.0s, infinite loop, ~1.5–2.5MB) using native `AVFoundation` + `VideoToolbox` + `ImageIO`.
4. **Drag & Drop**: Users drag the pill onto Google Slides, Keynote, Figma, Miro, or Notion to deposit all collected items at once.
5. **Interactive Preview**: Clicking the pill fluidly morphs it into an in-place grid preview panel allowing reordering, single-item deletion, and drag-and-drop.
6. **Shake-to-Clear**: Rapidly shaking the cursor triggers a puff particle animation that clears the entire deck.

---

## 2. Key Areas to Audit

Please examine the following critical areas:
1. **Pinterest Video Link Scraping & Stream Resolution (`PinterestMediaResolver.swift`)**:
   - URL parsing & regex across canonical URLs, localized domains (`in.pinterest.com`), slug variations, and `pin.it` redirects.
   - Pinterest API JSON traversal (`videos.video_list`, `story_pin_data`, `embed`, etc.).
   - CDN MP4 derivation vs HLS stream fallback.
   - Any cases where network failures or edge-case response payloads could cause silent drops, hangs, or unexpected fallbacks.
2. **Video-to-GIF Transcoding & Memory Leaks (`VideoToGIFConverter.swift`)**:
   - `AVAssetImageGenerator` time-step sampling vs `AVPlayerItemVideoOutput` + `VTCreateCGImageFromCVPixelBuffer` streaming.
   - Memory management: Are `CVPixelBuffer`, `CGImage`, or `NSMutableData` buffers leaking during loop execution?
   - Timer invalidation and thread safety between the main runloop and `conversionQueue`.
3. **Clipboard Polling & Race Conditions (`ClipboardWatcher.swift`)**:
   - Polling frequency (80ms) and asynchronous retry mechanism for Electron / browser pasteboard latency.
   - Self-capture loop prevention (`com.cursordeck.internal-marker`).
   - Paused state handling (`isPaused`) ensuring no background network or disk tasks add items after pause.
4. **Drag-and-Drop & Pasteboard Types (`DeckDragItemWriter.swift` & `PasteboardWriter.swift`)**:
   - Pasteboard flavors registered (`public.file-url`, `NSFilenamesPboardType`, `com.compuserve.gif`, `public.png`, `public.tiff`).
   - Compatibility across web presentation tools (Google Slides, Figma in browser) vs native desktop apps (Keynote, Photoshop).
5. **HUD Panel & Preview Grid (`CursorHUDPanel.swift`, `DeckHUDView.swift`, `DeckPreviewPanel.swift`)**:
   - Cursor tracking loop latency and window positioning near screen edges.
   - Retain cycles with delegates or observer closures (`[weak self]`).
   - Expansion animation smoothness from pill to preview deck.

---

## 3. Core Source Code Files

### File 1: `Sources/CursorDeckCore/PinterestMediaResolver.swift`
```swift
import Foundation

public enum PinterestMediaResult {
    case video(URL)
    case image(URL)
}

/// Resolves Pinterest pin links (including pin.it short links and localized URLs)
/// to direct high-resolution video streams (MP4/HLS) or fallback images.
public final class PinterestMediaResolver {
    public static let shared = PinterestMediaResolver()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        self.session = URLSession(configuration: config)
    }

    /// Checks if a string contains or is a Pinterest pin URL.
    public func isPinterestURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("pin.it/") { return true }
        if trimmed.contains("pinterest.") && (trimmed.contains("/pin/") || trimmed.contains("id=")) { return true }
        return false
    }

    /// Extracts the numeric Pin ID from any canonical, slugged, or query-based Pinterest URL.
    public func extractPinId(from urlString: String) -> String? {
        let pinIdRegex = try? NSRegularExpression(pattern: #"(?:/pin/(?:.*?[-/])?|id=)(\d{6,})"#, options: [])
        let nsString = urlString as NSString
        let match = pinIdRegex?.firstMatch(in: urlString, range: NSRange(location: 0, length: nsString.length))

        guard let range = match?.range(at: 1), range.location != NSNotFound else {
            return nil
        }
        return nsString.substring(with: range)
    }

    /// Resolves a Pinterest link to direct media (video MP4/HLS or high-res image).
    public func resolveMedia(from urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle pin.it redirect
        if trimmed.contains("pin.it/") {
            guard let url = URL(string: trimmed) else {
                completion(nil)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: req) { [weak self] _, response, _ in
                if let finalURL = response?.url?.absoluteString {
                    self?.extractFromCanonicalPinURL(finalURL, completion: completion)
                } else {
                    self?.extractFromCanonicalPinURL(trimmed, completion: completion)
                }
            }.resume()
        } else {
            extractFromCanonicalPinURL(trimmed, completion: completion)
        }
    }

    private func extractFromCanonicalPinURL(_ urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        guard let pinId = extractPinId(from: urlString) else {
            completion(nil)
            return
        }

        var components = URLComponents(string: "https://www.pinterest.com/resource/PinResource/get/")!
        let dataDict: [String: Any] = [
            "options": [
                "id": pinId,
                "field_set_key": "unauth_react_main_pin"
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dataDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(nil)
            return
        }

        components.queryItems = [URLQueryItem(name: "data", value: jsonString)]

        guard let requestURL = components.url else {
            completion(nil)
            return
        }

        var request = URLRequest(url: requestURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("www/[username].js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resourceResponse = json["resource_response"] as? [String: Any],
                  let pinData = resourceResponse["data"] as? [String: Any] else {
                completion(nil)
                return
            }

            self.processPinData(pinData, pinId: pinId, completion: completion)
        }.resume()
    }

    private func processPinData(_ pinData: [String: Any], pinId: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        var videoStreams: [String] = []

        // 1. Direct videos dict
        if let videos = pinData["videos"] as? [String: Any],
           let videoList = videos["video_list"] as? [String: Any] {
            // Prioritize high-quality MP4s
            for key in ["V_720P", "V_EXP7", "V_480P", "V_EXP6", "V_EXP5", "V_EXP4", "V_EXP3"] {
                if let vInfo = videoList[key] as? [String: Any],
                   let u = vInfo["url"] as? String, !u.isEmpty {
                    videoStreams.append(u)
                }
            }
            // Add remaining formats (e.g. HLS)
            for (_, val) in videoList {
                if let vInfo = val as? [String: Any],
                   let u = vInfo["url"] as? String, !u.isEmpty, !videoStreams.contains(u) {
                    videoStreams.append(u)
                }
            }
        }

        // 2. Story / Idea Pin pages & blocks
        if let story = pinData["story_pin_data"] as? [String: Any],
           let pages = story["pages"] as? [[String: Any]] {
            for page in pages {
                if let blocks = page["blocks"] as? [[String: Any]] {
                    for block in blocks {
                        if let video = block["video"] as? [String: Any],
                           let videoList = video["video_list"] as? [String: Any] {
                            for key in ["V_720P", "V_EXP7", "V_480P", "V_EXP6", "V_EXP5", "V_EXP4", "V_EXP3"] {
                                if let vInfo = videoList[key] as? [String: Any],
                                   let u = vInfo["url"] as? String, !u.isEmpty {
                                    videoStreams.append(u)
                                }
                            }
                            for (_, val) in videoList {
                                if let vInfo = val as? [String: Any],
                                   let u = vInfo["url"] as? String, !u.isEmpty, !videoStreams.contains(u) {
                                    videoStreams.append(u)
                                }
                            }
                        }
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
                    for (_, val) in videoList {
                        if let vInfo = val as? [String: Any],
                           let u = vInfo["url"] as? String, !u.isEmpty, !videoStreams.contains(u) {
                            videoStreams.append(u)
                        }
                    }
                }
            }
        }

        // 4. Embed src
        if let embed = pinData["embed"] as? [String: Any],
           let src = embed["src"] as? String, !src.isEmpty {
            videoStreams.append(src)
        }

        let isVideoPin = (pinData["is_video"] as? Bool == true) ||
                         (pinData["is_playable"] as? Bool == true) ||
                         !videoStreams.isEmpty

        // If we found video stream candidates:
        if !videoStreams.isEmpty {
            resolveBestVideoStream(from: videoStreams) { resolvedURL in
                if let resolvedURL = resolvedURL {
                    completion(.video(resolvedURL))
                } else if !isVideoPin {
                    // Fallback to image only if it is not explicitly a video pin
                    self.fallbackToImage(pinData: pinData, completion: completion)
                } else {
                    completion(nil)
                }
            }
            return
        }

        // If marked as video but no streams in PinResource, scrape the HTML for video URLs
        if isVideoPin {
            scrapeHTMLForVideo(pinId: pinId) { scrapedURL in
                if let scrapedURL = scrapedURL {
                    completion(.video(scrapedURL))
                } else {
                    completion(nil)
                }
            }
            return
        }

        // Fallback: Pure image pin
        fallbackToImage(pinData: pinData, completion: completion)
    }

    /// Resolves direct MP4 or checks CDN candidates for HLS streams.
    private func resolveBestVideoStream(from streams: [String], completion: @escaping (URL?) -> Void) {
        // 1. Direct MP4
        for stream in streams {
            if stream.contains(".mp4") {
                if let u = URL(string: stream) {
                    completion(u)
                    return
                }
            }
        }

        // 2. Derive MP4 from .m3u8 stream on Pinterest CloudFront CDN
        for stream in streams {
            if stream.contains(".m3u8") {
                let candidates = generateMP4Candidates(from: stream)
                checkFirstAvailableURL(candidates: candidates) { validURL in
                    if let validURL = validURL {
                        completion(validURL)
                    } else if let hlsURL = URL(string: stream) {
                        // Fall back to the raw HLS stream URL for native streaming conversion
                        completion(hlsURL)
                    } else {
                        completion(nil)
                    }
                }
                return
            }
        }

        if let first = streams.first, let u = URL(string: first) {
            completion(u)
        } else {
            completion(nil)
        }
    }

    private func generateMP4Candidates(from m3u8URL: String) -> [String] {
        var candidates: [String] = []

        // Pattern 1: /hls/ -> /720p/
        let c1 = m3u8URL
            .replacingOccurrences(of: "/hls/", with: "/720p/")
            .replacingOccurrences(of: "_mobile.m3u8", with: ".mp4")
            .replacingOccurrences(of: ".m3u8", with: ".mp4")
        candidates.append(c1)

        // Pattern 2: /v2/hls/ -> /720p/
        let c2 = m3u8URL
            .replacingOccurrences(of: "/v2/hls/", with: "/720p/")
            .replacingOccurrences(of: "_mobile.m3u8", with: ".mp4")
            .replacingOccurrences(of: ".m3u8", with: ".mp4")
        if c2 != c1 { candidates.append(c2) }

        // Pattern 3: /hls/ -> /expMp4/ ... _t1.mp4
        let c3 = m3u8URL
            .replacingOccurrences(of: "/hls/", with: "/expMp4/")
            .replacingOccurrences(of: "_mobile.m3u8", with: "_t1.mp4")
            .replacingOccurrences(of: ".m3u8", with: "_t1.mp4")
        candidates.append(c3)

        return candidates
    }

    private func checkFirstAvailableURL(candidates: [String], completion: @escaping (URL?) -> Void) {
        guard let first = candidates.first, let url = URL(string: first) else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 3.0

        session.dataTask(with: req) { [weak self] _, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                completion(url)
            } else {
                let remaining = Array(candidates.dropFirst())
                if remaining.isEmpty {
                    completion(nil)
                } else {
                    self?.checkFirstAvailableURL(candidates: remaining, completion: completion)
                }
            }
        }.resume()
    }

    private func scrapeHTMLForVideo(pinId: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: "https://www.pinterest.com/pin/\(pinId)/") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }

            // Search for direct mp4 links in HTML or embedded __PWS_DATA__
            let pattern = #"https://[^"'\s]*v1\.pinimg\.com/videos/[^"'\s]*\.(?:mp4|m3u8)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = html as NSString
                let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
                var foundStreams: [String] = []
                for m in matches {
                    let s = ns.substring(with: m.range)
                    if !foundStreams.contains(s) { foundStreams.append(s) }
                }
                if !foundStreams.isEmpty {
                    self.resolveBestVideoStream(from: foundStreams, completion: completion)
                    return
                }
            }

            completion(nil)
        }.resume()
    }

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

### File 2: `Sources/CursorDeckCore/VideoToGIFConverter.swift`
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

    private let conversionQueue = DispatchQueue(label: "com.cursordeck.gifconverter", qos: .utility)

    public init() {}

    /// Converts a local video file (MP4, MOV, WEBM) into an animated GIF Data in the background.
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

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let frameDuration = 1.0 / fps
            let times: [NSValue] = (0..<totalFrames).map { i in
                let time = CMTime(seconds: Double(i) * frameDuration, preferredTimescale: 600)
                return NSValue(time: time)
            }

            var frames: [CGImage] = []
            for val in times {
                let time = val.timeValue
                if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                    frames.append(image)
                }
            }

            guard !frames.isEmpty,
                  let finalData = self.encodeImagesToGIF(frames: frames, fps: fps, maxWidth: maxWidth) else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            DispatchQueue.main.async {
                completion(finalData, finalData.count)
            }
        }
    }

    /// Converts an HLS (.m3u8) video stream into an animated GIF Data.
    public func convertHLS(
        streamURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player.rate = 1.0

        let frameInterval = 1.0 / fps
        let targetFrameCount = max(1, Int(maxDuration * fps))
        var frames: [CGImage] = []
        var tickCount = 0

        let timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] t in
            tickCount += 1
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time) {
                if let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    var cgImg: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(buf, options: nil, imageOut: &cgImg)
                    if let img = cgImg {
                        frames.append(img)
                    }
                }
            }

            if frames.count >= targetFrameCount || tickCount > Int(maxDuration * fps * 2.5) {
                t.invalidate()
                player.pause()

                guard let self = self, !frames.isEmpty else {
                    completion(nil, 0)
                    return
                }

                self.conversionQueue.async {
                    let gifData = self.encodeImagesToGIF(frames: frames, fps: fps, maxWidth: maxWidth)
                    DispatchQueue.main.async {
                        completion(gifData, gifData?.count ?? 0)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Assembles an array of CGImage frames into a slide-friendly looping GIF Data.
    private func encodeImagesToGIF(frames: [CGImage], fps: Double, maxWidth: CGFloat) -> Data? {
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

        let frameDuration = 1.0 / fps
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDuration
            ]
        ]

        for frame in frames {
            let finalImage: CGImage
            if CGFloat(frame.width) > maxWidth || CGFloat(frame.height) > maxWidth {
                let aspect = CGFloat(frame.width) / CGFloat(frame.height)
                let w = aspect >= 1.0 ? maxWidth : maxWidth * aspect
                let h = aspect >= 1.0 ? maxWidth / aspect : maxWidth
                if let ctx = CGContext(
                    data: nil,
                    width: Int(w),
                    height: Int(h),
                    bitsPerComponent: frame.bitsPerComponent,
                    bytesPerRow: 0,
                    space: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: frame.bitmapInfo.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                    finalImage = ctx.makeImage() ?? frame
                } else {
                    finalImage = frame
                }
            } else {
                finalImage = frame
            }

            CGImageDestinationAddImage(destination, finalImage, frameProperties as CFDictionary)
        }

        let success = CGImageDestinationFinalize(destination)
        return (success && gifData.length > 0) ? (gifData as Data) : nil
    }
}
```

---

### File 3: `Sources/CursorDeckCore/ClipboardWatcher.swift`
```swift
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
        let currentCount = pasteboard.changeCount
        guard currentCount != lastProcessedChangeCount else { return }

        guard !isPaused else {
            lastProcessedChangeCount = currentCount
            return
        }

        if extractAndCaptureImage(for: currentCount) {
            return
        }

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
                    self.lastProcessedChangeCount = currentCount
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
                if supportedImageExtensions.contains(ext) && !url.path.contains("cursor-deck") {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                } else if supportedVideoExtensions.contains(ext) && !url.path.contains("cursor-deck") {
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
                if supportedImageExtensions.contains(ext) && !url.path.contains("cursor-deck") {
                    if let item = queueManager.add(existingFileURL: url) {
                        delegate?.clipboardWatcher(self, didCaptureItem: item)
                        captured = true
                    }
                } else if supportedVideoExtensions.contains(ext) && !url.path.contains("cursor-deck") {
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

    private func handlePinterestURL(_ urlString: String) {
        PinterestMediaResolver.shared.resolveMedia(from: urlString) { [weak self] result in
            guard let self = self, !self.isPaused, let result = result else { return }
            switch result {
            case .video(let videoRemoteURL):
                self.downloadAndConvertVideo(videoRemoteURL)
            case .image(let imageRemoteURL):
                self.downloadAndAddImage(imageRemoteURL)
            }
        }
    }

    private func handleLocalVideoFile(_ url: URL) {
        VideoToGIFConverter.shared.convert(videoURL: url) { [weak self] gifData, _ in
            guard let self = self, !self.isPaused, let gifData = gifData else { return }
            DispatchQueue.main.async {
                if let item = self.queueManager.add(imageData: gifData, extension: "gif") {
                    self.delegate?.clipboardWatcher(self, didCaptureItem: item)
                }
            }
        }
    }

    private func downloadAndConvertVideo(_ remoteURL: URL) {
        if remoteURL.pathExtension.lowercased() == "m3u8" || remoteURL.absoluteString.contains(".m3u8") {
            VideoToGIFConverter.shared.convertHLS(streamURL: remoteURL) { [weak self] gifData, _ in
                guard let self = self, !self.isPaused, let gifData = gifData else { return }
                DispatchQueue.main.async {
                    if let item = self.queueManager.add(imageData: gifData, extension: "gif") {
                        self.delegate?.clipboardWatcher(self, didCaptureItem: item)
                    }
                }
            }
            return
        }

        let task = URLSession.shared.downloadTask(with: remoteURL) { [weak self] tempURL, _, error in
            guard let self = self, !self.isPaused, let tempURL = tempURL, error == nil else { return }

            let tempDir = FileManager.default.temporaryDirectory
            let localVideoURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try FileManager.default.moveItem(at: tempURL, to: localVideoURL)
            } catch {
                return
            }

            VideoToGIFConverter.shared.convert(videoURL: localVideoURL) { [weak self] gifData, _ in
                try? FileManager.default.removeItem(at: localVideoURL)
                guard let self = self, !self.isPaused, let gifData = gifData else { return }
                DispatchQueue.main.async {
                    if let item = self.queueManager.add(imageData: gifData, extension: "gif") {
                        self.delegate?.clipboardWatcher(self, didCaptureItem: item)
                    }
                }
            }
        }
        task.resume()
    }

    private func downloadAndAddImage(_ remoteURL: URL) {
        let task = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, _, error in
            guard let self = self, !self.isPaused, let data = data, error == nil, !data.isEmpty else { return }
            let ext = remoteURL.pathExtension.lowercased().isEmpty ? "jpg" : remoteURL.pathExtension.lowercased()
            DispatchQueue.main.async {
                if let item = self.queueManager.add(imageData: data, extension: ext) {
                    self.delegate?.clipboardWatcher(self, didCaptureItem: item)
                }
            }
        }
        task.resume()
    }
}
```

---

### File 4: `Sources/CursorDeckCore/DeckDragItemWriter.swift`
```swift
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Universal drag item writer providing matching flavors for Finder, Slides, Keynote, and Figma.
public final class DeckDragItemWriter: NSObject, NSPasteboardWriting {
    public let fileURL: URL
    private let cachedPNGData: Data?
    private let cachedGIFData: Data?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let ext = fileURL.pathExtension.lowercased()
        if ext == "gif" {
            self.cachedGIFData = try? Data(contentsOf: fileURL)
            self.cachedPNGData = nil
        } else {
            self.cachedGIFData = nil
            if let img = NSImage(contentsOf: fileURL),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                self.cachedPNGData = rep.representation(using: .png, properties: [:])
            } else {
                self.cachedPNGData = try? Data(contentsOf: fileURL)
            }
        }
        super.init()
    }

    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .init(rawValue: "NSFilenamesPboardType")
        ]
        if fileURL.pathExtension.lowercased() == "gif" {
            types.append(.init(rawValue: "com.compuserve.gif"))
            types.append(.init(rawValue: "image/gif"))
        }
        types.append(.png)
        types.append(.tiff)
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

        case .init(rawValue: "NSFilenamesPboardType"):
            return [fileURL.path]

        case .init(rawValue: "com.compuserve.gif"), .init(rawValue: "image/gif"):
            return cachedGIFData

        case .png:
            return cachedPNGData

        case .tiff:
            return NSImage(contentsOf: fileURL)?.tiffRepresentation

        default:
            return nil
        }
    }
}
```

---

### File 5: `Sources/CursorDeckCore/PasteboardWriter.swift`
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
            if ext == "png" {
                pbItem.setData(data, forType: .png)
            } else if ext == "jpg" || ext == "jpeg" {
                pbItem.setData(data, forType: .init("public.jpeg"))
            } else if ext == "gif" {
                pbItem.setData(data, forType: .init("com.compuserve.gif"))
                pbItem.setData(data, forType: .init("image/gif"))
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

    public func simulatePasteEvent() {
        let vKeyCode: CGKeyCode = 9 // Virtual key code for 'V'
        
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
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

### File 6: `Sources/CursorDeckCore/DeckQueueManager.swift`
```swift
import Foundation
import AppKit

public final class DeckQueueManager {
    private var items: [DeckItem] = []
    private let queue = DispatchQueue(label: "com.cursordeck.queuemanager", attributes: .concurrent)
    private var observers: [(Int) -> Void] = []
    private let tempDirectory: URL

    public var count: Int {
        return queue.sync { items.count }
    }

    public var isEmpty: Bool {
        return queue.sync { items.isEmpty }
    }

    public init(customTempDirectory: URL? = nil) {
        if let dir = customTempDirectory {
            self.tempDirectory = dir
        } else {
            let fileManager = FileManager.default
            let baseDir = fileManager.temporaryDirectory.appendingPathComponent("cursor-deck", isDirectory: true)
            try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
            self.tempDirectory = baseDir
        }
    }

    public func add(imageData: Data, extension fileExtension: String = "png") -> DeckItem? {
        let id = UUID()
        let filename = "\(id.uuidString).\(fileExtension)"
        let fileURL = tempDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: fileURL)
            let item = DeckItem(id: id, fileURL: fileURL, timestamp: Date())
            
            queue.async(flags: .barrier) {
                self.items.append(item)
            }
            
            notifyObservers()
            return item
        } catch {
            return nil
        }
    }

    public func add(existingFileURL: URL) -> DeckItem? {
        let id = UUID()
        let ext = existingFileURL.pathExtension
        let filename = "\(id.uuidString).\(ext)"
        let fileURL = tempDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: existingFileURL, to: fileURL)
            let item = DeckItem(id: id, fileURL: fileURL, timestamp: Date())
            
            queue.async(flags: .barrier) {
                self.items.append(item)
            }
            
            notifyObservers()
            return item
        } catch {
            return nil
        }
    }

    public func remove(byId id: UUID) {
        var removedItem: DeckItem?
        queue.async(flags: .barrier) {
            if let index = self.items.firstIndex(where: { $0.id == id }) {
                removedItem = self.items.remove(at: index)
            }
        }
        if let item = removedItem {
            try? FileManager.default.removeItem(at: item.fileURL)
            notifyObservers()
        }
    }

    public func clear() {
        var itemsToRemove: [DeckItem] = []
        queue.async(flags: .barrier) {
            itemsToRemove = self.items
            self.items.removeAll()
        }

        for item in itemsToRemove {
            try? FileManager.default.removeItem(at: item.fileURL)
        }

        notifyObservers()
    }

    public func allItems() -> [DeckItem] {
        return queue.sync { items }
    }

    public func addObserver(_ observer: @escaping (Int) -> Void) {
        observers.append(observer)
    }

    private func notifyObservers() {
        let currentCount = self.count
        DispatchQueue.main.async {
            for observer in self.observers {
                observer(currentCount)
            }
        }
    }

    public func cleanup() {
        clear()
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
```

---

## 4. Specific Audit Questions for Claude

1. **Memory & Lifecycle**:
   - In `VideoToGIFConverter.convertHLS`, `AVPlayer`, `AVPlayerItem`, and `AVPlayerItemVideoOutput` are instantiated per stream. Are all audio/video buffers properly deallocated after `t.invalidate()` and `player.pause()`?
   - In `ClipboardWatcher.downloadAndConvertVideo`, `URLSession.shared.downloadTask` moves to a temporary UUID file and removes it on completion. Are there edge cases where failed conversion leaves orphaned `.mp4` files in `/tmp`?
2. **Pinterest Scraping Robustness**:
   - Are there any edge cases with `PinterestMediaResolver.extractPinId` where non-pin Pinterest URLs (e.g., boards, search queries, profiles) might trigger unwanted extraction or infinite loops?
   - In `checkFirstAvailableURL`, candidates are checked recursively. Does it properly handle DNS failures or CloudFront timeouts without blocking the calling thread?
3. **AppKit Drag & Drop Reliability**:
   - When dropping onto Google Slides or Keynote, does `DeckDragItemWriter` provide all expected representations? Is `cachedPNGData` properly initialized for non-GIF images without blocking the main runloop?
4. **Swift Concurrency & Thread Safety**:
   - In `DeckQueueManager`, `queue.async(flags: .barrier)` is used with `queue.sync`. In `remove(byId:)`, `removedItem` is set inside `queue.async(flags: .barrier)` but checked outside it — is this an asynchronous race condition?
   - Are there any main-thread UI violations when calling `delegate?.clipboardWatcher`?

---

*Generated from CursorDeck v1.1.1 codebase.*
