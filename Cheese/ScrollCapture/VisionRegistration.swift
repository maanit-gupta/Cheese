import CoreGraphics
import Vision
import os

/// Fallback offset finder for frames whose rows don't match exactly (sub-pixel scrolling, animated content):
/// Vision's translational image registration on the scrolling parts of two frames.
enum VisionRegistration {
    static let fallback: StitchProgress.OffsetFallback = { previous, next, sticky in
        offset(previous: previous, next: next, sticky: sticky)
    }

    static func offset(previous: ImageBuffer, next: ImageBuffer, sticky: StickyRegion) -> Int? {
        let rows = sticky.contentRows(height: previous.height)
        guard let reference = previous.rows(rows)?.makeCGImage(),
              let floating = next.rows(rows)?.makeCGImage()
        else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        do {
            try VNImageRequestHandler(cgImage: reference).perform([request])
        } catch {
            Logger.scrollCapture.error("Image registration failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let transform = request.results?.first?.alignmentTransform,
              abs(transform.tx) <= 2
        else { return nil }

        // Vision's sign convention depends on which image it treats as moving; the caller verifies
        // whichever positive reading fits, so offer the magnitude.
        let offset = Int(abs(transform.ty).rounded())
        return offset > 0 && offset < rows.count ? offset : nil
    }
}
