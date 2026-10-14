# Que

**Copy it. Que it. Drop it.**

Que (say "queue") is a small native Mac app for collecting images. Copy images from anywhere and they join Que, a little glass badge that follows your pointer. When you're ready, drag Que into Google Slides, Keynote, Figma, Slack or WhatsApp and every image lands at once.

No setup: Que never asks for Accessibility, Screen Recording or Input Monitoring access.

> Developer and architecture notes: [QUE_MASTER_DOC.md](QUE_MASTER_DOC.md)

---

## What Que does

- **Collects as you copy.** Copy an image in a browser, Finder or a design app and it joins Que. Screenshots go straight in too, without landing on your desktop.
- **Pinterest boards and videos.** Copy a board link to add its pins, or a video link to get a looping GIF.
- **One drag drops everything.** Hold the Option key (⌥), or tap the Control key (⌃) twice: Que snaps under your pointer. Drag it onto your slide, canvas or chat.
- **Preview and pick.** Click Que while it's under your pointer to see what's in it, select images, drag some out or remove them.
- **Stays out of your way.** Ignores shapes copied inside Illustrator, Photoshop and Figma, skips password-manager copies, and pauses with one switch.
- **Light.** Pure Swift and AppKit, about 15 MB of memory and no CPU while idle.

## Install

1. Download **[Que.dmg](https://github.com/spandanmahajan-rgb/que/releases/latest/download/Que.dmg)** (always the latest version; release notes on the **[releases page](https://github.com/spandanmahajan-rgb/que/releases/latest)**).
2. Open it and drag **Que** into **Applications**.
3. Open **Que**. Its icon appears in the menu bar, and a short tour lets you choose how Que comes to you.

Que opens by itself when you log in. To stop that, turn off **Launch at Login** in the menu bar panel.

> **First launch:** Que isn't from the App Store, so the first time you open it macOS says "Que" Not Opened. Click **Done**, then open **System Settings › Privacy & Security**, scroll to the bottom and click **Open Anyway** (confirm with your password or Touch ID if asked). Que opens. You only need to do this once.

**Used CursorDeck?** Que is its new name. Download Que.dmg above, drag Que into Applications and open it; your settings carry over. Then you can move CursorDeck from Applications to the Trash.

## How to use

1. **Copy images** (⌘C or right-click › Copy Image). Que appears next to your pointer with a count.
2. **Hold the Option key (⌥)**, or **tap the Control key (⌃) twice** if you chose that in the tour. Que snaps under your pointer.
3. **Drag** onto Slides, Keynote, Figma, Slack, WhatsApp or Finder and let go. Everything drops at once.

Click the menu bar icon for the switches, Copy All, Clear, how Que comes to you, and the full **How to Use** guide. Right-click it for a quick menu.

## Build from source

Needs macOS 13 or later and Xcode's command line tools.

```bash
swift build && .build/debug/que-tests       # build and run the checks
./scripts/deploy-local.sh --check           # build a universal, ad-hoc signed ./Que.app without installing it
```

`./scripts/deploy-local.sh` (without `--check`) also swaps the result into /Applications/Que.app.

---

## License

Copyright © 2026 Spandan Mahajan. Licensed under the **[PolyForm Noncommercial License 1.0.0](LICENSE)**.

You're welcome to read, learn from and use Que for personal and other noncommercial purposes. **Commercial use, including selling it or shipping it inside a paid product, is not permitted** without written permission. For commercial licensing, contact me via GitHub.
