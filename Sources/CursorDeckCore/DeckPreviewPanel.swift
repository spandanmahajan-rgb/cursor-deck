import AppKit
import Foundation

/// Fluid frosted-glass grid showing everything in the deck.
/// The pill seamlessly expands into this preview deck, and collapses back when dismissed.
/// Closes on: ⌥ + click, clicking outside, cursor wandering away (>90pt), or deck emptying.
public final class DeckPreviewPanel: NSPanel {
    private let glassView = NSVisualEffectView()
    private let contentContainer = NSView()
    private weak var queueManager: DeckQueueManager?

    public var onClose: (() -> Void)?
    private var clickOutsideMonitor: Any?
    private var isClosing = false
    private var openedAt: TimeInterval = 0

    private let thumbnailSize: CGFloat = 58.0
    private let gutter: CGFloat = 8.0
    private let padding: CGFloat = 8.0
    private let dismissDistance: CGFloat = 90.0

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        setupGlassSurface()
    }

    deinit { removeClickOutsideMonitor() }

    private func setupGlassSurface() {
        glassView.material = .hudWindow
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 16.0
        glassView.layer?.masksToBounds = true
        glassView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        glassView.layer?.borderWidth = 1.0
        glassView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.62).cgColor
        contentView = glassView

        contentContainer.wantsLayer = true
        contentContainer.autoresizingMask = []
        contentContainer.frame = glassView.bounds
        glassView.addSubview(contentContainer)
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && event.modifierFlags.contains(.option) {
            close()
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Layout helpers

    private func gridMetrics(for count: Int) -> (columns: Int, size: NSSize) {
        let columns: Int
        switch count {
        case ...2:  columns = max(count, 1)
        case ...4:  columns = 2
        case ...9:  columns = 3
        case ...16: columns = 4
        case ...30: columns = 6
        default:    columns = 8
        }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let w = CGFloat(columns) * thumbnailSize + CGFloat(columns - 1) * gutter + padding * 2
        let h = CGFloat(rows) * thumbnailSize + CGFloat(rows - 1) * gutter + padding * 2
        return (columns, NSSize(width: w, height: h))
    }

    private func visibleBounds(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    // MARK: - Open / Morph / Refresh / Close

    /// Opens by smoothly expanding directly from the pill's origin frame into the full grid deck.
    public func open(from sourceRect: NSRect, queueManager: DeckQueueManager, onClose: (() -> Void)? = nil) {
        guard !queueManager.isEmpty else { return }
        self.queueManager = queueManager
        self.onClose = onClose
        isClosing = false
        openedAt = CACurrentMediaTime()

        let targetSize = gridMetrics(for: queueManager.count).size
        let bounds = visibleBounds(containing: NSPoint(x: sourceRect.midX, y: sourceRect.midY))

        // Center horizontally on the pill, clamped to screen bounds
        var targetX = sourceRect.midX - targetSize.width / 2
        targetX = max(bounds.minX + 8, min(targetX, bounds.maxX - targetSize.width - 8))

        // Blossom downwards from pill's top edge; if hitting bottom, expand upwards
        var targetY = sourceRect.maxY - targetSize.height
        if targetY < bounds.minY + 8 {
            targetY = sourceRect.minY
        }
        targetY = max(bounds.minY + 8, min(targetY, bounds.maxY - targetSize.height - 8))

        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize)

        // 1. Initial State: Identical to the pill footprint
        setFrame(sourceRect, display: true)
        glassView.layer?.cornerRadius = 14.0
        alphaValue = 1.0
        contentContainer.alphaValue = 0.0
        contentContainer.frame = NSRect(origin: .zero, size: targetSize)

        rebuildGrid()
        orderFrontRegardless()
        installClickOutsideMonitor()

        // 2. Swift, fluid expansion animation: morph from pill into deck
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            self.animator().setFrame(targetFrame, display: true)
            self.contentContainer.animator().alphaValue = 1.0
        }

        // Corner radius morph (14pt capsule -> 16pt card)
        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = 14.0
        radiusAnim.toValue = 16.0
        radiusAnim.duration = 0.20
        radiusAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
        glassView.layer?.add(radiusAnim, forKey: "expandRadius")
        glassView.layer?.cornerRadius = 16.0
    }

    /// Re-syncs the grid with the queue (new copy, ✕ delete, clear). Closes if the deck is empty.
    public func refresh() {
        guard isVisible, !isClosing else { return }
        guard let qm = queueManager, !qm.isEmpty else {
            close()
            return
        }

        let size = gridMetrics(for: qm.count).size
        let bounds = visibleBounds(containing: NSPoint(x: frame.midX, y: frame.midY))
        var x = frame.minX
        var y = frame.maxY - size.height
        x = max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8))
        y = max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8))
        let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(targetFrame, display: true)
        }

        contentContainer.frame = NSRect(origin: .zero, size: targetFrame.size)
        rebuildGrid()
    }

    private func rebuildGrid() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let queueManager = queueManager, !queueManager.isEmpty else {
            close()
            return
        }

        let items = queueManager.items
        let (columns, _) = gridMetrics(for: items.count)
        let rows = Int(ceil(Double(items.count) / Double(columns)))

        for (index, item) in items.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = padding + CGFloat(col) * (thumbnailSize + gutter)
            // Cocoa y-axis points up, so row 0 is at the top
            let y = padding + CGFloat(rows - 1 - row) * (thumbnailSize + gutter)

            let cell = PreviewThumbnailCell(
                item: item,
                frame: NSRect(x: x, y: y, width: thumbnailSize, height: thumbnailSize)
            )
            // Deleting only mutates the queue; the queue observer calls refresh() once.
            cell.onDelete = { [weak self] deleted in
                self?.queueManager?.remove(id: deleted.id)
            }
            contentContainer.addSubview(cell)
        }
    }

    /// Called every ~16ms from CursorHUDPanel's tracking timer: dismiss if the cursor wanders off.
    public func tick() {
        guard isVisible, !isClosing else { return }
        if CACurrentMediaTime() - openedAt < 0.35 { return }
        let mouse = NSEvent.mouseLocation
        if !frame.insetBy(dx: -dismissDistance, dy: -dismissDistance).contains(mouse) {
            close()
        }
    }

    public override func close() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeClickOutsideMonitor()

        // Collapse smoothly back toward center
        let collapseRect = NSRect(
            x: frame.midX - 29,
            y: frame.midY - 14,
            width: 58,
            height: 28
        )

        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = 16.0
        radiusAnim.toValue = 14.0
        radiusAnim.duration = 0.14
        radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        glassView.layer?.add(radiusAnim, forKey: "collapseRadius")
        glassView.layer?.cornerRadius = 14.0

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
            self.animator().setFrame(collapseRect, display: true)
            self.contentContainer.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.orderOut(nil)
            self.alphaValue = 1.0
            self.contentContainer.alphaValue = 1.0
            self.isClosing = false
            let cb = self.onClose
            self.onClose = nil
            cb?()
        })
    }

    // MARK: - Click-outside

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self else { return }
            if CACurrentMediaTime() - self.openedAt < 0.15 { return }
            self.close()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - Thumbnail cell

/// NSButton that fires on the first click even though the panel never becomes key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PreviewThumbnailCell: NSView {
    let item: DeckItem
    var onDelete: ((DeckItem) -> Void)?

    private let imageView = NSImageView()
    private let deleteButton = FirstMouseButton()
    private var trackingArea: NSTrackingArea?

    init(item: DeckItem, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8.0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.65).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        layer?.borderWidth = 0.5

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // AUDIT: cached downsampled thumbnail (decoded once, pre-warmed on add) instead of a full-size
        // decode on the main thread for every cell on every rebuild. Falls back exactly as before.
        imageView.image = DeckThumbnailCache.shared.thumbnail(for: item.fileURL)
            ?? NSImage(contentsOf: item.fileURL)
            ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
        addSubview(imageView)

        let btn: CGFloat = 16.0
        deleteButton.frame = NSRect(x: bounds.width - btn - 3, y: bounds.height - btn - 3, width: btn, height: btn)
        deleteButton.isBordered = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = btn / 2
        deleteButton.layer?.backgroundColor = NSColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 0.90).cgColor
        deleteButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 9, weight: .bold)
            ]
        )
        deleteButton.alphaValue = 0.0
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        addSubview(deleteButton)
    }

    @objc private func deleteClicked() { onDelete?(item) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; deleteButton.animator().alphaValue = 1.0 }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; deleteButton.animator().alphaValue = 0.0 }
    }
}

