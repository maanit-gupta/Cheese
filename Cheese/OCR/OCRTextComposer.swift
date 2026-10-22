import CoreGraphics

/// One recognized line of text and where it was.
struct OCRLine: Equatable, Sendable {
    var text: String
    /// Normalized to the image (0…1), origin at the bottom-left, as Vision reports it.
    var box: CGRect
}

/// Turns recognized lines into text in reading order: top to bottom, and left to right within a row.
enum OCRTextComposer {
    /// Characters that end a sentence, including the Devanagari danda.
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", "।", "॥", "\u{201D}", "\""]

    static func compose(_ lines: [OCRLine], mode: OCRLineBreakMode) -> String {
        let rows = rows(from: lines)
        switch mode {
        case .keepLineBreaks:
            return rows.map(\.text).joined(separator: "\n")
        case .joinParagraphs:
            return joinParagraphs(rows)
        }
    }

    /// Words in the text, for "Copied 42 words".
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    struct Row: Equatable {
        var text: String
        var box: CGRect
    }

    /// Groups lines that sit side by side (table cells, columns of a form) into rows.
    static func rows(from lines: [OCRLine]) -> [Row] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.box.maxY != $1.box.maxY ? $0.box.maxY > $1.box.maxY : $0.box.minX < $1.box.minX }

        var rows: [[OCRLine]] = []
        for line in sorted {
            if let last = rows.indices.last, rows[last].contains(where: { sharesRow($0.box, line.box) }) {
                rows[last].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return Row(text: text, box: box)
        }
    }

    /// Two boxes are on the same row when they overlap for most of the shorter one's height.
    private static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * min(a.height, b.height)
    }

    private static func joinParagraphs(_ rows: [Row]) -> String {
        guard let first = rows.first else { return "" }
        let heights = rows.map(\.box.height).sorted()
        let lineHeight = heights[heights.count / 2]
        let rightEdge = rows.map(\.box.maxX).max() ?? 1
        let leftEdge = rows.map(\.box.minX).min() ?? 0
        let fullWidth = max(rightEdge - leftEdge, .ulpOfOne)

        var text = first.text
        for (previous, row) in zip(rows, rows.dropFirst()) {
            let gap = previous.box.minY - row.box.maxY
            let endsSentence = previous.text.last.map(sentenceEnds.contains) ?? false
            let isShort = (rightEdge - previous.box.maxX) / fullWidth > 0.15
            if gap > 0.75 * lineHeight || (endsSentence && isShort) {
                text += "\n\n" + row.text
            } else if let joined = dehyphenated(text, row.text) {
                text = joined
            } else {
                text += " " + row.text
            }
        }
        return text
    }

    /// Rejoins a word split across lines ("recog-" + "nition"), but keeps real hyphens before capitals.
    private static func dehyphenated(_ text: String, _ next: String) -> String? {
        guard text.hasSuffix("-"),
              let beforeHyphen = text.dropLast().last, beforeHyphen.isLetter,
              let nextFirst = next.first, nextFirst.isLowercase
        else { return nil }
        return String(text.dropLast()) + next
    }
}
