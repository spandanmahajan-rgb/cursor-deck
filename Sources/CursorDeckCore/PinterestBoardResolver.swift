// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation

public struct PinterestBoard: Equatable {
    public let id: String
    public let name: String
    /// Pinterest's own count. Treat it as approximate: it includes hidden/removed pins
    /// (a board reporting 48 served 45 when tested).
    public let pinCount: Int
    public let username: String
    public let slug: String

    public init(id: String, name: String, pinCount: Int, username: String, slug: String) {
        self.id = id; self.name = name; self.pinCount = pinCount; self.username = username; self.slug = slug
    }
}

public struct PinterestBoardPin: Identifiable, Hashable {
    public let id: String
    public let title: String?
    /// ~236px wide, for the picker grid.
    public let thumbnailURL: URL
    /// Full-size image (also the still frame for video pins).
    public let imageURL: URL
    /// Direct MP4 for video pins; becomes a looping GIF when added.
    public let videoURL: URL?
    /// Hex colour Pinterest computes for the image; used as the placeholder while thumbnails load.
    public let dominantColor: String?
    public var isVideo: Bool { videoURL != nil }

    public init(id: String, title: String?, thumbnailURL: URL, imageURL: URL, videoURL: URL?, dominantColor: String?) {
        self.id = id; self.title = title; self.thumbnailURL = thumbnailURL; self.imageURL = imageURL
        self.videoURL = videoURL; self.dominantColor = dominantColor
    }
}

public enum PinterestError: Error, Equatable {
    /// HTTP 429. `retryAfter` (seconds) when Pinterest says how long to wait.
    case rateLimited(retryAfter: TimeInterval?)
    /// Secret or deleted board (logged-out requests can't tell the difference).
    case notFound
    case offline
    case unexpected
}

/// Reads public Pinterest boards through the same unofficial web endpoints CursorDeck already uses for pins.
/// They can change or rate-limit without notice, so every failure is reported as a specific `PinterestError`.
public final class PinterestBoardResolver {
    public static let shared = PinterestBoardResolver()

    private let session: URLSession
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    public static let pageSize = 25

    /// First path segments that are Pinterest pages, not usernames.
    private static let reservedRoots: Set<String> = [
        "pin", "pins", "search", "ideas", "today", "settings", "_", "business", "categories", "topics", "explore",
        "login", "signup", "about", "help", "shop", "news_hub", "edit", "following", "followers", "notifications",
        "resource", "videos", "homefeed", "board", "boards", "user", "password", "oauth", "privacy", "terms"
    ]
    /// Second path segments that are profile tabs, not boards.
    private static let reservedBoardSlugs: Set<String> = ["pins", "boards", "followers", "following", "more_ideas"]

    /// Each resolver has its own private, in-memory session: cookies live only as long as the resolver and are
    /// never written to disk. Use a new resolver per board link (BoardImportController does).
    ///
    /// Why: with a long-lived, saved Pinterest session (the default URLSession behaviour), Pinterest started
    /// answering board feeds with only the first 25 pins and "-end-" (verified on a 105-pin board), while a fresh
    /// session paged through the whole board.
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
    }

    // MARK: - URL recognition

    /// `https://www.pinterest.com/<username>/<board>/` (any Pinterest country domain) → (username, slug).
    /// Pins, searches, profile tabs (`/_saved/`), board sections (3 segments) and short links return nil.
    public func boardReference(from string: String) -> (username: String, slug: String)? {
        let media = PinterestMediaResolver.shared
        guard let url = media.firstURL(in: string), media.isPinterestHost(url.host),
              url.host?.lowercased() != "pin.it" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let username = parts[0], slug = parts[1]
        guard !Self.reservedRoots.contains(username.lowercased()),
              !slug.hasPrefix("_"),
              !Self.reservedBoardSlugs.contains(slug.lowercased()) else { return nil }
        return (username, slug)
    }

    // MARK: - Requests

    /// Board name and pin count (one request).
    public func fetchBoard(username: String, slug: String,
                           completion: @escaping (Result<PinterestBoard, PinterestError>) -> Void) {
        let options: [String: Any] = ["username": username, "slug": slug, "field_set_key": "detailed"]
        request("BoardResource", sourcePath: "/\(username)/\(slug)/", options: options) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let body):
                let response = body["resource_response"] as? [String: Any] ?? [:]
                guard let data = response["data"] as? [String: Any],
                      let id = data["id"] as? String,
                      let name = data["name"] as? String else {
                    completion(.failure(.unexpected))
                    return
                }
                let count = (data["pin_count"] as? NSNumber)?.intValue ?? 0
                completion(.success(PinterestBoard(id: id, name: name, pinCount: count, username: username, slug: slug)))
            }
        }
    }

    /// One page of pins (25). `nextBookmark` is nil when there are no more pages.
    public func fetchPins(of board: PinterestBoard, bookmark: String?,
                          completion: @escaping (Result<(pins: [PinterestBoardPin], nextBookmark: String?), PinterestError>) -> Void) {
        let path = "/\(board.username)/\(board.slug)/"
        var options: [String: Any] = [
            "board_id": board.id, "board_url": path, "page_size": Self.pageSize, "field_set_key": "react_grid_pin",
            // Include pins that live inside the board's sections. By default the feed leaves them out (Pinterest's
            // website shows sections separately), so a board with sections stopped after its loose pins.
            "filter_section_pins": false
        ]
        if let bookmark = bookmark { options["bookmarks"] = [bookmark] }
        request("BoardFeedResource", sourcePath: path, options: options) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let body):
                let response = body["resource_response"] as? [String: Any] ?? [:]
                let items = response["data"] as? [[String: Any]] ?? []
                let pins = items.compactMap(Self.pin(from:))
                // The next-page marker is in resource_response.bookmark, or (depending on the response shape)
                // in resource.options.bookmarks. Read either; "-end-" means the last page.
                let fromOptions = ((body["resource"] as? [String: Any])?["options"] as? [String: Any])?["bookmarks"] as? [String]
                let next = [response["bookmark"] as? String, fromOptions?.first]
                    .compactMap { $0 }
                    .first { !$0.isEmpty && $0 != "-end-" }
                completion(.success((pins, next)))
            }
        }
    }

    private static func pin(from item: [String: Any]) -> PinterestBoardPin? {
        guard item["type"] as? String == "pin", let id = item["id"] as? String,
              let images = item["images"] as? [String: Any] else { return nil }
        func url(_ key: String) -> URL? {
            ((images[key] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
        }
        guard let full = url("orig") ?? url("736x") ?? url("474x"),
              let thumb = url("236x") ?? url("474x") ?? url("736x") else { return nil }

        // Prefer a direct MP4 rendition; HLS-only video pins fall back to their still image.
        var video: URL?
        if let list = (item["videos"] as? [String: Any])?["video_list"] as? [String: Any] {
            let mp4s = list.values.compactMap { ($0 as? [String: Any])?["url"] as? String }.filter { $0.hasSuffix(".mp4") }
            video = mp4s.sorted().first.flatMap(URL.init(string:))
        }
        let title = [item["grid_title"], item["title"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        return PinterestBoardPin(id: id, title: title, thumbnailURL: thumb, imageURL: full, videoURL: video,
                                 dominantColor: item["dominant_color"] as? String)
    }

    /// Calls a Pinterest resource endpoint. Success hands back the whole JSON body
    /// (`resource_response` holds the data; `resource` echoes the options, including paging bookmarks).
    private func request(_ resource: String, sourcePath: String, options: [String: Any],
                         completion: @escaping (Result<[String: Any], PinterestError>) -> Void) {
        var components = URLComponents(string: "https://www.pinterest.com/resource/\(resource)/get/")!
        guard let json = try? JSONSerialization.data(withJSONObject: ["options": options, "context": [String: Any]()]),
              let jsonString = String(data: json, encoding: .utf8) else {
            completion(.failure(.unexpected))
            return
        }
        components.queryItems = [URLQueryItem(name: "source_url", value: sourcePath),
                                 URLQueryItem(name: "data", value: jsonString)]
        var req = URLRequest(url: components.url!)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("www/[username].js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, response, error in
            if let limit = Self.rateLimit(in: response, data: data) {
                completion(.failure(.rateLimited(retryAfter: limit.retryAfter)))
                return
            }
            if let error = error as? URLError {
                let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                                   .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
                completion(.failure(offline.contains(error.code) ? .offline : .unexpected))
                return
            }
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let response2 = body?["resource_response"] as? [String: Any]
            if (response as? HTTPURLResponse)?.statusCode == 404 || Self.bodyStatus(response2) == 404 {
                completion(.failure(.notFound))
                return
            }
            guard let body = body, response2 != nil,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("[Pinterest] \(resource) failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                completion(.failure(.unexpected))
                return
            }
            completion(.success(body))
        }.resume()
    }

    // MARK: - Rate limit detection (shared with PinterestMediaResolver)

    public struct RateLimit { public let retryAfter: TimeInterval? }

    /// Non-nil when Pinterest answered "too many requests" (HTTP 429, either as the status or inside the JSON body).
    static func rateLimit(in response: URLResponse?, data: Data? = nil) -> RateLimit? {
        let http = response as? HTTPURLResponse
        var limited = http?.statusCode == 429
        if !limited, let data = data,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            limited = bodyStatus(body["resource_response"] as? [String: Any]) == 429
        }
        guard limited else { return nil }
        return RateLimit(retryAfter: retryAfterSeconds(http?.value(forHTTPHeaderField: "Retry-After")))
    }

    private static func bodyStatus(_ resourceResponse: [String: Any]?) -> Int? {
        let error = resourceResponse?["error"] as? [String: Any]
        return (error?["http_status"] as? NSNumber)?.intValue ?? (resourceResponse?["http_status"] as? NSNumber)?.intValue
    }

    /// `Retry-After` is either seconds ("120") or an HTTP date.
    static func retryAfterSeconds(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) }
    }
}
