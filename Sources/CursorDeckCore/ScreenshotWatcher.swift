import AppKit
import Foundation

/// Automatically monitors the macOS screenshot directory (default: ~/Desktop)
/// for newly taken screenshots (Cmd+Shift+4, Cmd+Shift+3, Cmd+Shift+5)
/// and seamlessly adds them into the CursorDeck queue.
public final class ScreenshotWatcher {
    private let queueManager: DeckQueueManager
    private var source: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var processedFilePaths: Set<String> = []
    private var watchedDirectoryURL: URL
    private let monitorQueue = DispatchQueue(label: "com.cursordeck.screenshotwatcher", qos: .utility)

    /// Whether screenshot auto-collection is enabled
    public var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    /// Common localized and third-party screenshot filename prefixes
    private let screenshotPrefixes: [String] = [
        "screenshot",
        "screen shot",
        "cleanshot",
        "shottr",
        "capture d’écran",
        "capture d'ecran",
        "bildschirmfoto",
        "captura de pantalla",
        "schermopname"
    ]

    private let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "tiff"
    ]

    public init(queueManager: DeckQueueManager) {
        self.queueManager = queueManager
        self.watchedDirectoryURL = Self.resolveScreenshotDirectory()

        // Seed existing files on startup so we only capture NEW screenshots taken while running
        seedExistingFiles()
    }

    deinit {
        stop()
    }

    /// Resolves the user's screenshot destination folder from macOS defaults (defaults to ~/Desktop)
    public static func resolveScreenshotDirectory() -> URL {
        if let customLocation = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !customLocation.isEmpty {
            let expanded = NSString(string: customLocation).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Standard macOS default is ~/Desktop
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Desktop").expandingTildeInPath, isDirectory: true)
    }

    private func seedExistingFiles() {
        let path = watchedDirectoryURL.path
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for file in existing {
                processedFilePaths.insert(path + "/" + file)
            }
        }
    }

    public func start() {
        guard source == nil else { return }

        self.watchedDirectoryURL = Self.resolveScreenshotDirectory()
        let path = watchedDirectoryURL.path

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("[ScreenshotWatcher] Failed to open directory for monitoring: \(path)")
            return
        }

        self.directoryFileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: monitorQueue
        )

        src.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }

        src.setCancelHandler { [weak self] in
            if let fd = self?.directoryFileDescriptor, fd >= 0 {
                close(fd)
                self?.directoryFileDescriptor = -1
            }
        }

        src.resume()
        self.source = src
        print("[ScreenshotWatcher] Monitoring screenshots in: \(path)")
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func handleDirectoryChange() {
        guard isEnabled else { return }

        let dirPath = watchedDirectoryURL.path
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

        let now = Date()

        for filename in files {
            let fullPath = dirPath + "/" + filename
            guard !processedFilePaths.contains(fullPath) else { continue }

            let url = URL(fileURLWithPath: fullPath)
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let lowerName = filename.lowercased()
            let isScreenshotName = screenshotPrefixes.contains { lowerName.hasPrefix($0) }

            // Check file attributes
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let creationDate = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date,
                  let fileSize = attrs[.size] as? Int, fileSize > 100 else {
                continue
            }

            // Only consider files created within the last 15 seconds
            let age = now.timeIntervalSince(creationDate)
            guard age >= 0 && age < 15.0 else {
                processedFilePaths.insert(fullPath)
                continue
            }

            if isScreenshotName {
                processedFilePaths.insert(fullPath)

                // Wait 200ms to allow macOS screenshot utility to finish flushing file to disk
                monitorQueue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self = self else { return }
                    // Re-verify file exists and has size
                    guard let updatedAttrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                          let updatedSize = updatedAttrs[.size] as? Int, updatedSize > 500 else {
                        return
                    }

                    DispatchQueue.main.async {
                        print("[ScreenshotWatcher] Captured new screenshot: \(filename) (\(updatedSize) bytes)")
                        self.queueManager.add(existingFileURL: url)
                    }
                }
            }
        }
    }
}
