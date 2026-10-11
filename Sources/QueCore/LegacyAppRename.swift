// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation

/// CursorDeck was renamed Que in 2.0. Updaters in CursorDeck 1.x install the new version over
/// /Applications/CursorDeck.app (they can't be changed any more), so on its first launch Que renames its own
/// bundle to Que.app and reopens from there. Nothing happens if the bundle already has the new name, if a
/// Que.app already exists next to it, or if the folder isn't writable (it then simply keeps the old file name).
public enum LegacyAppRename {
    public static let legacyBundleName = "CursorDeck.app"
    public static let bundleName = "Que.app"

    /// Where `bundlePath` should move to, or nil when it isn't a CursorDeck-named bundle.
    public static func targetPath(for bundlePath: String) -> String? {
        let url = URL(fileURLWithPath: bundlePath)
        guard url.lastPathComponent == legacyBundleName else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(bundleName).path
    }

    /// Renames the bundle and returns its new path, or nil if nothing was (or could be) renamed.
    @discardableResult
    public static func renameIfNeeded(bundlePath: String = Bundle.main.bundlePath) -> String? {
        guard let target = targetPath(for: bundlePath) else { return nil }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target) else { return nil }
        do {
            try fm.moveItem(atPath: bundlePath, toPath: target)
            return target
        } catch {
            return nil
        }
    }

    /// Opens `path` once this process has exited (a detached shell outlives us), so only one copy ever runs.
    public static func reopen(at path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                             "sh", "\(pid)", path]
        try? process.run()
    }
}
