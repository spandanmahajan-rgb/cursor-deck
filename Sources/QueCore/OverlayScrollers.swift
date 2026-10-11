// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// CursorDeck's panels always use macOS *overlay* scroll bars: a thin bar floating over the content, no track.
/// With "Show scroll bars: Automatic" and a mouse connected, macOS otherwise draws legacy scroll bars inside a
/// track that takes width from the content (it pushed the How to Use text into extra line breaks).
enum OverlayScrollers {
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private static var scrollerKeepers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// Applies overlay style to `scrollView` and keeps it if the system setting changes later.
    static func enforce(on scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true   // also for SwiftUI ScrollViews that hide their own indicators
        if scrollerKeepers[ObjectIdentifier(scrollView)] == nil {
            // A SwiftUI ScrollView with hidden indicators turns the scroller back off on its next update; keep it on.
            scrollerKeepers[ObjectIdentifier(scrollView)] = scrollView.observe(\.hasVerticalScroller) { view, _ in
                guard !view.hasVerticalScroller else { return }
                DispatchQueue.main.async { view.hasVerticalScroller = true }
            }
        }
        // Hovering an overlay scroll bar makes macOS draw a track box behind it; ours shows only the bar.
        if !(scrollView.verticalScroller is TracklessScroller) {
            scrollView.verticalScroller = TracklessScroller()
        }
        let key = ObjectIdentifier(scrollView)
        guard observers[key] == nil else { return }
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak scrollView] _ in
            // NSScrollView resets itself to the system style on this notification; set ours back afterwards.
            DispatchQueue.main.async { scrollView?.scrollerStyle = .overlay }
        }
    }
}

/// An overlay scroll bar without the track: still fades in while scrolling and out when idle, but hovering it
/// no longer draws the box behind the bar.
final class TracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// SwiftUI: put `.background(OverlayScrollerStyle())` on a ScrollView's content to give that ScrollView
/// overlay scroll bars.
struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The enclosing NSScrollView is only reachable once the view is in the hierarchy.
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                OverlayScrollers.enforce(on: scrollView)
                scrollView.flashScrollers()   // briefly show the bar so it's clear the content scrolls
            }
        }
    }
}
