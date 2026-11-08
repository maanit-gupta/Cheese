import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a movie into an animated GIF with ImageIO: frames taken at the GIF's frame rate,
/// scaled down to its width, looping forever.
enum GIFEncoder {
    @concurrent
    static func makeGIF(from movie: URL, to output: URL, settings: GIFSettings) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.export("The recording has no video")
        }
        let naturalSize = try await track.load(.naturalSize)
        let plan = GIFPlan(duration: duration, sourceSize: naturalSize, settings: settings)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = plan.size
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, plan.times.count, nil
        ) else {
            throw RecordingError.export("Couldn't create the GIF")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        let frame = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: plan.frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: plan.frameDelay,
            ],
        ] as CFDictionary

        let times = plan.times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var added = 0
        var last: CGImage?
        for await result in generator.images(for: times) {
            // A frame that can't be read repeats the one before, so the count stays as declared.
            guard let image = (try? result.image) ?? last else { continue }
            CGImageDestinationAddImage(destination, image, frame)
            last = image
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw RecordingError.export("Couldn't write the GIF")
        }
    }
}
