// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// The welcome + tour, shown whenever someone installs a fresh copy of Que by hand (from Que.dmg): brand-new users,
/// and returning users who deleted the app and reinstalled it. Not shown after an in-app update, or on normal launches.
public final class WelcomeWindowController: NSObject, NSWindowDelegate {
    public static let shared = WelcomeWindowController()

    /// The copy of the app that ran last (its bundle folder's file number: every installed copy gets a new one).
    static let lastCopyKey = "Que_lastLaunchedCopy"
    /// Written by Que's updater just before it swaps in a new version, so that launch doesn't count as an install.
    public static let updateInProgressKey = "Que_updateInProgress"
    /// Set once the welcome with the "How should Que come to you?" choice has been shown. People who installed before
    /// that choice existed see the welcome once after updating, so they get to pick too.
    static let callChoiceShownKey = "Que_callChoiceShown"

    /// Window content width in points; the height follows the content.
    static let width: CGFloat = 380

    private var window: NSWindow?
    /// Opens the menu bar panel (set by the app): the tour's last button sends the user there to explore.
    public var onOpenQue: (() -> Void)?

    /// Identifies this installed copy of the app, or nil when not running from an .app bundle (development builds).
    public static func currentCopyID(bundlePath: String = Bundle.main.bundlePath) -> String? {
        guard bundlePath.hasSuffix(".app"),
              let number = (try? FileManager.default.attributesOfItem(atPath: bundlePath))?[.systemFileNumber] as? NSNumber
        else { return nil }
        return number.stringValue
    }

    /// Call once at launch. True when this copy was just installed by hand (new or returning user), or on the first
    /// update since the call-over choice was added; false for normal launches and other in-app updates. Records the
    /// copy and clears the update note.
    public static func shouldShowWelcome(copyID: String?, defaults: UserDefaults = .standard) -> Bool {
        let wasUpdate = defaults.object(forKey: updateInProgressKey) != nil
        defaults.removeObject(forKey: updateInProgressKey)
        guard let copyID = copyID, copyID != defaults.string(forKey: lastCopyKey) else { return false }
        defaults.set(copyID, forKey: lastCopyKey)
        let hasSeenChoice = defaults.bool(forKey: callChoiceShownKey)
        defaults.set(true, forKey: callChoiceShownKey)
        return !wasUpdate || !hasSeenChoice
    }

    public func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WelcomeView(
            onStart: { [weak self] in self?.window?.close() },
            onOpenQue: { [weak self] in
                self?.window?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.onOpenQue?() }
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Que"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = hosting
        window.delegate = self
        // On the screen the pointer is on (where the user is looking), a little above centre. `center()` picked
        // the other display on a two-screen Mac, where the window ended up out of sight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                          y: (area.minY + (area.height - size.height) * 0.6).rounded()))
        } else {
            window.center()
        }
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Welcome + tour

/// Page 0 is the welcome; "Start Queing" walks through a short tour: copy, choose how Que comes to you, practise the
/// moves with the real keys, then the menu bar.
struct WelcomeView: View {
    var onStart: () -> Void            // closes the window (close button / finished)
    var onOpenQue: () -> Void = {}     // last page: close and open the menu bar panel
    @State private var page = 0
    @State private var forward = true
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    /// The logo animation plays once per window; coming back to this page shows the finished logo and text.
    @State private var introPlayed = false
    @State private var textVisible = false
    /// How Que comes to the user (QueControls); the tour only ever shows this way.
    @State private var usesDoubleTap = QueControls.usesDoubleTap
    @StateObject private var practice = TourPractice()
    @State private var practiced: Set<TourPage> = []
    @State private var hintPage: TourPage?
    @State private var dragOffset: CGSize = .zero
    @State private var isDraggingBadge = false
    @State private var isOverSlide = false
    @State private var landed = false
    @State private var gridOpen = false
    @State private var shaken = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onStart: @escaping () -> Void, onOpenQue: @escaping () -> Void = {}, initialPage: Int = 0) {
        self.onStart = onStart
        self.onOpenQue = onOpenQue
        self._page = State(initialValue: initialPage)
    }

    static let height: CGFloat = 410

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private func go(to newPage: Int) {
        guard newPage >= 0, newPage <= Self.tourCount, newPage != page else { return }
        forward = newPage > page
        withAnimation(animation) { page = newPage }
    }

    var body: some View {
        ZStack {
            Group {
                if page == 0 { welcomePage } else { tourPage(page) }
            }
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .frame(width: WelcomeWindowController.width, height: Self.height)
        // After the frame: the pages are only as wide as their text, so an overlay on them would shift with the text.
        .overlay(alignment: .bottom) { if page > 0 { tourNav(page) } }
        .clipped()
        .background(keyboardShortcuts)
        .onAppear { practice.start() }
        .onDisappear { practice.stop() }
        .onChange(of: page) { practice.watchesShake = $0 == TourPage.shake.rawValue }
        .onChange(of: practice.isCatching) { caught in
            if caught && page == TourPage.callOver.rawValue { practiced.insert(.callOver) }
        }
        .onChange(of: practice.shakes) { _ in
            guard page == TourPage.shake.rawValue, !shaken else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)) { shaken = true }
            practiced.insert(.shake)
        }
    }

    /// ← / → move between tour pages (hidden buttons: keyboard shortcuts without onKeyPress, which needs macOS 14).
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { if page > 0 { go(to: page + 1) } }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { if page > 1 { go(to: page - 1) } }.keyboardShortcut(.leftArrow, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()   // logo + text sit centred in the space above the button
            // The "que" wordmark forms itself once (no app-icon box), in the text colour: black in light mode, white in dark.
            AnimatedWordmark(animate: !introPlayed) {
                introPlayed = true
                withAnimation(.easeOut(duration: 0.35)) { textVisible = true }
            }
            .foregroundColor(.primary)
                .padding(.top, 20)   // optical: the title bar area sits above

            Group {
                Text("Welcome to Que, you Quetie!")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 36)

                Text("Copy images. Drop them all at once.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
            }
            .opacity(textVisible ? 1 : 0)   // fades in once the logo has formed

            Spacer()

            Button(action: { go(to: 1) }) {
                Text("Start Queing").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
    }

    // MARK: Tour

    /// The tour after the welcome. The user picks how Que comes to them, then practises with the real keys and
    /// pointer on a little desk (the real badge isn't involved: Que is usually empty on a fresh install).
    enum TourPage: Int, CaseIterable {
        case copy = 1, choose, callOver, drag, closerLook, shake, menuBar
    }
    static let tourCount = TourPage.allCases.count

    @ViewBuilder
    private func tourPage(_ index: Int) -> some View {
        let p = TourPage(rawValue: index) ?? .copy
        if p == .choose { choosePage } else { standardPage(p) }
    }

    private func standardPage(_ p: TourPage) -> some View {
        VStack(spacing: 0) {
            stage(p)
                .frame(height: 150)
                .padding(.top, 40)

            Text(title(p))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 32)

            Text(instruction(p))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 44)

            if isPractice(p) { practiceStatus(p).padding(.top, 10) }

            if p == .menuBar {
                HStack {
                    Text("Open Que when you log in").font(.callout)
                    Spacer()
                    Toggle("Open Que when you log in", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            LaunchAtLoginManager.shared.setEnabled(newValue)
                            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                .padding(.top, 18)
                .padding(.horizontal, 44)
            }

            Spacer()
        }
    }

    private func isPractice(_ p: TourPage) -> Bool { [.callOver, .drag, .closerLook, .shake].contains(p) }

    // MARK: Copy (describes only the chosen way)

    private func title(_ p: TourPage) -> String {
        switch p {
        case .copy: return "Copy what catches your eye"
        case .choose: return "How should Que come to you?"
        case .callOver: return usesDoubleTap ? "Tap the Control key twice" : "Hold the Option key"
        case .drag: return "Drag, then let go"
        case .closerLook: return usesDoubleTap ? "Click for a closer look" : "Option-click for a closer look"
        case .shake: return "Shake to start fresh"
        case .menuBar: return "Que lives up here"
        }
    }

    private func instruction(_ p: TourPage) -> String {
        switch p {
        case .copy: return "Every image you copy joins Que, the little badge that follows your pointer."
        case .choose: return ""
        case .callOver: return usesDoubleTap ? "Try it: tap the Control key (⌃) twice, quickly. Que moves under your pointer."
                                             : "Try it: hold the Option key (⌥). Que moves under your pointer."
        case .drag: return usesDoubleTap ? "Try it: tap the Control key twice, then drag Que onto the slide."
                                         : "Try it: hold the Option key and drag Que onto the slide."
        case .closerLook: return usesDoubleTap ? "Try it: tap the Control key twice, then click Que."
                                               : "Try it: hold the Option key and click Que."
        case .shake: return "Try it: shake the pointer quickly from side to side."
        case .menuBar: return "Click the Que icon in your menu bar for switches, tips and everything else."
        }
    }

    private func success(_ p: TourPage) -> String {
        switch p {
        case .callOver: return usesDoubleTap ? "That's it. Tap the Control key twice again to send it back." : "That's it. Let go and it moves aside."
        case .drag: return "Everything landed at once."
        case .closerLook: return "Pick a few, drag them out, or clear some out."
        default: return "Que is empty again."
        }
    }

    private var keyHint: String { usesDoubleTap ? "Tap the Control key twice first." : "Hold the Option key while you do it." }

    /// One line under the instruction: a check once the move worked, a nudge if the key was missing. Fixed height,
    /// so nothing jumps when it changes.
    private func practiceStatus(_ p: TourPage) -> some View {
        Group {
            if practiced.contains(p) {
                Label(success(p), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.primary)
                    .labelStyle(SuccessLabelStyle())
            } else if hintPage == p {
                Text(keyHint).foregroundColor(.secondary)
            } else {
                Text(" ")
            }
        }
        .font(.callout.weight(.medium))
        .frame(height: 20)
        .padding(.horizontal, 32)
        .animation(.easeOut(duration: 0.15), value: practiced)
        .animation(.easeOut(duration: 0.15), value: hintPage)
        .accessibilityElement(children: .combine)
    }

    private struct SuccessLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.foregroundColor(.green)
                configuration.title
            }
        }
    }

    private func nudge(_ p: TourPage) {
        hintPage = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if hintPage == p { hintPage = nil } }
    }

    // MARK: Choose

    private var choosePage: some View {
        VStack(spacing: 0) {
            Text("How should Que come to you?")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 48)

            VStack(spacing: 10) {
                choiceCard(doubleTap: false, keys: "⌥", title: "Hold the Option key",
                           line: "A smooth way to use Que, though it can sit over the app you're in.")
                choiceCard(doubleTap: true, keys: "⌃⌃", title: "Tap the Control key twice",
                           line: "Que stays away from the apps underneath.")
            }
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Text("You can switch anytime in the menu bar.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 14)

            Spacer()
        }
    }

    private func choiceCard(doubleTap: Bool, keys: String, title: String, line: String) -> some View {
        let isChosen = usesDoubleTap == doubleTap
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: { choose(doubleTap: doubleTap) }) {
            HStack(alignment: .center, spacing: 12) {
                KeycapBadgeView(keys).scaleEffect(1.4).frame(width: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundColor(.primary)
                    Text(line)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isChosen ? .accentColor : Color.primary.opacity(0.25))
            }
            .padding(12)
            .background(shape.fill(isChosen ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035)))
            .overlay(shape.strokeBorder(isChosen ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isChosen ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(line)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Saves the choice right away (closing the window mid-tour keeps it) and resets the practice for the new way.
    private func choose(doubleTap: Bool) {
        guard doubleTap != usesDoubleTap else { return }
        withAnimation(.easeOut(duration: 0.15)) { usesDoubleTap = doubleTap }
        QueControls.usesDoubleTap = doubleTap
        practice.usesDoubleTap = doubleTap
        practiced = []
        landed = false
        gridOpen = false
        shaken = false
    }

    // MARK: Practice desks

    @ViewBuilder
    private func stage(_ p: TourPage) -> some View {
        switch p {
        case .copy:
            VStack(spacing: 18) {
                bigKeys("⌘ C")
                Image(systemName: "arrow.down").font(.title3.weight(.semibold)).foregroundColor(.secondary)
                QueBadgeMock(count: 3)
            }
            .accessibilityHidden(true)
        case .callOver: desk { callOverDesk }
        case .drag: desk { dragDesk }
        case .closerLook: desk { closerLookDesk }
        case .shake: desk { shakeDesk }
        default:
            // A sliver of menu bar with the Que icon picked out.
            HStack(spacing: 18) {
                Image(systemName: "wifi").foregroundColor(.secondary)
                Image(nsImage: QueLogoAsset.menuBarImage)
                    .renderingMode(.template)
                    .foregroundColor(.primary)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.12)))
                Image(systemName: "battery.75").foregroundColor(.secondary)   // "battery.75percent" needs macOS 14
                Text("9:41").font(.callout.weight(.medium)).foregroundColor(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .accessibilityHidden(true)
        }
    }

    private static let deskSize = CGSize(width: 300, height: 150)

    /// The practice surface: a quiet tray the moves happen on. Coordinates inside are top-left based ("desk").
    private func desk<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .topLeading) { content() }
            .frame(width: Self.deskSize.width, height: Self.deskSize.height, alignment: .topLeading)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .clipShape(shape)
            .coordinateSpace(name: "desk")
            .accessibilityElement()
            .accessibilityLabel("Practice area")
    }

    private var snapAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.86) }
    private var badgeShines: Bool { usesDoubleTap && practice.isCatching }

    /// Que follows beside a pointer; calling it over pulls it under the pointer, the way the real badge snaps.
    private var callOverDesk: some View {
        let tip = CGPoint(x: 112, y: 58)
        let caught = practice.isCatching
        return ZStack(alignment: .topLeading) {
            QueBadgeMock(count: 3, shining: badgeShines)
                .offset(caught ? CGSize(width: tip.x - 22, height: tip.y - 17)    // pointer over its left part
                               : CGSize(width: tip.x + 22, height: tip.y + 12))   // beside the pointer, as it follows
                .animation(snapAnimation, value: caught)
            pointerGlyph.offset(x: tip.x - 5, y: tip.y - 4)
        }
    }

    private var pointerGlyph: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22, weight: .regular))
            .foregroundColor(.primary)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }

    private static let slideFrame = CGRect(x: 172, y: 32, width: 104, height: 86)
    private static let dragHome = CGPoint(x: 34, y: 58)

    /// Drag the badge onto the slide. It only moves while Que is called over, like the real one.
    private var dragDesk: some View {
        let slide = Self.slideFrame
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isOverSlide ? 0.5 : 0.18), lineWidth: isOverSlide ? 2 : 1))
                .overlay(landedImages)
                .frame(width: slide.width, height: slide.height)
                .offset(x: slide.minX, y: slide.minY)

            if !landed {
                QueBadgeMock(count: 3, shining: badgeShines)
                    .offset(x: Self.dragHome.x + dragOffset.width, y: Self.dragHome.y + dragOffset.height)
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("desk"))
                        .onChanged { value in
                            if !isDraggingBadge {
                                guard practice.isCatching else { nudge(.drag); return }
                                isDraggingBadge = true
                            }
                            dragOffset = value.translation
                            isOverSlide = slide.contains(value.location)
                        }
                        .onEnded { value in
                            guard isDraggingBadge else { return }
                            isDraggingBadge = false
                            isOverSlide = false
                            if slide.contains(value.location) {
                                withAnimation(.easeOut(duration: 0.2)) { landed = true }
                                dragOffset = .zero
                                practiced.insert(.drag)
                                practice.release()   // a drop sends Que back, as in the real thing
                            } else {
                                withAnimation(snapAnimation ?? .easeOut(duration: 0.1)) { dragOffset = .zero }
                            }
                        })
                    .transition(.opacity)
            }
        }
    }

    private var landedImages: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35 + 0.15 * Double(i)))
                    .frame(width: 24, height: 24)
            }
        }
        .opacity(landed ? 1 : 0)
        .scaleEffect(landed || reduceMotion ? 1 : 0.7)
    }

    /// Click the badge while it's called over: the grid opens out of it. Click the grid to close it.
    private var closerLookDesk: some View {
        ZStack {
            if gridOpen {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 4), spacing: 6) {
                    ForEach(0..<8) { i in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: [1, 2, 5].contains(i) ? 2 : 0))
                            .frame(width: 30, height: 30)
                    }
                }
                .frame(width: 30 * 4 + 6 * 3)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(snapAnimation) { gridOpen = false } }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                QueBadgeMock(count: 8, shining: badgeShines)
                    .onTapGesture {
                        guard practice.isCatching else { nudge(.closerLook); return }
                        withAnimation(snapAnimation ?? .easeOut(duration: 0.15)) { gridOpen = true }
                        practiced.insert(.closerLook)
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: Self.deskSize.width, height: Self.deskSize.height)
    }

    /// Shake the pointer (anywhere on screen, as with the real badge) and Que empties.
    private var shakeDesk: some View {
        ZStack {
            if !shaken {
                QueBadgeMock(count: 3)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: Self.deskSize.width, height: Self.deskSize.height)
    }

    /// Dots, Back and Next live outside the sliding page, so only the illustration and text move.
    private func tourNav(_ index: Int) -> some View {
        let isLast = index == Self.tourCount
        return ZStack {
            pageDots(current: index)
            HStack {
                Button(action: { go(to: index - 1) }) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(index > 1 ? 1 : 0)
                .disabled(index <= 1)
                .accessibilityLabel("Back")

                Spacer()

                if isLast {
                    Button("Open Que", action: onOpenQue)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: { go(to: index + 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Next")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    private func pageDots(current: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(1...Self.tourCount, id: \.self) { i in
                Circle()
                    .fill(Color.primary.opacity(i == current ? 0.85 : 0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current) of \(Self.tourCount)")
    }

    private func bigKeys(_ badge: String) -> some View {
        KeycapBadgeView(badge).scaleEffect(1.7).frame(height: 30)
    }
}

/// Watches the real keys and pointer for the tour's practice pages, the same permission-free way the badge does:
/// polled ⌥ (or ⌃⌃ via ControlDoubleTap), and pointer shakes. Runs while the welcome window is open.
final class TourPractice: ObservableObject {
    @Published private(set) var isCatching = false
    @Published private(set) var shakes = 0
    var usesDoubleTap = QueControls.usesDoubleTap { didSet { release() } }
    var watchesShake = false

    private var tapSnapped = false
    private var doubleTap = ControlDoubleTap()
    private let shakeDetector = ShakeDetector()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        shakeDetector.onShakeDetected = { [weak self] in self?.shakes += 1 }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// After a drop: Que goes back beside the pointer (⌃⌃ mode).
    func release() {
        tapSnapped = false
        if isCatching { isCatching = false }
    }

    private func tick() {
        let caught: Bool
        if usesDoubleTap {
            if doubleTap.poll() { tapSnapped.toggle() }
            caught = tapSnapped
        } else {
            caught = CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
        }
        if caught != isCatching { isCatching = caught }
        if watchesShake { shakeDetector.observe(x: NSEvent.mouseLocation.x) }
    }
}

/// A static copy of the Que badge (dark glass capsule, green dot, count) for the tour. `shining`: the green pulse
/// the real badge's dot sends out while it's called over with ⌃⌃.
struct QueBadgeMock: View {
    let count: Int
    var shining = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(red: 0.20, green: 0.85, blue: 0.40)).frame(width: 7, height: 7)
            Text("\(count)").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Group { if shining { RimLight() } })   // on the glass, under the dot and count
        .background(Capsule().fill(Color(white: 0.12)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// The badge's ripple in SwiftUI: one soft round ring of green light grows out of the dot to the edges and fades,
/// 3.6 s, then a rest to 5.4 s (as `DeckHUDView`). Reduce Motion: a steady glow. Sits under the dot and count in
/// `QueBadgeMock`.
struct RimLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var dotX: CGFloat = 17.5   // QueBadgeMock: 14 pt padding + half the 7 pt dot
    private static let spread = 3.6
    private static let cycle = 5.4
    private static let green = Color(red: 0.20, green: 0.85, blue: 0.40)

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                ring(in: geo.size, scale: 0.45, opacity: 1)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
                    let q = min(t / Self.spread, 1)
                    let eased = 1 - pow(1 - q, 2.5)   // eases out like water
                    let opacity = q < 0.25 ? sin(q / 0.25 * .pi / 2) : cos((q - 0.25) / 0.75 * .pi / 2)
                    ring(in: geo.size, scale: 0.1 + 1.1 * eased, opacity: opacity)
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }

    /// A round gradient centred on the dot, as wide as the distance to the far end.
    private func ring(in size: CGSize, scale: CGFloat, opacity: Double) -> some View {
        let reach = max(dotX, size.width - dotX)
        return Circle()
            .fill(RadialGradient(stops: [.init(color: Self.green.opacity(0.1), location: 0),
                                         .init(color: Self.green.opacity(0.12), location: 0.4),
                                         .init(color: Self.green.opacity(0.4), location: 0.8),
                                         .init(color: Self.green.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: reach))
            .frame(width: reach * 2, height: reach * 2)
            .scaleEffect(scale)
            .position(x: dotX, y: size.height / 2)
            .opacity(opacity)
    }
}
