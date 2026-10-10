import Foundation
import AppKit
import CursorDeckCore

// Configure NSApplication as a background Agent (LSUIElement: true, zero dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Turn Launch at Login on by default, but only the first time the app runs from /Applications.
// (It used to re-enable on EVERY launch, so switching it off never stuck past a restart or update.)
let launchAtLoginDefaultKey = "CursorDeck_launchAtLoginDefaultApplied"
if Bundle.main.bundlePath.hasPrefix("/Applications") && !UserDefaults.standard.bool(forKey: launchAtLoginDefaultKey) {
    if !LaunchAtLoginManager.shared.isEnabled {
        LaunchAtLoginManager.shared.installLaunchAgent()
    }
    UserDefaults.standard.set(true, forKey: launchAtLoginDefaultKey)
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
