// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import AVFoundation

/// The part of a video a GIF is made from. Start and end move independently; the length stays within the limits.
public struct GIFSegment: Equatable {
    /// Shortest GIF: a few frames at 14 fps, anything shorter barely reads as motion.
    public static let minLength = 0.5
    /// Longest GIF: twice the instant 4 s. The converter holds every frame in memory before encoding (up to ~1 MB each
    /// at 500 px, so ~110 MB at 8 s) and the GIF's file size doubles too (Slides refuses images over 50 MB).
    public static let maxLength = 8.0

    public let sourceDuration: Double
    public private(set) var start: Double
    public private(set) var end: Double
    public var length: Double { end - start }

    private var shortest: Double { min(Self.minLength, sourceDuration) }
    private var longest: Double { min(Self.maxLength, sourceDuration) }

    /// Defaults to what the instant GIF shows: the first 4 seconds.
    public init(sourceDuration: Double, start: Double = 0, length: Double = 4) {
        let duration = max(0, sourceDuration)
        self.sourceDuration = duration
        self.start = min(max(start, 0), max(0, duration - min(Self.minLength, duration)))
        self.end = self.start
        moveEnd(to: self.start + length)
    }

    /// Moves the start, stopping where the part would get too short or too long (the end stays put).
    public mutating func moveStart(to time: Double) {
        start = min(max(time, 0, end - longest), max(0, end - shortest))
    }

    /// Moves the end, stopping where the part would get too short or too long (the start stays put).
    public mutating func moveEnd(to time: Double) {
        end = max(min(time, sourceDuration, start + longest), min(sourceDuration, start + shortest))
    }

    /// Moves the whole part, keeping its length exactly, clamped to the video.
    public mutating func slide(toStart time: Double) {
        let length = self.length
        start = min(max(time, 0), sourceDuration - length)
        end = start + length
    }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public var isValid: Bool {
        sourceDuration > 0 && start >= 0 && end <= sourceDuration + 0.001
            && length >= shortest - 0.001 && length <= longest + 0.001
    }

    /// "0:02.4", "1:05.0".
    public static func timeLabel(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths % 600) / 10, tenths % 10)
    }

    /// "4.0 s".
    public static func lengthLabel(_ seconds: Double) -> String { String(format: "%.1f s", seconds) }
}

/// What a press on the filmstrip grabs. Handles win over everything (the nearer one when a short part puts them
/// together), then the playhead line, then the chosen part's body; anywhere else seeks.
public enum GIFTimelineTarget: Equatable {
    case startHandle, endHandle, playhead, range, seek

    /// Handles are drawn `handleWidth` wide outside the part; their hit areas reach 4 pt further each way, so they're
    /// easy to catch without looking bigger. The playhead catches ±4 pt.
    public static func at(_ x: CGFloat, startX: CGFloat, endX: CGFloat, playheadX: CGFloat?,
                          handleWidth: CGFloat = 10) -> GIFTimelineTarget {
        let slop: CGFloat = 4
        let onStart = x >= startX - handleWidth - slop && x <= startX + slop
        let onEnd = x >= endX - slop && x <= endX + handleWidth + slop
        if onStart && onEnd {
            return abs(x - (startX - handleWidth / 2)) <= abs(x - (endX + handleWidth / 2)) ? .startHandle : .endHandle
        }
        if onStart { return .startHandle }
        if onEnd { return .endHandle }
        if let px = playheadX, abs(x - px) <= slop { return .playhead }
        return x > startX && x < endX ? .range : .seek
    }
}

public enum GIFSegmentEditing {
    /// Makes a GIF of `segment` from the item's whole source video, then swaps it into Que in place. The original GIF is
    /// untouched until the new one exists. `completion` (main queue) gets the updated item, or nil when the conversion
    /// failed or the item left Que meanwhile (cleared, removed), in which case nothing changed.
    public static func replaceGIF(of id: UUID, in queueManager: DeckQueueManager, segment: GIFSegment,
                                  completion: @escaping (DeckItem?) -> Void) {
        guard segment.isValid, let source = queueManager.items.first(where: { $0.id == id })?.sourceVideoURL else {
            completion(nil); return
        }
        VideoToGIFConverter.shared.convert(videoURL: source, start: segment.start, maxDuration: segment.length) {
            [weak queueManager] data, _ in
            completion(data.flatMap { queueManager?.replaceImage(of: id, with: $0, extension: "gif") })
        }
    }

    /// Whether `item` gets the edit button: a GIF whose whole video is still on disk.
    public static func canEdit(_ item: DeckItem) -> Bool {
        guard item.fileURL.pathExtension.lowercased() == "gif", let source = item.sourceVideoURL else { return false }
        return FileManager.default.fileExists(atPath: source.path)
    }
}

// MARK: - Editor view

/// The preview panel's temporary "Edit GIF" state: the video looping the chosen part, a filmstrip of the whole video
/// with start/end handles, and Cancel / Update GIF in the header (same metrics as the grid's header).
final class GIFSegmentEditorView: NSView {
    static let size = NSSize(width: 404, height: 389)
    private static let inset: CGFloat = 16
    private static let headerHeight: CGFloat = 56

    let item: DeckItem
    var onCancel: (() -> Void)?
    var onConfirm: ((GIFSegment) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Edit GIF")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let cancelButton = PanelPushButton(isPrimary: false)
    private let confirmButton = PanelPushButton(isPrimary: true)
    private let videoView = NSView()
    private let playerLayer = AVPlayerLayer()
    private let timeline = SegmentTimelineView()
    private let playButton = FirstMouseButton()
    private let startLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")
    private let endLabel = NSTextField(labelWithString: "")

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var generator: AVAssetImageGenerator?
    private var segment: GIFSegment?
    private var isPlaying = true
    private var isProcessing = false
    private var isTornDown = false
    private static let hint = "Drag the edges to choose a moment"

    init(item: DeckItem) {
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setupViews()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        let size = Self.size, inset = Self.inset
        titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = Self.hint
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            addSubview(label)
        }

        for (button, title, action) in [
            (confirmButton, "Update GIF", #selector(confirmClicked)),
            (cancelButton, "Cancel", #selector(cancelClicked)),
        ] {
            button.title = title
            button.target = self
            button.action = action
            button.sizeToFit()
            addSubview(button)
        }
        confirmButton.toolTip = "Replace the GIF in Que with this part"
        confirmButton.isEnabled = false   // until the video has loaded

        // Header, laid out like DeckPreviewPanel.layoutContent.
        let headerTop = size.height, midY = headerTop - Self.headerHeight / 2
        var x = size.width - inset
        for button in [confirmButton, cancelButton] {
            let h = button.frame.height
            button.frame.origin = NSPoint(x: x - button.frame.width, y: (midY - h / 2).rounded())
            x -= button.frame.width + 8
        }
        let textWidth = x - inset
        let titleH = titleLabel.frame.height, subH = subtitleLabel.frame.height
        let blockTop = headerTop - (Self.headerHeight - titleH - 2 - subH) / 2
        titleLabel.frame = NSRect(x: inset, y: blockTop - titleH, width: textWidth, height: titleH)
        subtitleLabel.frame = NSRect(x: inset, y: blockTop - titleH - 2 - subH, width: textWidth, height: subH)
        separator.boxType = .separator
        separator.frame = NSRect(x: 0, y: headerTop - Self.headerHeight - 1, width: size.width, height: 1)
        addSubview(separator)

        // Bottom up: time row 18, filmstrip 44, video fills the rest.
        let timeRowY = inset, stripY = timeRowY + 18 + 6, videoY = stripY + 44 + 12
        videoView.frame = NSRect(x: inset, y: videoY, width: size.width - inset * 2,
                                 height: separator.frame.minY - inset - videoY)
        videoView.wantsLayer = true
        videoView.layer?.cornerRadius = 6
        videoView.layer?.cornerCurve = .continuous
        videoView.layer?.masksToBounds = true
        videoView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = videoView.bounds
        videoView.layer?.addSublayer(playerLayer)
        videoView.setAccessibilityElement(true)
        videoView.setAccessibilityRole(.image)
        videoView.setAccessibilityLabel("Video preview")
        addSubview(videoView)

        // The handles stick out 10 pt beyond the filmstrip, so the strip lines up with the video.
        timeline.frame = NSRect(x: inset - SegmentTimelineView.handleWidth, y: stripY,
                                width: size.width - (inset - SegmentTimelineView.handleWidth) * 2, height: 44)
        timeline.onChange = { [weak self] edge, time in self?.timelineChanged(edge, time: time) }
        timeline.onDragEnded = { [weak self] edge in self?.timelineDragEnded(edge) }
        addSubview(timeline)

        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.contentTintColor = .secondaryLabelColor
        playButton.target = self
        playButton.action = #selector(playClicked)
        playButton.frame = NSRect(x: inset - 3, y: timeRowY - 1, width: 20, height: 20)
        addSubview(playButton)
        updatePlayButton()

        let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                       weight: .regular)
        for (label, alignment) in [(startLabel, NSTextAlignment.left), (lengthLabel, .center), (endLabel, .right)] {
            label.font = digits
            label.textColor = .secondaryLabelColor
            label.alignment = alignment
            addSubview(label)
        }
        lengthLabel.textColor = .labelColor
        let rowWidth = size.width - inset * 2 - 22
        startLabel.frame = NSRect(x: inset + 22, y: timeRowY, width: rowWidth / 3, height: 18)
        lengthLabel.frame = NSRect(x: inset + 22 + rowWidth / 3, y: timeRowY, width: rowWidth / 3, height: 18)
        endLabel.frame = NSRect(x: inset + 22 + rowWidth * 2 / 3, y: timeRowY, width: rowWidth / 3, height: 18)
    }

    // MARK: Loading

    private func load() {
        guard let source = item.sourceVideoURL else { showLoadFailure(); return }
        let asset = AVURLAsset(url: source)
        Task { [weak self] in
            do {
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                var aspect: CGFloat = 16 / 9
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let shown = CGRect(origin: .zero, size: natural).applying(transform)
                    if shown.height > 0 { aspect = abs(shown.width / shown.height) }
                }
                await MainActor.run { self?.didLoad(asset: asset, duration: duration, aspect: aspect) }
            } catch {
                await MainActor.run { self?.showLoadFailure() }
            }
        }
    }

    private func didLoad(asset: AVURLAsset, duration: Double, aspect: CGFloat) {
        guard !isTornDown else { return }
        guard duration.isFinite, duration > 0 else { showLoadFailure(); return }
        let segment = GIFSegment(sourceDuration: duration)
        self.segment = segment
        timeline.segment = segment
        updateLabels()
        confirmButton.isEnabled = !isProcessing

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        self.player = player
        // Loops the chosen part; the playhead follows along on the filmstrip.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            guard let self = self, let player = self.player, let segment = self.segment, !self.timeline.isDragging else { return }
            let seconds = CMTimeGetSeconds(time)
            self.timeline.playhead = seconds
            if self.isPlaying && (seconds >= segment.end - 0.02 || seconds < segment.start - 0.1 || player.rate == 0) {
                self.playSegmentFromStart()
            }
        }
        playSegmentFromStart()
        makeThumbnails(asset: asset, duration: duration, aspect: aspect)
    }

    /// Filmstrip frames, decoded in the background at strip size (never the whole video, never full-size frames).
    private func makeThumbnails(asset: AVURLAsset, duration: Double, aspect: CGFloat) {
        let strip = timeline.stripRect
        let slotWidth = min(max(strip.height * aspect, 16), 120)
        let count = max(1, Int(ceil(strip.width / slotWidth)))
        timeline.thumbnails = Array(repeating: nil, count: count)
        let step = duration / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: slotWidth * 2, height: strip.height * 2)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        self.generator = generator
        let times = (0..<count).map { NSValue(time: CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600)) }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            guard let image = image else { return }
            let index = Int(CMTimeGetSeconds(requested) / step)
            DispatchQueue.main.async { self?.timeline.setThumbnail(image, at: index) }
        }
    }

    private func showLoadFailure() {
        showError("This video can't be opened. Copy the link again to make a new GIF.")
        confirmButton.isEnabled = false
    }

    // MARK: Playback

    private func playSegmentFromStart() {
        guard let segment = segment else { return }
        play(from: segment.start)
    }

    private func play(from time: Double) {
        guard let player = player else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying { player.play() }
    }

    @objc private func playClicked() {
        isPlaying.toggle()
        updatePlayButton()
        if isPlaying { playSegmentFromStart() } else { player?.pause() }
    }

    private func updatePlayButton() {
        let name = isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .callout))
        let label = isPlaying ? "Pause" : "Play"
        playButton.setAccessibilityLabel(label)
        playButton.toolTip = label
    }

    /// While dragging, the video shows the frame under whatever moves; scrubbing shows its time in the middle label.
    private func timelineChanged(_ edge: SegmentTimelineView.Edge, time: Double) {
        player?.pause()
        if edge == .playhead {
            lengthLabel.stringValue = GIFSegment.timeLabel(time)
            lengthLabel.setAccessibilityLabel("At \(lengthLabel.stringValue)")
        } else {
            segment = timeline.segment
            updateLabels()
        }
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Playing: carries on from the playhead if it's inside the part, otherwise loops the part from its start.
    /// Paused: stays on the frame that was last shown.
    private func timelineDragEnded(_ edge: SegmentTimelineView.Edge) {
        updateLabels()
        guard isPlaying, let segment = segment else { return }
        if edge == .playhead && segment.contains(timeline.playhead) { play(from: timeline.playhead) } else { playSegmentFromStart() }
    }

    private func updateLabels() {
        guard let segment = segment else { return }
        startLabel.stringValue = GIFSegment.timeLabel(segment.start)
        endLabel.stringValue = GIFSegment.timeLabel(segment.end)
        lengthLabel.stringValue = GIFSegment.lengthLabel(segment.length)
        startLabel.setAccessibilityLabel("Starts at \(startLabel.stringValue)")
        endLabel.setAccessibilityLabel("Ends at \(endLabel.stringValue)")
        lengthLabel.setAccessibilityLabel("\(lengthLabel.stringValue) long")
    }

    // MARK: Confirm / cancel

    @objc private func confirmClicked() {
        guard !isProcessing, let segment = segment, segment.isValid else { return }
        onConfirm?(segment)
    }

    @objc private func cancelClicked() {
        guard !isProcessing else { return }
        onCancel?()
    }

    /// While the new GIF is being made nothing can be changed or confirmed twice.
    func setProcessing(_ processing: Bool) {
        isProcessing = processing
        confirmButton.isEnabled = !processing && segment != nil
        cancelButton.isEnabled = !processing
        timeline.isEnabled = !processing
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = processing ? "Making the new GIF…" : Self.hint
    }

    func showError(_ text: String) {
        subtitleLabel.textColor = .systemRed
        subtitleLabel.stringValue = text
        subtitleLabel.toolTip = text
    }

    /// Stops playback and thumbnail decoding. Safe to call more than once.
    func tearDown() {
        isTornDown = true
        generator?.cancelAllCGImageGeneration()
        generator = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player?.pause()
        playerLayer.player = nil
        player = nil
    }
}

// MARK: - Filmstrip

/// The whole video as a filmstrip. The chosen part is framed in the accent colour with a handle on each side; the rest
/// is dimmed. Drag a handle to move that edge, drag the part to move it whole, drag the playhead (or anywhere outside the
/// part) to scrub, click to look at that moment.
final class SegmentTimelineView: NSView {
    enum Edge { case start, end, range, playhead }
    static let handleWidth: CGFloat = 10

    var segment: GIFSegment? { didSet { updateAccessibilityFrames(); needsDisplay = true } }
    var playhead: Double = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    var thumbnails: [CGImage?] = [] { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { if !isEnabled { endDrag(notify: false) }; needsDisplay = true } }
    var onChange: ((Edge, Double) -> Void)?
    var onDragEnded: ((Edge) -> Void)?
    /// True from press to release (the player stops moving the playhead meanwhile).
    private(set) var isDragging = false
    private var dragEdge: Edge?
    /// A press on the part's body: a click seeks, a drag past 3 pt moves the part.
    private var pendingRangePress: (x: CGFloat, time: Double)?
    /// Where the grab point sits relative to what's dragged, in points or seconds, so nothing jumps on the first move.
    private var grabOffset: CGFloat = 0
    private var grabTimeOffset: Double = 0
    private var hover: GIFTimelineTarget? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private lazy var handleElements = [Edge.start, .end].map { HandleElement(timeline: self, edge: $0) }

    var stripRect: NSRect { bounds.insetBy(dx: Self.handleWidth, dy: 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setThumbnail(_ image: CGImage, at index: Int) {
        guard thumbnails.indices.contains(index) else { return }
        thumbnails[index] = image
    }

    private func x(for time: Double) -> CGFloat {
        guard let duration = segment?.sourceDuration, duration > 0 else { return stripRect.minX }
        return stripRect.minX + CGFloat(time / duration) * stripRect.width
    }

    private func time(at x: CGFloat) -> Double {
        guard let duration = segment?.sourceDuration, stripRect.width > 0 else { return 0 }
        return Double(min(max((x - stripRect.minX) / stripRect.width, 0), 1)) * duration
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let strip = stripRect

        context.saveGState()
        context.addPath(CGPath(roundedRect: strip, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.clip()
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.08).cgColor)
        context.fill(strip)
        if !thumbnails.isEmpty {
            let slot = strip.width / CGFloat(thumbnails.count)
            for (i, image) in thumbnails.enumerated() {
                guard let image = image else { continue }
                let cell = NSRect(x: strip.minX + CGFloat(i) * slot, y: strip.minY, width: slot, height: strip.height)
                context.saveGState()
                context.clip(to: cell)
                // Aspect-fill each slot, like the grid's tiles.
                let scale = max(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
                let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                context.draw(image, in: NSRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h))
                context.restoreGState()
            }
        }
        guard let segment = segment else { context.restoreGState(); return }
        let startX = x(for: segment.start), endX = x(for: segment.end)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(NSRect(x: strip.minX, y: strip.minY, width: startX - strip.minX, height: strip.height))
        context.fill(NSRect(x: endX, y: strip.minY, width: strip.maxX - endX, height: strip.height))
        if hover == .range || dragEdge == .range {   // the part lifts slightly when it can be (or is being) moved
            context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            context.fill(NSRect(x: startX, y: strip.minY, width: endX - startX, height: strip.height))
        }
        context.restoreGState()

        // Accent frame with a handle on each side (even-odd: the inside stays clear).
        let hw = Self.handleWidth
        let frame = CGMutablePath()
        frame.addRoundedRect(in: NSRect(x: startX - hw, y: bounds.minY, width: endX - startX + hw * 2, height: bounds.height),
                             cornerWidth: 4, cornerHeight: 4)
        frame.addRect(NSRect(x: startX, y: bounds.minY + 2, width: max(0, endX - startX), height: bounds.height - 4))
        context.addPath(frame)
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.5).cgColor)
        context.fillPath(using: .evenOdd)
        for (gripX, target, edge) in [(startX - hw / 2, GIFTimelineTarget.startHandle, Edge.start),
                                      (endX + hw / 2, .endHandle, .end)] {
            let active = hover == target || dragEdge == edge   // the grip grows under the pointer
            let w: CGFloat = active ? 3 : 2, h: CGFloat = active ? 16 : 12
            context.setFillColor(NSColor.white.withAlphaComponent(active ? 1 : 0.85).cgColor)
            context.addPath(CGPath(roundedRect: NSRect(x: gripX - w / 2, y: bounds.midY - h / 2, width: w, height: h),
                                   cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            context.fillPath()
        }

        // Playhead: a white line with a soft dark edge and a small round cap, unlike the flat handles.
        let px = x(for: playhead)
        guard px >= strip.minX, px <= strip.maxX else { return }
        let capY = strip.maxY - 7
        let active = hover == .playhead || dragEdge == .playhead
        let cap = NSRect(x: px - 3.5, y: capY, width: 7, height: 7).insetBy(dx: active ? -1 : 0, dy: active ? -1 : 0)
        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.fill(NSRect(x: px - 1.5, y: strip.minY, width: 3, height: strip.height))
        context.fillEllipse(in: cap.insetBy(dx: -0.5, dy: -0.5))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(NSRect(x: px - 1, y: strip.minY, width: 2, height: strip.height))
        context.fillEllipse(in: cap)
    }

    // MARK: Mouse

    private func target(at x: CGFloat) -> GIFTimelineTarget? {
        guard let segment = segment else { return nil }
        let px = self.x(for: playhead)
        return GIFTimelineTarget.at(x, startX: self.x(for: segment.start), endX: self.x(for: segment.end),
                                    playheadX: px >= stripRect.minX && px <= stripRect.maxX ? px : nil,
                                    handleWidth: Self.handleWidth)
    }

    override func mouseDown(with event: NSEvent) {
        endDrag(notify: false)   // a release we never saw (e.g. the pointer left the panel mid-drag)
        guard isEnabled, let segment = segment, let target = target(at: convert(event.locationInWindow, from: nil).x) else { return }
        let px = convert(event.locationInWindow, from: nil).x
        isDragging = true
        switch target {
        case .startHandle:
            dragEdge = .start; grabOffset = x(for: segment.start) - px
        case .endHandle:
            dragEdge = .end; grabOffset = x(for: segment.end) - px
        case .playhead:
            dragEdge = .playhead; grabOffset = x(for: playhead) - px
        case .range:
            pendingRangePress = (px, time(at: px))   // click or drag: decided once the pointer moves
            grabTimeOffset = time(at: px) - segment.start
        case .seek:
            dragEdge = .playhead; grabOffset = 0
            drag(to: px)
        }
        updateCursor(for: target)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let px = convert(event.locationInWindow, from: nil).x
        if let press = pendingRangePress {
            guard abs(px - press.x) > 3 else { return }
            pendingRangePress = nil
            dragEdge = .range
            NSCursor.closedHand.set()
        }
        drag(to: px)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        if let press = pendingRangePress {   // a plain click on the part: look at that moment
            pendingRangePress = nil
            dragEdge = .playhead
            grabOffset = 0
            drag(to: press.x)
        }
        endDrag(notify: true)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func endDrag(notify: Bool) {
        guard isDragging else { return }
        let edge = dragEdge
        isDragging = false
        dragEdge = nil
        pendingRangePress = nil
        needsDisplay = true
        if notify, let edge = edge { onDragEnded?(edge) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endDrag(notify: false) }
    }

    /// Only the dragged thing moves: an edge (the other stays put), the whole part (same length), or the playhead.
    private func drag(to pointX: CGFloat) {
        guard var segment = segment, let edge = dragEdge else { return }
        let time: Double
        switch edge {
        case .start: segment.moveStart(to: self.time(at: pointX + grabOffset)); time = segment.start
        case .end: segment.moveEnd(to: self.time(at: pointX + grabOffset)); time = segment.end
        case .range: segment.slide(toStart: self.time(at: pointX) - grabTimeOffset); time = segment.start
        case .playhead:
            time = self.time(at: pointX + grabOffset)
            playhead = time
            onChange?(edge, time)
            return
        }
        self.segment = segment
        playhead = time
        onChange?(edge, time)
    }

    // MARK: Hover and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        hover = nil
        NSCursor.arrow.set()
    }

    private func updateHover(at point: NSPoint) {
        guard !isDragging else { return }
        hover = isEnabled && bounds.contains(point) ? target(at: point.x) : nil
        updateCursor(for: hover)
    }

    private func updateCursor(for target: GIFTimelineTarget?) {
        switch target {
        case .startHandle?, .endHandle?, .playhead?: NSCursor.resizeLeftRight.set()
        case .range?: (dragEdge == .range ? NSCursor.closedHand : NSCursor.openHand).set()
        default: NSCursor.arrow.set()
        }
    }

    /// VoiceOver: each handle is a slider that moves its edge by a tenth of a second.
    fileprivate func nudge(_ edge: Edge, by delta: Double) {
        guard isEnabled, var segment = segment else { return }
        if edge == .start { segment.moveStart(to: segment.start + delta) } else { segment.moveEnd(to: segment.end + delta) }
        self.segment = segment
        let time = edge == .start ? segment.start : segment.end
        playhead = time
        onChange?(edge, time)
        onDragEnded?(edge)
    }

    fileprivate func value(of edge: Edge) -> String {
        guard let segment = segment else { return "" }
        return GIFSegment.timeLabel(edge == .start ? segment.start : segment.end)
    }

    override func accessibilityChildren() -> [Any]? { segment == nil ? [] : handleElements }

    private func updateAccessibilityFrames() {
        guard let segment = segment else { return }
        let hw = Self.handleWidth
        handleElements[0].setAccessibilityFrameInParentSpace(NSRect(x: x(for: segment.start) - hw, y: 0, width: hw, height: bounds.height))
        handleElements[1].setAccessibilityFrameInParentSpace(NSRect(x: x(for: segment.end), y: 0, width: hw, height: bounds.height))
    }

    private final class HandleElement: NSAccessibilityElement {
        private weak var timeline: SegmentTimelineView?
        private let edge: Edge

        init(timeline: SegmentTimelineView, edge: Edge) {
            self.timeline = timeline
            self.edge = edge
            super.init()
            setAccessibilityParent(timeline)
            setAccessibilityRole(.slider)
            setAccessibilityLabel(edge == .start ? "Start" : "End")
        }

        override func accessibilityValue() -> Any? { timeline?.value(of: edge) }
        override func accessibilityPerformIncrement() -> Bool { timeline?.nudge(edge, by: 0.1); return true }
        override func accessibilityPerformDecrement() -> Bool { timeline?.nudge(edge, by: -0.1); return true }
    }
}
