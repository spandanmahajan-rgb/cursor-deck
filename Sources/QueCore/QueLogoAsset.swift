// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// The Que mark (a circle with a small dot) for the menu bar, as template images: macOS tints them for light/dark
/// menu bars and the selected state. Each size has its own 1x and 2x drawing; the small sizes open the gap around the dot a
/// little so it doesn't merge into the circle (stronger at 1x, where there are fewer pixels).
public enum QueLogoAsset {
    private static let menuBar1x = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABP0lEQVR42oXTvU5VQRQF4O/+QEVCg0E6CaHQitLeJyDhAUy0ITQSQgEdJXYUvgFvQIsYE0JPQm+D0WA0FFIo99xLswaHk3tlJ5OZ7LXXPmvtmcO/6GWfxzY+4hu+4hhbwaCrFYX8FpcYTViXeNPi3B/2q8IBGgyzmuQK/r7d5HWAvymepKBJzSgcMIergP8j102acJ70sI7VSO15PDqpncEPOKl8TvrqALdVTZnPJ/ie5HACeTjGQsld9cfdaWIUuR18znt4gZUogikBx1lo8AdrLf97Vc0R7FQ+C3Cb/TDEPqbTQF7lARbgKX61rrE0eJebmWqpuI9uhribc2lQYrlq/BxnOMerqOrXz/FDy8IA11gMflLhX6Kq080Au9jAJn6mcw+zWXBTKfvdUvrgF32WSZ9mBsX3Uixc4GXh3AGBpI2vVYX33gAAAABJRU5ErkJggg=="
    private static let menuBar2x = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACx0lEQVR42sWXP2gUQRTGfzu3Z2KiAUWNIDbBSgMSVFJYKUSQWCh2ShAFqzRWipVga6echYWVEEGCVmqCIAiKiiI2BjU2EQstDIKBJOfd2rwXHpPZvd09Lw48bnduZr7v/Zn33kZkjwrQMO/7gEPAAWAA2AU0gS/ALPAaeAq8zzgj14hkI8B64DzwHFgGkhayBDwDzgHdhkRUBFwXnwBmPIA/Ig3RvinPOm/XfgCOB85NHU5+Y6BmDqoLSJJTGrJH32typsVI1bwXmDLaFgEOEVGrTMnZQUuoz2NgWjYstwHsi541LRirYkIDrtYBcJ/ETQ9z5WHU+DvpkCiJYxbbAV3AZxPRnSKgN2dWruiKG86YoEs6LIpx1gbgC2G2VgSawEu1wGCHgq6V1IG9DhgBqmXydRujIddxxAHD/L8x7KSqUaRY/IOhWAMR8BPYJH6J2jRrEijnWWcuxKZIlAXXoKpkEEv7rxJLUhiSq+FKgGtxeQU8BuYkyQxJKd4SIKFYHwEmSyYh7QV+A2MpBLcDE4EUr+X9AcDlkgS01B41/o490TFpakFdiCfASYD9JfK/anNbANZl9JQO6AOeeOSv2kXvCqZiJXxQACo5uiyAI1IDBv3AHy9QitV8C+Lj0A2KPFJxIMCdXbwR+JazHCuBX8DWAIHIA+4x79UQGWV6qkA3pER3C6DzwDcA14BPwFfgHrAnqylVEndzklBXXTKaKpFu+S7w98yL76MQCZ3sBd7kIKE54DvQL/urXjwtmg5oUeYeZVlBJ7cBb42mzRZWuCj7uuT3odeOW8LzwGbrLhdIjz+Aw8B9Y1rtYkJ5fqc3Vzdp2k/bjTx9hyU1Lma2mugnmFpg1LPAaeNCdcGSzE34LXlWvVYi/cAVKRy+G24Z0rrHAXcCa2eAHWlBmDZsPu8Rba/LbRkLfHTa5wvymT4H3BBFViWtvyWf/MG0gBV1AAAAAElFTkSuQmCC"

    private static let menuBarNoDot1x = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABG0lEQVR42oXTvUpDQRAF4C9/naWiVtrYWIivIvgAgjZ2EbHQypTaWfgGvoGtPwg+SkSJIraa3MRmVpclNxlY7rLnnNkzM3v5j1Z8l3GCe7ziBXc4DgyaikjiA/QxqVl97Beav81FRhyhwjhWFWcJvyyT7AXwE+Q6B1VwJqEBixgEOEucJ6lCs9TCIXbCasv8aAR3Ae/wkNVZd+sIw4yT+vMIb3E4rhGPp5SQzgbtaTONmITdBp7iPWxiOxxBR4DTSqjwjd0i8XnGuYXTrM4EDON7k93UDjdwhCuswgo+izGmBN2YTCebQCO304wmnsU+JUixkTVN5rCdO0qzvy5KGOELa3U/UP4wEtjFR9HMrXkJFIR19PAcCWeKfwH124bF8iiq9wAAAABJRU5ErkJggg=="
    private static let menuBarNoDot2x = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACcklEQVR42sWXsWsUURDGf/tuo1GJIKixsQlWEpAQQwqrCFEkFoqdIKKQKr1iJfg/XAoLmxSxCdoISRCEQERFCTaKGBvBQgtBMIW53K3NTBie7/be7t7GgeF2b3fn+97MvJl5CfnSANrmfhyYAiaAEeAU0AG+AJvAG+AF8D7HRpQk8iHAAWAWWAe2gayH/gHWgNvAoCGRFAHXl68CHz2AHdG2rL4j1/q/ffcDcCVgt6s4+U2BpjHUEpAsUtvyjd43xabF6LryQ8CKWW0R4BAR9cqK2A56QmOeAqvywXYFYF/V1qpg/JMTmnDNGsB9EvMe5u7FjIl3VpMqicsW2wH7gc8mo+sioDtnU7bobhhumqTLalbFuGUT8KUw2ysCHeCVemC0pqTrpS3gjAOmgYEy9bqCtGU7Tjtgkv8nk066GkWaRR9EsUYS4CdwROKSVHRrFmjneTa3UtMkyoJrUjVyiHV71kilKIzJ1nAlwLW5vAaWga9SZMakFR8NkFCsTwBLJYuQzgK/gRtdCJ4AFgMlXtv7U4B7JQloq71k4p16qrJkekFLiGfANYCzJeq/ruaRAOzLmSkdcBh47pF/YF/aKFiKlfA5AWhEbDmAC9IDRv1ncwVasbpvS2Ics4OSnPGPBBgCvkW2YyXwCzhWYAvbqcuFpqHrBaYhJXpaDLuqpVFJPI4koaG6a6boyrXZydT6NoKE1oDvwHDszB97JjgOvDMr7fTwwp0qXnCB8vgDOA88EaOJmWJCdf5kv1ulJTUnbrau1yOYemDGH7P71a+VyDBwXxqHH4aHvY5blCgQVlJZLcBBOZpflDx5BiwYG1kZAn8BbNbSkYp5h00AAAAASUVORK5CYII="

    /// Decoded once (these used to be rebuilt on every access).
    private static func makeImage(points: CGFloat, oneX: String, twoX: String) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for encoded in [oneX, twoX] {
            guard let data = Data(base64Encoded: encoded), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = image.size   // 16px or 32px drawn into the same 16pt box
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// Menu bar extra: 16pt (a circle reads smaller than a square, so this matches a 15pt square icon's weight).
    public static let menuBarImage: NSImage = makeImage(points: 16, oneX: menuBar1x, twoX: menuBar2x)

    /// The menu bar mark without its small circle: shown while an update is waiting, with a blue dot drawn in the
    /// circle's place (`updateDotRect`), so the dot can be coloured while the mark stays a template image.
    public static let menuBarImageWithoutDot: NSImage = makeImage(points: 16, oneX: menuBarNoDot1x, twoX: menuBarNoDot2x)

    /// Where the small circle sits in the 16pt menu bar mark (points, origin top-left).
    public static let updateDotRect = CGRect(x: 10.1, y: 12.0, width: 3.9, height: 3.9)

}
