// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation
import ImageIO

/// Small downsampled-thumbnail cache shared by the preview grid and the drag session.
///
/// AUDIT: before this, DeckPreviewPanel decoded every FULL-size image on the main thread each time the
/// grid was (re)built (every copy, every delete), and DeckHUDView did the same for all items when a drag
/// started. A 40-item deck of 5K screenshots meant tens of full decodes per rebuild. Now each image is
/// decoded once (pre-warmed in the background when it is added) and reused.
public final class DeckThumbnailCache {
    public static let shared = DeckThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let workQueue = DispatchQueue(label: "com.cursordeck.thumbnails", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 200
    }

    /// Returns the cached thumbnail, decoding it now (synchronously) on a cache miss.
    /// Returns nil if ImageIO can't read the file (e.g. SVG); callers keep their old fallbacks.
    public func thumbnail(for url: URL, maxPixel: Int = 192) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = Self.decodeThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Decodes in the background so the first preview / drag is instant.
    public func prewarm(_ url: URL, maxPixel: Int = 192) {
        if cache.object(forKey: url as NSURL) != nil { return }
        workQueue.async { [weak self] in
            guard let self = self, self.cache.object(forKey: url as NSURL) == nil,
                  let image = Self.decodeThumbnail(url: url, maxPixel: maxPixel) else { return }
            self.cache.setObject(image, forKey: url as NSURL)
        }
    }

    public func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    private static func decodeThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
