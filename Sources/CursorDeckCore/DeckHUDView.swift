// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

public protocol DeckHUDViewDelegate: AnyObject {
    func deckHUDViewDidRequestClear(_ view: DeckHUDView)
    func deckHUDViewDidCompleteDrop(_ view: DeckHUDView)
    func deckHUDViewDidCancelDrop(_ view: DeckHUDView)
    func deckHUDViewWillBeginDragging(_ view: DeckHUDView)
    func deckHUDViewDidRequestPreview(_ view: DeckHUDView)
}

public final class DeckHUDView: NSView, NSDraggingSource {
    public weak var delegate: DeckHUDViewDelegate?
    public var queueManager: DeckQueueManager?

    // Native Liquid Glass Visual Effect View
    private let visualEffectView = NSVisualEffectView()

    // Subviews
    private let dotView = NSView()
    private let countLabel = NSTextField(labelWithString: "0")
    private let iconImageView = NSImageView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = 14

        // 1. Native macOS Liquid Glass Material (Frosted Translucent Blur)
        // NOTE: .withinWindow instead of .behindWindow — .behindWindow requires a composited
        // window behind it to sample from. During app-switch animations macOS briefly has
        // no eligible window, causing the pill to go fully transparent (the "vanish" glitch).
        // .withinWindow always renders consistently regardless of what app is focused.
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.frame = bounds
        addSubview(visualEffectView, positioned: .below, relativeTo: nil)

        // 2. Specular glass rim border and dark glass tint
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        layer?.borderWidth = 1.0

        // 3. Ambient glass drop shadow matching exact capsule curve
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.38
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8

        // 4. Emerald active dot
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.0
        dotView.layer?.backgroundColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // 5. High-legibility count typography
        countLabel.wantsLayer = true
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        countLabel.textColor = .white
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // 6. Solid Deck Logo icon (subtle, secondary accent)
        iconImageView.image = DeckLogoAsset.pillImage
        iconImageView.contentTintColor = NSColor(white: 0.72, alpha: 0.88)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            countLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconImageView.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 10),
            iconImageView.heightAnchor.constraint(equalToConstant: 10)
        ])

        // VoiceOver: the pill is one button that announces how many items are in the deck.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("CursorDeck")
        setAccessibilityValue("0 items")
        setAccessibilityHelp("Press to copy all items for pasting. Option-click to preview them.")
        for subview in [dotView, countLabel, iconImageView] { subview.setAccessibilityElement(false) }
    }

    /// VoiceOver "press" does what a plain click does: arms the clipboard with the whole deck.
    public override func accessibilityPerformPress() -> Bool {
        guard let items = queueManager?.items, !items.isEmpty else { return false }
        PasteboardWriter.shared.writeToPasteboard(items: items)
        showCopiedFeedback()
        return true
    }

    public override func layout() {
        super.layout()
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        visualEffectView.layer?.cornerRadius = radius
        visualEffectView.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    public func updateCount(_ count: Int, animateGlow: Bool = false) {
        countLabel.stringValue = "\(count)"
        setAccessibilityValue(count == 1 ? "1 item" : "\(count) items")
        needsDisplay = true

        if animateGlow && count > 0 {
            triggerCaptureGlowAnimation()
        }
    }

    /// Solid shape illumination glow through native Liquid Glass
    public func triggerCaptureGlowAnimation() {
        guard let layer = self.layer else { return }

        // 1. Solid Shape Background Glow: glass tint illuminates with rich emerald
        let bgGlow = CAKeyframeAnimation(keyPath: "backgroundColor")
        bgGlow.values = [
            NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor,
            NSColor(red: 0.12, green: 0.44, blue: 0.22, alpha: 0.88).cgColor, // Luminous emerald glass fill
            NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52).cgColor
        ]
        bgGlow.keyTimes = [0.0, 0.30, 1.0]
        bgGlow.duration = 0.60
        bgGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bgGlow, forKey: "bgGlow")

        // 2. Radiant Glass Rim Glow
        let borderGlow = CAKeyframeAnimation(keyPath: "borderColor")
        borderGlow.values = [
            NSColor(white: 1.0, alpha: 0.28).cgColor,
            NSColor(red: 0.30, green: 0.95, blue: 0.50, alpha: 0.95).cgColor,
            NSColor(white: 1.0, alpha: 0.28).cgColor
        ]
        borderGlow.keyTimes = [0.0, 0.30, 1.0]
        borderGlow.duration = 0.60
        borderGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(borderGlow, forKey: "borderGlow")

        // 3. Dot Flash
        if let dotLayer = dotView.layer {
            let dotAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
            dotAnim.values = [
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor,
                NSColor(red: 0.65, green: 1.0, blue: 0.75, alpha: 1.0).cgColor,
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
            ]
            dotAnim.keyTimes = [0.0, 0.30, 1.0]
            dotAnim.duration = 0.60
            dotAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dotLayer.add(dotAnim, forKey: "dotFlash")
        }

        // 4. Subtle Count Pop (skipped with Reduce Motion; the colour glow above still signals the capture)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let countLayer = countLabel.layer {
            let popAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            popAnim.values = [1.0, 1.22, 1.0]
            popAnim.keyTimes = [0.0, 0.35, 1.0]
            popAnim.duration = 0.40
            popAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            countLayer.add(popAnim, forKey: "pop")
        }
    }

    /// Delightful puff/dissolve animation when discarded via Shake-to-Clear gesture
    public func triggerDismissPuffAnimation(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.alphaValue = 1.0
            completion()
        })
    }

    private var dragStartScreenPoint: NSPoint = .zero
    private var isDraggingSessionActive = false

    // MARK: - Drag & Drop and Click Handling

    private var clickHadOption = false

    public override func mouseDown(with event: NSEvent) {
        guard let items = queueManager?.items, !items.isEmpty else { return }
        dragStartScreenPoint = NSEvent.mouseLocation
        isDraggingSessionActive = false
        // Remember ⌥ at press time (user may release it before mouse-up)
        clickHadOption = event.modifierFlags.contains(.option)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let items = queueManager?.items, !items.isEmpty, !isDraggingSessionActive else { return }

        let currentScreenPoint = NSEvent.mouseLocation
        let dist = hypot(currentScreenPoint.x - dragStartScreenPoint.x, currentScreenPoint.y - dragStartScreenPoint.y)

        // When ⌘/⌥ is held (the only way to catch the pill), allow a generous 20pt
        // threshold so trackpad clicks and resting fingers don't start an accidental drag.
        let flags = CGEventSource.flagsState(.hidSystemState)
        let isModifierHeld = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
            || flags.contains(.maskCommand) || flags.contains(.maskAlternate)
        let threshold: CGFloat = isModifierHeld ? 20.0 : 4.0

        guard dist > threshold else { return }

        isDraggingSessionActive = true
        startDragSession(with: event, items: items)
    }

    public override func mouseUp(with event: NSEvent) {
        // If a drag session was active, AppKit handles session end via draggingSession(_:endedAt:operation:)
        guard !isDraggingSessionActive else { return }
        guard let items = queueManager?.items, !items.isEmpty else { return }

        // ⌥ + click (no drag) → toggle the preview grid instead of copying the batch
        if clickHadOption {
            clickHadOption = false
            delegate?.deckHUDViewDidRequestPreview(self)
            return
        }

        // Quick click without holding!
        // 1. Arm clipboard with full batch
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Show green ✓ pop on pill
        showCopiedFeedback()
    }

    private func startDragSession(with event: NSEvent, items: [DeckItem]) {
        // 1. Arm system clipboard with full batch payload
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Build one NSDraggingItem per queued image using native NSURL.
        // NSURL natively provides:
        //   • public.file-url
        //   • CorePasteboardFlavorType 0x6675726C
        //   • NSFilenamesPboardType
        //   • Apple URL pasteboard type
        let draggingItems: [NSDraggingItem] = items.enumerated().map { idx, item in
            let dragItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)

            // Use the actual image as the drag thumbnail (64pt square, stacked)
            let thumbSize: CGFloat = 64
            // AUDIT: use the cached downsampled thumbnail instead of decoding every full-size image
            // synchronously on the main thread when the drag starts.
            let thumb: NSImage = DeckThumbnailCache.shared.thumbnail(for: item.fileURL)
                ?? NSImage(contentsOf: item.fileURL)
                ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
            // Slight offset per item so the stack is visible
            let offset = CGFloat(idx) * 4
            dragItem.setDraggingFrame(
                NSRect(x: offset, y: -offset, width: thumbSize, height: thumbSize),
                contents: thumb
            )
            return dragItem
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack

        // 3. Register global NSFilenamesPboardType paths array on dragging pasteboard (critical for WhatsApp/Catalyst)
        let paths = items.map { $0.fileURL.path }
        session.draggingPasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        // Park badge off-screen so it doesn't block the drag target
        delegate?.deckHUDViewWillBeginDragging(self)
    }

    // MARK: - NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Strictly return .copy so that even when Command (⌘) is held, macOS and target apps
        // (Google Slides, Chrome, Figma, WhatsApp) do not attempt an illegal .move operation,
        // allowing Cmd+drag+drop to complete natively!
        return .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSessionActive = false
        let isAccepted = operation != []
        let logMsg = "[CursorDeck] Drag ended at \(screenPoint), operation raw=\(operation.rawValue), accepted=\(isAccepted)\n"
        print(logMsg)
        appendDragLog(logMsg)

        if isAccepted {
            print("[CursorDeck] Drop ACCEPTED ✓ operation=\(operation.rawValue)")
            delegate?.deckHUDViewDidCompleteDrop(self)
        } else {
            print("[CursorDeck] Drop not accepted natively (raw=\(operation.rawValue))")
            delegate?.deckHUDViewDidCancelDrop(self)
        }
    }

    /// Shows instant feedback on the pill when clicked to copy
    private var copiedFeedbackToken = 0

    public func showCopiedFeedback() {
        triggerCaptureGlowAnimation()
        // AUDIT: the old version remembered the *displayed* text and restored it later. Clicking twice
        // within 1.2s remembered "✓" itself and left the pill stuck on ✓; a copy during the 1.2s restored a
        // stale count. Restore the live count instead, and let only the latest click's timer act.
        copiedFeedbackToken &+= 1
        let token = copiedFeedbackToken
        countLabel.stringValue = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.copiedFeedbackToken == token else { return }
            self.countLabel.stringValue = "\(self.queueManager?.count ?? 0)"
        }
    }

    private func appendDragLog(_ message: String) {
        // AUDIT: was /private/tmp/cursor-deck.log (readable by other accounts); keep it in the per-user temp dir.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-deck.log").path
        guard let data = message.data(using: .utf8) else { return }
        // AUDIT: this debug log grew without bound; keep it under ~200 KB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), size > 200_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

