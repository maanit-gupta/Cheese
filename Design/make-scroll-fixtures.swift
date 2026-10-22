// Regenerates the scrolling-capture test fixtures in CheeseTests/Fixtures.
//
//   swift Design/make-scroll-fixtures.swift CheeseTests/Fixtures
//
// Draws a tall "web page" (text lines, colored boxes, blank gaps) and slices it into viewport frames the
// way a scrolling capture would see them: each frame has the same sticky header and footer, and the
// content between them shows the page at a different scroll offset. The last two frames are identical,
// like a capture that has reached the end of the page.
//
//   scroll-page.png        the page content alone (480 × 2400)
//   scroll-frame-N.png     viewport frames (480 × 700: 56 px header, 608 px content, 36 px footer)
//   scroll-expected.png    header + whole page + footer: what stitching the frames must produce
//
// Everything is deterministic, so regenerating produces identical files.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: make-scroll-fixtures <output folder>")
    exit(1)
}
let folder = URL(filePath: arguments[1], directoryHint: .isDirectory)

let width = 480
let pageHeight = 2400
let headerHeight = 56
let footerHeight = 36
let frameHeight = 700
let contentHeight = frameHeight - headerHeight - footerHeight
let offsets = [0, 400, 800, 1200, 1600, 1792, 1792]

guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }

/// A context whose drawing uses a top-left origin.
func makeContext(height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(1) }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    return context
}

func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: point.x, y: point.y + CTFontGetAscent(font))
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
    context.restoreGState()
}

/// A tiny deterministic generator so the page looks varied but never changes.
struct Generator {
    var state: UInt64 = 0x5EED
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

let words = ["cheese", "stitch", "scroll", "frame", "offset", "header", "pixel", "retina", "vision", "buffer",
             "menu", "clipboard", "window", "snap", "region", "capture", "annotate", "preview", "export", "history"]

func drawPage() -> CGImage {
    let context = makeContext(height: pageHeight)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))

    var random = Generator()
    var y = 16
    var line = 1
    while y < pageHeight - 24 {
        switch random.next(10) {
        case 0:
            // A blank gap, like the space between sections.
            y += 60 + random.next(60)
        case 1:
            let hue = CGFloat(random.next(360)) / 360
            let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor
            let boxHeight = 40 + random.next(50)
            context.setFillColor(color)
            context.fill(CGRect(x: 24 + random.next(80), y: y, width: 160 + random.next(200), height: boxHeight))
            y += boxHeight + 12
        default:
            let count = 3 + random.next(6)
            let text = "\(line). " + (0..<count).map { _ in words[random.next(words.count)] }.joined(separator: " ")
            drawText(text, at: CGPoint(x: 24 + random.next(40), y: y), size: 15, color: CGColor(gray: 0.1, alpha: 1), in: context)
            y += 24
            line += 1
        }
    }
    guard let image = context.makeImage() else { exit(1) }
    return image
}

func drawFrame(page: CGImage, offset: Int) -> CGImage {
    let context = makeContext(height: frameHeight)
    // Header: a dark bar with a title and a few "buttons".
    context.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: headerHeight))
    drawText("Sticky Header", at: CGPoint(x: 20, y: 18), size: 18, color: CGColor(gray: 1, alpha: 1), in: context)
    for index in 0..<3 {
        context.setFillColor(CGColor(red: 0.35, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 330 + index * 46, y: 16, width: 34, height: 24))
    }

    // Content: the page at this scroll offset. Page rows are top-left based, CGImage cropping too.
    if let slice = page.cropping(to: CGRect(x: 0, y: offset, width: width, height: contentHeight)) {
        context.saveGState()
        // Undo the flip for image drawing, which would otherwise come out upside down.
        context.translateBy(x: 0, y: CGFloat(headerHeight + contentHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: contentHeight))
        context.restoreGState()
    }

    // Footer: a light bar with a label.
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: frameHeight - footerHeight, width: width, height: footerHeight))
    drawText("Footer · always visible", at: CGPoint(x: 20, y: CGFloat(frameHeight - footerHeight + 10)), size: 13, color: CGColor(gray: 0.3, alpha: 1), in: context)

    guard let image = context.makeImage() else { exit(1) }
    return image
}

func drawExpected(page: CGImage, firstFrame: CGImage) -> CGImage {
    let height = headerHeight + pageHeight + footerHeight
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ),
        let header = firstFrame.cropping(to: CGRect(x: 0, y: 0, width: width, height: headerHeight)),
        let footer = firstFrame.cropping(to: CGRect(x: 0, y: frameHeight - footerHeight, width: width, height: footerHeight))
    else { exit(1) }
    // Unflipped context: y measured from the bottom.
    context.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footerHeight))
    context.draw(page, in: CGRect(x: 0, y: footerHeight, width: width, height: pageHeight))
    context.draw(header, in: CGRect(x: 0, y: footerHeight + pageHeight, width: width, height: headerHeight))
    guard let image = context.makeImage() else { exit(1) }
    return image
}

func write(_ image: CGImage, _ name: String) {
    let url = folder.appending(path: name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("wrote \(url.path(percentEncoded: false))")
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let page = drawPage()
write(page, "scroll-page.png")
let frames = offsets.map { drawFrame(page: page, offset: $0) }
for (index, frame) in frames.enumerated() {
    write(frame, "scroll-frame-\(index).png")
}
write(drawExpected(page: page, firstFrame: frames[0]), "scroll-expected.png")
