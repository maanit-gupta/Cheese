import CoreImage
import CoreImage.CIFilterBuiltins

/// Makes sharp QR code images with Core Image.
enum QRGenerator {
    /// A QR code at error correction level M, scaled up by whole pixels (nearest neighbour) to at
    /// least `minimumPixels` wide. Nil when the message doesn't fit in a QR code.
    static func image(for message: String, minimumPixels: Int) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }

        let scale = max(1, (CGFloat(minimumPixels) / code.extent.width).rounded(.up))
        let scaled = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
