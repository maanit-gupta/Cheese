// Regenerates the app icon from Design/logo.png.
//
//   swift Design/make-app-icon.swift Design/logo.png /tmp/icon_1024.png
//   then `sips -z` it into each size in Cheese/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Crops the icon tile out of the artwork (dropping the backdrop) and lays it on Apple's
// macOS icon grid: an 824 px rounded-rect body centred on a transparent 1024 px canvas.
// The crop rect is specific to the current logo.png; re-measure it if the artwork changes.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-app-icon <logo.png> <out.png>")
    exit(1)
}

let tile = CGRect(x: 194, y: 194, width: 636, height: 636)  // just inside the tile's border
let canvasSize = 1024
let bodySize = CGFloat(824)
let cornerRadius = bodySize * 0.235

guard
    let logo = NSImage(contentsOf: URL(filePath: arguments[1])),
    let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil),
    let cropped = source.cropping(to: tile),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    print("couldn't read \(arguments[1])")
    exit(1)
}

let inset = (CGFloat(canvasSize) - bodySize) / 2
let body = CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
context.interpolationQuality = .high
context.addPath(CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.clip()
context.draw(cropped, in: body)

guard
    let icon = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:])
else {
    print("couldn't render the icon")
    exit(1)
}
try png.write(to: URL(filePath: arguments[2]))
