# CursorDeck — Comprehensive Codebase Audit & Optimization Prompt (v1.1.8)

> **Instructions for Claude**:
> You are acting as a Senior macOS AppKit & Systems Swift Engineer auditing the **CursorDeck** codebase (v1.1.8).
>
> Your objective is to perform a rigorous, line-by-line review across all Swift files in `Sources/` to identify:
> 1. **Code Bloat & Dead Code**: Redundant helpers, unused types, legacy workarounds that are no longer needed, and duplicated logic.
> 2. **Memory Leaks & Retain Cycles**: Unreleased `NSEvent` monitors, strong reference cycles in closures (`[weak self]`), `CVPixelBuffer`/`CGImage` buffer retention in video conversion, and `DispatchSource` lifecycle management.
> 3. **Thread Safety & Concurrency**: Races on `DeckQueueManager`, main-thread UI dispatch safety (`DispatchQueue.main`), and Swift 6 concurrency readiness.
> 4. **Modern macOS API Compliance**: Deprecated API warnings (e.g., `AVURLAsset.duration` in macOS 13+), WindowServer multi-display edge cases, and Apple Silicon efficiency.
> 5. **Disk & Resource Management**: Temporary file lifecycle in `/private/tmp/cursor-deck/` ensuring no disk space leakage over prolonged system uptime.
>
> Provide specific, actionable corrections with before/after code diffs.

---

## 1. Project Context & Architectural Invariants

* **What CursorDeck Is**: An ambient visual accumulator attached to the mouse pointer (`[ N ⧉ ]`). Users copy images or Pinterest video links (`⌘C`), take screenshots (`⌘⇧4`), accumulate them in a liquid frosted-glass pill tracking the cursor, and burst-drop them onto Google Slides, Keynote, Figma, or chat (WhatsApp/Slack).
* **Stack**: 100% Native Swift (Swift 6.1.2) + AppKit + SwiftUI. Universal Binary (Apple Silicon + Intel).
* **Strict Constraint — ZERO System Permissions**: The app MUST NOT request Accessibility (`AXUIElement`), Screen Recording, or Input Monitoring permissions. All mouse tracking, clipboard sensing, and screenshot ingestion must remain non-intrusive.
* **Strict Constraint — Zero-Password In-Place Updates**: Updates MUST NOT trigger admin password / Touch ID prompts in `/Applications`.

---

## 2. Priority Files & Specific Areas to Audit

### 1. `Sources/CursorDeckCore/MenuBarManager.swift` & `DeckControlCenterPanel.swift`
* **Outside Click Monitors**:
  ```swift
  globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { ... }
  localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { ... }
  ```
  - *Audit*: Verify that every open/close cycle completely tears down and zeroes monitors without leakage.
  - *Audit*: Check the timestamp debounce (`now - lastDismissTimestamp < 0.25`) to ensure no race conditions when rapidly clicking the menu bar icon.
* **Multi-Monitor & Coordinate Calculation**:
  - Check `buttonWindow.convertToScreen(sender.bounds)`: Does it accurately handle secondary displays, displays positioned above/below the main screen, and MacBook display notches (`screen.auxiliaryTopLeftArea` / `safeAreaInsets`)?
* **Panel Configuration**:
  - Verify that `DeckControlCenterPanel` adheres strictly to `.popUpMenu` level without conflicting with other status bar items or active modal windows.

### 2. `Sources/CursorDeckCore/DeckControlCenterView.swift`
* **View Hierarchy & Sizing**:
  - Both `controlsPage` and `howToUsePage` are constrained to `256 × 350 pt`.
  - *Audit*: Is there unnecessary SwiftUI view re-evaluation or redundant state variables (e.g. `hoveredRow`, `hoveredAction`, `isHowToUseHovered`)?
  - *Audit*: Verify `KeycapBadgeView` rendering performance inside `ScrollView(.vertical)`. Are tokens recomputed on every frame? Could token parsing be memoized or statically declared?
* **State Binding**:
  - `DeckControlCenterState`: Check observer registration with `DeckQueueManager`. Is the token properly invalidated on deinit?

### 3. `Sources/CursorDeckCore/VideoToGIFConverter.swift`
* **Compiler Warning**:
  ```swift
  let durationSeconds = CMTimeGetSeconds(asset.duration)
  // Warning: 'duration' was deprecated in macOS 13.0: Use load(.duration) instead
  ```
  - *Audit*: Modernize to async `try await asset.load(.duration)` or structured concurrency to remove the deprecation warning while maintaining backward compatibility with macOS 13.
* **Memory Management in Frame Generation**:
  - Does the frame sampling loop (`AVAssetImageGenerator` or `CVPixelBuffer`) accumulate unreleased `CGImage` references inside autorelease pools?
  - Wrap frame processing in `autoreleasepool { ... }` blocks to prevent memory spikes when converting large 4-second videos into GIFs.
* **Timeout & Error Recovery**:
  - If a corrupted video URL is passed, does `conversionQueue` cleanly exit and invoke the completion handler, or can it hang indefinitely?

### 4. `Sources/CursorDeckCore/ClipboardWatcher.swift`
* **Async Retry Ladder**:
  - Polling interval is 80ms, ladder intervals: `35ms → 80ms → 150ms → 280ms`.
  - *Audit*: If the user rapidly copies multiple items in under 200ms, does an in-flight retry ladder overwrite or race against a newer copy?
  - *Audit*: Is `isPaused` checked at *every* stage of the retry ladder to prevent paused item queuing?
* **Smart Filter Heuristics**:
  - Review the rejection conditions for Adobe Illustrator, Photoshop, and Figma. Are there edge cases where legitimate external image copies from Figma (e.g., "Copy as PNG") are erroneously filtered out?

### 5. `Sources/CursorDeckCore/ScreenshotWatcher.swift`
* **Kernel Dispatch Source**:
  - Uses `DispatchSource.makeFileSystemObjectSource` on `~/Desktop`.
  - *Audit*: Does `ScreenshotWatcher` correctly cancel and nullify the dispatch source on deinit?
  - *Audit*: File writing race condition: When macOS writes a new screenshot file, it can take 50–150ms to finish flushing bytes to disk. Does `ScreenshotWatcher` verify the file is completely written before reading (`Data(contentsOf:)`), or could it ingest a 0-byte partial screenshot?

### 6. `Sources/CursorDeckCore/DeckQueueManager.swift` & Disk Storage
* **Session Cache Lifecycle**:
  - Temporary files are stored in `/private/tmp/cursor-deck/session_<UUID>/`.
  - *Audit*: Are session directories deleted on app termination (`applicationWillTerminate`)?
  - *Audit*: If the app crashes or the Mac is restarted without clean exit, do orphan directories accumulate in `/private/tmp/`? Add a startup purge for stale directories older than 24 hours.
* **Thread Safety**:
  - `items: [DeckItem]` is protected by an internal lock or queue. Is array access completely atomic during simultaneous observer notifications?

### 7. `Sources/CursorDeckCore/CursorHUDPanel.swift` & `DeckHUDView.swift`
* **Cursor Tracking Loop**:
  - Tracks cursor position at 60fps via timer / display link.
  - *Audit*: Does the tracking timer pause when the deck is empty (`items.isEmpty`)? Keeping a 60fps timer firing continuously while empty wastes battery power.
  - *Audit*: Ensure the tracking loop sleeps when the display turns off or the Mac enters low-power mode.

### 8. `Sources/CursorDeckCore/UpdateManager.swift`
* **Update Security & Sanitation**:
  - Validates GitHub release JSON payloads.
  - *Audit*: Verify that downloaded URLs are strictly hosted on `github.com` or `githubusercontent.com` before executing ditto extraction.
  - *Audit*: Verify that quarantine removal (`xattr -cr`) and the PID swap shell script handle paths containing spaces or quotes safely.

---

## 3. Desired Audit Output Format

Please organize your audit findings into the following sections:

### Section 1: Executive Audit Summary
- **Overall Codebase Health Rating** (1 to 10).
- Key highlights of what is done exceptionally well.
- Primary areas of concern categorized by severity (**Critical**, **High**, **Medium**, **Low/Polishing**).

### Section 2: Code Bloat & Redundancy Analysis
- Specific unused functions, variables, imports, or dead code paths to delete.
- Opportunities to simplify complex methods.

### Section 3: Memory & Resource Leak Vulnerabilities
- Identified retain cycles, uncollected event monitors, or un-autoreleased buffer allocations.
- Concrete code fixes for each.

### Section 4: Concurrency, Threading & Race Conditions
- Thread safety analysis across `DeckQueueManager`, `ClipboardWatcher`, and `UpdateManager`.
- Concrete synchronization improvements.

### Section 5: Modernization & API Cleanups
- Elimination of deprecation warnings (`load(.duration)` in `VideoToGIFConverter`).
- Swift 6 strict concurrency readiness.

### Section 6: Ready-to-Apply Diffs
- Provide exact unified git diffs or clean code replacements for the most impactful fixes so they can be merged directly.
