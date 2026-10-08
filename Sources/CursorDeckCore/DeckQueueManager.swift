import Foundation
import AppKit

public final class DeckQueueManager {
    public private(set) var items: [DeckItem] = []
    public private(set) var sessionDirectory: URL

    public var count: Int {
        return items.count
    }

    public var isEmpty: Bool {
        return items.isEmpty
    }

    public var onChange: (([DeckItem]) -> Void)? {
        didSet {
            notifyObservers()
        }
    }

    private var observers: [UUID: ([DeckItem]) -> Void] = [:]

    @discardableResult
    public func addObserver(_ observer: @escaping ([DeckItem]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        let currentItems = items
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onChange?(currentItems)
            for (_, observer) in self.observers {
                observer(currentItems)
            }
        }
    }

    public init(sessionBaseDirectory: URL? = nil) {
        let base = sessionBaseDirectory ?? URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)
        let sessionId = UUID().uuidString
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
    }

    deinit {
        cleanup()
    }

    /// Returns true if the file was created or owned by CursorDeck, preventing self-capture loops
    public func owns(_ url: URL) -> Bool {
        return url.path.hasPrefix(sessionDirectory.path) || url.path.contains("cursor-deck")
    }

    @discardableResult
    public func add(imageData: Data, extension fileExt: String = "png", originalName: String? = nil) -> DeckItem? {
        guard !imageData.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let itemId = UUID()
        let filename = originalName ?? "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(fileExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: targetURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
            let item = DeckItem(
                id: itemId,
                type: .image,
                fileURL: targetURL,
                originalFileName: originalName,
                dataSize: imageData.count
            )
            items.append(item)
            notifyObservers()
            return item
        } catch {
            print("[DeckQueueManager] Failed to write item: \(error)")
            return nil
        }
    }

    @discardableResult
    public func add(existingFileURL: URL) -> DeckItem? {
        let itemId = UUID()
        let ext = existingFileURL.pathExtension.lowercased()
        
        // Google Slides and web canvas editors strictly require PNG/JPEG/GIF/WEBP.
        // If the source file is HEIC, TIFF, or non-standard, convert it to high-res standard PNG!
        if ext == "heic" || ext == "tiff" || ext == "tif" || ext == "bmp" {
            if let image = NSImage(contentsOf: existingFileURL),
               let tiffData = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]) {
                let filename = "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).png"
                let targetURL = sessionDirectory.appendingPathComponent(filename)
                do {
                    try pngData.write(to: targetURL, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
                    let item = DeckItem(
                        id: itemId,
                        type: .image,
                        fileURL: targetURL,
                        originalFileName: existingFileURL.lastPathComponent,
                        dataSize: pngData.count
                    )
                    items.append(item)
                    notifyObservers()
                    return item
                } catch {
                    print("[DeckQueueManager] Failed to convert/write converted PNG: \(error)")
                }
            }
        }

        // Standard copy for directly supported image formats (png, jpg, jpeg, gif, webp, svg)
        let safeExt = ext.isEmpty ? "png" : ext
        let filename = "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(safeExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: existingFileURL, to: targetURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetURL.path)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
            let item = DeckItem(
                id: itemId,
                type: .fileURL,
                fileURL: targetURL,
                originalFileName: existingFileURL.lastPathComponent,
                dataSize: fileSize
            )
            items.append(item)
            notifyObservers()
            return item
        } catch {
            print("[DeckQueueManager] Failed to copy item from \(existingFileURL): \(error)")
            return nil
        }
    }

    public func removeLast() -> DeckItem? {
        guard let item = items.popLast() else { return nil }
        try? FileManager.default.removeItem(at: item.fileURL)
        notifyObservers()
        return item
    }

    @discardableResult
    public func remove(id: UUID) -> DeckItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        try? FileManager.default.removeItem(at: item.fileURL)
        notifyObservers()
        return item
    }

    public func clear() {
        let oldSessionDirectory = self.sessionDirectory
        items.removeAll()
        
        let sessionId = UUID().uuidString
        let base = URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        
        notifyObservers()

        // Keep previously dropped files on disk for 60 seconds so destination apps
        // (WhatsApp, Google Slides, Chrome, Finder) can asynchronously read and upload them!
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60.0) {
            try? FileManager.default.removeItem(at: oldSessionDirectory)
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}
