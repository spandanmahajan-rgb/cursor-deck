# CursorDeck ⧉

**CursorDeck** is a lightweight native macOS companion that lets you accumulate copied image references at your cursor and drop them simultaneously anywhere—Google Slides, WhatsApp, Figma, Slack, Keynote, and local folders.

Zero terminal needed. Zero accessibility or screen recording permissions. Always ready.

> 📖 **Developer & Architecture Reference**: For technical architecture, macOS system restrictions, breakthrough solutions, and the release pipeline, see [CURSOR_DECK_MASTER_DOC.md](CURSOR_DECK_MASTER_DOC.md).

---

## ✨ Features

- **Cursor Accumulator Pill**: As you copy images across web pages, screenshots, or folders, an ultra-compact glowing pill badge (`● 3 ⧉`) tracks near your pointer.
- **⌘ Fluid Magnet Snap**: Hold `CMD` (⌘) to snap the pill directly under your cursor pointer with a spring glide for instant click-and-drag.
- **Universal Burst Drop**: Drag from the badge and release onto **Google Slides, WhatsApp chats, Figma, Slack, or Finder**—all images land simultaneously.
- **Smart Filter (Zero Design Tool Clutter)**: Automatically detects and ignores internal shape/vector copies inside **Adobe Illustrator, Photoshop, Figma, and Sketch**.
- **Auto-Run at Startup**: Runs quietly in the background upon login (0% Dock clutter, clean `⧉` menu bar extra).
- **Featherlight Footprint**: Written in pure native Swift & AppKit. Uses ~15MB RAM and 0% CPU at rest.

---

## 🚀 Installation

1. Download the latest **`CursorDeck-v<version>.dmg`** from the **[Releases page](https://github.com/spandanmahajan-rgb/cursor-deck/releases/latest)**.
2. Double-click the DMG and drag **CursorDeck** into your **Applications** folder.
3. Open **CursorDeck** from your Applications folder.

> **Note for first launch**: Because CursorDeck is independent and open-source, on first open macOS may show an unidentified developer prompt. Simply **Right-click CursorDeck in Applications → Open → Open**. You only need to do this once!

---

## 🕹 How to Use

1. **Copy Images**: Press `Cmd + C` on any image on Google, Pinterest, Twitter, screenshots, or Finder. The compact emerald badge (`● 1 ⧉`) appears beside your cursor.
2. **Hold ⌘ (Command)**: The badge magnetically glides to your cursor pointer.
3. **Drag & Drop**: Click and drag from the badge into your destination (Google Slides, WhatsApp, Figma, Slack, or Finder) and release. All references are dropped at once!

---

## 🛠 Menu Bar Controls (`⧉`)

Click the `⧉` icon in your macOS menu bar to:
- **Copy Batch to Clipboard**: Export the full accumulated batch to clipboard.
- **Clear Deck**: Reset the queue anytime (`Cmd + K`).
- **⏸ Pause Tracking / ▶ Resume Tracking**: Temporarily mute clipboard monitoring (`P`).
- **Smart Filter**: Toggle automatic exclusion of design software.
- **Launch at Startup**: Toggle auto-start on macOS login.

---

## 📄 License
Copyright © 2026 Spandan Mahajan. Licensed under the **[PolyForm Noncommercial License 1.0.0](LICENSE)**.

You're welcome to read, learn from and use CursorDeck for personal and other noncommercial purposes. **Commercial use, including selling it or shipping it inside a paid product, is not permitted** without written permission. For commercial licensing, contact me via GitHub.

Created with ❤️ for Mac creators and power users.
