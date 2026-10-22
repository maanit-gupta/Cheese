import CoreGraphics
import Foundation

/// Finds where images are drawn on a PDF page by scanning its content stream: tracks the
/// transformation matrix through `q`/`Q`/`cm`, and on `Do` with an image XObject records the
/// unit square mapped through it. Form XObjects are followed a few levels deep.
enum PDFImageInspector {
    /// Pages whose images cover at least this share of the page count as image-dominant.
    static let dominantCoverage = 0.5
    private static let maxFormDepth = 3

    /// Image rects in the page's default user space.
    static func imageRects(on page: CGPDFPage) -> [CGRect] {
        let state = ScanState()
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream, state: state, depth: 0)
        CGPDFContentStreamRelease(stream)
        return state.rects
    }

    static func isImageDominant(_ page: CGPDFPage) -> Bool {
        coverage(of: imageRects(on: page), on: page.getBoxRect(.cropBox)) >= dominantCoverage
    }

    /// Share of the page covered by the rects, counting each rect's part inside the page, capped at 1.
    static func coverage(of rects: [CGRect], on page: CGRect) -> Double {
        let pageArea = page.width * page.height
        guard pageArea > 0 else { return 0 }
        let covered = rects.reduce(0.0) { total, rect in
            let visible = rect.intersection(page)
            return visible.isNull ? total : total + visible.width * visible.height
        }
        return min(covered / pageArea, 1)
    }

    private final class ScanState {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
        var streams: [CGPDFContentStreamRef] = []
        var depth = 0
    }

    private static func scan(_ stream: CGPDFContentStreamRef, state: ScanState, depth: Int) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let state = PDFImageInspector.state(info) else { return }
            state.stack.append(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let state = PDFImageInspector.state(info) else { return }
            state.ctm = state.stack.popLast() ?? .identity
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = PDFImageInspector.state(info) else { return }
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.ctm = matrix.concatenating(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = PDFImageInspector.state(info), let stream = state.streams.last else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(stream, "XObject", name)
            else { return }
            var xObject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xObject), let xObject,
                  let dictionary = CGPDFStreamGetDictionary(xObject)
            else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                state.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm))
            case "Form" where state.depth < PDFImageInspector.maxFormDepth:
                PDFImageInspector.scanForm(xObject, dictionary: dictionary, parent: stream, state: state)
            default:
                break
            }
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        state.streams.append(stream)
        state.depth = depth
        CGPDFScannerScan(scanner)
        state.streams.removeLast()
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    private static func scanForm(_ form: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef, state: ScanState) {
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let saved = state.ctm
        let savedStack = state.stack
        let savedDepth = state.depth
        var matrixArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray, CGPDFArrayGetCount(matrixArray) == 6 {
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in 0..<6 {
                _ = CGPDFArrayGetNumber(matrixArray, index, &values[index])
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.ctm = matrix.concatenating(state.ctm)
        }
        let stream = CGPDFContentStreamCreateWithStream(form, resources ?? dictionary, parent)
        scan(stream, state: state, depth: savedDepth + 1)
        CGPDFContentStreamRelease(stream)
        state.ctm = saved
        state.stack = savedStack
        state.depth = savedDepth
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        info.map { Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }
    }
}
