// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AppKit

public final class DeckQueueManager {
    public private(set) var items: [DeckItem] = []
    public private(set) var sessionDirectory: URL

    // AUDIT: base directory is now stored (clear() used to hard-code it and ignore a custom base)
    private let baseDirectory: URL

    public var count: Int {
        return items.count
    }

    public var isEmpty: Bool {
        return items.isEmpty
    }

    private var observers: [UUID: ([DeckItem]) -> Void] = [:]

    @discardableResult
    public func addObserver(_ observer: @escaping ([DeckItem]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    private func notifyObservers() {
        let currentItems = items
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (_, observer) in self.observers {
                observer(currentItems)
            }
        }
    }

    public init(sessionBaseDirectory: URL? = nil) {
        // AUDIT: was the shared, world-writable /private/tmp/cursor-deck (0777), so any other account on the
        // Mac could read (or delete) clipboard images. The per-user temp dir (/var/folders/…/T) is 0700.
        let base = sessionBaseDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-deck", isDirectory: true)
        self.baseDirectory = base
        let sessionId = UUID().uuidString
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // AUDIT: main.swift keeps `queueManager` as a global, so deinit never runs at quit and every
        // launch/crash/force-quit/update left its session_* folder behind forever. Purge old ones at startup.
        // (Deliberately NOT deleted at quit: "⌘+Click arms the clipboard, then ⌘V in WhatsApp later" must
        // keep working even if the app is quit or auto-updates in between.)
        purgeStaleSessions()
        // Same 24h rule for the old shared folder, so leftovers from older versions stop lingering there.
        if sessionBaseDirectory == nil {
            purgeStaleSessions(in: Self.legacySharedBaseDirectory)
        }
    }

    private static let legacySharedBaseDirectory = URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)

    deinit {
        cleanup()
    }

    /// Removes session folders from previous runs that haven't been touched for 24 hours, so anything you
    /// dropped or armed on the clipboard recently (and any other running CursorDeck instance, e.g. a dev
    /// build next to the installed app) is never pulled out from under the receiving app.
    private func purgeStaleSessions(in directory: URL? = nil, olderThan age: TimeInterval = 86_400) {
        let base = directory ?? baseDirectory
        let currentName = sessionDirectory.lastPathComponent
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: []
            ) else { return }
            let cutoff = Date().addingTimeInterval(-age)
            for url in entries where url.lastPathComponent.hasPrefix("session_") && url.lastPathComponent != currentName {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// Returns true if the file was created or owned by CursorDeck, preventing self-capture loops
    public func owns(_ url: URL) -> Bool {
        // AUDIT: was `|| url.path.contains("cursor-deck")`, which silently ignored ANY file whose path merely
        // contained that text (e.g. images inside a project folder called cursor-deck). Match the real folder.
        let base = baseDirectory.resolvingSymlinksInPath().path
        let candidate = url.resolvingSymlinksInPath().path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    @discardableResult
    public func add(imageData: Data, extension fileExt: String = "png", originalName: String? = nil) -> DeckItem? {
        guard !imageData.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let itemId = UUID()
        let filename = originalName ?? "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(fileExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: targetURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            let item = DeckItem(
                id: itemId,
                type: .image,
                fileURL: targetURL,
                originalFileName: originalName,
                dataSize: imageData.count
            )
            items.append(item)
            DeckThumbnailCache.shared.prewarm(item.fileURL)
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
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
                    let item = DeckItem(
                        id: itemId,
                        type: .image,
                        fileURL: targetURL,
                        originalFileName: existingFileURL.lastPathComponent,
                        dataSize: pngData.count
                    )
                    items.append(item)
                    DeckThumbnailCache.shared.prewarm(item.fileURL)
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
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
            let item = DeckItem(
                id: itemId,
                type: .fileURL,
                fileURL: targetURL,
                originalFileName: existingFileURL.lastPathComponent,
                dataSize: fileSize
            )
            items.append(item)
            DeckThumbnailCache.shared.prewarm(item.fileURL)
            notifyObservers()
            return item
        } catch {
            print("[DeckQueueManager] Failed to copy item from \(existingFileURL): \(error)")
            return nil
        }
    }

    @discardableResult
    public func remove(id: UUID) -> DeckItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        DeckThumbnailCache.shared.evict(item.fileURL)
        try? FileManager.default.removeItem(at: item.fileURL)
        notifyObservers()
        return item
    }

    public func clear() {
        let oldSessionDirectory = self.sessionDirectory
        items.removeAll()
        DeckThumbnailCache.shared.removeAll()
        
        let sessionId = UUID().uuidString
        let base = baseDirectory
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
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

