// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

public final class CursorHUDPanel: NSPanel, DeckHUDViewDelegate {
    public let queueManager: DeckQueueManager
    public let shakeDetector = ShakeDetector()
    public let previewPanel = DeckPreviewPanel()

    private let hudView: DeckHUDView
    private var trackingTimer: Timer?
    private var previousCount: Int = 0
    private var wasCommandHeld = false
    private var isDragging = false
    private var isDismissing = false

    private let badgeHeight: CGFloat = 28.0

    private var badgeWidth: CGFloat {
        return queueManager.count > 9 ? 66.0 : 58.0
    }

    // MARK: Notice state
    private var notice: PillNotice?
    private var noticeToken = 0
    /// True while the pill shrinks back to its dot and fades after the last notice on an empty deck.
    private var isCollapsing = false
    /// The smallest pill: just the dot, a 28pt circle. Notices grow out of it and collapse back into it.
    private static let dotSize = NSSize(width: 28, height: 28)

    /// Size the pill is animating towards: the notice's size while one shows, otherwise the count badge.
    private var targetSize: NSSize {
        if isCollapsing { return Self.dotSize }
        if let notice = notice { return hudView.preferredSize(for: notice) }
        return NSSize(width: badgeWidth, height: badgeHeight)
    }

    /// The pill is on screen while the deck has items, a notice is showing, or it is collapsing away.
    private var isActive: Bool { !queueManager.isEmpty || notice != nil || isCollapsing }

    /// Hides the pill and stops it following the cursor (used while the board picker is open).
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            alphaValue = isSuspended ? 0 : 1
            ignoresMouseEvents = isSuspended
            if !isSuspended { refreshHUD() }
        }
    }

    /// The pill's frame if it is on screen (also while suspended behind the picker), else nil.
    /// Panels that open out of the pill collapse back into this.
    public var pillFrameIfShowing: NSRect? { isVisible ? frame : nil }

    public init(queueManager: DeckQueueManager) {
        self.queueManager = queueManager
        let initialWidth: CGFloat = 58.0
        let rect = NSRect(x: 100, y: 100, width: initialWidth, height: badgeHeight)

        self.hudView = DeckHUDView(frame: NSRect(origin: .zero, size: rect.size))

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false          // Never auto-hide on app switch
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        hudView.queueManager = queueManager
        hudView.delegate = self
        contentView = hudView

        // The preview grid collapses back into the pill wherever it currently is.
        previewPanel.collapseTarget = { [weak self] in self?.frame }

        // Wire up Shake gesture: Discard ENTIRE deck (Clear All)
        shakeDetector.onShakeDetected = { [weak self] in
            guard let self = self, !self.queueManager.isEmpty, !self.isDragging, !self.isDismissing else { return }
            if self.previewPanel.isVisible {
                self.previewPanel.close()
            }
            self.isDismissing = true
            self.hudView.triggerDismissPuffAnimation {
                self.queueManager.clear()
                self.isDismissing = false
                self.refreshHUD()
            }
        }

        queueManager.addObserver { [weak self] _ in
            guard let self = self else { return }
            // Keep an open preview in sync (new copy, ✕ delete, deck cleared)
            if self.previewPanel.isVisible { self.previewPanel.refresh() }
            self.refreshHUD()
        }

        // Re-surface the pill whenever the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, !self.isDragging, !self.isDismissing, !self.isSuspended else { return }
            if !self.previewPanel.isVisible {
                self.orderFrontRegardless()
            }
        }

        refreshHUD()
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    /// AUDIT: the 60 fps timer now only runs while the deck has items. It used to fire ~62x/second
    /// forever (just to hide an already-hidden panel), which keeps the CPU awake while idle.
    /// refreshHUD() starts/stops it as the deck fills and empties; calling this on an empty deck is a no-op.
    public func startTracking(interval: TimeInterval = 0.016) {
        guard trackingTimer == nil, isActive else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.trackingTimer = timer
    }

    public func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePosition() {
        // Hide only when there is nothing to show (empty deck, no notice) and no drag is in flight
        guard isActive else {
            if isVisible && !isDragging { orderOut(nil) }
            return
        }

        guard !isDragging, !isDismissing, !isSuspended else { return }

        // While the preview grid is open, let it auto-dismiss if the cursor wanders off
        if previewPanel.isVisible {
            previewPanel.tick()
            return
        }

        // Freeze panel while mouse button is pressed down so clicks don't jitter
        if NSEvent.pressedMouseButtons != 0 {
            return
        }

        let mousePos = NSEvent.mouseLocation
        let currentOrigin = frame.origin

        // Grow/shrink smoothly towards the target size (notice text or count), riding the same 60fps loop
        // as the position so the two never fight. Reduce Motion: jump straight to the new size.
        let target = targetSize
        var currentW = frame.width
        var currentH = frame.height
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            currentW = target.width
            currentH = target.height
        } else {
            currentW += (target.width - currentW) * 0.3
            currentH += (target.height - currentH) * 0.3
            // Snap the last point: with whole-point rounding below, a 1pt gap would otherwise never close.
            if abs(target.width - currentW) < 1.5 { currentW = target.width }
            if abs(target.height - currentH) < 1.5 { currentH = target.height }
        }
        currentW = currentW.rounded()
        currentH = currentH.rounded()
        // Only force a redraw when the size actually changes; moving alone needs no redraw.
        let sizeChanged = currentW != frame.width || currentH != frame.height

        // Feed horizontal movement into ShakeDetector to detect rapid cursor shake
        shakeDetector.observe(x: mousePos.x)

        // Find current display frame (taking Dock and Menu Bar into account)
        let screen = NSScreen.screens.first { NSMouseInRect(mousePos, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // MARK: - Screen Edge Clamping & Flip
        var targetX: CGFloat
        var targetY: CGFloat

        // ⌘ or ⌥ pulls the pill under the pointer like a magnet.
        // ⌘ + drag = burst-drop, ⌥ + click = open preview grid.
        let heldFlags = CGEventSource.flagsState(.hidSystemState)
        let isMagnetHeld = heldFlags.contains(.maskCommand) || heldFlags.contains(.maskAlternate)

        if isMagnetHeld {
            // Magnet Snap: under the pointer, clamped safely to screen edges. The pointer sits over the pill's
            // left part (its centre for the normal 58pt badge), so a wider notice grows to the right of it.
            targetX = mousePos.x - min(currentW / 2, 29)
            targetY = mousePos.y - currentH / 2
            targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))
            targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

            let factor: CGFloat = wasCommandHeld ? 0.85 : 0.92
            let dx = (targetX - currentOrigin.x) * factor
            let dy = (targetY - currentOrigin.y) * factor
            setFrame(NSRect(x: currentOrigin.x + dx, y: currentOrigin.y + dy, width: currentW, height: currentH), display: sizeChanged)
            wasCommandHeld = true
            return
        }

        wasCommandHeld = false

        // Free-Flow Mode:
        // Horizontal: Default +22 to right; if the *badge* wouldn't fit, flip to the left of the pointer.
        // (Decided on the badge width, not the current width, so a growing notice doesn't flip mid-animation;
        // a wide notice near the edge is just pushed left by the clamp below.)
        if mousePos.x + 22 + badgeWidth > bounds.maxX - 6 {
            targetX = mousePos.x - currentW - 14
        } else {
            targetX = mousePos.x + 22
        }
        targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))

        // Vertical: Default -currentH - 10; if near bottom edge (or Dock), flip above (+14)
        if mousePos.y - currentH - 10 < bounds.minY + 6 {
            targetY = mousePos.y + 14
        } else {
            targetY = mousePos.y - currentH - 10
        }
        targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

        if !isVisible {
            setFrame(NSRect(x: targetX, y: targetY, width: currentW, height: currentH), display: sizeChanged)
            orderFrontRegardless()
            return
        }

        // Fluid spring interpolation towards edge-aware target
        let dx = (targetX - currentOrigin.x) * 0.35
        let dy = (targetY - currentOrigin.y) * 0.35
        setFrame(NSRect(x: currentOrigin.x + dx, y: currentOrigin.y + dy, width: currentW, height: currentH), display: sizeChanged)
    }

    public func refreshHUD() {
        guard !isDragging, !isDismissing else { return }

        let count = queueManager.count
        let hasNewItems = count > previousCount
        previousCount = count

        hudView.updateCount(count, animateGlow: hasNewItems)

        if isActive { startTracking() } else { stopTracking() }

        // Size changes animate in updatePosition(). When appearing for a notice, start as the dot and fade in,
        // so the message grows out of it from the left; otherwise appear at full size as before.
        if !isVisible {
            let startsAsDot = notice != nil && queueManager.isEmpty
            setFrame(NSRect(origin: frame.origin, size: startsAsDot ? Self.dotSize : targetSize), display: false)
            if startsAsDot && !isSuspended {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self.animator().alphaValue = 1 }
            }
        }

        if isActive {
            if !isVisible && !previewPanel.isVisible && !isSuspended {
                let mousePos = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: mousePos.x + 22, y: mousePos.y - frame.height - 10))
                orderFrontRegardless()
            }
        } else {
            orderOut(nil)
        }
    }

    // MARK: - Notices

    /// Shows a message inside the pill. Replaces any notice already showing. The pill appears for it even
    /// when the deck is empty, grows to fit the text, and shrinks back when the notice ends.
    public func show(_ notice: PillNotice) {
        if isCollapsing {
            isCollapsing = false
            alphaValue = 1
        }
        self.notice = notice
        noticeToken &+= 1
        hudView.setNotice(notice)

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: notice.spokenText,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )

        refreshHUD()
        if let duration = notice.duration { scheduleNoticeEnd(after: duration, token: noticeToken) }
    }

    /// Replaces the text of the notice that is showing (e.g. progress "3 of 12") without announcing it again
    /// or restarting its timer. Shows it normally if no notice is up.
    public func updateNotice(_ notice: PillNotice) {
        guard self.notice != nil else { show(notice); return }
        self.notice = notice
        hudView.setNotice(notice)
    }

    /// Ends the current notice (no-op if none is showing). With items in the deck the pill shrinks back to the
    /// count; on an empty deck it collapses back to its dot (right edge moving left) and fades out.
    public func dismissNotice(animated: Bool = true) {
        guard notice != nil else { return }
        notice = nil
        noticeToken &+= 1

        guard animated, queueManager.isEmpty, isVisible, !isSuspended else {
            hudView.setNotice(nil)
            if queueManager.isEmpty { hudView.restoreCountInstantly() }
            refreshHUD()
            return
        }
        hudView.setNotice(nil, restoringCount: false)
        isCollapsing = true
        let token = noticeToken
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Shrink first (updatePosition animates towards the dot), then fade the dot out.
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.14)) { [weak self] in
            guard let self = self, self.noticeToken == token else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; self.animator().alphaValue = 0 }, completionHandler: {
                guard self.noticeToken == token else { return }   // a new notice arrived mid-collapse
                self.isCollapsing = false
                self.orderOut(nil)
                self.alphaValue = 1
                self.hudView.restoreCountInstantly()
                self.refreshHUD()
            })
        }
    }

    private func scheduleNoticeEnd(after delay: TimeInterval, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.noticeToken == token else { return }
            // Don't pull the notice away while the user is holding ⌘/⌥ to catch the pill.
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.contains(.maskCommand) || flags.contains(.maskAlternate) {
                self.scheduleNoticeEnd(after: 1.0, token: token)
                return
            }
            self.dismissNotice()
        }
    }

    // MARK: - DeckHUDViewDelegate

    public func deckHUDViewWillBeginDragging(_ view: DeckHUDView) {
        if previewPanel.isVisible {
            previewPanel.close()
        }
        isDragging = true
        setFrameOrigin(NSPoint(x: -500, y: -500))
    }

    public func deckHUDViewDidCompleteDrop(_ view: DeckHUDView) {
        isDragging = false
        queueManager.clear()
    }

    public func deckHUDViewDidCancelDrop(_ view: DeckHUDView) {
        isDragging = false
        refreshHUD()
    }

    public func deckHUDViewDidRequestClear(_ view: DeckHUDView) {
        queueManager.clear()
        refreshHUD()
    }

    public func deckHUDViewDidRequestPreview(_ view: DeckHUDView) {
        togglePreview()
    }

    public func togglePreview() {
        if previewPanel.isVisible {
            previewPanel.close()
            return
        }
        guard !queueManager.isEmpty, !isDragging, !isDismissing else { return }

        // Morph effect: The pill seamlessly blossoms into the preview deck.
        // We hide the pill so there is NEVER a second deck beside it!
        let pillRect = self.frame
        self.alphaValue = 0.0

        previewPanel.open(from: pillRect, queueManager: queueManager) { [weak self] in
            guard let self = self else { return }
            self.alphaValue = 1.0
            self.updatePosition()
        }
    }
}

