// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation

public final class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()

    private let agentLabel = "com.que.app.login"
    /// The LaunchAgent CursorDeck 1.x wrote; replaced by Que's own on first launch (see `migrateLegacyAgent`).
    private let legacyAgentLabel = "com.cursordeck.app"
    private let launchAgentsDir: URL
    private var plistURL: URL { launchAgentsDir.appendingPathComponent("\(agentLabel).plist") }
    private var legacyPlistURL: URL { launchAgentsDir.appendingPathComponent("\(legacyAgentLabel).plist") }

    /// `launchAgentsDirectory` is for tests; the app uses ~/Library/LaunchAgents.
    public init(launchAgentsDirectory: URL? = nil) {
        launchAgentsDir = launchAgentsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func setEnabled(_ enable: Bool) {
        if enable {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    /// The app this Login Item opens: the running copy when it's in /Applications, else the standard location.
    public var appExecutablePath: String {
        if Bundle.main.bundlePath.hasPrefix("/Applications"), let exe = Bundle.main.executablePath { return exe }
        return "/Applications/Que.app/Contents/MacOS/Que"
    }

    /// CursorDeck 1.x → Que: swap the old Login Item for Que's (keeping whether it was on), and keep the path
    /// current if the app moved (e.g. renamed from CursorDeck.app to Que.app). Safe to call on every launch.
    public func migrateLegacyAgent() {
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyPlistURL.path) {
            try? fm.removeItem(at: legacyPlistURL)
            installLaunchAgent()
        } else if isEnabled,
                  let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (plist["ProgramArguments"] as? [String])?.first != appExecutablePath {
            installLaunchAgent()
        }
    }

    public func installLaunchAgent() {
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let appPath = appExecutablePath
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    public func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
