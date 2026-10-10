// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// CursorDeck's panels always use macOS *overlay* scroll bars: a thin bar floating over the content, no track.
/// With "Show scroll bars: Automatic" and a mouse connected, macOS otherwise draws legacy scroll bars inside a
/// track that takes width from the content (it pushed the How to Use text into extra line breaks).
enum OverlayScrollers {
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Applies overlay style to `scrollView` and keeps it if the system setting changes later.
    static func enforce(on scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
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
