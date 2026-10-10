// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation
import SwiftUI

public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private let queueManager: DeckQueueManager
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?

    private var panel: DeckControlCenterPanel?
    private var controlCenterState: DeckControlCenterState?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var lastDismissTimestamp: TimeInterval = 0

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

    deinit {
        removeClickOutsideMonitors()
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
        // Pausing from the Control Center switch must update the ⏸ in the menu bar too.
        state.onTrackingPausedChanged = { [weak self] in
            self?.updateStatusItemBadge()
        }

        let panel = DeckControlCenterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 350)
        )
        panel.onEscPressed = { [weak self] in
            self?.closePanel()
        }

        let hostingView = NSHostingView(
            rootView: DeckControlCenterView(
                state: state,
                onDismiss: { [weak self] in
                    self?.closePanel()
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 256, height: 350)
        panel.contentView = hostingView
        self.panel = panel

        updateStatusItemBadge()

        queueManager.addObserver { [weak self] _ in
            self?.updateStatusItemBadge()
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            closePanel()
            showContextMenu(sender)
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastDismissTimestamp < 0.25 {
                return
            }
            togglePanel(sender)
        }
    }

    public func togglePanel(_ sender: NSStatusBarButton) {
        guard let panel = panel else { return }
        if panel.isVisible {
            closePanel()
        } else {
            openPanel(sender)
        }
    }

    public func openPanel(_ sender: NSStatusBarButton) {
        guard let panel = panel, let buttonWindow = sender.window else { return }
        
        controlCenterState?.refresh()
        
        let buttonScreenRect = buttonWindow.convertToScreen(sender.bounds)
        let panelSize = NSSize(width: 256, height: 350)
        
        var originX = buttonScreenRect.midX - (panelSize.width / 2.0)
        
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            if originX + panelSize.width > screenFrame.maxX - 8 {
                originX = screenFrame.maxX - panelSize.width - 8
            }
            if originX < screenFrame.minX + 8 {
                originX = screenFrame.minX + 8
            }
        }
        
        let originY = buttonScreenRect.minY - panelSize.height - 4
        
        panel.setFrame(NSRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        
        setupClickOutsideMonitors()
    }

    public func closePanel() {
        guard let panel = panel, panel.isVisible else { return }
        removeClickOutsideMonitors()
        lastDismissTimestamp = Date().timeIntervalSinceReferenceDate
        panel.orderOut(nil)
    }

    private func setupClickOutsideMonitors() {
        removeClickOutsideMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            
            if let button = self.statusItem?.button, let buttonWindow = button.window {
                let mouseLoc = NSEvent.mouseLocation
                let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                if buttonScreenRect.contains(mouseLoc) {
                    self.closePanel()
                    return
                }
            }
            
            let mouseLoc = NSEvent.mouseLocation
            if !panel.frame.contains(mouseLoc) {
                self.closePanel()
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            
            if event.window != panel {
                if let button = self.statusItem?.button, let buttonWindow = button.window {
                    let mouseLoc = NSEvent.mouseLocation
                    let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                    if buttonScreenRect.contains(mouseLoc) {
                        self.closePanel()
                        return event
                    }
                }
                self.closePanel()
            }
            return event
        }
    }

    private func removeClickOutsideMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
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
        controlCenterState?.refresh()
        controlCenterState?.toggleTracking()
    }

    @objc public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
