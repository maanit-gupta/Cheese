import CoreGraphics
import Foundation

/// A stretch of text in one font.
struct LayoutRun: Equatable, Sendable {
    var text: String
    var fontSize: CGFloat
    var isBold = false
    var isItalic = false
}

/// One line of text on a page. Frames use a top-left origin, y growing downward.
struct LayoutLine: Equatable, Sendable {
    var runs: [LayoutRun]
    var frame: CGRect

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

/// A paragraph-level piece of the document, in reading order.
struct LayoutBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case listItem(ordered: Bool)
        case image(Int)
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

    static func blocks(lines: [LayoutLine], images: [LayoutImage] = []) -> [LayoutBlock] {
        let body = bodySize(of: lines)
        let lineHeight = median(lines.map(\.frame.height)) ?? 12
        var pendingImages = images.sorted { $0.frame.minY < $1.frame.minY }
        var blocks: [LayoutBlock] = []
        var previous: (line: LayoutLine, kind: LayoutBlock.Kind)?

        for line in lines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Images that sit above this line come first.
            var placedImage = false
            while let image = pendingImages.first, image.frame.minY < line.frame.minY {
                blocks.append(LayoutBlock(kind: .image(image.id)))
                pendingImages.removeFirst()
                placedImage = true
            }

            let (kind, runs) = classify(line, body: body)
            if !placedImage, let previous, let last = blocks.last, continues(line, kind: kind, after: previous, lastBlock: last, lineHeight: lineHeight) {
                blocks[blocks.count - 1].runs = join(last.runs, runs)
            } else {
                blocks.append(LayoutBlock(kind: kind, runs: runs))
            }
            previous = (line, kind)
        }
        blocks += pendingImages.map { LayoutBlock(kind: .image($0.id)) }
        return blocks.map(merged)
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

    /// Joins two lines' runs with a space, or rejoins a word hyphenated across the break.
    private static func join(_ first: [LayoutRun], _ second: [LayoutRun]) -> [LayoutRun] {
        var result = first
        guard var last = result.popLast() else { return second }
        let next = second.first?.text.first
        if last.text.hasSuffix("-"), last.text.dropLast().last?.isLetter == true, next?.isLowercase == true {
            last.text.removeLast()
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
            if var last = runs.last, last.fontSize == run.fontSize, last.isBold == run.isBold, last.isItalic == run.isItalic {
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
