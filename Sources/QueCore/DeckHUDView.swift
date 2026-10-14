// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
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

    /// Dark tint layered over the HUD blur. Was 52%, which hid most of the frosting; 22% keeps the white count legible
    /// (the .hudWindow material underneath is always dark) while letting the glass read like a native HUD.
    private static let glassTint = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.22)
    public var queueManager: DeckQueueManager?

    // Native Liquid Glass Visual Effect View
    private let visualEffectView = NSVisualEffectView()

    // Subviews
    private let dotView = NSView()
    private let countLabel = NSTextField(labelWithString: "0")

    // Notice (PillNotice): text that replaces the count while a message is showing.
    // The text sits at its final width inside a clip that is exactly the pill's shape, so as the pill grows from the
    // left the text is revealed left-to-right (and hidden right-to-left as it shrinks) instead of popping in.
    private let noticeClipView = NSView()
    private let noticeStack = NSStackView()
    private var noticeWidthConstraint: NSLayoutConstraint?
    private let noticeMessageLabel = NSTextField(labelWithString: "")
    private let noticeDetailLabel = NSTextField(labelWithString: "")
    /// The notice currently shown, if any. Set through `setNotice(_:)`.
    public private(set) var activeNotice: PillNotice?

    private static let emerald = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0)
    /// Notice text stops growing the pill at this width and truncates instead.
    private static let noticeMaxTextWidth: CGFloat = 260
    private static let noticeLeading: CGFloat = 21      // dot (9 + 6) + 6pt gap
    private static let noticeTrailing: CGFloat = 12

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
        layer?.backgroundColor = Self.glassTint.cgColor
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

        NSLayoutConstraint.activate([
            // [ ● 3 ]: just the status dot and the count (the 10pt logo that used to follow was too small to read
            // and carried no information). With the badge widths in CursorHUDPanel (40pt + 8pt per extra digit) the
            // visible dot-to-digits group sits centred, ~10pt from each edge (the label box is wider than its digits).
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            countLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Not required: lets the pill shrink to its 28pt dot when collapsing (the count is hidden then).
            {
                let c = countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
                c.priority = .dragThatCannotResizeWindow   // < 500, so the window doesn't treat it as a minimum size
                return c
            }()
        ])

        // 7. Notice text (hidden until a PillNotice is shown)
        for label in [noticeMessageLabel, noticeDetailLabel] {
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        noticeMessageLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        noticeMessageLabel.textColor = .white
        noticeDetailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        noticeDetailLabel.textColor = NSColor(white: 1.0, alpha: 0.72)
        noticeStack.orientation = .vertical
        noticeStack.alignment = .leading
        noticeStack.spacing = 1
        noticeStack.addArrangedSubview(noticeMessageLabel)
        noticeStack.addArrangedSubview(noticeDetailLabel)
        noticeClipView.wantsLayer = true
        noticeClipView.layer?.masksToBounds = true
        noticeClipView.autoresizingMask = [.width, .height]
        noticeClipView.frame = bounds
        addSubview(noticeClipView)

        noticeStack.translatesAutoresizingMaskIntoConstraints = false
        noticeStack.alphaValue = 0
        noticeClipView.addSubview(noticeStack)
        let width = noticeStack.widthAnchor.constraint(equalToConstant: 0)
        noticeWidthConstraint = width
        NSLayoutConstraint.activate([
            noticeStack.leadingAnchor.constraint(equalTo: noticeClipView.leadingAnchor, constant: Self.noticeLeading),
            noticeStack.centerYAnchor.constraint(equalTo: noticeClipView.centerYAnchor),
            width
        ])

        // VoiceOver: the pill is one button that announces how many items are in the deck.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Que")
        setAccessibilityValue("0 items")
        setAccessibilityHelp("Press to copy everything in Que for pasting. Option-click to preview it.")
        for subview in [dotView, countLabel, noticeClipView, noticeStack, noticeMessageLabel, noticeDetailLabel] {
            subview.setAccessibilityElement(false)
        }
    }

    /// VoiceOver "press" does what a plain click does: arms the clipboard with the whole deck.
    public override func accessibilityPerformPress() -> Bool {
        if let action = activeNotice?.primaryAction {
            action()
            return true
        }
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
        noticeClipView.frame = bounds
        noticeClipView.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layoutShinePath()
    }

    /// Tracking paused: the dot turns orange (green while active). A notice still shows its own tone colour.
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if activeNotice == nil {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.duration = 0.2
                dotView.layer?.add(fade, forKey: "pauseFade")
                dotView.layer?.backgroundColor = idleDotColor.cgColor
                setAccessibilityValue(countDescription)
            }
        }
    }

    /// "Tap ⌃ twice" mode: snapped under the pointer. Any click is then a catch (click = preview, drag = drop), like ⌥
    /// is today. Cue: a soft light runs around the glass rim. Reduce Motion: the rim just brightens.
    public var isTapSnapped = false {
        didSet { if isTapSnapped != oldValue { updateShine() } }
    }

    /// The rim light: a short bright stroke with a glow, travelling the capsule outline. The path goes round twice
    /// and the stroke moves exactly one lap, so the loop has no seam.
    private let shineLayer = CAShapeLayer()
    private static let shineLap: CFTimeInterval = 2.4
    private static let shineLength: CGFloat = 0.11   // of one lap

    private func updateShine() {
        guard let layer = layer else { return }
        if shineLayer.superlayer == nil {
            shineLayer.fillColor = nil
            shineLayer.lineWidth = 1.5
            shineLayer.lineCap = .round
            shineLayer.shadowColor = NSColor.white.cgColor
            shineLayer.shadowOffset = .zero
            shineLayer.shadowRadius = 3
            shineLayer.shadowOpacity = 0.9
            shineLayer.zPosition = 10
            layer.addSublayer(shineLayer)
        }
        shineLayer.removeAllAnimations()
        guard isTapSnapped else {
            fadeShine(to: 0)
            return
        }
        layoutShinePath()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            // Whole rim, steady: brighter than the usual hairline.
            shineLayer.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
            shineLayer.strokeStart = 0
            shineLayer.strokeEnd = 1
        } else {
            shineLayer.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
            let half = Self.shineLength / 2   // the stroke is measured on the doubled path
            shineLayer.strokeStart = 0
            shineLayer.strokeEnd = half
            let start = CABasicAnimation(keyPath: "strokeStart")
            start.fromValue = 0; start.toValue = 0.5
            let end = CABasicAnimation(keyPath: "strokeEnd")
            end.fromValue = half; end.toValue = 0.5 + half
            let lap = CAAnimationGroup()
            lap.animations = [start, end]
            lap.duration = Self.shineLap
            lap.repeatCount = .infinity
            lap.timingFunction = CAMediaTimingFunction(name: .linear)
            shineLayer.add(lap, forKey: "lap")
        }
        fadeShine(to: 1)
    }

    private func fadeShine(to opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shineLayer.presentation()?.opacity ?? shineLayer.opacity
        fade.duration = 0.2
        shineLayer.opacity = opacity
        shineLayer.add(fade, forKey: "fade")
    }

    /// Follows the pill's size (notices grow it) without restarting the lap.
    private func layoutShinePath() {
        guard shineLayer.superlayer != nil else { return }
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let radius = rect.height / 2
        let once = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let twice = CGMutablePath()
        twice.addPath(once)
        twice.addPath(once)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = bounds
        shineLayer.path = twice
        CATransaction.commit()
    }

    private var idleDotColor: NSColor {
        if isWorking { return Self.workingGrey }
        return isPaused ? .systemOrange : Self.emerald
    }

    private static let workingGrey = NSColor(white: 0.78, alpha: 1)

    /// Something is on its way into Que (a GIF being made, a pin downloading): grey dot, gently bouncing.
    /// With Reduce Motion it pulses in place instead. A notice still colours the dot while it shows.
    public var isWorking = false {
        didSet {
            guard isWorking != oldValue, let dot = dotView.layer else { return }
            if activeNotice == nil {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.duration = 0.2
                dot.add(fade, forKey: "workFade")
                dot.backgroundColor = idleDotColor.cgColor
            }
            if isWorking {
                let motion: CAKeyframeAnimation
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    motion = CAKeyframeAnimation(keyPath: "opacity")
                    motion.values = [1.0, 0.35, 1.0]
                    motion.duration = 1.2
                } else {
                    motion = CAKeyframeAnimation(keyPath: "transform.translation.y")
                    motion.values = [0, 2.5, 0]          // a small hop (layer y points up in this view)
                    motion.keyTimes = [0, 0.4, 1]
                    motion.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
                    motion.duration = 0.55
                }
                motion.repeatCount = .infinity
                dot.add(motion, forKey: "working")
            } else {
                dot.removeAnimation(forKey: "working")
            }
            setAccessibilityValue(countDescription)
        }
    }

    private var countDescription: String {
        let count = queueManager?.count ?? 0
        let items = count == 1 ? "1 item" : "\(count) items"
        if isWorking { return "Adding to Que, \(items)" }
        return isPaused ? "Paused, \(items)" : items
    }

    public func updateCount(_ count: Int, animateGlow: Bool = false) {
        countLabel.stringValue = "\(count)"
        countLabel.isHidden = count == 0   // an empty Que that's working shows just the dot
        setAccessibilityValue(countDescription)
        needsDisplay = true

        // While a notice is showing (e.g. "Adding 3 of 48") it is the feedback; skip a glow per item.
        if animateGlow && count > 0 && activeNotice == nil {
            triggerCaptureGlowAnimation()
        }
    }

    // MARK: - Notices

    private static func textWidth(for notice: PillNotice) -> CGFloat {
        let font12 = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let font11 = NSFont.systemFont(ofSize: 11, weight: .regular)
        var width = (notice.message as NSString).size(withAttributes: [.font: font12]).width
        if let detail = notice.detail {
            width = max(width, (detail as NSString).size(withAttributes: [.font: font11]).width)
        }
        return min(ceil(width) + 2, noticeMaxTextWidth)
    }

    /// Size the pill needs to show `notice` (one line: 28pt tall, with a detail line: 42pt).
    public func preferredSize(for notice: PillNotice) -> NSSize {
        let width = Self.noticeLeading + Self.textWidth(for: notice) + Self.noticeTrailing
        return NSSize(width: max(width, 58), height: notice.detail == nil ? 28 : 42)
    }

    /// Shows `notice` in place of the count (or restores the count when `nil`). The panel animates the size;
    /// the text fades in while the growing pill reveals it from the left.
    public func setNotice(_ notice: PillNotice?, restoringCount: Bool = true) {
        let wasShowing = activeNotice != nil
        activeNotice = notice
        if let notice = notice {
            noticeMessageLabel.stringValue = notice.message
            noticeDetailLabel.stringValue = notice.detail ?? ""
            noticeDetailLabel.isHidden = notice.detail == nil
            noticeWidthConstraint?.constant = Self.textWidth(for: notice)
            dotView.layer?.backgroundColor = notice.tone.dotColor.cgColor
            setAccessibilityValue(notice.spokenText)
            guard !wasShowing else { return }   // text just changed (e.g. progress): no re-fade
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                countLabel.animator().alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                noticeStack.animator().alphaValue = 1
            }
        } else {
            dotView.layer?.backgroundColor = idleDotColor.cgColor
            setAccessibilityValue(countDescription)
            // Text fades while the shrinking pill hides it right-to-left; the count comes back once it's gone
            // (unless the pill is collapsing away entirely, when there is no count to show).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                noticeStack.animator().alphaValue = 0
            }
            guard restoringCount else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 1, 1)
                countLabel.animator().alphaValue = 1
            }
        }
    }

    /// Puts the count back without animation (used after the pill collapsed away while showing a notice).
    public func restoreCountInstantly() {
        noticeStack.alphaValue = 0
        countLabel.alphaValue = 1
    }

    /// Solid shape illumination glow through native Liquid Glass
    public func triggerCaptureGlowAnimation() {
        guard let layer = self.layer else { return }

        // 1. Solid Shape Background Glow: glass tint illuminates with rich emerald
        let bgGlow = CAKeyframeAnimation(keyPath: "backgroundColor")
        bgGlow.values = [
            Self.glassTint.cgColor,
            NSColor(red: 0.12, green: 0.44, blue: 0.22, alpha: 0.88).cgColor, // Luminous emerald glass fill
            Self.glassTint.cgColor
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

        // 3. Dot Flash (not while a notice owns the dot colour)
        if activeNotice == nil, let dotLayer = dotView.layer {
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
    private var clickHadShift = false

    /// True from a mouse-down on the pill until that click or drag ends (the panel holds still meanwhile).
    public private(set) var isPressed = false

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        // A previous hold may still be settling; it belongs to that press, not this one.
        if longPress == .fired || longPress == .cancelled { longPress = .idle }
        if let notice = activeNotice, notice.hasActions {
            clickHadOption = event.modifierFlags.contains(.option) || isTapSnapped
            clickHadShift = event.modifierFlags.contains(.shift)
            dragStartScreenPoint = NSEvent.mouseLocation
            isDraggingSessionActive = false
            // Two choices (the board offer): holding the click picks the other one.
            if notice.primaryAction != nil && notice.alternateAction != nil { beginLongPress() }
            return
        }
        guard let items = queueManager?.items, !items.isEmpty else { return }
        dragStartScreenPoint = NSEvent.mouseLocation
        isDraggingSessionActive = false
        // Remember ⌥ at press time (user may release it before mouse-up)
        clickHadOption = event.modifierFlags.contains(.option) || isTapSnapped
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !isDraggingSessionActive else { return }

        let currentScreenPoint = NSEvent.mouseLocation
        let dist = hypot(currentScreenPoint.x - dragStartScreenPoint.x, currentScreenPoint.y - dragStartScreenPoint.y)

        // When ⌥ is held (the only way to catch the pill), allow a generous 20pt
        // threshold so trackpad clicks and resting fingers don't start an accidental drag.
        let isModifierHeld = event.modifierFlags.contains(.option) || isTapSnapped
            || CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
        let threshold: CGFloat = isModifierHeld ? 20.0 : 4.0

        guard dist > threshold else { return }
        // Moving off turns a hold into a drag: no "add all".
        if longPress == .waiting || longPress == .shaking { longPress = .cancelled }
        guard let items = queueManager?.items, !items.isEmpty else { return }

        isDraggingSessionActive = true
        startDragSession(with: event, items: items)
    }

    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        // If a drag session was active, AppKit handles session end via draggingSession(_:endedAt:operation:)
        guard !isDraggingSessionActive else { return }

        let press = longPress
        if press == .waiting { longPress = .idle } else if press == .shaking { longPress = .cancelled }
        // A hold that was recognised (already ran "add all"), dragged away, or let go mid-shake is not a click.
        if press == .shaking || press == .fired || press == .cancelled {
            clickHadOption = false
            clickHadShift = false
            return
        }

        // A notice with actions (e.g. the board offer) answers the click instead of the deck: ⌥-click runs the
        // first choice, ⌥-click and hold the other (⌥⇧-click still works too; ⌥-click alone when there's just one).
        if let notice = activeNotice, notice.hasActions {
            let wantsAlternate = clickHadShift || notice.primaryAction == nil
            let action = wantsAlternate ? notice.alternateAction : notice.primaryAction
            clickHadOption = false
            clickHadShift = false
            action?()
            return
        }

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

    // MARK: - Click and hold: the alternate choice (adds a whole board)

    /// `waiting`: pressed, still a plain click. `shaking`: past the threshold, Que trembles while it gets ready.
    /// `fired`: the alternate ran (once). `cancelled`: let go early or dragged; the shake settles, nothing runs.
    enum LongPress { case idle, waiting, shaking, fired, cancelled }
    private var longPress: LongPress = .idle
    static let longPressShakeAfter: TimeInterval = 0.3
    static let longPressCommitAfter: TimeInterval = 0.8
    private var longPressTimer: Timer?
    private var longPressStart: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var shakeAmplitude: CGFloat = 0   // 0...1
    private var shakePhase: CGFloat = 0
    private var shakeOffset: CGFloat = 0      // points currently added to the window's x

    private func beginLongPress() {
        longPress = .waiting
        longPressStart = ProcessInfo.processInfo.systemUptime
        lastTick = longPressStart
        guard longPressTimer == nil else { return }   // still settling from a previous hold: keep its motion
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.longPressTick() }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    /// One clock drives both the gesture and the motion, so the shake can never outlive the hold.
    private func longPressTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let held = now - longPressStart
        let dt = CGFloat(min(now - lastTick, 0.05))
        lastTick = now

        if longPress == .waiting && held >= Self.longPressShakeAfter { longPress = .shaking }
        if longPress == .shaking && held >= Self.longPressCommitAfter {
            longPress = .fired
            // The same notice check a click makes; a notice that changed under the finger runs nothing.
            if let notice = activeNotice, notice.primaryAction != nil { notice.alternateAction?() }
        }

        // Weighted: builds slowly while held, then slows and fades out once recognised or let go.
        if longPress == .shaking {
            shakeAmplitude += (1 - shakeAmplitude) * min(1, dt * 7)
        } else {
            shakeAmplitude *= pow(0.02, dt / 0.35)   // ~0.35 s to settle
        }
        shakePhase += 2 * .pi * (4 + 4 * shakeAmplitude) * dt   // 8 Hz at full, slowing to 4 Hz as it settles
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let settled = longPress != .waiting && longPress != .shaking && shakeAmplitude < 0.03
        let offset = (reduceMotion || settled) ? 0 : sin(shakePhase) * shakeAmplitude * 1.5
        // Side to side only: the window is exactly the pill's size, so a tilt would clip its corners. Applied as a
        // change, so it adds to wherever the panel puts Que and always ends exactly where it started.
        if let window = window, offset != shakeOffset {
            let base = window.frame.origin.x - shakeOffset
            window.setFrameOrigin(NSPoint(x: base + offset, y: window.frame.origin.y))
            shakeOffset = window.frame.origin.x - base   // macOS snaps windows to pixels: remember what really moved
        }

        if settled {
            longPressTimer?.invalidate()
            longPressTimer = nil
            shakeAmplitude = 0   // `fired`/`cancelled` stay until the next press, so its mouse-up is still swallowed
        }
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
        // Strictly return .copy so target apps (Google Slides, Chrome, Figma, WhatsApp) never attempt a .move.
        // ⌥ still held at the drop means "copy" to macOS, so ⌥ + drag + drop completes without letting go of ⌥
        // (owner-tested in Slides and WhatsApp). ⌘ held at the drop would mean "move" and be refused.
        return .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSessionActive = false
        isPressed = false
        let isAccepted = operation != []
        let logMsg = "[Que] Drag ended at \(screenPoint), operation raw=\(operation.rawValue), accepted=\(isAccepted)\n"
        print(logMsg)
        appendDragLog(logMsg)

        if isAccepted {
            print("[Que] Drop ACCEPTED ✓ operation=\(operation.rawValue)")
            delegate?.deckHUDViewDidCompleteDrop(self)
        } else {
            print("[Que] Drop not accepted natively (raw=\(operation.rawValue))")
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
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("que.log").path
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

