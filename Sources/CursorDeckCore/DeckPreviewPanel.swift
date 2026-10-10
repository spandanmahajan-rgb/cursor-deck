// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// The deck preview (⌥-click on the pill). Same design system as the Pinterest board picker: native popover glass,
/// a title header, and a grid of uniform square, aspect-filled thumbnails. Opens out of the pill's left corner and
/// collapses back into it. Closes on: ⌥ + click, clicking outside, cursor wandering away (>90pt), or deck emptying.
public final class DeckPreviewPanel: NSPanel {
    // Shared metrics with BoardPickerPanel so the two read as one family.
    private static let tile: CGFloat = 72
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 16
    private static let headerHeight: CGFloat = 56
    private static let cornerRadius: CGFloat = 14
    private static let maxColumns = 5
    private static let morphCurve = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

    /// Clips everything to the rounded shape while the panel morphs to and from the pill.
    private let morphContainer = NSView()
    /// The same material a native popover uses (blending stays .withinWindow per project invariant).
    private let glassView = NSVisualEffectView()
    /// Header + grid, laid out at the final size and pinned top-left so nothing re-lays out mid-morph.
    private let contentContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "Deck")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let gridView = FlippedView()
    private weak var queueManager: DeckQueueManager?

    public var onClose: (() -> Void)?
    /// Where to collapse to on close (the pill's frame). Falls back to a pill-sized rect at the grid's centre.
    public var collapseTarget: (() -> NSRect?)?
    private var clickOutsideMonitor: Any?
    private var isClosing = false
    private var openedAt: TimeInterval = 0
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

        setupViews()
    }

    deinit { removeClickOutsideMonitor() }

    private func setupViews() {
        morphContainer.wantsLayer = true
        morphContainer.layer?.masksToBounds = true
        morphContainer.layer?.cornerCurve = .continuous
        morphContainer.layer?.cornerRadius = Self.cornerRadius
        contentView = morphContainer

        glassView.material = .popover
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.autoresizingMask = [.width, .height]
        morphContainer.addSubview(glassView)

        contentContainer.autoresizingMask = [.maxXMargin, .minYMargin]   // pinned top-left while the panel morphs
        morphContainer.addSubview(contentContainer)

        titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            contentContainer.addSubview(label)
        }
        separator.boxType = .separator
        contentContainer.addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        OverlayScrollers.enforce(on: scrollView)   // thin floating scroll bar; no track taking width
        scrollView.documentView = gridView
        contentContainer.addSubview(scrollView)
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

    // MARK: - Layout

    private struct Layout {
        let columns: Int
        let rows: Int
        let size: NSSize          // whole panel
        let gridHeight: CGFloat   // visible grid area
        let scrolls: Bool
    }

    /// 3–5 columns (narrow decks don't get a header squeezed into one column), up to 4½ rows visible
    /// before the grid scrolls (the half row signals it), exactly like the board picker.
    private func layout(for count: Int) -> Layout {
        let columns = min(max(count, 3), Self.maxColumns)
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let scrolls = rows > 4
        let visibleRows: CGFloat = scrolls ? 4.5 : CGFloat(rows)
        let gridHeight = visibleRows * Self.tile + (ceil(visibleRows) - 1) * Self.gap + Self.inset * 2
        // Overlay scroll bars float over the grid's 16pt margin, so no width is reserved for them.
        let width = CGFloat(columns) * Self.tile + CGFloat(columns - 1) * Self.gap + Self.inset * 2
        let height = Self.headerHeight + 1 + gridHeight
        return Layout(columns: columns, rows: rows, size: NSSize(width: width, height: height),
                      gridHeight: gridHeight, scrolls: scrolls)
    }

    private func visibleBounds(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Lays out header + grid inside `contentContainer` for `layout` (container coordinates, y up).
    private func layoutContent(_ layout: Layout) {
        let size = layout.size
        let headerTop = size.height
        titleLabel.sizeToFit()
        subtitleLabel.sizeToFit()
        let textWidth = size.width - Self.inset * 2
        let titleH = titleLabel.frame.height, subH = subtitleLabel.frame.height
        let blockH = titleH + 2 + subH
        let blockTop = headerTop - (Self.headerHeight - blockH) / 2
        titleLabel.frame = NSRect(x: Self.inset, y: blockTop - titleH, width: textWidth, height: titleH)
        subtitleLabel.frame = NSRect(x: Self.inset, y: blockTop - titleH - 2 - subH, width: textWidth, height: subH)
        separator.frame = NSRect(x: 0, y: headerTop - Self.headerHeight - 1, width: size.width, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: size.width, height: layout.gridHeight)
    }

    private func rebuildGrid(_ layout: Layout) {
        gridView.subviews.forEach { $0.removeFromSuperview() }
        guard let queueManager = queueManager, !queueManager.isEmpty else { return }
        let items = queueManager.items
        let count = items.count
        subtitleLabel.stringValue = count == 1 ? "1 item" : "\(count) items"

        // Fixed 72pt tiles; the overlay scroll bar floats in the right margin rather than taking width.
        let tile = Self.tile
        let docHeight = CGFloat(layout.rows) * tile + CGFloat(layout.rows - 1) * Self.gap + Self.inset * 2
        let gridWidth = CGFloat(layout.columns) * tile + CGFloat(layout.columns - 1) * Self.gap + Self.inset * 2
        gridView.frame = NSRect(x: 0, y: 0, width: gridWidth, height: max(docHeight, layout.gridHeight))

        for (index, item) in items.enumerated() {
            let col = index % layout.columns, row = index / layout.columns
            let cell = PreviewThumbnailCell(
                item: item, position: index + 1, total: count,
                frame: NSRect(x: Self.inset + CGFloat(col) * (tile + Self.gap),
                              y: Self.inset + CGFloat(row) * (tile + Self.gap),   // flipped: row 0 at the top
                              width: tile, height: tile)
            )
            // Deleting only mutates the queue; the queue observer calls refresh() once.
            cell.onDelete = { [weak self] deleted in self?.queueManager?.remove(id: deleted.id) }
            gridView.addSubview(cell)
        }
    }

    // MARK: - Open / Morph / Refresh / Close

    /// Opens by growing out of the pill's left corner into the full preview.
    public func open(from sourceRect: NSRect, queueManager: DeckQueueManager, onClose: (() -> Void)? = nil) {
        guard !queueManager.isEmpty else { return }
        self.queueManager = queueManager
        self.onClose = onClose
        isClosing = false
        openedAt = CACurrentMediaTime()

        let layout = self.layout(for: queueManager.count)
        let targetSize = layout.size
        let bounds = visibleBounds(containing: NSPoint(x: sourceRect.midX, y: sourceRect.midY))

        // Left-anchored on the pill (same left and top edge), growing right and down; clamped to the screen.
        var targetX = sourceRect.minX
        targetX = max(bounds.minX + 8, min(targetX, bounds.maxX - targetSize.width - 8))
        var targetY = sourceRect.maxY - targetSize.height
        if targetY < bounds.minY + 8 { targetY = sourceRect.minY }
        targetY = max(bounds.minY + 8, min(targetY, bounds.maxY - targetSize.height - 8))
        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? targetFrame : sourceRect
        setFrame(start, display: false)
        glassView.frame = morphContainer.bounds
        contentContainer.frame = NSRect(x: 0, y: start.height - targetSize.height,
                                        width: targetSize.width, height: targetSize.height)
        layoutContent(layout)
        rebuildGrid(layout)
        scrollView.contentView.scroll(to: .zero)
        if layout.scrolls { scrollView.flashScrollers() }   // briefly show the bar so it's clear the grid scrolls

        contentContainer.alphaValue = reduceMotion ? 1 : 0
        alphaValue = reduceMotion ? 0 : 1
        hasShadow = false
        orderFrontRegardless()
        installClickOutsideMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.15 : 0.24
            context.timingFunction = Self.morphCurve
            self.animator().setFrame(targetFrame, display: true)
            self.animator().alphaValue = 1
            self.contentContainer.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.hasShadow = true
            self?.invalidateShadow()
        })
    }

    /// Re-syncs the grid with the queue (new copy, ✕ delete, clear). Closes if the deck is empty.
    public func refresh() {
        guard isVisible, !isClosing else { return }
        guard let qm = queueManager, !qm.isEmpty else {
            close()
            return
        }

        let layout = self.layout(for: qm.count)
        let size = layout.size
        let bounds = visibleBounds(containing: NSPoint(x: frame.midX, y: frame.midY))
        var x = frame.minX
        var y = frame.maxY - size.height   // keep the top edge where it is
        x = max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8))
        y = max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8))
        let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        // Top-aligned against the current height; autoresizing lands it at y = 0 when the resize finishes.
        contentContainer.frame = NSRect(x: 0, y: frame.height - size.height, width: size.width, height: size.height)
        layoutContent(layout)
        rebuildGrid(layout)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in self?.invalidateShadow() })
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

    /// Collapses back into the pill (or, with Reduce Motion, fades out in place).
    public override func close() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeClickOutsideMonitor()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pill = collapseTarget?()
        let collapseRect = reduceMotion ? frame : (pill ?? NSRect(x: frame.minX, y: frame.maxY - 28, width: 58, height: 28))
        hasShadow = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.4)   // accelerate into the pill
            self.animator().setFrame(collapseRect, display: true)
            self.contentContainer.animator().alphaValue = 0
            // Into the pill: stay opaque so the pill takes over seamlessly. Otherwise fade away.
            if pill == nil || reduceMotion { self.animator().alphaValue = 0 }
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

/// Grid document view with row 0 at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Thumbnail cell

/// NSButton that fires on the first click even though the panel never becomes key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One deck item: a square, aspect-filled thumbnail (like the board picker's tiles). Hover shows a remove button.
final class PreviewThumbnailCell: NSView {
    let item: DeckItem
    private let position: Int
    private let total: Int
    var onDelete: ((DeckItem) -> Void)?

    private let imageLayer = CALayer()
    private let deleteButton = FirstMouseButton()
    private var gifTag: NSTextField?
    private var trackingArea: NSTrackingArea?

    init(item: DeckItem, position: Int, total: Int, frame: NSRect) {
        self.item = item
        self.position = position
        self.total = total
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        // Aspect-fill: every tile is a uniform square crop, whatever the image's proportions.
        imageLayer.frame = bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        // AUDIT: cached downsampled thumbnail (decoded once, pre-warmed on add) instead of a full-size decode.
        let image = DeckThumbnailCache.shared.thumbnail(for: item.fileURL)
            ?? NSImage(contentsOf: item.fileURL)
            ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
        imageLayer.contents = image
        layer?.addSublayer(imageLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image \(position) of \(total)")

        if item.fileURL.pathExtension.lowercased() == "gif" {
            let tag = Self.badgeLabel("GIF")
            tag.frame.origin = NSPoint(x: 4, y: 4)
            addSubview(tag)
            gifTag = tag
            setAccessibilityValue("Animated GIF")
        }

        // Remove button: same neutral dark badge style as the picker's tags (not an iOS-style red circle).
        let size: CGFloat = 18
        deleteButton.frame = NSRect(x: bounds.width - size - 4, y: bounds.height - size - 4, width: size, height: size)
        deleteButton.isBordered = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = size / 2
        deleteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        deleteButton.title = ""
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        deleteButton.imagePosition = .imageOnly
        deleteButton.contentTintColor = .white
        deleteButton.setAccessibilityLabel("Remove image \(position)")
        deleteButton.toolTip = "Remove from the deck"
        deleteButton.alphaValue = 0.0
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        addSubview(deleteButton)
    }

    /// Small white-on-dark capsule label, matching the board picker's "In deck" tag.
    private static func badgeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.sizeToFit()
        label.frame.size = NSSize(width: label.frame.width + 10, height: label.frame.height + 2)
        label.layer?.cornerRadius = label.frame.height / 2
        label.setAccessibilityElement(false)
        return label
    }

    override func updateLayer() {
        // Hairline + placeholder follow light/dark appearance (resolved here, where the appearance is current).
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
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
