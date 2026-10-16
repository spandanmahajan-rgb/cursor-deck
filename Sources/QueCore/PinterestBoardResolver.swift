// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
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
    /// The board's owner has a private profile: Pinterest hides all their boards (even public ones) from
    /// logged-out visitors, and CursorDeck is always logged out.
    case privateProfile
    case offline
    case unexpected
}

/// Reads public Pinterest boards through the same unofficial web endpoints CursorDeck already uses for pins.
/// They can change or rate-limit without notice, so every failure is reported as a specific `PinterestError`.
public final class PinterestBoardResolver {
    public static let shared = PinterestBoardResolver()

    private let session: URLSession
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 100 = the pins Que loads at first (`BoardImportController.pinCap`) in one request. Pinterest blocks a Mac
    /// for 10 minutes after only a few requests (seen 2026-10-16, exact number unknown), so every request counts.
    public static let pageSize = 100

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

    /// Board name and pin count (one request), from the board's own web page: it also carries the first pins, so
    /// the first `fetchPins` needs no request. Falls back to `BoardResource` when the page can't be read.
    ///
    /// Why the page: since 2026-10-16 Pinterest refuses `BoardResource` from logged-out apps after very few
    /// requests (HTTP 429, 10-minute wait), while the board page and `BoardFeedResource` kept answering.
    public func fetchBoard(username: String, slug: String,
                           completion: @escaping (Result<PinterestBoard, PinterestError>) -> Void) {
        fetchBoardPage(username: username, slug: slug) { result in
            switch result {
            case .success(let board): completion(.success(board))
            case .failure(.rateLimited(let wait)): completion(.failure(.rateLimited(retryAfter: wait)))
            case .failure(.notFound):
                // The page loaded but holds no such board: missing, secret, or on a private profile (Pinterest serves
                // the same empty page for all three). Ask about the profile first: `UserResource` still answers, while
                // `BoardResource` is the refused one and would show "limiting requests" for a board that isn't there.
                self.isPrivateProfile(username: username) { isPrivate in
                    switch isPrivate {
                    case true?: completion(.failure(.privateProfile))
                    // Public profile and an intact page without the board. Not asking BoardResource: a refusal there
                    // starts the shared wait, which would then block copying the next (real) board.
                    case false?: completion(.failure(.notFound))
                    case nil: self.fetchBoardResource(username: username, slug: slug, completion: completion)
                    }
                }
            case .failure: self.fetchBoardResource(username: username, slug: slug, completion: completion)
            }
        }
    }

    /// Pins the board page already carried, handed out once by the first `fetchPins` (bookmark nil) for that board.
    private var firstPage: (boardID: String, pins: [PinterestBoardPin], next: String?)?
    private let firstPageLock = NSLock()

    private func fetchBoardPage(username: String, slug: String,
                                completion: @escaping (Result<PinterestBoard, PinterestError>) -> Void) {
        if let wait = Self.remainingWait() {
            completion(.failure(.rateLimited(retryAfter: wait)))
            return
        }
        guard let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let board = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.pinterest.com/\(user)/\(board)/") else {
            completion(.failure(.unexpected))
            return
        }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, response, _ in
            if let limit = Self.rateLimit(in: response) {
                completion(.failure(.rateLimited(retryAfter: limit.retryAfter)))
                return
            }
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(.unexpected))
                return
            }
            guard let page = Self.parseBoardPage(data, username: username, slug: slug) else {
                completion(.failure(Self.boardPageIsReadable(data) ? .notFound : .unexpected))
                return
            }
            if let pins = page.pins {
                self.firstPageLock.lock()
                self.firstPage = (page.board.id, pins, page.nextBookmark)
                self.firstPageLock.unlock()
            }
            completion(.success(page.board))
        }.resume()
    }

    /// Reads a board page's embedded data (`__PWS_INITIAL_PROPS__`): the board, and its first pins with the bookmark
    /// for the next ones. `pins` is nil for boards with sections: the page's feed may leave section pins out, so
    /// those boards load every pin through `BoardFeedResource` as before. Nil when the page has no matching board.
    public static func parseBoardPage(_ data: Data, username: String, slug: String)
        -> (board: PinterestBoard, pins: [PinterestBoardPin]?, nextBookmark: String?)? {
        guard let state = boardPageState(data),
              let boards = (state["boards"] as? [String: Any])?.values.compactMap({ $0 as? [String: Any] }) else { return nil }
        let path = "/\(username)/\(slug)/".lowercased()
        guard let data = boards.first(where: { ($0["url"] as? String)?.lowercased() == path }) ?? (boards.count == 1 ? boards[0] : nil),
              let id = data["id"] as? String, let name = data["name"] as? String else { return nil }
        let board = PinterestBoard(id: id, name: name, pinCount: (data["pin_count"] as? NSNumber)?.intValue ?? 0,
                                   username: username, slug: slug)
        guard (data["section_count"] as? NSNumber)?.intValue ?? 0 == 0 else { return (board, nil, nil) }
        let feeds = ((state["resources"] as? [String: Any])?["BoardFeedResource"] as? [String: Any])?
            .compactMap { $0.value as? [String: Any] } ?? []
        guard let feed = feeds.first(where: { !(($0["data"] as? [Any])?.isEmpty ?? true) }) else { return (board, nil, nil) }
        let pins = (feed["data"] as? [[String: Any]] ?? []).compactMap(Self.pin(from:))
        let next = (feed["nextBookmark"] as? String).flatMap { $0.isEmpty || $0 == "-end-" ? nil : $0 }
        return (board, pins.isEmpty ? nil : pins, next)
    }

    /// True when the page's data is intact (it has a `boards` list, empty or not). An intact page without the board
    /// means Pinterest doesn't show that board to logged-out visitors; an unreadable page means the format changed.
    public static func boardPageIsReadable(_ data: Data) -> Bool { boardPageState(data) != nil }

    private static func boardPageState(_ data: Data) -> [String: Any]? {
        guard let html = String(data: data, encoding: .utf8),
              let tag = html.range(of: "id=\"__PWS_INITIAL_PROPS__\""),
              let start = html[tag.upperBound...].range(of: ">"),
              let end = html[start.upperBound...].range(of: "</script>"),
              let props = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let state = props["initialReduxState"] as? [String: Any],
              state["boards"] is [String: Any] else { return nil }
        return state
    }

    /// Board name and pin count through the `BoardResource` endpoint (the fallback).
    private func fetchBoardResource(username: String, slug: String,
                                    completion: @escaping (Result<PinterestBoard, PinterestError>) -> Void) {
        let options: [String: Any] = ["username": username, "slug": slug, "field_set_key": "detailed"]
        // Strong capture on purpose: the closure belongs to the URL task (no retain cycle), and a resolver created
        // just for this lookup must live until the follow-up profile check is done.
        request("BoardResource", sourcePath: "/\(username)/\(slug)/", options: options) { result in
            switch result {
            case .failure(.notFound):
                // "Not found" also happens for public boards on a private profile; check which, so the
                // message points at the real reason instead of "secret or deleted".
                self.isPrivateProfile(username: username) { isPrivate in
                    completion(.failure(isPrivate == true ? .privateProfile : .notFound))
                }
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

    /// Whether `username` has a private profile (verified on a real account: Pinterest returns a stub user
    /// with `is_private_profile: true` and none of its boards). nil when Pinterest didn't answer (error, limit).
    private func isPrivateProfile(username: String, completion: @escaping (Bool?) -> Void) {
        let options: [String: Any] = ["username": username, "field_set_key": "profile"]
        request("UserResource", sourcePath: "/\(username)/", options: options) { result in
            guard case .success(let body) = result,
                  let data = (body["resource_response"] as? [String: Any])?["data"] as? [String: Any] else {
                completion(nil)
                return
            }
            completion(data["is_private_profile"] as? Bool == true)
        }
    }

    /// One page of pins (25). `nextBookmark` is nil when there are no more pages.
    public func fetchPins(of board: PinterestBoard, bookmark: String?,
                          completion: @escaping (Result<(pins: [PinterestBoardPin], nextBookmark: String?), PinterestError>) -> Void) {
        if bookmark == nil {
            firstPageLock.lock()
            let first = firstPage?.boardID == board.id ? firstPage : nil
            if first != nil { firstPage = nil }
            firstPageLock.unlock()
            if let first = first {
                completion(.success((first.pins, first.next)))
                return
            }
        }
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
        if let wait = Self.remainingWait() {
            completion(.failure(.rateLimited(retryAfter: wait)))
            return
        }
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
                completion(.failure(.unexpected))
                return
            }
            completion(.success(body))
        }.resume()
    }

    // MARK: - Rate limit detection (shared with PinterestMediaResolver)

    public struct RateLimit { public let retryAfter: TimeInterval? }

    /// Until when Pinterest asked Que to wait. While it lasts, board lookups answer "limited" without asking
    /// Pinterest: every request during the wait counts against the limit and can make the wait longer.
    /// Single pins still ask (1–2 requests); image-server limits don't start a wait (see `rateLimit(in:)`).
    /// Saved, so quitting or updating Que doesn't forget the wait (asking again too soon restarts it).
    private static var limitedUntil: Date? = UserDefaults.standard.object(forKey: limitKey) as? Date {
        didSet { UserDefaults.standard.set(limitedUntil, forKey: limitKey) }
    }
    public static let limitKey = "Que_pinterestLimitedUntil"
    private static let limitLock = NSLock()
    /// Used when Pinterest doesn't say how long to wait.
    static let defaultWait: TimeInterval = 5 * 60

    public static func rememberLimit(retryAfter: TimeInterval?, now: Date = Date()) {
        let until = now.addingTimeInterval(retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? defaultWait)
        limitLock.lock(); defer { limitLock.unlock() }
        if limitedUntil.map({ until > $0 }) ?? true { limitedUntil = until }
    }

    /// Seconds left before Que may ask Pinterest again, or nil when it may ask now.
    public static func remainingWait(now: Date = Date()) -> TimeInterval? {
        limitLock.lock(); defer { limitLock.unlock() }
        guard let until = limitedUntil, until > now else {
            if limitedUntil != nil { limitedUntil = nil }   // avoids saving on every lookup
            return nil
        }
        return until.timeIntervalSince(now)
    }

    public static func forgetLimit() {
        limitLock.lock(); defer { limitLock.unlock() }
        limitedUntil = nil
    }

    /// Non-nil when Pinterest answered "too many requests" (HTTP 429, either as the status or inside the JSON body).
    /// Also remembers the wait (see `limitedUntil`), so every Pinterest request site shares it.
    static func rateLimit(in response: URLResponse?, data: Data? = nil) -> RateLimit? {
        let http = response as? HTTPURLResponse
        var limited = http?.statusCode == 429
        var inBody = false
        if !limited, let data = data,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            limited = bodyStatus(body["resource_response"] as? [String: Any]) == 429
            inBody = limited
        }
        guard limited else { return nil }
        let header = http?.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = retryAfterSeconds(header)
        // Image servers (i.pinimg.com, v.pinimg.com) have their own, stricter limit: it stops that board import only.
        if !isImageServer(response?.url) { rememberLimit(retryAfter: retryAfter) }
        let note = limitNote(url: response?.url, inBody: inBody, retryAfter: header)
        DispatchQueue.main.async { ProblemReport.note(note) }   // called on URLSession queues; the list lives on main
        return RateLimit(retryAfter: retryAfter)
    }

    public static func isImageServer(_ url: URL?) -> Bool {
        url?.host?.lowercased().hasSuffix("pinimg.com") ?? false
    }

    /// "Pinterest 429 (PinResource, in reply, Retry-After none)": which request was refused, for "Report a Problem…".
    /// Only the server and the endpoint name: never the pin id, board or link.
    public static func limitNote(url: URL?, inBody: Bool, retryAfter: String?) -> String {
        let parts = url?.pathComponents ?? []
        let endpoint = parts.firstIndex(of: "resource").flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil }
        let what = endpoint ?? (parts.contains("pin") ? "pin page" : url?.host ?? "unknown")
        return "Pinterest 429 (\(what), \(inBody ? "in reply" : "HTTP status"), Retry-After \(retryAfter ?? "none"))"
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
