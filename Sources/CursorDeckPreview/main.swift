import AppKit
import Foundation
import SwiftUI
import CursorDeckCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let queueManager = DeckQueueManager()
for _ in 1...6 {
    let dummyData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    queueManager.add(imageData: dummyData, extension: "png")
}

// 1. ACTIVE STATE WINDOW
let stateActive = DeckControlCenterState(queueManager: queueManager)
stateActive.itemCount = 6
stateActive.isTrackingPaused = false
stateActive.isSmartFilterEnabled = true
stateActive.isScreenshotWatcherEnabled = true
stateActive.isShakeClearEnabled = true
stateActive.isLaunchAtLoginEnabled = true

let viewActive = DeckControlCenterView(state: stateActive)
let hostActive = NSHostingController(rootView: viewActive)

let windowActive = NSWindow(
    contentRect: NSRect(x: 200, y: 300, width: 290, height: 350),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
windowActive.titleVisibility = .hidden
windowActive.titlebarAppearsTransparent = true
windowActive.isOpaque = false
windowActive.backgroundColor = .clear
windowActive.hasShadow = true
windowActive.contentViewController = hostActive
windowActive.makeKeyAndOrderFront(nil)

// 2. PAUSED STATE WINDOW
let emptyQueue = DeckQueueManager()
let statePaused = DeckControlCenterState(queueManager: emptyQueue)
statePaused.isTrackingPaused = true
statePaused.isSmartFilterEnabled = true
statePaused.isScreenshotWatcherEnabled = false
statePaused.isShakeClearEnabled = true
statePaused.isLaunchAtLoginEnabled = false

let viewPaused = DeckControlCenterView(state: statePaused)
let hostPaused = NSHostingController(rootView: viewPaused)

let windowPaused = NSWindow(
    contentRect: NSRect(x: 530, y: 300, width: 290, height: 350),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
windowPaused.titleVisibility = .hidden
windowPaused.titlebarAppearsTransparent = true
windowPaused.isOpaque = false
windowPaused.backgroundColor = .clear
windowPaused.hasShadow = true
windowPaused.contentViewController = hostPaused
windowPaused.makeKeyAndOrderFront(nil)

NSApp.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    let outputActive = "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_active.png"
    let outputPaused = "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_paused.png"
    
    let task1 = Process()
    task1.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task1.arguments = ["-l", "\(windowActive.windowNumber)", "-o", outputActive]
    try? task1.run()
    task1.waitUntilExit()

    let task2 = Process()
    task2.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task2.arguments = ["-l", "\(windowPaused.windowNumber)", "-o", outputPaused]
    try? task2.run()
    task2.waitUntilExit()
    
    // Also copy active to standard preview path
    try? FileManager.default.removeItem(atPath: "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview.png")
    try? FileManager.default.copyItem(atPath: outputActive, toPath: "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview.png")

    print("SNAPSHOTS_DONE")
    exit(0)
}

app.run()
