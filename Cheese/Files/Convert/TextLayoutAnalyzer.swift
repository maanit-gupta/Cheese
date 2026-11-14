import CoreGraphics
import Foundation

/// A stretch of text in one font.
struct LayoutRun: Equatable, Sendable {
    enum Script: Equatable, Sendable {
        case none, superscript, `subscript`
    }

    var text: String
    var fontSize: CGFloat
    var isBold = false
    var isItalic = false
    /// Raised or lowered, like the 2 in x² or the i in aᵢ (Word's `w:vertAlign`).
    var script: Script = .none
}

/// One line of text on a page. Frames use a top-left origin, y growing downward.
struct LayoutLine: Equatable, Sendable {
    var runs: [LayoutRun]
    var frame: CGRect
    /// The line is a table row: its cells are separated by tab runs.
    var isTabular = false

    var text: String { runs.map(\.text).joined() }

    /// The size most of the line's characters are set in.
    var fontSize: CGFloat {
        var counts: [CGFloat: Int] = [:]
        for run in runs {
            counts[run.fontSize, default: 0] += run.text.count
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 0
    }
}

/// An image on the page, placed among the text by its position.
struct LayoutImage: Equatable, Sendable {
    var id: Int
    var frame: CGRect
}

/// What a page holds, already in reading order.
enum LayoutItem: Equatable, Sendable {
    case line(LayoutLine)
    case image(LayoutImage)
    case equation(LayoutImage, number: String?)
}

/// A paragraph-level piece of the document, in reading order.
struct LayoutBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case listItem(ordered: Bool)
        case image(Int)
        /// A display equation as a picture, with its number (like "(3)") as text when it was set apart.
        case equation(Int, number: String?)
        /// Rows of cells.
        case table([[String]])
    }

    var kind: Kind
    var runs: [LayoutRun] = []

    var text: String { runs.map(\.text).joined() }
}

/// Turns a page's lines into headings, paragraphs and list items: lines group into paragraphs by
/// vertical gaps, headings are lines set noticeably larger than the page's body size, and lines
/// starting with a bullet or number become list items. Pure, so the rules are tested.
enum TextLayoutAnalyzer {
    /// A gap above a line larger than this share of the usual line height starts a new paragraph.
    static let paragraphGap: CGFloat = 0.6

    /// Lines and images in top-to-bottom order (images go before the first line below them).
    static func blocks(lines: [LayoutLine], images: [LayoutImage] = []) -> [LayoutBlock] {
        var items: [LayoutItem] = []
        var pendingImages = images.sorted { $0.frame.minY < $1.frame.minY }
        for line in lines {
            while let image = pendingImages.first, image.frame.minY < line.frame.minY {
                items.append(.image(image))
                pendingImages.removeFirst()
            }
            items.append(.line(line))
        }
        items += pendingImages.map { .image($0) }
        return blocks(items: items)
    }

    /// Blocks from items already in reading order. `vocabulary` holds the document's words, to tell a
    /// word hyphenated at a line end ("pa-" "rameter") from a compound ("state-" "of-the-art").
    static func blocks(items: [LayoutItem], vocabulary: Set<String> = []) -> [LayoutBlock] {
        let lines = items.compactMap { item -> LayoutLine? in
            if case let .line(line) = item { line } else { nil }
        }
        let body = bodySize(of: lines)
        let lineHeight = median(lines.map(\.frame.height)) ?? 12
        var blocks: [LayoutBlock] = []
        var previous: (line: LayoutLine, kind: LayoutBlock.Kind)?
        var tableRows: [[String]] = []
        var tableLines: [LayoutLine] = []

        func flushTable() {
            let rows = tableRows
            let lines = tableLines
            tableRows = []
            tableLines = []
            guard !rows.isEmpty else { return }
            if rows.count >= 2 {
                blocks.append(LayoutBlock(kind: .table(rows)))
                previous = nil
            } else if var only = lines.first {
                // One row on its own isn't a table: "1⇥Introduction" is a numbered heading.
                only.isTabular = false
                only.runs = only.runs.map { run in
                    var copy = run
                    copy.text = copy.text.replacing("\t", with: " ")
                    return copy
                }
                addLine(only)
            }
        }

        func addLine(_ line: LayoutLine) {
            let (kind, runs) = classify(line, body: body)
            if let previous, let last = blocks.last, continues(line, kind: kind, after: previous, lastBlock: last, lineHeight: lineHeight) {
                blocks[blocks.count - 1].runs = join(last.runs, runs, vocabulary: vocabulary)
            } else {
                blocks.append(LayoutBlock(kind: kind, runs: runs))
            }
            previous = (line, kind)
        }

        for item in items {
            switch item {
            case let .image(image):
                flushTable()
                blocks.append(LayoutBlock(kind: .image(image.id)))
                previous = nil
            case let .equation(image, number):
                flushTable()
                blocks.append(LayoutBlock(kind: .equation(image.id, number: number)))
                previous = nil
            case let .line(line):
                guard !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if line.isTabular {
                    let cells = line.text.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                    // A row with a different number of cells starts a new table.
                    if let last = tableRows.last, last.count != cells.count {
                        flushTable()
                    }
                    tableRows.append(cells)
                    tableLines.append(line)
                    previous = nil
                    continue
                }
                flushTable()
                addLine(line)
            }
        }
        flushTable()
        return blocks.map(merged)
    }

    /// Words as they appear in the text, lowercased, hyphenated compounds included, for `blocks(items:vocabulary:)`.
    static func vocabulary(of lines: [LayoutLine]) -> Set<String> {
        var words = Set<String>()
        for line in lines {
            // A word cut at the line's end isn't a word yet.
            var text = line.text
            if text.hasSuffix("-") {
                text = String(text.dropLast())
                if let space = text.lastIndex(where: \.isWhitespace) {
                    text = String(text[..<space])
                } else {
                    continue
                }
            }
            for match in text.matches(of: /[\p{L}]+(?:-[\p{L}]+)*/) {
                words.insert(String(match.0).lowercased())
            }
        }
        return words
    }

    /// The median font size over all characters on the page: what body text is set in.
    static func bodySize(of lines: [LayoutLine]) -> CGFloat {
        let sizes = lines.flatMap { line in line.runs.flatMap { Array(repeating: $0.fontSize, count: $0.text.count) } }
        return median(sizes) ?? 0
    }

    /// Heading levels by size relative to the body: 1.8× → 1, 1.35× → 2, 1.2× → 3.
    static func headingLevel(size: CGFloat, body: CGFloat) -> Int? {
        guard body > 0 else { return nil }
        let ratio = size / body
        if ratio >= 1.8 { return 1 }
        if ratio >= 1.35 { return 2 }
        if ratio >= 1.2 { return 3 }
        return nil
    }

    private static func classify(_ line: LayoutLine, body: CGFloat) -> (LayoutBlock.Kind, [LayoutRun]) {
        if let level = headingLevel(size: line.fontSize, body: body) {
            return (.heading(level: level), line.runs)
        }
        let text = line.text
        if let match = text.firstMatch(of: /^\s*[•◦▪‣·●○■\-–*]\s+/) {
            return (.listItem(ordered: false), dropPrefix(match.0.count, from: line.runs))
        }
        if let match = text.firstMatch(of: /^\s*\d{1,3}[.)]\s+/) {
            return (.listItem(ordered: true), dropPrefix(match.0.count, from: line.runs))
        }
        return (.paragraph, line.runs)
    }

    /// Whether `line` carries on the block the previous line started.
    private static func continues(
        _ line: LayoutLine,
        kind: LayoutBlock.Kind,
        after previous: (line: LayoutLine, kind: LayoutBlock.Kind),
        lastBlock: LayoutBlock,
        lineHeight: CGFloat
    ) -> Bool {
        let gap = line.frame.minY - previous.line.frame.maxY
        guard gap <= lineHeight * paragraphGap, gap > -lineHeight else { return false }
        switch (kind, lastBlock.kind) {
        case (.paragraph, .paragraph):
            return abs(line.fontSize - previous.line.fontSize) <= max(previous.line.fontSize * 0.1, 0.5)
        case let (.heading(level), .heading(lastLevel)):
            return level == lastLevel
        case (.paragraph, .listItem):
            // A wrapped list item: indented past the bullet.
            return line.frame.minX > previous.line.frame.minX + 2
        default:
            return false
        }
    }

    /// Prefixes whose compounds keep their hyphen ("self-aware", "well-known").
    static let compoundPrefixes: Set<String> = ["self", "well", "ill", "ex", "all", "half", "non", "co", "cross", "multi"]

    /// Joins two lines' runs with a space, or rejoins a word hyphenated across the break. The hyphen
    /// stays when the continuation is itself hyphenated ("state-" "of-the-art"), when the document
    /// spells the word with a hyphen elsewhere, or after a prefix like "well-"; it goes when the
    /// document spells the word without one, and otherwise.
    static func join(_ first: [LayoutRun], _ second: [LayoutRun], vocabulary: Set<String> = []) -> [LayoutRun] {
        var result = first
        guard var last = result.popLast() else { return second }
        let nextText = second.map(\.text).joined()
        let next = nextText.first
        if last.text.hasSuffix("-"), last.text.dropLast().last?.isLetter == true, next?.isLowercase == true {
            let prefix = String(last.text.dropLast().reversed().prefix { $0.isLetter }.reversed()).lowercased()
            let continuation = String(nextText.prefix { $0.isLetter || $0 == "-" }).lowercased()
            let keepsHyphen: Bool = if continuation.contains("-") {
                true
            } else if vocabulary.contains(prefix + "-" + continuation) {
                true
            } else if vocabulary.contains(prefix + continuation) {
                false
            } else {
                compoundPrefixes.contains(prefix)
            }
            if !keepsHyphen {
                last.text.removeLast()
            }
        } else if !last.text.hasSuffix(" ") {
            last.text += " "
        }
        result.append(last)
        return result + second
    }

    private static func dropPrefix(_ count: Int, from runs: [LayoutRun]) -> [LayoutRun] {
        var remaining = count
        var result: [LayoutRun] = []
        for var run in runs {
            if remaining > 0 {
                let drop = min(remaining, run.text.count)
                run.text = String(run.text.dropFirst(drop))
                remaining -= drop
            }
            if !run.text.isEmpty {
                result.append(run)
            }
        }
        return result
    }

    /// Adjacent runs in the same style become one.
    private static func merged(_ block: LayoutBlock) -> LayoutBlock {
        var copy = block
        copy.runs = block.runs.reduce(into: []) { runs, run in
            if var last = runs.last, last.fontSize == run.fontSize, last.isBold == run.isBold, last.isItalic == run.isItalic, last.script == run.script {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        if let last = copy.runs.indices.last {
            copy.runs[last].text = copy.runs[last].text.replacing(/\s+$/, with: "")
        }
        return copy
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
