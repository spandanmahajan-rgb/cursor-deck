import AppKit
import Foundation

/// Manages checking for GitHub Releases, downloading, and auto-updating CursorDeck in-place.
public final class UpdateManager {
    public static let shared = UpdateManager()

    public static let currentVersion = "1.1.8"
    public static let repoOwner = "spandanmahajan-rgb"
    public static let repoName = "cursor-deck"

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

    private var isChecking = false

    private init() {}

    /// Checks GitHub for new releases.
    /// - Parameter userInitiated: If true, shows an alert when already up-to-date or on error. If false, fails silently.
    public func checkForUpdates(userInitiated: Bool) {
        if !userInitiated {
            // Background check: throttle to at most once every 24 hours
            let lastCheck = UserDefaults.standard.double(forKey: "CursorDeck_lastBackgroundCheck")
            let now = Date().timeIntervalSince1970
            if now - lastCheck < 86400 {
                return
            }
        }

        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("CursorDeck-App", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if !userInitiated {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CursorDeck_lastBackgroundCheck")
                }

                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if userInitiated {
                        self.showAlert(
                            title: "Check for Updates",
                            message: "Unable to check for updates right now. Please check your internet connection.",
                            button: "OK"
                        )
                    }
                    return
                }

                self.handleReleaseResponse(json, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleReleaseResponse(_ json: [String: Any], userInitiated: Bool) {
        guard let tagName = json["tag_name"] as? String else {
            if userInitiated {
                showAlert(title: "CursorDeck", message: "No release information found.", button: "OK")
            }
            return
        }

        let cleanRemoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let cleanCurrentVersion = UpdateManager.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let isNewer = compareVersions(cleanRemoteVersion, cleanCurrentVersion) > 0

        if !isNewer {
            if userInitiated {
                showAlert(
                    title: "You're Up to Date!",
                    message: "CursorDeck \(cleanCurrentVersion) is currently the newest version available.",
                    button: "OK"
                )
            }
            return
        }

        // If background check, check if user previously clicked "Later" for this specific version
        if !userInitiated {
            if let snoozed = UserDefaults.standard.string(forKey: "CursorDeck_snoozedVersion"),
               snoozed == cleanRemoteVersion {
                return
            }
        }

        // Newer version found!
        let body = (json["body"] as? String) ?? "A new update for CursorDeck is available."
        let htmlURL = (json["html_url"] as? String) ?? "https://github.com/\(UpdateManager.repoOwner)/\(UpdateManager.repoName)/releases"

        // Search for downloadable zip (preferred for seamless passwordless in-place update) or pkg
        var downloadURL: URL?
        var isZip = true

        if let assets = json["assets"] as? [[String: Any]] {
            // First check for ZIP for silent, passwordless auto-update
            for asset in assets {
                if let name = asset["name"] as? String,
                   let downloadString = asset["browser_download_url"] as? String,
                   let url = URL(string: downloadString),
                   name.lowercased().hasSuffix(".zip") {
                    downloadURL = url
                    isZip = true
                    break
                }
            }

            // Fallback to PKG if ZIP not present
            if downloadURL == nil {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       let downloadString = asset["browser_download_url"] as? String,
                       let url = URL(string: downloadString),
                       name.lowercased().hasSuffix(".pkg") {
                        downloadURL = url
                        isZip = false
                        break
                    }
                }
            }
        }

        promptUserToUpdate(
            remoteVersion: cleanRemoteVersion,
            releaseNotes: body,
            downloadURL: downloadURL,
            fallbackWebURL: URL(string: htmlURL)!,
            isZip: isZip
        )
    }

    private func promptUserToUpdate(
        remoteVersion: String,
        releaseNotes: String,
        downloadURL: URL?,
        fallbackWebURL: URL,
        isZip: Bool
    ) {
        let alert = NSAlert()
        alert.messageText = "CursorDeck \(remoteVersion) Available"
        alert.informativeText = "A newer version of CursorDeck is available (you currently have \(UpdateManager.currentVersion)).\n\nRelease Notes:\n\(releaseNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.removeObject(forKey: "CursorDeck_snoozedVersion")
            if let downloadURL = downloadURL {
                performDownloadAndInstall(from: downloadURL, isZip: isZip, remoteVersion: remoteVersion)
            } else {
                NSWorkspace.shared.open(fallbackWebURL)
            }
        } else {
            // User clicked "Later": snooze this version for background checks
            UserDefaults.standard.set(remoteVersion, forKey: "CursorDeck_snoozedVersion")
        }
    }

    private func performDownloadAndInstall(from url: URL, isZip: Bool, remoteVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Downloading Update..."
        alert.informativeText = "CursorDeck \(remoteVersion) is downloading in the background. Once ready, the installer will launch automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        URLSession.shared.downloadTask(with: url) { [weak self] tempFileUrl, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                guard let tempFileUrl = tempFileUrl, error == nil else {
                    self.showAlert(
                        title: "Update Failed",
                        message: "The download could not be completed: \(error?.localizedDescription ?? "Unknown error")",
                        button: "OK"
                    )
                    return
                }

                if isZip {
                    self.installZipUpdate(downloadedFile: tempFileUrl)
                } else {
                    self.installPkgUpdate(downloadedFile: tempFileUrl)
                }
            }
        }.resume()
    }

    private func installZipUpdate(downloadedFile: URL) {
        let tempExtractDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CursorDeckUpdate_\(UUID().uuidString)")

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", downloadedFile.path, tempExtractDir.path]

        do {
            try ditto.run()
            ditto.waitUntilExit()

            let appPath = tempExtractDir.appendingPathComponent("CursorDeck.app").path
            guard FileManager.default.fileExists(atPath: appPath) else {
                showAlert(title: "Update Failed", message: "The update archive did not contain CursorDeck.app.", button: "OK")
                return
            }

            let destinationPath = Bundle.main.bundlePath.hasPrefix("/Applications") ? Bundle.main.bundlePath : "/Applications/CursorDeck.app"
            let currentPID = ProcessInfo.processInfo.processIdentifier

            let isDestinationWritable = FileManager.default.isWritableFile(atPath: destinationPath)

            if !isDestinationWritable {
                // Requires admin privileges to overwrite root-owned /Applications bundle
                let script = "rm -rf '\(destinationPath)' && cp -R '\(appPath)' '\(destinationPath)' && xattr -cr '\(destinationPath)' && open '\(destinationPath)'"
                let appleScriptSource = "do shell script \"\(script)\" with administrator privileges"
                var errorDict: NSDictionary?
                if let appleScript = NSAppleScript(source: appleScriptSource) {
                    appleScript.executeAndReturnError(&errorDict)
                    if errorDict == nil {
                        NSApplication.shared.terminate(nil)
                        return
                    }
                }
            }

            // Standard non-privileged swap script waiting for PID exit
            let swapScript = """
            while kill -0 \(currentPID) 2>/dev/null; do
                sleep 0.1
            done
            rm -rf "\(destinationPath)"
            cp -R "\(appPath)" "\(destinationPath)"
            xattr -cr "\(destinationPath)" 2>/dev/null || true
            open "\(destinationPath)"
            rm -rf "\(tempExtractDir.path)"
            """

            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", swapScript]
            try relauncher.run()

            NSApplication.shared.terminate(nil)
        } catch {
            showAlert(title: "Update Error", message: "Failed to extract and install update: \(error.localizedDescription)", button: "OK")
        }
    }

    private func installPkgUpdate(downloadedFile: URL) {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CursorDeck-Installer.pkg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: downloadedFile, to: dest)
            NSWorkspace.shared.open(dest)
            NSApplication.shared.terminate(nil)
        } catch {
            showAlert(title: "Update Error", message: "Failed to launch package installer: \(error.localizedDescription)", button: "OK")
        }
    }

    private func showAlert(title: String, message: String, button: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: button)
        alert.runModal()
    }

    /// Compares two semver strings (e.g., "1.1.0" vs "1.0.0"). Returns >0 if v1 > v2, <0 if v1 < v2, 0 if equal.
    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let p1 = v1.split(separator: ".").compactMap { Int($0) }
        let p2 = v2.split(separator: ".").compactMap { Int($0) }

        let count = max(p1.count, p2.count)
        for i in 0..<count {
            let num1 = i < p1.count ? p1[i] : 0
            let num2 = i < p2.count ? p2[i] : 0
            if num1 != num2 {
                return num1 > num2 ? 1 : -1
            }
        }
        return 0
    }
}
