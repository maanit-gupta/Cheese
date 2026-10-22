import AppKit

/// Drags onto the menu bar icon: what they carry, and the icon's highlight while one hovers.
@MainActor
enum StatusItemDropHandler {
    /// What the icon takes: files, images, links and text.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]

    static func payload(from pasteboard: NSPasteboard) -> DropPayload? {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let webURL = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first { !$0.isFileURL }
        let image = fileURLs.isEmpty ? imagePNG(from: pasteboard) : nil
        return DropPayload.resolve(fileURLs: fileURLs, imagePNG: image, webURL: webURL, string: pasteboard.string(forType: .string))
    }

    private static func imagePNG(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// A soft accent pill behind the icon while a drag hovers, with one small pulse as it arrives.
    static func setHighlighted(_ highlighted: Bool, _ button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.cornerRadius = DesignTokens.Radius.small
        layer.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
        layer.removeAnimation(forKey: "dropPulse")
        guard highlighted, !DesignTokens.reducesMotion else { return }
        // Scale about the button's center; layer-backed views anchor at their corner.
        let size = layer.bounds.size
        let toCenter = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        let fromCenter = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [1, 1.12, 1].map { scale in
            NSValue(caTransform3D: CATransform3DConcat(CATransform3DConcat(fromCenter, CATransform3DMakeScale(scale, scale, 1)), toCenter))
        }
        pulse.duration = DesignTokens.Duration.gentle * 1.2
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pulse, forKey: "dropPulse")
    }
}
