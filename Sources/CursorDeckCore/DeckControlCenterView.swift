import AppKit
import Foundation
import SwiftUI

// MARK: - Control Center Switch (Native macOS 30x17 Capsule)

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

// MARK: - Native macOS Dropdown Style Popover (Matched to System Wi-Fi Dropdown & Golden Gate Tokens)

public struct DeckControlCenterView: View {
    @ObservedObject public var state: DeckControlCenterState
    public var onDismiss: (() -> Void)?

    @State private var hoveredRow: String? = nil
    @State private var hoveredAction: String? = nil

    public init(state: DeckControlCenterState, onDismiss: (() -> Void)? = nil) {
        self.state = state
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. MASTER HEADER (Matches "Wi-Fi [Toggle]" row in macOS)
            masterHeaderRow
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            dividerView

            // 2. CAPTURE PREFERENCES SECTION (Liquid Glass Circular Badges with Switches)
            sectionHeader("Preferences")
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 3)

            VStack(spacing: 2) {
                // Smart Filter
                listToggleRow(
                    id: "filter",
                    symbol: "line.3.horizontal.decrease",
                    title: "Smart Filter",
                    isOn: state.isSmartFilterEnabled,
                    action: { state.toggleSmartFilter() }
                )

                // Screenshots
                listToggleRow(
                    id: "screenshots",
                    symbol: "camera.viewfinder",
                    title: "Screenshots",
                    isOn: state.isScreenshotWatcherEnabled,
                    action: { state.toggleScreenshots() }
                )

                // Shake Clear
                listToggleRow(
                    id: "shake",
                    symbol: "pointer.arrow.motionlines",
                    title: "Shake to Clear",
                    isOn: state.isShakeClearEnabled,
                    action: { state.toggleShakeClear() }
                )
            }
            .padding(.horizontal, 8)

            dividerView
                .padding(.top, 6)

            // 3. DECK ACTIONS (Horizontal Action Row)
            sectionHeader("Actions")
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 5)

            deckActionsRow
                .padding(.horizontal, 10)

            dividerView
                .padding(.top, 7)

            // 4. SYSTEM PREFERENCE (Launch at Login)
            VStack(spacing: 2) {
                listToggleRow(
                    id: "launch",
                    symbol: "power",
                    title: "Launch at Login",
                    isOn: state.isLaunchAtLoginEnabled,
                    action: { state.toggleLaunchAtLogin() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            dividerView
                .padding(.top, 6)

            // 5. UTILITY FOOTER (Matches "Wi-Fi Settings..." in macOS)
            utilityFooter
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .frame(width: 256)
        .background(Material.ultraThin)
    }

    // MARK: - Master Header (Title + Master Tracking Toggle)

    private var masterHeaderRow: some View {
        Button(action: {
            state.toggleTracking()
        }) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CursorDeck")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundColor(.primary)

                    Text(statusSubtitle)
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(.secondary)
                }

                Spacer()

                ControlCenterSwitch(isOn: !state.isTrackingPaused)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusSubtitle: String {
        if state.isTrackingPaused {
            return "Tracking is paused"
        } else if state.itemCount == 0 {
            return "Nothing in the deck"
        } else if state.itemCount == 1 {
            return "1 item ready"
        } else {
            return "\(state.itemCount) items ready"
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .default))
            .foregroundColor(.secondary)
    }

    // MARK: - Native List Toggle Row (Matches Wi-Fi list row with Golden Gate Liquid Glass badge)

    private func listToggleRow(
        id: String,
        symbol: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRow == id

        return Button(action: action) {
            HStack(spacing: 9) {
                // Liquid Glass circular icon badge
                ZStack {
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 26, height: 26)

                    // Specular highlight rim from Liquid Glass - Small token
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.35 : 0.16),
                                    Color.white.opacity(isOn ? 0.08 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                        .frame(width: 26, height: 26)

                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundColor(isOn ? .white : Color.secondary)
                }

                // Row title
                Text(title)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.primary)

                Spacer()

                // Native switch toggle
                ControlCenterSwitch(isOn: isOn)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredRow = inside ? id : nil
            }
        }
    }

    // MARK: - Deck Actions Row (Liquid Glass compact action buttons)

    private var deckActionsRow: some View {
        HStack(spacing: 6) {
            actionButton(
                id: "copy",
                symbol: state.isCopiedFeedback ? "checkmark" : "doc.on.doc",
                label: state.isCopiedFeedback ? "Copied" : "Copy All",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                action: { state.copyAll() }
            )

            actionButton(
                id: "grid",
                symbol: "square.grid.2x2",
                label: "Grid",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                action: { state.openGrid(onDismiss: onDismiss) }
            )

            actionButton(
                id: "clear",
                symbol: "trash",
                label: "Clear",
                isDestructive: true,
                isEnabled: state.itemCount > 0,
                action: { state.clearDeck() }
            )
        }
        .frame(height: 32)
    }

    private func actionButton(
        id: String,
        symbol: String,
        label: String,
        isDestructive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction == id

        let normalBg = Color.primary.opacity(0.05)
        let hoverBg = isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.09)
        let currentBg = isHovered ? hoverBg : normalBg

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
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(fgColor)

                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .default))
                    .foregroundColor(fgColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(currentBg)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.10 : 0.05), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredAction = inside ? id : nil
            }
        }
    }

    // MARK: - Utility Footer

    private var utilityFooter: some View {
        HStack {
            Button(action: {
                onDismiss?()
                state.checkForUpdates()
            }) {
                Text("Check for Updates...")
                    .font(.system(size: 11.5, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                state.quitApp()
            }) {
                Text("Quit")
                    .font(.system(size: 11.5, weight: .regular, design: .default))
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
            .padding(.horizontal, 10)
    }
}
