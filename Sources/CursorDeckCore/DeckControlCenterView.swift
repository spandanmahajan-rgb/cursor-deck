import AppKit
import Foundation
import SwiftUI

// MARK: - Control Center Switch

public struct ControlCenterSwitch: View {
    public let isOn: Bool

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: 30, height: 17)

            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .padding(2)
                .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 0.5)
        }
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

// MARK: - Observable State Model

public final class DeckControlCenterState: ObservableObject {
    @Published public var itemCount: Int = 0
    @Published public var isTrackingPaused: Bool = false
    @Published public var isSmartFilterEnabled: Bool = true
    @Published public var isScreenshotWatcherEnabled: Bool = true
    @Published public var isShakeClearEnabled: Bool = true
    @Published public var isLaunchAtLoginEnabled: Bool = false
    @Published public var isCopiedFeedback: Bool = false

    private weak var queueManager: DeckQueueManager?
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?
    private var observerToken: UUID?

    public init(
        queueManager: DeckQueueManager? = nil,
        clipboardWatcher: ClipboardWatcher? = nil,
        screenshotWatcher: ScreenshotWatcher? = nil,
        hudPanel: CursorHUDPanel? = nil
    ) {
        self.queueManager = queueManager
        self.clipboardWatcher = clipboardWatcher
        self.screenshotWatcher = screenshotWatcher
        self.hudPanel = hudPanel
        refresh()

        self.observerToken = queueManager?.addObserver { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    public func refresh() {
        self.itemCount = queueManager?.count ?? 0
        self.isTrackingPaused = clipboardWatcher?.isPaused ?? false
        self.isSmartFilterEnabled = clipboardWatcher?.isSmartFilterEnabled ?? true
        self.isScreenshotWatcherEnabled = screenshotWatcher?.isEnabled ?? true
        self.isShakeClearEnabled = hudPanel?.shakeDetector.isEnabled ?? true
        self.isLaunchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
    }

    public func toggleTracking() {
        let newPaused = !isTrackingPaused
        clipboardWatcher?.isPaused = newPaused
        screenshotWatcher?.isPaused = newPaused
        isTrackingPaused = newPaused
    }

    public func toggleSmartFilter() {
        let newFilter = !isSmartFilterEnabled
        clipboardWatcher?.isSmartFilterEnabled = newFilter
        isSmartFilterEnabled = newFilter
    }

    public func toggleScreenshots() {
        let newScreenshots = !isScreenshotWatcherEnabled
        screenshotWatcher?.isEnabled = newScreenshots
        isScreenshotWatcherEnabled = newScreenshots
    }

    public func toggleShakeClear() {
        let newShake = !isShakeClearEnabled
        hudPanel?.shakeDetector.isEnabled = newShake
        isShakeClearEnabled = newShake
    }

    public func toggleLaunchAtLogin() {
        let newLaunch = !isLaunchAtLoginEnabled
        LaunchAtLoginManager.shared.setEnabled(newLaunch)
        isLaunchAtLoginEnabled = newLaunch
    }

    public func copyAll() {
        guard let queueManager = queueManager, !queueManager.isEmpty else { return }
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            withAnimation(.easeInOut(duration: 0.15)) {
                self?.isCopiedFeedback = false
            }
        }
    }

    public func clearDeck() {
        queueManager?.clear()
        refresh()
    }

    public func openGrid(onDismiss: (() -> Void)? = nil) {
        onDismiss?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.hudPanel?.togglePreview()
        }
    }

    public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Deck Control Center View

public struct DeckControlCenterView: View {
    @ObservedObject public var state: DeckControlCenterState
    public var onDismiss: (() -> Void)?

    @State private var hoveredTile: String? = nil
    @State private var pressedTile: String? = nil
    @State private var hoveredAction: String? = nil
    @State private var pressedAction: String? = nil
    @State private var hoveredLaunch: Bool = false

    public init(state: DeckControlCenterState, onDismiss: (() -> Void)? = nil) {
        self.state = state
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .frame(height: 48)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            // LEVEL 1: Primary Controls 2x2 Grid (Compact)
            primaryControlsGrid
                .padding(.horizontal, 12)
                .padding(.top, 2)

            // Divider 1
            dividerView
                .padding(.vertical, 10)

            // LEVEL 2: Deck Actions
            deckActionsRow
                .padding(.horizontal, 12)

            // Divider 2
            dividerView
                .padding(.vertical, 10)

            // LEVEL 3: System Preference (Launch at Login)
            launchAtLoginRow
                .padding(.horizontal, 12)
                .frame(height: 40)

            // Quiet utility footer (Updates & Quit)
            utilityFooterView
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(width: 290)
        .background(
            Material.ultraThin
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CURSOR DECK")
                    .font(.system(size: 12.5, weight: .semibold, design: .default))
                    .foregroundColor(.primary)
                    .accessibilityAddTraits(.isHeader)

                Text(itemCountText)
                    .font(.system(size: 11.5, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status Indicator Dot
            Circle()
                .fill(state.isTrackingPaused ? Color.secondary.opacity(0.55) : Color.accentColor)
                .frame(width: 6, height: 6)
                .accessibilityLabel(state.isTrackingPaused ? "Tracking paused" : "Tracking active")
        }
    }

    private var itemCountText: String {
        if state.itemCount == 0 {
            return "Nothing in the deck"
        } else if state.itemCount == 1 {
            return "1 item ready"
        } else {
            return "\(state.itemCount) items ready"
        }
    }

    // MARK: - Primary Controls Grid (2x2 Compact)

    private var primaryControlsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]

        return LazyVGrid(columns: columns, spacing: 8) {
            // Tile 1: Tracking
            controlTile(
                id: "tracking",
                symbol: state.isTrackingPaused ? "pause.circle.fill" : "waveform.circle.fill",
                title: "Tracking",
                isOn: !state.isTrackingPaused,
                tooltip: "Pauses or resumes CursorDeck capture",
                action: { state.toggleTracking() }
            )

            // Tile 2: Smart Filter
            controlTile(
                id: "smartFilter",
                symbol: "line.3.horizontal.decrease.circle",
                title: "Smart Filter",
                isOn: state.isSmartFilterEnabled,
                tooltip: "Ignores content copied from design tools",
                action: { state.toggleSmartFilter() }
            )

            // Tile 3: Screenshots
            controlTile(
                id: "screenshots",
                symbol: "rectangle.dashed.badge.record",
                title: "Screenshots",
                isOn: state.isScreenshotWatcherEnabled,
                tooltip: "Automatically add macOS screenshots to the deck",
                action: { state.toggleScreenshots() }
            )

            // Tile 4: Shake Clear
            controlTile(
                id: "shakeClear",
                symbol: "arrow.left.and.right",
                title: "Shake Clear",
                isOn: state.isShakeClearEnabled,
                tooltip: "Shake the cursor to clear the deck",
                action: { state.toggleShakeClear() }
            )
        }
    }

    private func controlTile(
        id: String,
        symbol: String,
        title: String,
        isOn: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredTile == id
        let isPressed = pressedTile == id

        let bgOpacity: Double = isPressed ? 0.14 : (isHovered ? 0.10 : 0.065)
        let borderOpacity: Double = isHovered ? 0.14 : 0.08

        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Top Row: SF Symbol (Blue when ON) + Switch
                HStack(alignment: .center) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium, design: .default))
                        .foregroundColor(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: 22, height: 22)

                    Spacer()

                    ControlCenterSwitch(isOn: isOn)
                }

                Spacer(minLength: 6)

                // Bottom Row: Just the clean title (no redundant "on" / "off" text)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium, design: .default))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(height: 70)
            .background(Color.primary.opacity(bgOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .help(tooltip)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTile = inside ? id : nil
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(tooltip)
    }

    // MARK: - Deck Actions Row

    private var deckActionsRow: some View {
        HStack(spacing: 6) {
            // Action 1: Copy All
            actionButton(
                id: "copyAll",
                symbol: state.isCopiedFeedback ? "checkmark" : "doc.on.doc",
                label: state.isCopiedFeedback ? "Copied" : "Copy All",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                hint: "Copies all items in the deck",
                action: { state.copyAll() }
            )

            // Action 2: Grid
            actionButton(
                id: "grid",
                symbol: "square.grid.2x2",
                label: "Grid",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                hint: "Opens the deck grid preview",
                action: { state.openGrid(onDismiss: onDismiss) }
            )

            // Action 3: Clear
            actionButton(
                id: "clear",
                symbol: "trash",
                label: "Clear",
                isDestructive: true,
                isEnabled: state.itemCount > 0,
                hint: "Removes all items from the deck",
                action: { state.clearDeck() }
            )
        }
        .frame(height: 54)
    }

    private func actionButton(
        id: String,
        symbol: String,
        label: String,
        isDestructive: Bool,
        isEnabled: Bool,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction == id
        let isPressed = pressedAction == id

        let normalBg = Color.primary.opacity(0.04)
        let hoverBg = isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.10)
        let pressBg = isDestructive ? Color.red.opacity(0.20) : Color.primary.opacity(0.14)
        let currentBg = isPressed ? pressBg : (isHovered ? hoverBg : normalBg)

        let fgColor: Color
        if !isEnabled {
            fgColor = Color.secondary.opacity(0.4)
        } else if isDestructive && isHovered {
            fgColor = Color.red
        } else {
            fgColor = Color.primary
        }

        return Button(action: {
            if isEnabled { action() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(fgColor)

                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(fgColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(currentBg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredAction = inside ? id : nil
            }
        }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - Launch at Login Row

    private var launchAtLoginRow: some View {
        Button(action: {
            state.toggleLaunchAtLogin()
        }) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundColor(state.isLaunchAtLoginEnabled ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: 18)

                Text("Launch at Login")
                    .font(.system(size: 12.5, weight: .regular, design: .default))
                    .foregroundColor(.primary)

                Spacer()

                ControlCenterSwitch(isOn: state.isLaunchAtLoginEnabled)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hoveredLaunch ? Color.primary.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredLaunch = inside
            }
        }
        .accessibilityLabel("Launch at Login")
        .accessibilityValue(state.isLaunchAtLoginEnabled ? "On" : "Off")
    }

    // MARK: - Utility Footer View (Quiet updates & quit)

    private var utilityFooterView: some View {
        HStack {
            Button(action: {
                onDismiss?()
                state.checkForUpdates()
            }) {
                Text("Check for Updates...")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                state.quitApp()
            }) {
                Text("Quit")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Divider

    private var dividerView: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}
