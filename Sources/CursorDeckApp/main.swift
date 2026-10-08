import Foundation
import AppKit
import CursorDeckCore

// Configure NSApplication as a background Agent (LSUIElement: true, zero dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Ensure Launch at Startup is active by default when installed in /Applications
if Bundle.main.bundlePath.hasPrefix("/Applications") && !LaunchAtLoginManager.shared.isEnabled {
    LaunchAtLoginManager.shared.installLaunchAgent()
}

let queueManager = DeckQueueManager()
let clipboardWatcher = ClipboardWatcher(queueManager: queueManager)
let screenshotWatcher = ScreenshotWatcher(queueManager: queueManager)
let hudPanel = CursorHUDPanel(queueManager: queueManager)
let menuBarManager = MenuBarManager(
    queueManager: queueManager,
    clipboardWatcher: clipboardWatcher,
    screenshotWatcher: screenshotWatcher,
    hudPanel: hudPanel
)

clipboardWatcher.start()
screenshotWatcher.start()
hudPanel.startTracking()

// Quiet background update check 4 seconds after launch
DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
    UpdateManager.shared.checkForUpdates(userInitiated: false)
}

// Keep app event loop running
app.run()
