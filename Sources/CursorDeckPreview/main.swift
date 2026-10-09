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

// 1. CONTROLS VIEW WINDOW
let stateActive = DeckControlCenterState(queueManager: queueManager)
stateActive.itemCount = 6
stateActive.isTrackingPaused = false
stateActive.isSmartFilterEnabled = true
stateActive.isScreenshotWatcherEnabled = true
stateActive.isShakeClearEnabled = true
stateActive.isLaunchAtLoginEnabled = true

let viewControls = DeckControlCenterView(state: stateActive, initialPage: .controls)
let hostControls = NSHostingController(rootView: viewControls)

let windowControls = NSWindow(
    contentRect: NSRect(x: 200, y: 300, width: 256, height: 350),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
windowControls.titleVisibility = .hidden
windowControls.titlebarAppearsTransparent = true
windowControls.isOpaque = false
windowControls.backgroundColor = .clear
windowControls.hasShadow = true
windowControls.contentViewController = hostControls
windowControls.makeKeyAndOrderFront(nil)

// 2. HOW TO USE VIEW WINDOW
let viewHowToUse = DeckControlCenterView(state: stateActive, initialPage: .howToUse)
let hostHowToUse = NSHostingController(rootView: viewHowToUse)

let windowHowToUse = NSWindow(
    contentRect: NSRect(x: 500, y: 300, width: 256, height: 350),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
windowHowToUse.titleVisibility = .hidden
windowHowToUse.titlebarAppearsTransparent = true
windowHowToUse.isOpaque = false
windowHowToUse.backgroundColor = .clear
windowHowToUse.hasShadow = true
windowHowToUse.contentViewController = hostHowToUse
windowHowToUse.makeKeyAndOrderFront(nil)

NSApp.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    let outputControls = "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_controls.png"
    let outputHowToUse = "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_how_to_use.png"
    
    let task1 = Process()
    task1.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task1.arguments = ["-l", "\(windowControls.windowNumber)", "-o", outputControls]
    try? task1.run()
    task1.waitUntilExit()

    let task2 = Process()
    task2.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task2.arguments = ["-l", "\(windowHowToUse.windowNumber)", "-o", outputHowToUse]
    try? task2.run()
    task2.waitUntilExit()
    
    // Also copy controls to standard active preview path
    try? FileManager.default.removeItem(atPath: "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_active.png")
    try? FileManager.default.copyItem(atPath: outputControls, toPath: "/Users/spandan/.gemini/antigravity/brain/88db0e41-5ddc-42ab-9bac-dca6c2e1a3c9/control_center_preview_active.png")

    print("SNAPSHOTS_DONE")
    exit(0)
}

app.run()
