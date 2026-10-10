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
            guard let self, !self.queueManager.isEmpty, !self.isDragging, !self.isDismissing else { return }
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
        guard trackingTimer == nil, !queueManager.isEmpty else { return }
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
        // Hide only when deck is truly empty and no drag is in flight
        guard !queueManager.isEmpty else {
            if isVisible && !isDragging { orderOut(nil) }
            return
        }

        guard !isDragging, !isDismissing else { return }

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
        let currentW = badgeWidth
        let currentH = badgeHeight

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
            // Magnet Snap: centered under pointer, clamped safely to screen edges
            targetX = mousePos.x - currentW / 2
            targetY = mousePos.y - currentH / 2
            targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))
            targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

            let factor: CGFloat = wasCommandHeld ? 0.85 : 0.92
            let dx = (targetX - currentOrigin.x) * factor
            let dy = (targetY - currentOrigin.y) * factor
            setFrameOrigin(NSPoint(x: currentOrigin.x + dx, y: currentOrigin.y + dy))
            wasCommandHeld = true
            return
        }

        wasCommandHeld = false

        // Free-Flow Mode:
        // Horizontal: Default +22 to right; if near right edge, flip to left (-currentW - 14)
        if mousePos.x + 22 + currentW > bounds.maxX - 6 {
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
            setFrameOrigin(NSPoint(x: targetX, y: targetY))
            orderFrontRegardless()
            return
        }

        // Fluid spring interpolation towards edge-aware target
        let dx = (targetX - currentOrigin.x) * 0.35
        let dy = (targetY - currentOrigin.y) * 0.35
        setFrameOrigin(NSPoint(x: currentOrigin.x + dx, y: currentOrigin.y + dy))
    }

    public func refreshHUD() {
        guard !isDragging, !isDismissing else { return }

        let count = queueManager.count
        let hasNewItems = count > previousCount
        previousCount = count

        hudView.updateCount(count, animateGlow: hasNewItems)

        if count > 0 { startTracking() } else { stopTracking() }

        let targetWidth = badgeWidth
        if frame.width != targetWidth {
            let origin = frame.origin
            setFrame(NSRect(x: origin.x, y: origin.y, width: targetWidth, height: badgeHeight), display: true)
            hudView.frame = NSRect(origin: .zero, size: CGSize(width: targetWidth, height: badgeHeight))
        }

        if count > 0 {
            if !isVisible && !previewPanel.isVisible {
                let mousePos = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: mousePos.x + 22, y: mousePos.y - badgeHeight - 10))
                orderFrontRegardless()
            }
        } else {
            orderOut(nil)
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

