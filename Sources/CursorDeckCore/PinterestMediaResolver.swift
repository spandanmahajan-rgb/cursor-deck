import Foundation

public enum PinterestMediaResult {
    case video(URL)
    case image(URL)
}

/// Resolves Pinterest pin links (including pin.it short links) to high-resolution media streams.
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

    /// Resolves a Pinterest link to direct media (video MP4 or high-res image).
    public func resolveMedia(from urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle pin.it redirect
        if trimmed.contains("pin.it/") {
            guard let url = URL(string: trimmed) else {
                completion(nil)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: req) { [weak self] _, response, _ in
                if let finalURL = response?.url?.absoluteString {
                    self?.extractFromCanonicalPinURL(finalURL, completion: completion)
                } else {
                    // Fallback to GET if HEAD failed
                    self?.extractFromCanonicalPinURL(trimmed, completion: completion)
                }
            }.resume()
        } else {
            extractFromCanonicalPinURL(trimmed, completion: completion)
        }
    }

    private func extractFromCanonicalPinURL(_ urlString: String, completion: @escaping (PinterestMediaResult?) -> Void) {
        let pinIdRegex = try? NSRegularExpression(pattern: #"(?:/pin/(?:[\w-]+--)?|id=)(\d+)"#, options: [])
        let nsString = urlString as NSString
        let match = pinIdRegex?.firstMatch(in: urlString, range: NSRange(location: 0, length: nsString.length))

        guard let range = match?.range(at: 1), range.location != NSNotFound else {
            completion(nil)
            return
        }

        let pinId = nsString.substring(with: range)

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

        session.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resourceResponse = json["resource_response"] as? [String: Any],
                  let pinData = resourceResponse["data"] as? [String: Any] else {
                completion(nil)
                return
            }

            // 1. Check for Video
            if let videos = pinData["videos"] as? [String: Any],
               let videoList = videos["video_list"] as? [String: Any] {
                // Priority order: 720p, 480p, exp7, any other mp4
                for key in ["V_720P", "V_EXP7", "V_480P", "V_EXP6"] {
                    if let vInfo = videoList[key] as? [String: Any],
                       let u = vInfo["url"] as? String, u.hasSuffix(".mp4"),
                       let videoURL = URL(string: u) {
                        completion(.video(videoURL))
                        return
                    }
                }
                for (_, val) in videoList {
                    if let vInfo = val as? [String: Any],
                       let u = vInfo["url"] as? String, u.hasSuffix(".mp4"),
                       let videoURL = URL(string: u) {
                        completion(.video(videoURL))
                        return
                    }
                }
            }

            // 2. Check story pin video blocks
            if let story = pinData["story_pin_data"] as? [String: Any],
               let pages = story["pages"] as? [[String: Any]] {
                for page in pages {
                    if let blocks = page["blocks"] as? [[String: Any]] {
                        for block in blocks {
                            if let video = block["video"] as? [String: Any],
                               let videoList = video["video_list"] as? [String: Any] {
                                for (_, val) in videoList {
                                    if let vInfo = val as? [String: Any],
                                       let u = vInfo["url"] as? String, u.hasSuffix(".mp4"),
                                       let videoURL = URL(string: u) {
                                        completion(.video(videoURL))
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 3. Fallback: High-resolution Image
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
        }.resume()
    }
}
