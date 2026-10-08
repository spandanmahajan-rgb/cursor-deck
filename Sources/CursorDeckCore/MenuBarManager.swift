import AppKit
import Foundation
import SwiftUI

public final class MenuBarManager: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let queueManager: DeckQueueManager
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?

    private var popover: NSPopover?
    private var controlCenterState: DeckControlCenterState?

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
        super.init()
        setupStatusBar()
    }

    private func setupStatusBar() {
        // Create status bar item in macOS menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = DeckLogoAsset.menuBarImage
            button.imagePosition = .imageOnly
            button.toolTip = "Cursor Deck (Visual Accumulator)"
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let state = DeckControlCenterState(
            queueManager: queueManager,
            clipboardWatcher: clipboardWatcher,
            screenshotWatcher: screenshotWatcher,
            hudPanel: hudPanel
        )
        self.controlCenterState = state

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentSize = NSSize(width: 256, height: 336)

        let hostingController = NSHostingController(
            rootView: DeckControlCenterView(state: state, onDismiss: { [weak pop] in
                pop?.performClose(nil)
            })
        )
        pop.contentViewController = hostingController
        self.popover = pop

        updateStatusItemBadge()

        queueManager.addObserver { [weak self] _ in
            self?.updateStatusItemBadge()
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    public func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controlCenterState?.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let count = queueManager.count
        let isPaused = clipboardWatcher?.isPaused ?? false

        let headerItem = NSMenuItem(title: "Cursor Deck: \(count) item\(count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy Batch to Clipboard", action: #selector(copyBatch), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = count > 0
        menu.addItem(copyItem)

        let clearItem = NSMenuItem(title: "Clear Deck", action: #selector(clearDeck), keyEquivalent: "k")
        clearItem.target = self
        clearItem.isEnabled = count > 0
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(
            title: isPaused ? "▶ Resume Tracking" : "⏸ Pause Tracking",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Cursor Deck", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil // reset so left-click reopens popover
    }

    public func updateMenu() {
        updateStatusItemBadge()
        controlCenterState?.refresh()
    }

    public func updateStatusItemBadge() {
        guard let button = statusItem?.button else { return }
        let count = queueManager.count
        let isPaused = clipboardWatcher?.isPaused ?? false
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

    @objc public func copyBatch() {
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
    }

    @objc public func clearDeck() {
        queueManager.clear()
        updateStatusItemBadge()
    }

    @objc public func togglePause() {
        let isNowPaused = !(clipboardWatcher?.isPaused ?? false)
        clipboardWatcher?.isPaused = isNowPaused
        screenshotWatcher?.isPaused = isNowPaused
        updateStatusItemBadge()
        controlCenterState?.refresh()
    }

    @objc public func toggleSmartFilter() {
        if let watcher = clipboardWatcher {
            watcher.isSmartFilterEnabled = !watcher.isSmartFilterEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleScreenshotWatcher() {
        if let watcher = screenshotWatcher {
            watcher.isEnabled = !watcher.isEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleShakeToClear() {
        if let panel = hudPanel {
            panel.shakeDetector.isEnabled = !panel.shakeDetector.isEnabled
            controlCenterState?.refresh()
        }
    }

    @objc public func toggleLaunchAtLogin() {
        let current = LaunchAtLoginManager.shared.isEnabled
        LaunchAtLoginManager.shared.setEnabled(!current)
        controlCenterState?.refresh()
    }

    @objc public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
