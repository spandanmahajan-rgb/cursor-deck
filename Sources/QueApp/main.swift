// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AppKit
import QueCore

// CursorDeck → Que: an update from CursorDeck 1.x lands as /Applications/CursorDeck.app. Rename it to Que.app
// and reopen from there before anything starts (one quick blink, once).
if let renamed = LegacyAppRename.renameIfNeeded() {
    LegacyAppRename.reopen(at: renamed)
    exit(0)
}
LaunchAtLoginManager.shared.migrateLegacyAgent()

// Configure NSApplication as a background Agent (LSUIElement: true, zero dock icon)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A copy installed by hand (from Que.dmg; new or returning user) gets the welcome + tour. In-app updates and normal
// launches don't.
let showWelcome = WelcomeWindowController.shouldShowWelcome(copyID: WelcomeWindowController.currentCopyID())

// Turn Launch at Login on by default, but only the first time the app runs from /Applications.
// (It used to re-enable on EVERY launch, so switching it off never stuck past a restart or update.)
let launchAtLoginDefaultKey = "CursorDeck_launchAtLoginDefaultApplied"   // old key kept: settings carry over
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

// Pinterest boards: a copied board link becomes an offer in Que; messages show inside Que.
let boardImporter = BoardImportController(queueManager: queueManager, hudPanel: hudPanel)
clipboardWatcher.onPinterestBoard = { username, slug in
    boardImporter.handleBoardLink(username: username, slug: slug)
}
clipboardWatcher.onNotice = { notice in hudPanel.show(notice) }
queueManager.onFull = { hudPanel.show(.queFull()) }
clipboardWatcher.onWorkChanged = { working in hudPanel.isWorking = working }

clipboardWatcher.start()
screenshotWatcher.start()
hudPanel.startTracking()

// `open -a Que --args --show-welcome` shows it again (for checking the design; not needed by users).
if showWelcome || CommandLine.arguments.contains("--show-welcome") {
    WelcomeWindowController.shared.onOpenQue = { menuBarManager.openControlCenter() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WelcomeWindowController.shared.show() }
}

// Quiet background update checks (4 s after launch, then while running). A newer version turns the small circle of the
// menu bar icon blue; the update window only opens from "Check for Updates…" / "Update to Que x…".
UpdateManager.shared.startBackgroundChecks()

// Keep app event loop running
app.run()
