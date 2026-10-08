import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CoreVideo
import VideoToolbox
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

    /// Converts a local video file (MP4, MOV, WEBM) into an animated GIF Data in the background.
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

            var frames: [CGImage] = []
            for val in times {
                let time = val.timeValue
                if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                    frames.append(image)
                }
            }

            guard !frames.isEmpty,
                  let finalData = self.encodeImagesToGIF(frames: frames, fps: fps, maxWidth: maxWidth) else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            DispatchQueue.main.async {
                completion(finalData, finalData.count)
            }
        }
    }

    /// Converts an HLS (.m3u8) video stream into an animated GIF Data.
    public func convertHLS(
        streamURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player.rate = 1.0

        let frameInterval = 1.0 / fps
        let targetFrameCount = max(1, Int(maxDuration * fps))
        var frames: [CGImage] = []
        var tickCount = 0

        let timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] t in
            tickCount += 1
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time) {
                if let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    var cgImg: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(buf, options: nil, imageOut: &cgImg)
                    if let img = cgImg {
                        frames.append(img)
                    }
                }
            }

            if frames.count >= targetFrameCount || tickCount > Int(maxDuration * fps * 2.5) {
                t.invalidate()
                player.pause()

                guard let self = self, !frames.isEmpty else {
                    completion(nil, 0)
                    return
                }

                self.conversionQueue.async {
                    let gifData = self.encodeImagesToGIF(frames: frames, fps: fps, maxWidth: maxWidth)
                    DispatchQueue.main.async {
                        completion(gifData, gifData?.count ?? 0)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Assembles an array of CGImage frames into a slide-friendly looping GIF Data.
    private func encodeImagesToGIF(frames: [CGImage], fps: Double, maxWidth: CGFloat) -> Data? {
        guard !frames.isEmpty else { return nil }

        let gifData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            gifData as CFMutableData,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0 // Infinite loop
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameDuration = 1.0 / fps
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDuration
            ]
        ]

        for frame in frames {
            let finalImage: CGImage
            if CGFloat(frame.width) > maxWidth || CGFloat(frame.height) > maxWidth {
                let aspect = CGFloat(frame.width) / CGFloat(frame.height)
                let w = aspect >= 1.0 ? maxWidth : maxWidth * aspect
                let h = aspect >= 1.0 ? maxWidth / aspect : maxWidth
                if let ctx = CGContext(
                    data: nil,
                    width: Int(w),
                    height: Int(h),
                    bitsPerComponent: frame.bitsPerComponent,
                    bytesPerRow: 0,
                    space: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: frame.bitmapInfo.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                    finalImage = ctx.makeImage() ?? frame
                } else {
                    finalImage = frame
                }
            } else {
                finalImage = frame
            }

            CGImageDestinationAddImage(destination, finalImage, frameProperties as CFDictionary)
        }

        let success = CGImageDestinationFinalize(destination)
        return (success && gifData.length > 0) ? (gifData as Data) : nil
    }
}
