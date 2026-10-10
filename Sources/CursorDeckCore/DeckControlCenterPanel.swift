// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// Borderless, arrowless floating panel for the CursorDeck menu bar Control Center.
/// Replaces NSPopover to provide a clean, modern macOS system dropdown without triangular nibs.
public final class DeckControlCenterPanel: NSPanel {
    public var onEscPressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.animationBehavior = .utilityWindow
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
    }

    public override var canBecomeKey: Bool {
        return true
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscPressed?()
    }
}
