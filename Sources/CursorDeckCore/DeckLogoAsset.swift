// CursorDeck
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/cursor-deck
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// Official brand logo icon for CursorDeck (two solid stacked cards).
public enum DeckLogoAsset {
    /// 64x64 Retina PNG asset (transparent background, transparent separator gap, solid white cards)
    private static let base64Data = """
    iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAQKADAAQAAAABAAAAQAAAAABGUUKwAAADzUlEQVR4Ae2byWsUQRTG01GJuK8oLgfxIhKiHlQ8CBo8RAWFgEHwIAmoBw8iATFevHiSXETNwfUPMLcoEiWIiiseokluLigYwSVRE4JRk/H3TaaG7pCe7onRme7qB99Uddernvd99bq6GqqdkgBLpVLLcVkL1oAasAAMgf9tk/jDN+Aa6ATtjuN8pvw3BvEtoBn0gGK0boK6AComVAEuOA9cAkMgCtZHkCfBlPEI4bg7cRGlezPY4D4fkbriruW26M8n3qwAkJ9Lx1awPp8LFJmv5od9iPArbFyTXY6nqY+H/A/69YIBkAKFslL+uBIcAufCBpEWgNHfTIfasJ3w0+x7I4PnlB+BhCikAMrm6WAmCG0mA47QQ4+ZINMoS93zpNm70c4IGeYao7tN5HEvcX3J54IOQS+hQxeYE9Cxg/aD/MFj40ffddSrgCbNpWAaKLQpC/uA1gwPQCsxv6Ic2yCxEwTZfRwWmytQ3whawE9Q7PaVALVeWGHi95Q0NAQw6KR9kelE/RgYCOhTjM1aOFUbHtmSk205ou2nLbsmoN6YwzcKTcpYz2SvR4dmTj9r4v55qkY6aqKs93OMyHmtFpvgstXEKwH8Hl2aTc/IkQ7lFKdUj4FNhYNEmC0uEsDPrjP67zONJyhn+DlG8PwqYq5T3LkEaJEDSmn23KV6zKwObmV+AmhVpxWerBLkmifSThH8WU3M5X4C6P7/lCE1nveDKOgh7hV+AmjJqyyQLRspYvlb4yfAMHTN06EsltRHSFX5CRBjzl5qiQBePew7SjLAvjH3Mk4ywKuHfUdJBtg35l7GSQZ49bDvKMkA+8bcyzjJAK8e9h0lGWDfmHsZJxng1cO+oyQD7BtzL+MkA9DDahFEXttJrDUJcNta9hCXAC9sF6AdAbTR0UorZRPEB5jfspI9pM0TQFthftsoQloAsuAR5C9aK0CG+HHKh5m6QynE3swtUEIWfIftHqBs0MZI7aaKvWUFEFNE6KbYDi6D+SDuNmh2i2eJIsI3DurZQWV2fuf1BUb2QtGoXPVkgDtmhBjKHL90n49Zvc1XABdRMzG6TsWiqk1g7WEEuIujFktxMw3s60ABuBV6cLwSN/bwOQu34VDPeiZEPRGegJUxEULfO+3WPBeYASKMo3aOHgDaQBl106c0h0VeREIJIEc63KHYD6L8WBT5ari8pUxbaAHkTUd9nbkDmI3UOh0Vu0mg2+Cg1/+/M+aEWeAo6ADDoFhtkMDugb1gzMEONQn6ycVF9b6gT+s3gQawEBSDdRFEI3gGuhj1lF9QfwCap18iPJ/dqgAAAABJRU5ErkJggg==
    """

    /// AUDIT: these were computed properties that base64-decoded the PNG and built a new NSImage on EVERY
    /// access (updateStatusItemBadge() ran that on every deck change). Decode once.
    private static func makeImage(size: NSSize?) -> NSImage {
        guard let data = Data(base64Encoded: base64Data),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        if let size = size { img.size = size }
        img.isTemplate = true
        return img
    }

    /// Sized specifically for macOS system menu bar (15x15 pt, standard optical weight)
    public static let menuBarImage: NSImage = makeImage(size: NSSize(width: 15, height: 15))

    /// Sized specifically for floating cursor pill (10x10 pt, subtle and balanced)
    public static let pillImage: NSImage = makeImage(size: NSSize(width: 10, height: 10))
}
