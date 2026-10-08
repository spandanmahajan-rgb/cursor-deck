import AppKit
import Foundation

public final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let queueManager: DeckQueueManager
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?

    public init(
        queueManager: DeckQueueManager,
        clipboardWatcher: ClipboardWatcher? = nil,
        screenshotWatcher: ScreenshotWatcher? = nil,
        hudPanel: CursorHUDPanel? = nil
    ) {
        self.queueManager = queueManager
        self.clipboardWatcher = clipboardWatcher
        self.screenshotWatcher = screenshotWatcher
        self.hudPanel = hudPanel
        setupStatusBar()
    }

    private func setupStatusBar() {
        // Create status bar item in macOS menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = DeckLogoAsset.menuBarImage
            button.imagePosition = .imageOnly
            button.toolTip = "Cursor Deck (Visual Accumulator)"
        }

        updateMenu()

        queueManager.addObserver { [weak self] _ in
            self?.updateMenu()
        }
    }

    public func updateMenu() {
        let menu = NSMenu()
        let count = queueManager.count
        let isPaused = clipboardWatcher?.isPaused ?? false

        // Header item
        let statusText = isPaused ? " (Paused)" : ""
        let titleItem = NSMenuItem(title: "Cursor Deck: \(count) item\(count == 1 ? "" : "s") loaded\(statusText)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // Quick Controls
        let copyItem = NSMenuItem(title: "Copy Batch to Clipboard", action: #selector(copyBatch), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = count > 0
        menu.addItem(copyItem)

        let clearItem = NSMenuItem(title: "Clear Deck", action: #selector(clearDeck), keyEquivalent: "k")
        clearItem.target = self
        clearItem.isEnabled = count > 0
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        // Pause / Resume tracking
        let pauseItem = NSMenuItem(
            title: isPaused ? "▶ Resume Tracking" : "⏸ Pause Tracking",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        // Smart Filter toggle (Filters out Illustrator, Figma, Photoshop internal shape/layer copies)
        let isFilterOn = clipboardWatcher?.isSmartFilterEnabled ?? true
        let filterItem = NSMenuItem(
            title: "Smart Filter (Ignore Design Tools)",
            action: #selector(toggleSmartFilter),
            keyEquivalent: ""
        )
        filterItem.target = self
        filterItem.state = isFilterOn ? .on : .off
        menu.addItem(filterItem)

        // Auto-Collect Screenshots toggle
        let isScreenshotOn = screenshotWatcher?.isEnabled ?? true
        let screenshotItem = NSMenuItem(
            title: "Auto-Collect Screenshots (⌘⇧4, ⌘⇧3)",
            action: #selector(toggleScreenshotWatcher),
            keyEquivalent: ""
        )
        screenshotItem.target = self
        screenshotItem.state = isScreenshotOn ? .on : .off
        menu.addItem(screenshotItem)

        // Shake to Discard toggle
        let isShakeOn = hudPanel?.shakeDetector.isEnabled ?? true
        let shakeItem = NSMenuItem(
            title: "Shake Cursor to Discard Deck",
            action: #selector(toggleShakeToClear),
            keyEquivalent: ""
        )
        shakeItem.target = self
        shakeItem.state = isShakeOn ? .on : .off
        menu.addItem(shakeItem)

        menu.addItem(NSMenuItem.separator())

        // How to drop instructions
        let hintSnap = NSMenuItem(title: "💡 Hold ⌘ or ⌥ to magnet-snap deck", action: nil, keyEquivalent: "")
        hintSnap.isEnabled = false
        menu.addItem(hintSnap)

        let hintPreview = NSMenuItem(title: "💡 Click deck with ⌥ to open Grid Preview", action: nil, keyEquivalent: "")
        hintPreview.isEnabled = false
        menu.addItem(hintPreview)

        menu.addItem(NSMenuItem.separator())

        // Launch at startup option
        let isLaunchEnabled = LaunchAtLoginManager.shared.isEnabled
        let launchItem = NSMenuItem(title: "Launch at Startup", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchEnabled ? .on : .off
        menu.addItem(launchItem)

        // Check for updates
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Quit item
        let quitItem = NSMenuItem(title: "Quit Cursor Deck", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        if let button = statusItem?.button {
            button.image = DeckLogoAsset.menuBarImage
            if isPaused {
                button.imagePosition = .imageLeft
                button.title = " ⏸"
            } else if count > 0 {
                button.imagePosition = .imageLeft
                button.title = " \(count)"
            } else {
                button.imagePosition = .imageOnly
                button.title = ""
            }
        }
    }

    @objc private func copyBatch() {
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
    }

    @objc private func clearDeck() {
        queueManager.clear()
    }

    @objc private func togglePause() {
        if let watcher = clipboardWatcher {
            watcher.isPaused = !watcher.isPaused
            updateMenu()
        }
    }

    @objc private func toggleSmartFilter() {
        if let watcher = clipboardWatcher {
            watcher.isSmartFilterEnabled = !watcher.isSmartFilterEnabled
            updateMenu()
        }
    }

    @objc private func toggleScreenshotWatcher() {
        if let watcher = screenshotWatcher {
            watcher.isEnabled = !watcher.isEnabled
            updateMenu()
        }
    }

    @objc private func toggleShakeToClear() {
        if let panel = hudPanel {
            panel.shakeDetector.isEnabled = !panel.shakeDetector.isEnabled
            updateMenu()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let current = LaunchAtLoginManager.shared.isEnabled
        LaunchAtLoginManager.shared.setEnabled(!current)
        updateMenu()
    }

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
