import Foundation

public final class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()

    private let agentLabel = "com.cursordeck.app"
    private var plistURL: URL {
        let libraryDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return libraryDir.appendingPathComponent("\(agentLabel).plist")
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

    public func installLaunchAgent() {
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let appPath = "/Applications/CursorDeck.app/Contents/MacOS/CursorDeckApp"
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
