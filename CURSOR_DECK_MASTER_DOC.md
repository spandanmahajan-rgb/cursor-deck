# CursorDeck — Master Project & Architecture Guide

> **Living Documentation**: This document is the single source of truth for **CursorDeck**. It captures the product vision, complete feature set, macOS system constraints, critical engineering hurdles, breakthrough solutions, and operational workflows.

---

## 1. Executive Summary & Product Motive

### The Problem
Designers, researchers, and creators gathering visual references suffer from constant, exhausting context switching:
1. Find an image on Pinterest/Chrome/Figma.
2. Copy it (`⌘C`).
3. Switch apps to Google Slides, Keynote, Miro, or Figma.
4. Paste it (`⌘V`).
5. Arrange it.
6. Switch back to browser.
7. Repeat 30 to 50 times per deck or moodboard.

### The Solution: CursorDeck
**CursorDeck** is a lightweight, ambient macOS utility that transforms the mouse cursor into a **visual accumulator** (`[ N ⧉ ]`). 
- As you browse, images accumulate fluidly in a floating frosted glass pill following your cursor.
- When ready, a single drag gesture burst-drops all accumulated images simultaneously into your slides, canvas, or chat.
- **Zero Friction**: Operates invisibly in the background with zero intrusive setup, zero required system permissions, and near-zero CPU/battery consumption.

---

## 2. Core Philosophy & Design Principles

* **100% Native Swift & AppKit**: No Electron, no web wrapper, no bloated runtime. Swift 6.1.2 compiled to Universal Binaries (Apple Silicon M1–M4 + Intel).
* **Zero System Permissions**: Operates completely without Accessibility API (`AXUIElement`) permissions, Screen Recording permissions, or Input Monitoring permissions. Runs as a background Agent (`LSUIElement: true`).
* **Ambient & Non-Intrusive**: Only appears when items are actively accumulated in the deck. Disappears completely when empty.
* **Apple Golden Gate Aesthetic**: Strictly adheres to Apple Human Interface Guidelines (HIG) with `Material.ultraThin` vibrancy, continuous rounded corners, and native SF Symbols iconography.

---

## 3. Complete Feature Set & User Gestures

| Feature | Gesture / Trigger | Description |
| :--- | :--- | :--- |
| **Collect Images** | `⌘C` or Right-Click Copy | Automatically intercepts copied images from web browsers, Finder, and desktop apps. |
| **Screenshots** | `⌘⇧3` / `⌘⇧4` / `⌘⇧5` | Directly ingests newly taken desktop screenshots into the pill without desktop clutter. |
| **Pinterest to GIF** | Copy Pin URL (`⌘C`) | Detects Pinterest video pin URLs, extracts the MP4/HLS stream, clips up to 4s, converts to high-framerate looping GIF, and queues it. |
| **Drop on Slides** | `⌘ + Drag` → Release `⌘` | Hold `⌘` to snap the pill to the mouse, drag over Google Slides/Keynote/Figma, release `⌘` when the green `+` drop badge appears, and drop. |
| **Copy for Chat** | `⌘ + Click` on Pill | Arms the system pasteboard with all batch images. Pressing `⌘V` in WhatsApp Desktop, Slack, or Telegram pastes all images at once. |
| **Preview Grid** | `⌥ + Click` (Option-Click) | Unfurls a floating frosted glass grid displaying all accumulated thumbnails with individual `✕` delete buttons. Dismisses on `⌥ + Click`, clicking outside, or moving the cursor away (Esc can't reach it: the grid never takes keyboard focus). |
| **Shake to Clear** | Rapid cursor wiggle | Vigorously shaking the mouse back and forth clears the deck with a dissolve animation. `⌥ + Shake` pops only the last item. |
| **Control Center Popover** | Click Menu Bar Icon | Arrowless floating 256×350 pt glass panel with toggles (Smart Filter, Screenshots, Shake Clear, Launch at Login), actions (Copy All, Grid, Clear), and "How to Use" guide. |
| **In-App Auto Updater** | "Check for Updates..." | Automatic background check against GitHub Releases; performs silent, passwordless in-place app replacement. |

---

## 4. Key Architectural Hurdles, OS Restrictions & Breakthroughs

Building an interactive accumulator that floats alongside the cursor across macOS spaces without root or accessibility permissions presented unique engineering challenges:

### Hurdle 1: The Zero-Permissions Constraint
* **The Restriction**: Traditional macOS clipboard managers require Accessibility (`AXUIElement`) or Input Monitoring permissions to track keystrokes, detect copy events, and position floating windows. Users dislike granting invasive accessibility permissions for simple utilities.
* **The Breakthrough**:
  * Mouse positioning is achieved via polling `NSEvent.mouseLocation` synced to display refresh ticks (`60fps`) without needing event tap hooks.
  * Clipboard detection uses `NSPasteboard.general.changeCount` polling (at 80ms) with lightweight diffing.
  * Screenshot ingestion uses a kernel-level `DispatchSourceFileSystemObject` watching the user's Desktop directory.
  * **Result**: CursorDeck requires **zero permissions** in macOS System Settings.

---

### Hurdle 2: WindowServer & Space Switching Glitches
* **The Restriction**: Floating `NSPanel` overlays on macOS often disappear during full-screen app transitions, get hidden beneath full-screen spaces, or turn completely opaque/transparent when background windows change.
* **The Breakthrough**:
  1. Configured `NSPanel` with `.borderless, .nonactivatingPanel` and window level `.popUpMenu` (or `.screenSaver` for grid preview).
  2. Set `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`. Crucially, removed `.stationary`, which was causing macOS WindowServer to drop the panel during Mission Control / Space swipes.
  3. Switched `NSVisualEffectView` blending mode from `.behindWindow` to `.withinWindow` so vibrancy is calculated within the panel itself regardless of background window changes.
  4. Added `NSWorkspace.didActivateApplicationNotification` observer to immediately re-order the floating pill to the front whenever the active app changes.

---

### Hurdle 3: Multi-Part Clipboard Race Conditions (The "First Copy" Bug)
* **The Restriction**: Chromium browsers (Google Chrome, Arc, Brave) and WebKit (Safari) do not write images to `NSPasteboard` atomically. When a user right-clicks and copies an image, the browser writes text/HTML markers first, and writes the raw image bitmap up to 100–250ms later in a background thread. Standard interval polling was dropping the image or capturing null data.
* **The Breakthrough**:
  * Implemented an **Asynchronous Retry Ladder** in `ClipboardWatcher.swift`.
  * When a change in `changeCount` is detected, if valid image data isn't immediately found, the watcher re-polls across a stepped exponential ladder: `35ms → 80ms → 150ms → 280ms`.
  * **Result**: 100% capture reliability across all browsers and electron apps without increasing steady-state CPU usage.

---

### Hurdle 4: Vector Canvas Noise (Smart Filter)
* **The Restriction**: Design tools like Adobe Illustrator attach synthetic compatibility TIFF images to *every* copied vector path, bezier curve, or text frame. Copying a simple rectangle in Illustrator would falsely trigger the pill.
* **The Breakthrough**:
  * Built a multi-tier heuristic **Smart Filter** in `ClipboardWatcher`:
    1. Rejects any pasteboard containing `com.adobe.illustrator` pasteboard types unless an explicit disk image URL is present.
    2. Rejects images accompanied by plain text strings that match internal clipboard payloads.
    3. Filters out tiny icon fragments and 1x1 tracking pixels.
  * **Result**: Only genuine images and photos enter the deck.

---

### Hurdle 5: WindowServer `Command + Click` Conflict
* **The Restriction**: Initially, opening the Grid Preview was assigned to `Command + Click` on the pill. However, macOS WindowServer hardcodes `Command + Click` on non-activating windows as an OS-level window pass-through / move gesture. This caused Chromium and Finder drag coordinators to intercept the click, preventing the pill's hold timer from triggering.
* **The Breakthrough**:
  * Decoupled the triggers:
    * `⌘ + Drag`: Strictly reserved for the drop-to-slides drag session.
    * `⌥ + Click` (Option-Click): Dedicated to opening the **Preview Grid**. Option clicks pass through cleanly to AppKit mouse handlers without OS window manager conflicts.

---

### Hurdle 6: Eliminating the Popover Triangular Pointer/Arrow
* **The Restriction**: AppKit's `NSPopover` inherently forces a triangular nib/arrow pointing directly at the status bar button. There is no public API on `NSPopover` to disable the arrow.
* **The Breakthrough**:
  * Replaced `NSPopover` with a custom `DeckControlCenterPanel` subclassing `NSPanel`:
    * Style mask: `[.borderless, .nonactivatingPanel]`
    * Level: `.popUpMenu`
    * Background: `.clear` with `isOpaque = false` and `hasShadow = true`
    * Geometry: Positioned exactly 4 pt below the status item button bounds, centered horizontally and clamped to screen boundaries.
    * Dismissal: Managed via `NSEvent.addGlobalMonitorForEvents` and `NSEvent.addLocalMonitorForEvents` with a timestamp debounce to prevent double-toggle clicks on the menu bar button.
  * **Result**: Clean, modern macOS floating utility panel with continuous 14 pt rounded corners and zero top pointer.

---

### Hurdle 7: The Admin Password Trap during In-App Updates
* **The Restriction**: Traditional macOS `.pkg` installers write to `/Applications` using `installer` daemon, which forces a macOS administrative authentication prompt (Touch ID / system password). Users find password prompts annoying for frequent minor updates.
* **The Breakthrough**:
  * Restructured the release and update pipeline to prioritize `CursorDeck.zip` over PKG:
    1. Downloads `CursorDeck.zip` in the background.
    2. Unpacks via `/usr/bin/ditto` to a temporary directory.
    3. Checks if `/Applications/CursorDeck.app` is user-writable (default on macOS for user-installed apps).
    4. Launches a detached background shell script that monitors the current PID:
       ```bash
       while kill -0 <PID> 2>/dev/null; do sleep 0.1; done
       rm -rf "/Applications/CursorDeck.app"
       cp -R "<Extracted>/CursorDeck.app" "/Applications/CursorDeck.app"
       xattr -cr "/Applications/CursorDeck.app"
       open "/Applications/CursorDeck.app"
       ```
    5. Terminates the running app cleanly. The background script instantly completes the swap and relaunches the new version.
  * **Result**: **100% silent, passwordless, 1-click in-place update**.

---

## 5. Codebase Directory Map (`Sources/`)

```
Sources/
├── CursorDeckApp/
│   └── main.swift                     # App lifecycle, NSApplication initialization, agent policy
│
├── CursorDeckCore/
│   ├── DeckQueueManager.swift         # In-memory item store + disk cache (/private/tmp/cursor-deck/)
│   ├── DeckItem.swift                 # Data model (UUID, file URL, thumbnail, timestamp, dimensions)
│   ├── CursorHUDPanel.swift           # 60fps cursor-following NSPanel, displayLink sync
│   ├── DeckHUDView.swift              # Frosted glass pill UI, drag source coordinator, gestures
│   ├── DeckPreviewPanel.swift         # Frosted glass grid preview window (thumbnails, delete buttons)
│   ├── PasteboardWriter.swift         # Arms clipboard for multi-item chat paste (WhatsApp, Slack)
│   ├── ClipboardWatcher.swift         # 80ms pasteboard poller with Async Retry Ladder & Smart Filter
│   ├── ScreenshotWatcher.swift        # DispatchSource kernel watcher on ~/Desktop for screenshots
│   ├── PinterestMediaResolver.swift   # URL parser & API scraper for Pinterest video pin MP4 streams
│   ├── VideoToGIFConverter.swift      # AVFoundation + CGImageDestination 4s looping GIF converter
│   ├── ShakeDetector.swift            # Mouse reversal frequency & travel velocity detector
│   ├── MenuBarManager.swift           # NSStatusItem, status badge, right-click menu, panel controller
│   ├── DeckControlCenterPanel.swift   # Arrowless floating NSPanel for Control Center dropdown
│   ├── DeckControlCenterView.swift    # SwiftUI Control Center (Master switch, toggles, How to Use)
│   ├── DeckLogoAsset.swift            # Procedural drawing for solid card-stack menu bar icon
│   ├── LaunchAtLoginManager.swift     # LaunchAgent plist persistence (~/Library/LaunchAgents/)
│   └── UpdateManager.swift            # GitHub Releases API client, version compare, in-place swapper
│
└── CursorDeckTests/
    └── main.swift                     # Unit tests for queue manager, smart filter, and pin resolver
```

---

## 6. Build, Testing & Deployment Pipeline

### Automated Release Command
The entire build, codesigning, packaging, git tagging, and GitHub release is automated via:

```bash
./scripts/release.sh <version> "<release_notes>"
# Example:
./scripts/release.sh 1.1.8 "Arrowless Popover, How to Use Guide, Breathable Keycaps"
```

### What `scripts/release.sh` Executes:
1. **Version Sync**: Updates `UpdateManager.currentVersion` and `CursorDeck.app/Contents/Info.plist`.
2. **Universal Compilation**:
   - `swift build -c release --triple arm64-apple-macosx` (Apple Silicon)
   - `swift build -c release --triple x86_64-apple-macosx` (Intel)
   - Stitches binaries with `lipo -create`.
3. **Codesigning**: Ad-hoc deep codesign with `codesign --force --deep -s - CursorDeck.app`.
4. **Auto-Updater Zip**: Packages `CursorDeck.zip` via `ditto -c -k --sequesterRsrc --keepParent`.
5. **DMG Disk Image**: Stitches standard drag-and-drop installer `CursorDeck-v<VERSION>.dmg` with `/Applications` symlink via `hdiutil`.
6. **Git Release**: Commits changes to `main`, pushes to GitHub, and invokes `gh release create v<VERSION>` uploading both `.dmg` and `.zip`.

---

## 7. Current Project State & Ongoing Discussions

* **Current Released Version**: **v1.2.0**
* **Repository**: `spandanmahajan-rgb/cursor-deck`
* **Under Discussion**:
  * **Update Discovery**: Designing non-intrusive ways to alert users to new releases (e.g., subtle blue accent dot on menu bar logo + contextual banner inside the popover).

---
*Note: Whenever changes, architectural decisions, or new features are introduced, update this document to keep the project context complete and evergreen.*
