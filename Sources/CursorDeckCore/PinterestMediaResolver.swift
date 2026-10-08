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
                    // Could not locate video stream
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
