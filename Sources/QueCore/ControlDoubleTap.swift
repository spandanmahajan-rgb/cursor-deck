// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import CoreGraphics
import Foundation

/// Spots a double-tap of ⌃ from the polled modifier state (no key monitor, no permission).
/// A tap is ⌃ alone, pressed and released within `maxTapDuration`; two taps count when the second starts within
/// `maxGap` of the first ending and no other key or click happened in between (so ⌃C ⌃C in Terminal never fires).
public struct ControlDoubleTap {
    public static let maxTapDuration: TimeInterval = 0.3
    public static let maxGap: TimeInterval = 0.35

    private var wasDown = false
    private var downAt: TimeInterval = 0
    private var downClean = false
    private var firstTapDownAt: TimeInterval?
    private var firstTapUpAt: TimeInterval = 0

    public init() {}

    /// Feed one poll. `otherModifiers`: ⌘/⌥/⇧/fn held. `secondsSinceKeyOrClick`: age of the last key press or click.
    /// Returns true on the poll that completes a double-tap.
    public mutating func update(controlDown: Bool, otherModifiers: Bool,
                                secondsSinceKeyOrClick: TimeInterval, now: TimeInterval) -> Bool {
        defer { wasDown = controlDown }
        if controlDown {
            if !wasDown {
                downAt = now
                downClean = !otherModifiers
                // Too long since the first tap ended: this press starts over.
                if let _ = firstTapDownAt, now - firstTapUpAt > Self.maxGap { firstTapDownAt = nil }
            } else if otherModifiers {
                downClean = false
            }
            return false
        }
        guard wasDown else { return false }   // nothing to do until a release

        let since = firstTapDownAt ?? downAt
        let isTap = downClean && !otherModifiers && now - downAt <= Self.maxTapDuration
            && secondsSinceKeyOrClick > now - since   // no key or click since the (first) tap began
        guard isTap else { firstTapDownAt = nil; return false }

        if firstTapDownAt != nil {
            firstTapDownAt = nil
            return true
        }
        firstTapDownAt = downAt
        firstTapUpAt = now
        return false
    }
}

extension ControlDoubleTap {
    /// Feeds the live modifier state (the same permission-free polling Que uses for ⌥). True on a double-tap.
    public mutating func poll() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let age = { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        return update(
            controlDown: flags.contains(.maskControl),
            otherModifiers: !flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty,
            secondsSinceKeyOrClick: min(age(.keyDown), age(.leftMouseDown), age(.rightMouseDown)),
            now: ProcessInfo.processInfo.systemUptime)
    }
}

/// How the user calls Que over: hold ⌥ (the original way), or tap ⌃ twice (Que then stays under the pointer until a
/// drop or another double-tap, which leaves ⌥-drag free for duplicating in other apps). Chosen in the welcome tour
/// or the Control Center; every how-to text reads from here so it only ever describes the chosen way.
public enum QueControls {
    static let doubleTapKey = "Que_doubleTapControl"
    public static let didChange = Notification.Name("QueControlsDidChange")

    public static var usesDoubleTap: Bool {
        get { UserDefaults.standard.bool(forKey: doubleTapKey) }
        set {
            guard newValue != usesDoubleTap else { return }
            UserDefaults.standard.set(newValue, forKey: doubleTapKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// "⌥-click" / "⌃⌃ then click": the short form used inside notices.
    static var clickPhrase: String { usesDoubleTap ? "⌃⌃ then click" : "⌥-click" }
}
