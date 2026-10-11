// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// The Que mark (a circle with a small dot), as template images: macOS tints them for light/dark menu bars and
/// the selected state. Each size has its own 1x and 2x drawing; the small sizes open the gap around the dot a
/// little so it doesn't merge into the circle (stronger at 1x, where there are fewer pixels).
public enum QueLogoAsset {
    private static let menuBar1x = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABP0lEQVR42oXTvU5VQRQF4O/+QEVCg0E6CaHQitLeJyDhAUy0ITQSQgEdJXYUvgFvQIsYE0JPQm+D0WA0FFIo99xLswaHk3tlJ5OZ7LXXPmvtmcO/6GWfxzY+4hu+4hhbwaCrFYX8FpcYTViXeNPi3B/2q8IBGgyzmuQK/r7d5HWAvymepKBJzSgcMIergP8j102acJ70sI7VSO15PDqpncEPOKl8TvrqALdVTZnPJ/ie5HACeTjGQsld9cfdaWIUuR18znt4gZUogikBx1lo8AdrLf97Vc0R7FQ+C3Cb/TDEPqbTQF7lARbgKX61rrE0eJebmWqpuI9uhribc2lQYrlq/BxnOMerqOrXz/FDy8IA11gMflLhX6Kq080Au9jAJn6mcw+zWXBTKfvdUvrgF32WSZ9mBsX3Uixc4GXh3AGBpI2vVYX33gAAAABJRU5ErkJggg=="
    private static let menuBar2x = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACx0lEQVR42sWXP2gUQRTGfzu3Z2KiAUWNIDbBSgMSVFJYKUSQWCh2ShAFqzRWipVga6echYWVEEGCVmqCIAiKiiI2BjU2EQstDIKBJOfd2rwXHpPZvd09Lw48bnduZr7v/Zn33kZkjwrQMO/7gEPAAWAA2AU0gS/ALPAaeAq8zzgj14hkI8B64DzwHFgGkhayBDwDzgHdhkRUBFwXnwBmPIA/Ig3RvinPOm/XfgCOB85NHU5+Y6BmDqoLSJJTGrJH32typsVI1bwXmDLaFgEOEVGrTMnZQUuoz2NgWjYstwHsi541LRirYkIDrtYBcJ/ETQ9z5WHU+DvpkCiJYxbbAV3AZxPRnSKgN2dWruiKG86YoEs6LIpx1gbgC2G2VgSawEu1wGCHgq6V1IG9DhgBqmXydRujIddxxAHD/L8x7KSqUaRY/IOhWAMR8BPYJH6J2jRrEijnWWcuxKZIlAXXoKpkEEv7rxJLUhiSq+FKgGtxeQU8BuYkyQxJKd4SIKFYHwEmSyYh7QV+A2MpBLcDE4EUr+X9AcDlkgS01B41/o490TFpakFdiCfASYD9JfK/anNbANZl9JQO6AOeeOSv2kXvCqZiJXxQACo5uiyAI1IDBv3AHy9QitV8C+Lj0A2KPFJxIMCdXbwR+JazHCuBX8DWAIHIA+4x79UQGWV6qkA3pER3C6DzwDcA14BPwFfgHrAnqylVEndzklBXXTKaKpFu+S7w98yL76MQCZ3sBd7kIKE54DvQL/urXjwtmg5oUeYeZVlBJ7cBb42mzRZWuCj7uuT3odeOW8LzwGbrLhdIjz+Aw8B9Y1rtYkJ5fqc3Vzdp2k/bjTx9hyU1Lma2mugnmFpg1LPAaeNCdcGSzE34LXlWvVYi/cAVKRy+G24Z0rrHAXcCa2eAHWlBmDZsPu8Rba/LbRkLfHTa5wvymT4H3BBFViWtvyWf/MG0gBV1AAAAAElFTkSuQmCC"
    private static let pill1x = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAq0lEQVR42m3QQWoCQRAF0OeMKG6D55ABs/ECXkECkpVnyNojeIKAmxEkW917CvcGvMFIYDIZF6mGieTDp+j+v+p3F+R+8YwdPnFBiWloyWOBCu0Dq9BAgTqEGj/B7l2RY4MJvtFHL4zCNMATXDtT2n9Y45rFhIQ2aokV9pEygo8wfEU9+Yu39KEpmohusI2UMZbIul2vnYk3DLGO83vaY1rmDAcc411znPECd99qNLDFYIT3AAAAAElFTkSuQmCC"
    private static let pill2x = "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABnElEQVR42p3Uv2oVURAG8N/dbIxga2EjqEQQMYWxEG20ErW6sdBGxN7eZ/ANfAQlhYIgViKCaKkQEGvBwipEBb3Jza7NHJnsvbtqDhz2/Jn55pvZ78zI3rGA3VivYg0XcQoNPuEtnuLDHJ8ZMDiJx/iFtmf+xKOwzb4zYDewlRynEb2JuRtn5X4rfPaAlsU4Ge4MsJtnM85YIxzH98Si/cdZ2P8IjFFhuf4fzPqYrhewM9iOSO0+ZxPAKxVuYjEO9zsa1LhVh87k/AdGYVTsRx3fC/Al0R5KazpwVny/1vNE2ZPSQgj6YzA6jYPxp6sArOBVkkCfNFo8wYkUZBnP4q68qtfwYCClAva+RI9vWS/iZdh8wzU4G2DNgMbuBcCB9CJKqZZwpcP+D/WdnqKvRd3qv6ihqsLgPiaRStORCRxNRW9xCe+wgTthUxffQv12ksC0U8MNHArAI9jsZHK+r+PcDaZtahTbsb8eNldjPwkZtZFhYTnTE1fxovOTNnEsGB7G53Q3wUpSwNxGC5fxEM+jZpnBObyJUowz2G8zp9Xr0kW3/wAAAABJRU5ErkJggg=="

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

    /// Inside the floating Que badge, next to the count.
    public static let pillImage: NSImage = makeImage(points: 10, oneX: pill1x, twoX: pill2x)
}
