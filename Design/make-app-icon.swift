// Regenerates the app icon from Design/logo.png.
//
//   swift Design/make-app-icon.swift Design/logo.png /tmp/icon_1024.png
//   swift Design/make-app-icon.swift --tight Design/logo.png /tmp/icon_tight.png
//
// then `sips -z` the first into each size in Cheese/Resources/Assets.xcassets/AppIcon.appiconset.
//
// logo.png is 1024 px artwork whose rounded tile already sits on Apple's macOS icon grid (an
// 824 px body centred on the canvas) but on a white backdrop. This clips the artwork to the tile's
// continuous-corner outline, so the backdrop and its baked shadow become transparent. `--tight`
// crops to the tile itself (no grid margin), for favicons and touch icons that are shown small.
// The body rect and corner radius were measured from the current logo.png; re-measure if it changes.
import AppKit
import SwiftUI

var arguments = Array(CommandLine.arguments.dropFirst())
let tight = arguments.first == "--tight"
if tight {
    arguments.removeFirst()
}
guard arguments.count == 2 else {
    print("usage: make-app-icon [--tight] <logo.png> <out.png>")
    exit(1)
}

let canvasSize = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 180
// Pulled in a little so the white backdrop doesn't fringe the anti-aliased edge.
let fringeInset: CGFloat = 1.5

guard
    let logo = NSImage(contentsOf: URL(filePath: arguments[0])),
    let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil),
    source.width == canvasSize, source.height == canvasSize,
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    print("couldn't read \(arguments[0]) as \(canvasSize)×\(canvasSize) artwork")
    exit(1)
}

let mask = body.insetBy(dx: fringeInset, dy: fringeInset)
let outline = RoundedRectangle(cornerRadius: cornerRadius - fringeInset, style: .continuous).path(in: mask).cgPath
let canvas = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
context.interpolationQuality = .high
context.setShouldAntialias(true)
context.addPath(outline)
context.clip()
context.draw(source, in: canvas)

guard var icon = context.makeImage() else {
    print("couldn't render the icon")
    exit(1)
}
if tight {
    // CGImage cropping is top-left based; the body is centred, so the rect is the same either way.
    guard let cropped = icon.cropping(to: body) else {
        print("couldn't crop the icon")
        exit(1)
    }
    icon = cropped
}
guard let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]) else {
    print("couldn't encode the icon")
    exit(1)
}
try png.write(to: URL(filePath: arguments[1]))
