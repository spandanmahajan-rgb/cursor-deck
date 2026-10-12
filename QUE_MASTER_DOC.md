# Que — Master Project & Architecture Guide

> **Living Documentation**: This document is the single source of truth for **Que** (called CursorDeck until v2.0; the name was changed in v2.0). It captures the product vision, complete feature set, macOS system constraints, critical engineering hurdles, breakthrough solutions, and operational workflows.

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

### The Solution: Que
**Que** is a lightweight, ambient macOS utility that transforms the mouse cursor into a **visual accumulator** (`[ ● N ]`). 
- As you browse, images accumulate fluidly in Que, a floating frosted glass badge following your cursor.
- When ready, a single drag gesture burst-drops all accumulated images simultaneously into your slides, canvas, or chat.
- **Zero Friction**: Operates invisibly in the background with zero intrusive setup, zero required system permissions, and near-zero CPU/battery consumption.

---

## 2. Core Philosophy & Design Principles

* **100% Native Swift & AppKit**: No Electron, no web wrapper, no bloated runtime. Swift 6.1.2 compiled to Universal Binaries (Apple Silicon M1–M4 + Intel).
* **Zero System Permissions**: Operates completely without Accessibility API (`AXUIElement`) permissions, Screen Recording permissions, or Input Monitoring permissions. Runs as a background Agent (`LSUIElement: true`).
* **Ambient & Non-Intrusive**: Only appears when items are in Que. Disappears completely when empty.
* **Apple Golden Gate Aesthetic**: Strictly adheres to Apple Human Interface Guidelines (HIG) with `Material.ultraThin` vibrancy, continuous rounded corners, and native SF Symbols iconography.

---

## 3. Complete Feature Set & User Gestures

| Feature | Gesture / Trigger | Description |
| :--- | :--- | :--- |
| **Collect Images** | `⌘C` or Right-Click Copy | Automatically intercepts copied images from web browsers, Finder, and desktop apps. |
| **Screenshots** | `⌘⇧3` / `⌘⇧4` / `⌘⇧5` | Directly ingests newly taken desktop screenshots into Que without desktop clutter. Que hides itself while the screenshot overlay is open (⌘⇧4 / ⌘⇧5), but stays visible in screen shares. |
| **Pinterest to GIF** | Copy Pin URL (`⌘C`) | Detects Pinterest video pin URLs, extracts the MP4/HLS stream, clips up to 4s, converts to high-framerate looping GIF, and queues it. While a video or pin is on its way, Que says so ("Making a GIF / Saving it a spot in Que.") and its dot turns grey and hops until it lands; failures are announced. |
| **Pinterest Boards** | Copy a board link | Que offers the board ("48 pins in “Board”"). `⌥ + Click` adds its pins to Que (skipping any already there); `⌥⇧ + Click` opens a picker to choose pins. Public boards only; up to 100 at a time, "Load More Pins" for the rest. |
| **Que Messages** | Automatic | Status and errors appear inside Que itself, which grows from its left edge to fit the text (e.g. "Pinterest request limit reached"). |
| **Drop Anywhere** | `⌥ + Drag` and drop | Hold `⌥` to snap Que to the mouse, drag it onto Google Slides, Keynote, Figma or a chat like WhatsApp, and let go (no need to release `⌥` first). Everything lands at once. `⌘` no longer moves Que (since v2.5), so `⌘`-click in browsers and design apps never lands on it. While you select text or drag something else, Que keeps following the pointer instead of freezing in place. |
| **Copy All** | Control Center or right-click menu | Puts every image in Que on the clipboard for pasting. (The `⌘ + Click` gesture for this was removed in v2.5: `⌥ + Drag` drops into chats directly.) |
| **Preview Grid** | `⌥ + Click` (Option-Click) | Unfurls a floating frosted glass grid displaying all accumulated thumbnails with individual `✕` delete buttons. Click thumbnails to select several (⇧-click for a range, Select All in the header), then drag them out together or remove them with the trash button; dragged images stay in Que. Holding `⌥` from the opening click still selects. Dismisses on `⌥ + Click` outside the thumbnails, clicking outside, or moving the cursor away (Esc can't reach it: the grid never takes keyboard focus). |
| **Shake to Clear** | Rapid cursor wiggle | Vigorously shaking the mouse back and forth clears Que with a dissolve animation. |
| **Control Center** | Click Menu Bar Icon | Opens as a native macOS menu (256×372 pt), so the menu bar icon stays highlighted while it's open, like Battery or Wi-Fi. Switches (Que on/off, Smart Filter, Screenshots, Shake to Clear, Launch at Login), actions (Copy All, Grid, Clear), the How to Use guide, Check for Updates, Quit and Report a Problem. |
| **Report a Problem** | Control Center or right-click menu | Opens a short Google Form in the browser with Que's version, macOS, the Mac's chip and Que's last few messages already filled in (board names and links removed; never clipboard contents or images). The user adds what happened and an optional email. Que sends nothing itself. |
| **Welcome Tour** | After installing from Que.dmg | A welcome window where the "que" logo forms itself (a dot falls in from above the window, lands in a "u" and its weight tumbles it into the q), then "Welcome to Que, you Quetie!", with a short page-by-page tour of the core moves, ending with "Open Que", which opens the menu bar panel. Shown whenever a fresh copy is installed by hand (new or returning users), never after an in-app update or on normal launches. Opens on the screen with the pointer. |
| **In-App Auto Updater** | "Check for Updates..." | Background checks against GitHub Releases (at launch, hourly while running, and when the menu opens). The update window lists what's new as short bullets. A new version turns the small circle of the menu bar icon blue, and "Check for Updates…" becomes "Update to Que x…" in the Control Center and right-click menu; nothing pops up on its own. Installs with a passwordless in-place app replacement. |

---

> **Naming**: users only ever see the name **Que** (the app, the floating badge and its contents). In code and in the
> sections below, the floating badge is called the *pill* and its contents the *deck* (`DeckQueueManager`, `DeckHUDView`…).
> Hidden identifiers kept from CursorDeck for compatibility: bundle ID `com.cursordeck.app`, pasteboard marker
> `com.cursordeck.internal-marker`, `CursorDeck_*` settings keys, and a `CursorDeck.app` copy inside `Que.zip`.

## 4. Key Architectural Hurdles, OS Restrictions & Breakthroughs

Building an interactive accumulator that floats alongside the cursor across macOS spaces without root or accessibility permissions presented unique engineering challenges:

### Hurdle 1: The Zero-Permissions Constraint
* **The Restriction**: Traditional macOS clipboard managers require Accessibility (`AXUIElement`) or Input Monitoring permissions to track keystrokes, detect copy events, and position floating windows. Users dislike granting invasive accessibility permissions for simple utilities.
* **The Breakthrough**:
  * Mouse positioning is achieved via polling `NSEvent.mouseLocation` synced to display refresh ticks (`60fps`) without needing event tap hooks.
  * Clipboard detection uses `NSPasteboard.general.changeCount` polling (at 80ms) with lightweight diffing.
  * Screenshot ingestion uses a kernel-level `DispatchSourceFileSystemObject` watching the user's Desktop directory.
  * **Result**: Que requires **zero permissions** in macOS System Settings.

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
  * **Later (v2.3.0)**: replaced by a real `NSMenu` holding the same SwiftUI content, because macOS only keeps the menu bar icon highlighted while a real menu is open. The custom panel was deleted.

---

### Hurdle 7: The Admin Password Trap during In-App Updates
* **The Restriction**: Traditional macOS `.pkg` installers write to `/Applications` using `installer` daemon, which forces a macOS administrative authentication prompt (Touch ID / system password). Users find password prompts annoying for frequent minor updates.
* **The Breakthrough**:
  * Restructured the release and update pipeline to prioritize `Que.zip` over PKG:
    1. Downloads `Que.zip` in the background.
    2. Unpacks via `/usr/bin/ditto` to a temporary directory.
    3. Checks if `/Applications/Que.app` is user-writable (default on macOS for user-installed apps).
    4. Launches a detached background shell script that monitors the current PID:
       ```bash
       while kill -0 <PID> 2>/dev/null; do sleep 0.1; done
       rm -rf "/Applications/Que.app"
       cp -R "<Extracted>/Que.app" "/Applications/Que.app"
       xattr -cr "/Applications/Que.app"
       open "/Applications/Que.app"
       ```
    5. Terminates the running app cleanly. The background script instantly completes the swap and relaunches the new version.
  * **Result**: **100% silent, passwordless, 1-click in-place update**.

---

## 5. Codebase Directory Map (`Sources/`)

```
Sources/
├── QueApp/
│   └── main.swift                     # App lifecycle, NSApplication initialization, agent policy
│
├── QueCore/
│   ├── DeckQueueManager.swift         # In-memory item store + disk cache ($TMPDIR/que/)
│   ├── DeckItem.swift                 # Data model (UUID, file URL, thumbnail, timestamp, dimensions)
│   ├── CursorHUDPanel.swift           # 60fps cursor-following NSPanel, displayLink sync
│   ├── DeckHUDView.swift              # Frosted glass pill UI, drag source coordinator, gestures
│   ├── DeckPreviewPanel.swift         # Frosted glass grid preview window (thumbnails, delete buttons)
│   ├── PasteboardWriter.swift         # Arms clipboard for multi-item chat paste (WhatsApp, Slack)
│   ├── ClipboardWatcher.swift         # 80ms pasteboard poller with Async Retry Ladder & Smart Filter
│   ├── ScreenshotWatcher.swift        # DispatchSource kernel watcher on ~/Desktop for screenshots
│   ├── PinterestMediaResolver.swift   # URL parser & API scraper for Pinterest video pin MP4 streams
│   ├── PinterestBoardResolver.swift   # Public board info + paged pins (fresh session per board, early-end retries)
│   ├── BoardImportController.swift    # Board offer, picker model, ordered downloads into the deck, duplicate tracking
│   ├── BoardPickerPanel.swift         # Board picker panel (grows out of the pill), SwiftUI grid of pins
│   ├── PillNotice.swift               # The one message type the pill shows, plus its wording catalogue
│   ├── OverlayScrollers.swift         # Thin overlay scroll bars without a track (TracklessScroller) in all panels
│   ├── VideoToGIFConverter.swift      # AVFoundation + CGImageDestination 4s looping GIF converter
│   ├── ShakeDetector.swift            # Mouse reversal frequency & travel velocity detector
│   ├── MenuBarManager.swift           # NSStatusItem, status badge, right-click menu, panel controller
│   ├── DeckControlCenterView.swift    # SwiftUI Control Center (Master switch, toggles, How to Use)
│   ├── QueLogoAsset.swift             # The Que mark as menu bar / badge template images (1x + 2x)
│   ├── LaunchAtLoginManager.swift     # LaunchAgent plist persistence (~/Library/LaunchAgents/), CursorDeck migration
│   ├── WelcomeWindow.swift            # First-launch welcome + tour for new users
│   ├── AnimatedWordmark.swift         # The welcome logo animation (wordmark split into its shapes)
│   ├── ProblemReport.swift            # Report a Problem: pre-filled form link + Que's recent messages (memory only)
│   ├── LegacyAppRename.swift          # One-time CursorDeck.app → Que.app rename after updating from CursorDeck 1.x
│   └── UpdateManager.swift            # GitHub Releases API client, version compare, in-place swapper
│
└── QueTests/
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
1. **Version Sync**: Updates `UpdateManager.currentVersion` and `Que.app/Contents/Info.plist`.
2. **Universal Compilation**:
   - `swift build -c release --triple arm64-apple-macosx` (Apple Silicon)
   - `swift build -c release --triple x86_64-apple-macosx` (Intel)
   - Stitches binaries with `lipo -create`.
3. **Codesigning**: Ad-hoc deep codesign with `codesign --force --deep -s - Que.app`.
4. **Auto-Updater Zip**: Packages `Que.zip` via `ditto -c -k --sequesterRsrc --keepParent`.
5. **DMG Disk Image**: Stitches standard drag-and-drop installer `Que.dmg` with `/Applications` symlink via `hdiutil`.
6. **Git Release**: Commits changes to `main`, pushes to GitHub, and invokes `gh release create v<VERSION>` uploading both `.dmg` and `.zip`.

---

## 7. Current Project State & Ongoing Discussions

* **Current Released Version**: **v2.6.0**
* **Repository**: `spandanmahajan-rgb/que` (renamed from `cursor-deck`; GitHub redirects the old address)
* **Under Discussion**: nothing open right now.

---
*Note: Whenever changes, architectural decisions, or new features are introduced, update this document to keep the project context complete and evergreen.*
