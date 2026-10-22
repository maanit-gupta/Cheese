import Foundation

/// How Split divides a PDF.
enum SplitMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case ranges
    case everyN
    case eachPage

    var id: Self { self }

    var title: String {
        switch self {
        case .ranges: "Page ranges"
        case .everyN: "Every N pages"
        case .eachPage: "Each page"
        }
    }
}

/// One output of a split: which pages (1-based) and the label for its file name.
struct SplitPart: Equatable, Sendable {
    var pages: [Int]
    var label: String
}

/// Turns a split mode into the parts to write. Pure, so every mode is tested without PDFs.
enum SplitPlanner {
    static func parts(mode: SplitMode, ranges: String, everyN: Int, pageCount: Int) throws(PageRangeError) -> [SplitPart] {
        guard pageCount > 0 else { return [] }
        switch mode {
        case .ranges:
            return try PageRangeParser.parse(ranges, pageCount: pageCount).map { range in
                let pages = Array(range)
                return SplitPart(pages: pages, label: PageRangeFormatter.label(pages))
            }
        case .everyN:
            let size = max(1, everyN)
            return stride(from: 1, through: pageCount, by: size).map { start in
                let pages = Array(start...min(start + size - 1, pageCount))
                return SplitPart(pages: pages, label: PageRangeFormatter.label(pages))
            }
        case .eachPage:
            return (1...pageCount).map { SplitPart(pages: [$0], label: PageRangeFormatter.label([$0])) }
        }
    }
}
