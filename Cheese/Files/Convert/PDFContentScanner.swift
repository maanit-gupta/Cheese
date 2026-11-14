import CoreGraphics
import Foundation

/// One glyph as the content stream draws it: the real font (PDFKit reports every embedded font as
/// Helvetica, which hides the math fonts LaTeX uses), where it starts and how far it advances.
/// Coordinates are the page's default user space (unrotated, bottom-left origin).
struct ScannedGlyph: Equatable, Sendable {
    var fontName: String
    var origin: CGPoint
    /// From the origin to where the next glyph would start.
    var advance: CGVector
    /// From the baseline to one em above it: the size and the direction "up" (text can be turned).
    var up: CGVector
    /// False for fonts whose text can't be turned into Unicode at all: Type 3 and CID fonts without a
    /// `/ToUnicode` map. (Simple fonts without one still decode through their glyph names.)
    var hasUnicodeMap: Bool

    var size: CGFloat { hypot(up.dx, up.dy) }

    /// A rough ink box: the advance long, from a quarter em below the baseline to three quarters above.
    var box: CGRect {
        let bottom = CGPoint(x: origin.x - up.dx * 0.25, y: origin.y - up.dy * 0.25)
        let top = CGPoint(x: origin.x + up.dx * 0.75, y: origin.y + up.dy * 0.75)
        // A glyph with no advance (a combining mark, a zero-width font) still gets some width.
        let length = hypot(advance.dx, advance.dy)
        let along = length > size * 0.2 || size == 0 ? advance
            : CGVector(dx: up.dy / max(size, 0.0001) * size * 0.2, dy: -up.dx / max(size, 0.0001) * size * 0.2)
        let corners = [bottom, top, CGPoint(x: bottom.x + along.dx, y: bottom.y + along.dy), CGPoint(x: top.x + along.dx, y: top.y + along.dy)]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}

/// What a page's content stream draws, besides its images: every glyph and the bounds of every
/// painted path. Used to find figures drawn with lines and the fonts equations are set in.
struct ScannedPage: Sendable {
    var glyphs: [ScannedGlyph] = []
    /// Bounds of stroked or filled paths (lines, rules, boxes, curves), in default user space.
    var paths: [CGRect] = []
}

/// Walks a page's content stream with `CGPDFScanner`, tracking the graphics state (`q`/`Q`/`cm`),
/// the text state (`Tf`, `Tm`, `Td`, `TD`, `T*`, `TL`, `Tc`, `Tw`, `Tz`, `Ts`) and paths. Glyph
/// advances come from the font's `/Widths` (simple fonts) or `/W` (CID fonts). Form XObjects are
/// followed a few levels deep.
enum PDFContentScanner {
    private static let maxFormDepth = 4

    static func scan(_ page: CGPDFPage) -> ScannedPage {
        let state = State()
        let stream = CGPDFContentStreamCreateWithPage(page)
        run(stream, state: state)
        CGPDFContentStreamRelease(stream)
        return state.result
    }

    // MARK: State

    fileprivate struct FontInfo {
        var name: String
        var isComposite: Bool
        var firstChar = 0
        var widths: [CGFloat] = []
        var cidWidths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 500
        /// Glyph space → text space: 1/1000 for most fonts, the font matrix for Type 3.
        var unitsScale: CGFloat = 0.001
        var hasUnicodeMap: Bool

        func width(of code: Int) -> CGFloat {
            if isComposite {
                return (cidWidths[code] ?? defaultWidth) * unitsScale
            }
            let index = code - firstChar
            return (widths.indices.contains(index) ? widths[index] : defaultWidth) * unitsScale
        }
    }

    fileprivate struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var font: FontInfo?
        var fontSize: CGFloat = 0
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }

    fileprivate final class State {
        var graphics = GraphicsState()
        var stack: [GraphicsState] = []
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var pathBounds = CGRect.null
        var currentPoint = CGPoint.zero
        var streams: [CGPDFContentStreamRef] = []
        var fonts: [String: FontInfo] = [:]
        var depth = 0
        var result = ScannedPage()

        func addPathPoint(_ point: CGPoint) {
            let transformed = point.applying(graphics.ctm)
            pathBounds = pathBounds.union(CGRect(origin: transformed, size: .zero))
        }

        func paintPath() {
            if !pathBounds.isNull {
                result.paths.append(pathBounds)
            }
            pathBounds = .null
        }

        func moveToNextLine(tx: CGFloat, ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        /// Draws one string's glyphs and moves the text matrix past them.
        func show(_ bytes: [UInt8]) {
            guard let font = graphics.font else { return }
            let size = graphics.fontSize
            let codes: [Int] = font.isComposite
                ? stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) }
                : bytes.map(Int.init)
            for code in codes {
                let render = CGAffineTransform(a: size * graphics.horizontalScale, b: 0, c: 0, d: size, tx: 0, ty: graphics.rise)
                    .concatenating(textMatrix).concatenating(graphics.ctm)
                let width = font.width(of: code)
                let isSpace = !font.isComposite && code == 32
                let advance = (width * size + graphics.charSpacing + (isSpace ? graphics.wordSpacing : 0)) * graphics.horizontalScale
                let origin = CGPoint.zero.applying(render)
                let end = CGPoint(x: width, y: 0).applying(render)
                let top = CGPoint(x: 0, y: 1).applying(render)
                result.glyphs.append(ScannedGlyph(
                    fontName: font.name, origin: origin,
                    advance: CGVector(dx: end.x - origin.x, dy: end.y - origin.y),
                    up: CGVector(dx: top.x - origin.x, dy: top.y - origin.y),
                    hasUnicodeMap: font.hasUnicodeMap
                ))
                textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
            }
        }

        func adjust(_ thousandths: CGFloat) {
            let tx = -thousandths / 1000 * graphics.fontSize * graphics.horizontalScale
            textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
        }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State? {
        info.map { Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func numbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
        var values = [CGPDFReal](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            guard CGPDFScannerPopNumber(scanner, &values[index]) else { return nil }
        }
        return values
    }

    private static func bytes(of string: CGPDFStringRef) -> [UInt8] {
        guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
    }

    // MARK: Scanning

    // swiftlint:disable:next function_body_length
    private static func run(_ stream: CGPDFContentStreamRef, state: State) {
        guard let table = CGPDFOperatorTableCreate() else { return }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let state = PDFContentScanner.state(info) else { return }
            state.stack.append(state.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let state = PDFContentScanner.state(info) else { return }
            state.graphics = state.stack.popLast() ?? GraphicsState()
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 6) else { return }
            state.graphics.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(state.graphics.ctm)
        }

        // Paths
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 2) else { return }
            state.currentPoint = CGPoint(x: v[0], y: v[1])
            state.addPathPoint(state.currentPoint)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 2) else { return }
            state.currentPoint = CGPoint(x: v[0], y: v[1])
            state.addPathPoint(state.currentPoint)
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 6) else { return }
            for index in stride(from: 0, to: 6, by: 2) {
                state.addPathPoint(CGPoint(x: v[index], y: v[index + 1]))
            }
            state.currentPoint = CGPoint(x: v[4], y: v[5])
        }
        for name in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, name) { scanner, info in
                guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 4) else { return }
                state.addPathPoint(CGPoint(x: v[0], y: v[1]))
                state.addPathPoint(CGPoint(x: v[2], y: v[3]))
                state.currentPoint = CGPoint(x: v[2], y: v[3])
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 4) else { return }
            state.addPathPoint(CGPoint(x: v[0], y: v[1]))
            state.addPathPoint(CGPoint(x: v[0] + v[2], y: v[1] + v[3]))
        }
        for name in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                PDFContentScanner.state(info)?.paintPath()
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            PDFContentScanner.state(info)?.pathBounds = .null
        }

        // Text state
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let state = PDFContentScanner.state(info) else { return }
            state.textMatrix = .identity
            state.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let state = PDFContentScanner.state(info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            state.graphics.fontSize = size
            state.graphics.font = PDFContentScanner.font(named: String(cString: name), state: state)
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 1) else { return }
            state.graphics.charSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 1) else { return }
            state.graphics.wordSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 1) else { return }
            state.graphics.horizontalScale = v[0] / 100
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 1) else { return }
            state.graphics.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 1) else { return }
            state.graphics.rise = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 6) else { return }
            state.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            state.textMatrix = state.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 2) else { return }
            state.moveToNextLine(tx: v[0], ty: v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let state = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, count: 2) else { return }
            state.graphics.leading = -v[1]
            state.moveToNextLine(tx: v[0], ty: v[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let state = PDFContentScanner.state(info) else { return }
            state.moveToNextLine(tx: 0, ty: -state.graphics.leading)
        }

        // Text showing
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let state = PDFContentScanner.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            state.show(PDFContentScanner.bytes(of: string))
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let state = PDFContentScanner.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            state.moveToNextLine(tx: 0, ty: -state.graphics.leading)
            state.show(PDFContentScanner.bytes(of: string))
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let state = PDFContentScanner.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let v = PDFContentScanner.numbers(scanner, count: 2)
            else { return }
            state.graphics.wordSpacing = v[0]
            state.graphics.charSpacing = v[1]
            state.moveToNextLine(tx: 0, ty: -state.graphics.leading)
            state.show(PDFContentScanner.bytes(of: string))
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let state = PDFContentScanner.state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    state.show(PDFContentScanner.bytes(of: string))
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    state.adjust(number)
                }
            }
        }

        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = PDFContentScanner.state(info), let stream = state.streams.last else { return }
            var name: UnsafePointer<CChar>?
            guard state.depth < PDFContentScanner.maxFormDepth,
                  CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(stream, "XObject", name)
            else { return }
            var xObject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xObject), let xObject,
                  let dictionary = CGPDFStreamGetDictionary(xObject)
            else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
            PDFContentScanner.runForm(xObject, dictionary: dictionary, parent: stream, state: state)
        }

        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        state.streams.append(stream)
        CGPDFScannerScan(scanner)
        state.streams.removeLast()
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    private static func runForm(_ form: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef, state: State) {
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let savedGraphics = state.graphics
        let savedStack = state.stack
        let savedText = (state.textMatrix, state.lineMatrix)
        let savedFonts = state.fonts
        if let matrix = matrix(in: dictionary, key: "Matrix") {
            state.graphics.ctm = matrix.concatenating(state.graphics.ctm)
        }
        // Font names are per resource dictionary, so a form's fonts are looked up afresh.
        state.fonts = [:]
        state.depth += 1
        let stream = CGPDFContentStreamCreateWithStream(form, resources ?? dictionary, parent)
        run(stream, state: state)
        CGPDFContentStreamRelease(stream)
        state.depth -= 1
        state.fonts = savedFonts
        state.graphics = savedGraphics
        state.stack = savedStack
        (state.textMatrix, state.lineMatrix) = savedText
    }

    private static func matrix(in dictionary: CGPDFDictionaryRef, key: String) -> CGAffineTransform? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 6 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 6)
        for index in 0..<6 {
            _ = CGPDFArrayGetNumber(array, index, &v[index])
        }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    // MARK: Fonts

    private static func font(named resourceName: String, state: State) -> FontInfo? {
        if let cached = state.fonts[resourceName] {
            return cached
        }
        guard let stream = state.streams.last,
              let object = CGPDFContentStreamGetResource(stream, "Font", resourceName)
        else { return nil }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
        let info = fontInfo(dictionary, fallbackName: resourceName)
        state.fonts[resourceName] = info
        return info
    }

    private static func fontInfo(_ dictionary: CGPDFDictionaryRef, fallbackName: String) -> FontInfo {
        let subtype = name(in: dictionary, key: "Subtype") ?? ""
        var baseName = name(in: dictionary, key: "BaseFont") ?? fallbackName
        // Subset fonts are named "ABCDEF+CMMI10".
        if let plus = baseName.firstIndex(of: "+"), baseName.distance(from: baseName.startIndex, to: plus) == 6 {
            baseName = String(baseName[baseName.index(after: plus)...])
        }
        var hasToUnicode = false
        var toUnicode: CGPDFStreamRef?
        hasToUnicode = CGPDFDictionaryGetStream(dictionary, "ToUnicode", &toUnicode)

        if subtype == "Type0" {
            var info = FontInfo(name: baseName, isComposite: true, hasUnicodeMap: hasToUnicode)
            info.defaultWidth = 1000
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                var defaultWidth: CGPDFReal = 1000
                if CGPDFDictionaryGetNumber(descendant, "DW", &defaultWidth) {
                    info.defaultWidth = defaultWidth
                }
                info.cidWidths = cidWidths(in: descendant)
            }
            return info
        }

        var info = FontInfo(name: baseName, isComposite: false, hasUnicodeMap: hasToUnicode || subtype != "Type3")
        var firstChar: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, "FirstChar", &firstChar) {
            info.firstChar = firstChar
        }
        var widths: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Widths", &widths), let widths {
            info.widths = (0..<CGPDFArrayGetCount(widths)).map { index in
                var value: CGPDFReal = 0
                _ = CGPDFArrayGetNumber(widths, index, &value)
                return value
            }
        }
        var descriptor: CGPDFDictionaryRef?
        var missing: CGPDFReal = 0
        if CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor), let descriptor,
           CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing), missing > 0 {
            info.defaultWidth = missing
        }
        if subtype == "Type3", let fontMatrix = matrix(in: dictionary, key: "FontMatrix") {
            info.unitsScale = fontMatrix.a
            info.defaultWidth = info.widths.max() ?? 0.5 / max(fontMatrix.a, 0.0001)
        }
        return info
    }

    /// A CID font's `/W` array: `c [w1 w2 …]` or `cFirst cLast w`.
    private static func cidWidths(in font: CGPDFDictionaryRef) -> [Int: CGFloat] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(font, "W", &array), let array else { return [:] }
        var result: [Int: CGFloat] = [:]
        var index = 0
        let count = CGPDFArrayGetCount(array)
        while index < count {
            var first: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, index, &first) else { break }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, index + 1, &list), let list {
                for offset in 0..<CGPDFArrayGetCount(list) {
                    var width: CGPDFReal = 0
                    if CGPDFArrayGetNumber(list, offset, &width) {
                        result[first + offset] = width
                    }
                }
                index += 2
            } else {
                var last: CGPDFInteger = 0
                var width: CGPDFReal = 0
                guard CGPDFArrayGetInteger(array, index + 1, &last), CGPDFArrayGetNumber(array, index + 2, &width), last >= first,
                      last - first < 65536
                else { break }
                for cid in first...last {
                    result[cid] = width
                }
                index += 3
            }
        }
        return result
    }

    private static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
