// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// "Report a Problem…": opens the owner's Google Form in the browser with two answers filled in, the Que/Mac details
/// and Que's recent messages. Que sends nothing itself; the user reads (and can edit) everything before pressing Submit.
///
/// Privacy: only the text of messages Que already showed on screen goes in, with quoted names (boards) and any links
/// removed. Never the clipboard, images, links or file paths. The list lives in memory only and empties on quit.
public enum ProblemReport {
    /// The form's responder link and its pre-fill field ids (form "Report a problem with Que" in the owner's account).
    public static let formURL = "https://docs.google.com/forms/d/e/1FAIpQLSc6Hn_lS1Ohp-Sgj35hD3597KsqPv0mqNPvxazjMd431kwZ-A/viewform"
    public static let detailsField = "entry.1793571710"
    public static let recentField = "entry.1324349984"

    static let maxRecent = 10
    private static var recent: [(date: Date, text: String)] = []

    /// Called for every message the badge shows (`CursorHUDPanel.show`).
    public static func record(_ notice: PillNotice, at date: Date = Date()) {
        note([notice.message, notice.detail].compactMap { $0 }.joined(separator: " / "), at: date)
    }

    /// A behind-the-scenes line for the report (e.g. which Pinterest request was refused). Same privacy rules.
    public static func note(_ raw: String, at date: Date = Date()) {
        let text = sanitized(raw)
        guard !text.isEmpty else { return }
        recent.append((date, text))
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
    }

    /// Opens the form in the default browser.
    public static func open() {
        guard let url = url() else { return }
        NSWorkspace.shared.open(url)
    }

    /// The pre-filled form link.
    public static func url(now: Date = Date()) -> URL? {
        let fields = [("usp", "pp_url"), (detailsField, details()), (recentField, recentText(now: now))]
        // Encode strictly (Google reads "+" as a space, which URLComponents leaves alone).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return URL(string: "\(formURL)?\(query)")
    }

    /// "Que 2.5.1, macOS 27.0, Apple silicon"
    public static func details() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                                        : "\(os.majorVersion).\(os.minorVersion)"
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let chip = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1 ? "Apple silicon" : "Intel"
        return "Que \(UpdateManager.currentVersion), macOS \(macOS), \(chip)"
    }

    /// Recent messages, oldest first, plus the end of the update log if the last update went wrong.
    public static func recentText(now: Date = Date()) -> String {
        var lines = recent.map { "\(relative($0.date, now: now))  \($0.text)" }
        if lines.isEmpty { lines = ["No messages yet"] }
        if let updateLines = failedUpdateLines() {
            lines.append("")
            lines.append("Update log:")
            lines.append(contentsOf: updateLines)
        }
        let text = lines.joined(separator: "\n")
        return text.count > 1800 ? String(text.suffix(1800)) : text   // keeps the link a safe length
    }

    /// The last lines of the update log, only when one of them reports a failure. The home folder is shortened to ~.
    public static func failedUpdateLines(log: String? = nil) -> [String]? {
        guard let log = log ?? (try? String(contentsOf: UpdateManager.logURL, encoding: .utf8)) else { return nil }
        let last = log.split(whereSeparator: \.isNewline).suffix(8).map(String.init)
        guard last.contains(where: { $0.lowercased().contains("fail") }) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return last.suffix(6).map { $0.replacingOccurrences(of: home, with: "~") }
    }

    /// Board names (shown in “quotes”) become “…”, links are dropped, and very long text is cut.
    public static func sanitized(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"“[^”]*”"#, with: "“…”", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\b(?:https?://|www\.)\S+"#, with: "[link]", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > 140 ? String(result.prefix(140)) + "…" : result
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }

    /// Test hook: empties the list.
    public static func resetForTesting() { recent.removeAll() }
}
