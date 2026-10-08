import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Converts videos into lightweight, slide-friendly animated GIFs.
/// Optimized specifically for presentation decks (Google Slides, Keynote, Figma, Notion):
///   • 500px resolution (sharp on slides, compact payload)
///   • 14 FPS (fluid loop, eliminates presentation lag)
///   • 4.0s maximum duration (perfect reference loop)
///   • Infinite loop enabled (plays continuously in slides)
///   • File sizes typically 1.5MB – 3.2MB (well within all presentation platform limits)
public final class VideoToGIFConverter {
    public static let shared = VideoToGIFConverter()

    private let conversionQueue = DispatchQueue(label: "com.cursordeck.gifconverter", qos: .utility)

    public init() {}

    /// Converts a local video file into an animated GIF Data in the background.
    public func convert(
        videoURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        conversionQueue.async {
            let asset = AVURLAsset(url: videoURL)
            let durationSeconds = CMTimeGetSeconds(asset.duration)
            guard durationSeconds > 0 && !durationSeconds.isNaN else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            let loopDuration = min(durationSeconds, maxDuration)
            let totalFrames = max(1, Int(loopDuration * fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let frameDuration = 1.0 / fps
            let times: [NSValue] = (0..<totalFrames).map { i in
                let time = CMTime(seconds: Double(i) * frameDuration, preferredTimescale: 600)
                return NSValue(time: time)
            }

            let gifData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                gifData as CFMutableData,
                UTType.gif.identifier as CFString,
                totalFrames,
                nil
            ) else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            let fileProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFLoopCount as String: 0 // Infinite loop
                ]
            ]
            CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frameDuration,
                    kCGImagePropertyGIFUnclampedDelayTime as String: frameDuration
                ]
            ]

            for val in times {
                let time = val.timeValue
                if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
                }
            }

            let success = CGImageDestinationFinalize(destination)
            if success && gifData.length > 0 {
                let finalData = gifData as Data
                DispatchQueue.main.async {
                    completion(finalData, finalData.count)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil, 0)
                }
            }
        }
    }
}
