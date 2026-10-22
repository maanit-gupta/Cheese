import Foundation

enum PageRangeError: LocalizedError, Equatable {
    case empty
    case invalidToken(String)
    case pageZero
    case outOfRange(Int, pageCount: Int)
    case reversed(Int, Int)

    var errorDescription: String? {
        switch self {
        case .empty: "Enter pages, like 1-3, 5, 8-"
        case let .invalidToken(token): "“\(token)” isn't a page or a range, like 1-3, 5, 8-"
        case .pageZero: "Pages start at 1"
        case let .outOfRange(page, count): "There's no page \(page): the PDF has \(count) page\(count == 1 ? "" : "s")"
        case let .reversed(from, to): "\(from)-\(to) runs backwards; write \(to)-\(from)"
        }
    }
}

/// Parses page ranges like `1-3, 5, 8-` into 1-based closed ranges, in the order written.
/// Commas, semicolons and spaces separate ranges; `8-` runs to the last page, `-3` from the first.
enum PageRangeParser {
    static func parse(_ text: String, pageCount: Int) throws(PageRangeError) -> [ClosedRange<Int>] {
        // Treat en and em dashes like hyphens, and "8 - 10" like "8-10".
        let normalized = text
            .replacing("–", with: "-")
            .replacing("—", with: "-")
            .replacing(/\s*-\s*/, with: "-")
        let tokens = normalized.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init)
        guard !tokens.isEmpty else { throw .empty }
        return try tokens.map { token throws(PageRangeError) in try range(token, pageCount: pageCount) }
    }

    private static func range(_ token: String, pageCount: Int) throws(PageRangeError) -> ClosedRange<Int> {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let bounds: (Int, Int)
        switch parts.count {
        case 1:
            let page = try number(parts[0], token: token)
            bounds = (page, page)
        case 2:
            let from = parts[0].isEmpty ? 1 : try number(parts[0], token: token)
            let to = parts[1].isEmpty ? pageCount : try number(parts[1], token: token)
            if parts[0].isEmpty, parts[1].isEmpty {
                throw .invalidToken(token)
            }
            bounds = (from, to)
        default:
            throw .invalidToken(token)
        }
        guard bounds.0 >= 1, bounds.1 >= 1 else { throw .pageZero }
        guard bounds.0 <= bounds.1 else { throw .reversed(bounds.0, bounds.1) }
        guard bounds.1 <= pageCount else { throw .outOfRange(bounds.1, pageCount: pageCount) }
        return bounds.0...bounds.1
    }

    private static func number(_ text: String, token: String) throws(PageRangeError) -> Int {
        guard let value = Int(text), text.allSatisfy(\.isASCII) else { throw .invalidToken(token) }
        return value
    }
}

/// Writes 1-based page numbers back as compact labels: `pages 1-3, 5`, `page 4`.
enum PageRangeFormatter {
    /// `[1, 2, 3, 5]` → `1-3, 5`. Keeps the given order, collapsing ascending runs.
    static func compact(_ pages: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < pages.count {
            var end = index
            while end + 1 < pages.count, pages[end + 1] == pages[end] + 1 {
                end += 1
            }
            parts.append(end > index ? "\(pages[index])-\(pages[end])" : "\(pages[index])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }

    static func label(_ pages: [Int]) -> String {
        pages.count == 1 ? "page \(compact(pages))" : "pages \(compact(pages))"
    }
}
