// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// The one-time welcome shown on a brand-new user's first launch ("Welcome to Que, you Quetie!").
/// Existing users (anyone who ran CursorDeck/Que before) never see it.
public final class WelcomeWindowController: NSObject, NSWindowDelegate {
    public static let shared = WelcomeWindowController()

    static let shownKey = "Que_welcomeShown"
    /// Keys only a previous run would have written: their presence means this isn't a new user.
    static let priorUseKeys = ["CursorDeck_launchAtLoginDefaultApplied", "CursorDeck_lastBackgroundCheck"]

    /// Window content width in points; the height follows the content.
    static let width: CGFloat = 380
    /// The artwork slot at the top (points). Quetie artwork: export 3x = 480 x 480 px PNG, transparent background.
    static let artworkSize: CGFloat = 160

    private var window: NSWindow?
    /// Opens the menu bar panel (set by the app): the tour's last button sends the user there to explore.
    public var onOpenQue: (() -> Void)?

    /// Call once at launch, BEFORE anything writes the prior-use keys. Returns whether this is a new user, and marks the
    /// welcome as handled for everyone else so it never appears after an update.
    public static func isNewUser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: shownKey) { return false }
        let usedBefore = priorUseKeys.contains { defaults.object(forKey: $0) != nil }
        if usedBefore { defaults.set(true, forKey: shownKey) }
        return !usedBefore
    }

    public func show() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
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
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Welcome + tour

/// Page 0 is the welcome; "Start Queing" walks through a short tour of the core moves, ending in the menu bar.
struct WelcomeView: View {
    var onStart: () -> Void            // closes the window (close button / finished)
    var onOpenQue: () -> Void = {}     // last page: close and open the menu bar panel
    @State private var page = 0
    @State private var forward = true
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onStart: @escaping () -> Void, onOpenQue: @escaping () -> Void = {}, initialPage: Int = 0) {
        self.onStart = onStart
        self.onOpenQue = onOpenQue
        self._page = State(initialValue: initialPage)
    }

    static let height: CGFloat = 410
    private static let tourCount = 6   // pages 1...6

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
        .clipped()
        .background(keyboardShortcuts)
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
            // Artwork slot (Quetie goes here). Until the artwork exists, the app icon stands in.
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: WelcomeWindowController.artworkSize, height: WelcomeWindowController.artworkSize)
                .accessibilityHidden(true)
                .padding(.top, 40)

            Text("Welcome to Que, you Quetie!")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Text("Copy images. Drop them all at once.")
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.top, 6)

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

    private struct Step {
        let title: String
        let body: String
    }

    private static let steps: [Step] = [
        Step(title: "Copy what catches your eye", body: "Images you copy hop into Que, the little badge that follows your pointer."),
        Step(title: "Hold ⌘ to call Que over", body: "It scoots right under your pointer, ready to go."),
        Step(title: "Drag, then let go", body: "Drop Que on a slide or canvas and everything lands at once."),
        Step(title: "⌥-click for a closer look", body: "See what's lined up, pick a few, or clear some out."),
        Step(title: "Shake to start fresh", body: "A quick wiggle of the pointer empties Que."),
        Step(title: "Que lives up here", body: "Click the Que icon in your menu bar for switches, tips and everything else."),
    ]

    private func tourPage(_ index: Int) -> some View {
        let step = Self.steps[index - 1]
        let isLast = index == Self.tourCount
        return VStack(spacing: 0) {
            illustration(index)
                .frame(height: 150)
                .padding(.top, 40)
                .accessibilityHidden(true)

            Text(step.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 32)

            Text(step.body)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 44)

            if isLast {
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

            ZStack {
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

    // MARK: Illustrations (built from the real badge and keycaps, so they look like Que itself)

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        switch index {
        case 1:
            VStack(spacing: 18) {
                bigKeys("⌘ C")
                Image(systemName: "arrow.down").font(.title3.weight(.semibold)).foregroundColor(.secondary)
                QueBadgeMock(count: 3)
            }
        case 2:
            VStack(spacing: 14) {
                bigKeys("⌘")
                // The pointer sits just above the badge's left end, the way Que snaps under it.
                ZStack(alignment: .topLeading) {
                    QueBadgeMock(count: 3)
                        .padding(.top, 14)
                        .padding(.leading, 10)
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 22, weight: .regular))
                }
            }
        case 3:
            VStack(spacing: 16) {
                bigKeys("⌘ + Drag")
                HStack(spacing: 14) {
                    QueBadgeMock(count: 3)
                    Image(systemName: "arrow.right").font(.title3.weight(.semibold)).foregroundColor(.secondary)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 78, height: 50)
                        .overlay(HStack(spacing: 4) {
                            ForEach(0..<3) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.55)).frame(width: 16, height: 16)
                            }
                        })
                }
            }
        case 4:
            VStack(spacing: 16) {
                bigKeys("⌥ + Click")
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
            }
        case 5:
            Image(systemName: "pointer.arrow.motionlines")
                .font(.system(size: 64, weight: .regular))
                .foregroundColor(.primary.opacity(0.85))
        default:
            // A sliver of menu bar with the Que icon picked out.
            HStack(spacing: 18) {
                Image(systemName: "wifi").foregroundColor(.secondary)
                Image(nsImage: QueLogoAsset.menuBarImage)
                    .renderingMode(.template)
                    .foregroundColor(.primary)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.12)))
                Image(systemName: "battery.75percent").foregroundColor(.secondary)
                Text("9:41").font(.callout.weight(.medium)).foregroundColor(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }

    private func bigKeys(_ badge: String) -> some View {
        KeycapBadgeView(badge).scaleEffect(1.7).frame(height: 30)
    }
}

/// A static copy of the Que badge (dark glass capsule, green dot, count, mark) for the tour illustrations.
struct QueBadgeMock: View {
    let count: Int
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(red: 0.20, green: 0.85, blue: 0.40)).frame(width: 7, height: 7)
            Text("\(count)").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Image(nsImage: QueLogoAsset.pillImage)
                .renderingMode(.template)
                .resizable()
                .frame(width: 13, height: 13)
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color(white: 0.12)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}
