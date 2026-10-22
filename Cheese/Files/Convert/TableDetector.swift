import CoreGraphics
import Foundation

/// A word with its box on the page (top-left origin, y growing downward).
struct PositionedWord: Equatable, Sendable {
    var text: String
    var frame: CGRect
}

struct DetectedTable: Equatable, Sendable {
    var rows: [[String]]
}

/// One worksheet to write: a name and its rows of cell text.
struct SheetPlan: Equatable, Sendable {
    var name: String
    var rows: [[String]]
}

/// Finds tables in positioned words: rows by clustering words on their vertical centers, cells by
/// gaps between words, and columns by where cells line up across rows. Pure, so it's tested
/// without PDFs. Merged cells and ragged layouts won't come out perfectly.
enum TableDetector {
    private struct Cell {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
    }

    private struct Line {
        var cells: [Cell]
        var minY: CGFloat
        var maxY: CGFloat
    }

    private struct Table {
        var lines: Range<Int>
        var columns: [ClosedRange<CGFloat>]
    }

    static func tables(in words: [PositionedWord]) -> [DetectedTable] {
        let (lines, tables) = analyze(words)
        return tables.map { table in DetectedTable(rows: lines[table.lines].map { row($0, columns: table.columns) }) }
    }

    /// Every line as its cells, for pages without tables.
    static func rows(in words: [PositionedWord]) -> [[String]] {
        lines(of: words).map { $0.cells.map(\.text) }
    }

    /// One sheet per page, or one per table when the page has several.
    static func sheets(forPage number: Int, words: [PositionedWord]) -> [SheetPlan] {
        let (lines, tables) = analyze(words)
        guard !lines.isEmpty else { return [] }
        if tables.count > 1 {
            return tables.enumerated().map { index, table in
                SheetPlan(name: "Page \(number) Table \(index + 1)", rows: lines[table.lines].map { row($0, columns: table.columns) })
            }
        }
        // The page in order: table rows split into columns, other lines as single cells.
        let rows = lines.indices.map { index in
            if let table = tables.first, table.lines.contains(index) {
                return row(lines[index], columns: table.columns)
            }
            return lines[index].cells.map(\.text)
        }
        return [SheetPlan(name: "Page \(number)", rows: rows)]
    }

    private static func analyze(_ words: [PositionedWord]) -> ([Line], [Table]) {
        let lines = lines(of: words)
        let height = TextLayoutAnalyzer.median(words.map(\.frame.height)) ?? 12
        var tables: [Table] = []
        var index = 0
        while index < lines.count {
            guard lines[index].cells.count >= 2 else {
                index += 1
                continue
            }
            var end = index + 1
            var columns = columnRanges(lines[index..<end])
            while end < lines.count {
                let line = lines[end]
                guard line.minY - lines[end - 1].minY <= height * 2.5 else { break }
                if line.cells.count >= 2 {
                    end += 1
                    columns = columnRanges(lines[index..<end])
                } else if let cell = line.cells.first, columns.count(where: { overlap(cell, $0) > 0 }) <= 1 {
                    // A row with only one cell filled, inside one column, still belongs.
                    end += 1
                } else {
                    break
                }
            }
            let multiCellRows = lines[index..<end].count { $0.cells.count >= 2 }
            if multiCellRows >= 2 {
                tables.append(Table(lines: index..<end, columns: columns))
                index = end
            } else {
                index += 1
            }
        }
        return (lines, tables)
    }

    /// Words grouped into lines by their vertical centers, then into cells by the gaps between them.
    private static func lines(of words: [PositionedWord]) -> [Line] {
        let height = TextLayoutAnalyzer.median(words.map(\.frame.height)) ?? 12
        var groups: [[PositionedWord]] = []
        for word in words.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = groups.last, let center = last.first?.frame.midY, abs(word.frame.midY - center) <= height * 0.5 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.map { group in
            let sorted = group.sorted { $0.frame.minX < $1.frame.minX }
            var cells: [Cell] = []
            for word in sorted {
                // Words closer than about one character height apart are the same cell.
                if var last = cells.last, word.frame.minX - last.maxX <= height * 0.9 {
                    last.text += " " + word.text
                    last.maxX = max(last.maxX, word.frame.maxX)
                    cells[cells.count - 1] = last
                } else {
                    cells.append(Cell(text: word.text, minX: word.frame.minX, maxX: word.frame.maxX))
                }
            }
            return Line(cells: cells, minY: group.map(\.frame.minY).min() ?? 0, maxY: group.map(\.frame.maxY).max() ?? 0)
        }
    }

    /// Columns are the union of overlapping cell spans across multi-cell rows, so left-, right-
    /// and center-aligned columns all line up.
    private static func columnRanges(_ lines: ArraySlice<Line>) -> [ClosedRange<CGFloat>] {
        let spans = lines.filter { $0.cells.count >= 2 }.flatMap(\.cells).map { $0.minX...$0.maxX }.sorted { $0.lowerBound < $1.lowerBound }
        var columns: [ClosedRange<CGFloat>] = []
        for span in spans {
            if let last = columns.last, span.lowerBound <= last.upperBound + 2 {
                columns[columns.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                columns.append(span)
            }
        }
        return columns
    }

    private static func overlap(_ cell: Cell, _ column: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(cell.maxX, column.upperBound) - max(cell.minX, column.lowerBound))
    }

    /// A line's cells placed into the table's columns; empty columns stay empty.
    private static func row(_ line: Line, columns: [ClosedRange<CGFloat>]) -> [String] {
        var row = Array(repeating: "", count: columns.count)
        for cell in line.cells {
            let best = columns.indices.max { overlap(cell, columns[$0]) < overlap(cell, columns[$1]) }
            let index = best.flatMap { overlap(cell, columns[$0]) > 0 ? $0 : nil }
                ?? columns.indices.min { abs(columns[$0].lowerBound - cell.minX) < abs(columns[$1].lowerBound - cell.minX) }
            guard let index else { continue }
            row[index] = row[index].isEmpty ? cell.text : row[index] + " " + cell.text
        }
        return row
    }
}

/// A spreadsheet cell's value.
enum CellValue: Equatable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case date(Date)
}

/// Reads numbers, percentages, amounts and dates the way the user's locale writes them, so they
/// become real numeric and date cells. Everything else stays text.
enum CellValueParser {
    static func parse(_ raw: String, locale: Locale = .current) -> CellValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if text.hasSuffix("%"), let number = number(String(text.dropLast()).trimmingCharacters(in: .whitespaces), locale: locale) {
            return .number(number / 100)
        }
        if let number = number(stripCurrency(text, locale: locale), locale: locale) {
            return .number(number)
        }
        if let date = date(text, locale: locale) {
            return .date(date)
        }
        return .text(text)
    }

    /// A number written with the locale's grouping and decimal separators, grouping in threes.
    static func number(_ text: String, locale: Locale) -> Double? {
        let group = locale.groupingSeparator ?? ","
        let decimal = locale.decimalSeparator ?? "."
        let normalized = text.replacing("−", with: "-").replacing("\u{00A0}", with: " ")
        let g = NSRegularExpression.escapedPattern(for: group == "\u{00A0}" ? " " : group)
        let d = NSRegularExpression.escapedPattern(for: decimal)
        guard let regex = try? Regex("^[+-]?(\\d{1,3}(\(g)\\d{3})+|\\d+)(\(d)\\d+)?$"),
              normalized.wholeMatch(of: regex) != nil
        else { return nil }
        let plain = normalized.replacing(group == "\u{00A0}" ? " " : group, with: "").replacing(decimal, with: ".")
        return Double(plain)
    }

    private static func stripCurrency(_ text: String, locale: Locale) -> String {
        var result = text
        for symbol in Set([locale.currencySymbol, "$", "€", "£", "₹", "¥"].compactMap(\.self)) {
            if result.hasPrefix(symbol) {
                result = String(result.dropFirst(symbol.count))
            } else if result.hasSuffix(symbol) {
                result = String(result.dropLast(symbol.count))
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// ISO dates (2026-01-15) and the locale's numeric and medium dates, at midnight UTC.
    static func date(_ text: String, locale: Locale) -> Date? {
        guard text.contains(where: \.isNumber), text.count <= 20 else { return nil }
        let formats = ["yyyy-MM-dd"] + ["yMd", "yMMMd"].compactMap { DateFormatter.dateFormat(fromTemplate: $0, options: 0, locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        for format in formats {
            formatter.dateFormat = format
            // Formatting the date back must give the same text, which rules out "1,2,3" and the like.
            if let date = formatter.date(from: text), formatter.string(from: date) == text {
                return date
            }
        }
        return nil
    }
}
