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
