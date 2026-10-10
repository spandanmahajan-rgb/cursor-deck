// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit

/// A short message shown *inside* the pill. The pill grows to fit it, then shrinks back to the count.
///
/// Every message the pill gives the user goes through this one type: show it with `CursorHUDPanel.show(_:)`.
/// Wording lives in the catalogue at the bottom of this file so the voice stays consistent (sentence case,
/// says what happened and what to do next, no apologies).
public struct PillNotice {
    public enum Tone {
        case neutral, success, warning, error

        /// The pill's status dot takes this colour while the notice is showing.
        var dotColor: NSColor {
            switch self {
            case .neutral: return NSColor(white: 0.85, alpha: 1.0)
            case .success: return NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0)   // the pill's usual emerald
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }
    }

    /// First line, always shown.
    public let message: String
    /// Optional second line in a quieter style (the "what to do next" part).
    public let detail: String?
    public let tone: Tone
    /// Seconds before the notice leaves on its own; `nil` keeps it until it is replaced or dismissed.
    /// The timer pauses while ⌘ or ⌥ is held, so a notice can't vanish while you're reaching for it.
    public let duration: TimeInterval?
    /// Runs on a click (or ⌘-click) on the pill while the notice is showing.
    public let primaryAction: (() -> Void)?
    /// Runs on ⌥-click on the pill while the notice is showing.
    public let alternateAction: (() -> Void)?

    public init(
        _ message: String,
        detail: String? = nil,
        tone: Tone = .neutral,
        duration: TimeInterval? = 3.0,
        primaryAction: (() -> Void)? = nil,
        alternateAction: (() -> Void)? = nil
    ) {
        self.message = message
        self.detail = detail
        self.tone = tone
        self.duration = duration
        self.primaryAction = primaryAction
        self.alternateAction = alternateAction
    }

    var hasActions: Bool { primaryAction != nil || alternateAction != nil }

    /// What VoiceOver announces.
    var spokenText: String { [message, detail].compactMap { $0 }.joined(separator: ". ") }
}

// MARK: - Catalogue

public extension PillNotice {

    /// Pinterest answered HTTP 429. Says plainly that *the limit* was hit, and when to try again.
    /// `partial` reports how far a board download got before the limit (e.g. "Added 12 of 48").
    static func pinterestRateLimited(retryAfter: TimeInterval?,
                                     partial: (done: Int, total: Int, verb: String)? = nil) -> PillNotice {
        let wait: String
        if let seconds = retryAfter, seconds > 0 {
            let minutes = Int((seconds / 60).rounded(.up))
            wait = minutes <= 1 ? "Try again in about a minute." : "Try again in about \(minutes) minutes."
        } else {
            wait = partial == nil ? "Wait a few minutes, then copy the link again." : "Wait a few minutes, then retry."
        }
        let detail = partial.map { "\($0.verb) \($0.done) of \($0.total). \(wait)" } ?? wait
        return PillNotice("Pinterest request limit reached", detail: detail, tone: .warning, duration: 7)
    }

    /// Logged-out requests can't tell a secret board from a deleted one: Pinterest answers "not found" for both.
    static func boardNotFound() -> PillNotice {
        PillNotice("Board not found", detail: "It's secret or was deleted. Only public boards can be added.",
                   tone: .error, duration: 5)
    }

    static func boardEmpty(name: String) -> PillNotice {
        PillNotice("“\(name)” has no pins to add", tone: .neutral, duration: 3)
    }

    static func pinterestUnreachable() -> PillNotice {
        PillNotice("Couldn't reach Pinterest", detail: "Check your connection, then copy the link again.",
                   tone: .error, duration: 5)
    }

    static func pinterestUnexpected() -> PillNotice {
        PillNotice("Pinterest sent something unexpected", detail: "Try copying the link again.",
                   tone: .error, duration: 5)
    }

    /// The board offer: nothing is fetched into the deck until the user acts on it.
    static func boardOffer(name: String, pinCount: Int, cap: Int,
                           addAll: @escaping () -> Void, choose: @escaping () -> Void) -> PillNotice {
        let pins = pinCount == 1 ? "1 pin" : "\(pinCount) pins"
        let addHint = pinCount > cap ? "⌘-click adds the first \(cap)" : "⌘-click adds all"
        return PillNotice("\(pins) in “\(name)”", detail: "\(addHint), ⌥-click to choose",
                          tone: .neutral, duration: 10, primaryAction: addAll, alternateAction: choose)
    }

    static func boardAdding(count: Int, name: String) -> PillNotice {
        boardAddingProgress(done: 0, total: count, name: name)
    }

    /// Stays up (no timer) while pins download; updated in place as each one lands.
    static func boardAddingProgress(done: Int, total: Int, name: String) -> PillNotice {
        PillNotice("Adding from “\(name)”", detail: "\(done) of \(total)", tone: .neutral, duration: nil)
    }

    /// `alreadyInDeck`: pins of this board skipped because they were already in the deck (⌘-click add).
    static func boardAdded(added: Int, requested: Int, name: String, alreadyInDeck: Int = 0) -> PillNotice {
        let pins = { (n: Int) in n == 1 ? "1 pin" : "\(n) pins" }
        if added < requested {
            return PillNotice("Added \(added) of \(requested) pins from “\(name)”",
                              detail: "\(requested - added) couldn't be downloaded.", tone: .warning, duration: 4)
        }
        if alreadyInDeck > 0 {
            return PillNotice("Added \(added) new \(added == 1 ? "pin" : "pins") from “\(name)”",
                              detail: "\(pins(alreadyInDeck)) \(alreadyInDeck == 1 ? "was" : "were") already in the deck.",
                              tone: .success, duration: 3)
        }
        // A plain confirmation: brief, like a native macOS toast.
        return PillNotice("Added \(pins(added)) from “\(name)”", tone: .success, duration: 2)
    }

    /// The board link was copied again and its pins are all still in the deck. ⌥-click still opens the picker.
    static func boardAlreadyAdded(name: String, choose: @escaping () -> Void) -> PillNotice {
        PillNotice("“\(name)” is already in the deck", detail: "⌥-click to choose pins anyway",
                   tone: .neutral, duration: 4, alternateAction: choose)
    }

    static func nothingDownloaded() -> PillNotice {
        PillNotice("None of the pins could be downloaded", detail: "Try again in a moment.", tone: .error, duration: 5)
    }
}
