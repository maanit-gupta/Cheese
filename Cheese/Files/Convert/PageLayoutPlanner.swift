import CoreGraphics
import Foundation

/// One character from a PDF page's text layer, with its box (top-left origin, upright page points)
/// and the font the content stream really used (PDFKit reports embedded fonts as Helvetica).
struct PageChar: Equatable, Sendable {
    var text: String
    var frame: CGRect
    var fontSize: CGFloat
    var fontName = ""
    var isBold = false
    var isItalic = false
    /// Where the glyph sits (y, top-left origin), from the content stream. PDFKit's per-character
    /// boxes take the whole line's height, so they can't tell a superscript from the line.
    var baseline: CGFloat?

    var isSpace: Bool { text.allSatisfy(\.isWhitespace) }
}

/// What the planner gets for one page: PDFKit's lines as characters, plus what the content stream
/// draws that isn't text (path bounds, glyphs from LaTeX's line and circle fonts) and the images.
struct PageInput: Sendable {
    var lines: [[PageChar]]
    var paths: [CGRect] = []
    var graphicGlyphs: [CGRect] = []
    /// Glyphs drawn in fonts with no Unicode map: their text has to be read with OCR.
    var unextractedGlyphs: [CGRect] = []
    var images: [CGRect] = []
    var size: CGSize
}

/// A piece of a page in reading order.
enum PageItem: Equatable, Sendable {
    case line(LayoutLine)
    /// An embedded image, cropped from the page.
    case image(CGRect)
    /// A drawing made of lines and shapes, cropped from the page as a picture.
    case figure(CGRect)
    /// A display equation, cropped from the page as a picture; `number` is its "(3)" when set apart.
    case equation(CGRect, number: String?)
    /// A line whose text is unreadable (no Unicode map): read again with OCR from this region.
    case unreadable(CGRect, fontSize: CGFloat)

    var frame: CGRect {
        switch self {
        case let .line(line): line.frame
        case let .image(frame), let .figure(frame), let .equation(frame, _), let .unreadable(frame, _): frame
        }
    }
}

struct PlannedPage: Equatable, Sendable {
    var items: [PageItem]
    /// Most of the page's text is unreadable, so the whole page should be read with OCR.
    var needsOCR = false
}

/// Fonts by what they're for, from their PostScript names.
enum PDFFontClass {
    private static let mathPrefixes = [
        "CMMI", "CMSY", "CMEX", "CMBSY", "MSAM", "MSBM", "LMMI", "LMSY", "LMEX", "EUFM", "EUSM", "EURM", "RSFS",
        "STIX", "TXMI", "TXSY", "TXEX", "PXMI", "PXSY", "PXEX", "ESINT", "WASY",
    ]

    /// TeX and Unicode math fonts: CMMI*, CMSY*, CMEX*, MSAM*, MSBM*, *Math*, STIX, Latin Modern Math…
    static func isMath(_ name: String) -> Bool {
        let upper = name.uppercased()
        return mathPrefixes.contains { upper.hasPrefix($0) } || upper.contains("MATH")
    }

    /// LaTeX's `picture` fonts draw lines and circles with glyphs; their "text" is garbage.
    static func isGraphic(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["LINE10", "LINEW10", "LCIRCLE", "LCIRCLEW"].contains { upper.hasPrefix($0) }
    }

    static func isBold(_ name: String) -> Bool {
        let upper = name.uppercased()
        if ["BOLD", "BLACK", "HEAVY", "SEMIBOLD", "DEMI"].contains(where: upper.contains) { return true }
        // Computer Modern: CMBX10, CMB10, CMBXTI10, CMBXSL10.
        return upper.hasPrefix("CMB") && !upper.hasPrefix("CMBSY") || upper.hasPrefix("LMROMAN") && upper.contains("BOLD")
    }

    static func isItalic(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.contains("ITALIC") || upper.contains("OBLIQUE") { return true }
        return ["CMTI", "CMSL", "CMBXTI", "CMBXSL", "CMITT", "CMMI"].contains { upper.hasPrefix($0) }
    }
}

/// Turns a page's characters into items in reading order: fixes ligatures, inserts the spaces LaTeX
/// leaves out, marks superscripts and subscripts, finds display equations and line drawings (to be
/// cropped as pictures), table rows and unreadable text, and orders two-column pages column by
/// column. Pure, so every rule is unit-tested.
enum PageLayoutPlanner {
    // MARK: Tuning (set on the LaTeX fixture)

    /// A gap between two characters wider than this share of the font size is a word space.
    static let wordGap: CGFloat = 0.18
    /// A gap wider than this share of the font size separates table cells.
    static let cellGap: CGFloat = 1.0
    /// Characters smaller than this share of the line's size can be superscripts or subscripts.
    static let scriptSize: CGFloat = 0.85
    /// …when their middle sits this share of the line's size above or below the line's middle.
    static let scriptShift: CGFloat = 0.12
    /// A line counts as unreadable when this share of its characters can't be read.
    static let unreadableShare = 0.5

    static func plan(_ input: PageInput) -> PlannedPage {
        let graphicBoxes = input.graphicGlyphs
        var lines: [[PageChar]] = input.lines.map { line in
            line.flatMap { char -> [PageChar] in
                // Picture-font glyphs are drawing, not text; their boxes come from the content stream.
                if PDFFontClass.isGraphic(char.fontName) {
                    return []
                }
                return normalized(char)
            }
        }
        lines.removeAll { $0.allSatisfy(\.isSpace) }

        // Line drawings: the text inside them is part of the picture.
        let textChars = lines.flatMap { $0 }.filter { !$0.isSpace }
        let figures = figureRegions(paths: input.paths + graphicBoxes, chars: textChars, pageSize: input.size)
            .filter { figure in !input.images.contains { $0.contains(figure) } }
        if !figures.isEmpty {
            lines = lines.map { line in line.filter { char in !figures.contains { $0.insetBy(dx: -1, dy: -1).contains(char.frame.center) } } }
            lines.removeAll { $0.allSatisfy(\.isSpace) }
        }
        let images = input.images.filter { image in !figures.contains { $0.contains(image) } }

        let columns = ColumnLayout(lines: lines)
        let (equations, textLines) = equationRegions(lines: lines, paths: input.paths, columns: columns)

        var items: [PageItem] = images.map { .image($0) } + figures.map { .figure($0) } + equations
        var unreadable = 0
        var total = 0
        for chars in textLines {
            let count = chars.filter { !$0.isSpace }.count
            total += count
            if isUnreadable(chars.map(\.text).joined()) {
                unreadable += count
                let frame = union(chars.map(\.frame))
                items.append(.unreadable(frame, fontSize: dominantSize(chars)))
            } else if let line = layoutLine(chars) {
                items.append(.line(line))
            }
        }
        // Text that can't be extracted: read it with OCR where it sits, unless it's inside a picture.
        let pictures = figures + images + equations.map(\.frame)
        for region in missingTextRegions(input.unextractedGlyphs, pictures: pictures) {
            items.append(.unreadable(region, fontSize: region.height))
            unreadable += 1
        }
        let needsOCR = total > 0 && Double(unreadable) / Double(total) >= unreadableShare
        return PlannedPage(items: columns.ordered(items), needsOCR: needsOCR)
    }

    /// Rows of at least three unreadable glyphs, outside pictures (an equation's picture already shows them).
    static func missingTextRegions(_ glyphs: [CGRect], pictures: [CGRect]) -> [CGRect] {
        let loose = glyphs.filter { glyph in !pictures.contains { $0.contains(glyph.center) } }
        let size = TextLayoutAnalyzer.median(loose.map(\.height)) ?? 10
        return cluster(loose, tolerance: size * 0.3).filter { region in
            loose.filter { region.contains($0.center) }.count >= 3
        }
    }

    // MARK: Characters

    /// Ligatures and other presentation forms (U+FB00–FB4F, Arabic forms) become plain letters,
    /// each sharing the glyph's box.
    static func normalized(_ char: PageChar) -> [PageChar] {
        guard char.text.unicodeScalars.contains(where: isPresentationForm) else { return [char] }
        let plain = char.text.precomposedStringWithCompatibilityMapping
        let pieces = plain.map(String.init)
        guard pieces.count > 1 else {
            var copy = char
            copy.text = plain
            return [copy]
        }
        let width = char.frame.width / CGFloat(pieces.count)
        return pieces.enumerated().map { index, piece in
            var copy = char
            copy.text = piece
            copy.frame = CGRect(x: char.frame.minX + width * CGFloat(index), y: char.frame.minY, width: width, height: char.frame.height)
            return copy
        }
    }

    static func isPresentationForm(_ scalar: Unicode.Scalar) -> Bool {
        (0xFB00...0xFB4F).contains(scalar.value) || (0xFB50...0xFDFF).contains(scalar.value) || (0xFE70...0xFEFF).contains(scalar.value)
    }

    /// Normalizes presentation forms in extracted text (for PDF → Excel, which works on words).
    static func normalizedText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isPresentationForm) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.flatMap { scalar -> [Unicode.Scalar] in
            isPresentationForm(scalar) ? Array(String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars) : [scalar]
        }))
    }

    /// Private-use characters, U+FFFD and control characters: what a missing or broken Unicode map gives.
    static func isUnreadable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xFFFD, 0xE000...0xF8FF, 0xF0000...0x10FFFF: true
        case 0x00...0x08, 0x0B...0x1F, 0x7F...0x9F: true
        default: false
        }
    }

    static func isUnreadable(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count >= 2 else { return false }
        let bad = scalars.filter(isUnreadable).count
        return Double(bad) / Double(scalars.count) >= unreadableShare
    }

    static func dominantSize(_ chars: [PageChar]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for char in chars where !char.isSpace {
            counts[(char.fontSize * 10).rounded() / 10, default: 0] += 1
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 0
    }

    // MARK: Lines

    /// One line of text: spaces where the gaps say so, tabs between table cells, superscript and
    /// subscript runs, and a frame from its body-size characters (tall glyphs like ∑ don't stretch it).
    static func layoutLine(_ chars: [PageChar]) -> LayoutLine? {
        let visible = chars.filter { !$0.isSpace }
        guard !visible.isEmpty else { return nil }
        let size = dominantSize(visible)
        let body = visible.filter { abs($0.fontSize - size) <= size * 0.15 }
        let bodyTop = TextLayoutAnalyzer.median(body.map(\.frame.minY)) ?? visible[0].frame.minY
        let bodyBottom = TextLayoutAnalyzer.median(body.map(\.frame.maxY)) ?? visible[0].frame.maxY
        let bodyMiddle = (bodyTop + bodyBottom) / 2
        let bodyBaseline = TextLayoutAnalyzer.median(body.compactMap(\.baseline))

        var runs: [LayoutRun] = []
        var isTabular = false
        var previous: PageChar?
        var pendingSpace = false

        func append(_ text: String, size: CGFloat, bold: Bool, italic: Bool, script: LayoutRun.Script) {
            if var last = runs.last, last.fontSize == size, last.isBold == bold, last.isItalic == italic, last.script == script {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(LayoutRun(text: text, fontSize: size, isBold: bold, isItalic: italic, script: script))
            }
        }

        for char in chars {
            if char.isSpace {
                pendingSpace = previous != nil
                continue
            }
            let script = scriptPosition(of: char, lineSize: size, bodyMiddle: bodyMiddle, bodyBaseline: bodyBaseline)
            if let previous {
                let gap = char.frame.minX - previous.frame.maxX
                let em = max(char.fontSize, previous.fontSize, 1)
                if gap > em * cellGap, previous.fontSize >= size * scriptSize || char.fontSize >= size * scriptSize {
                    isTabular = true
                    append("\t", size: size, bold: false, italic: false, script: .none)
                } else if pendingSpace || gap > em * wordGap {
                    // No space between a base and its script (x² stays together).
                    if !(script != .none && !pendingSpace && gap < em * 0.5) {
                        append(" ", size: size, bold: false, italic: false, script: .none)
                    }
                }
            }
            append(char.text, size: char.fontSize, bold: char.isBold, italic: char.isItalic, script: script)
            previous = char
            pendingSpace = false
        }
        let minX = visible.map(\.frame.minX).min() ?? 0
        let maxX = visible.map(\.frame.maxX).max() ?? 0
        return LayoutLine(runs: runs, frame: CGRect(x: minX, y: bodyTop, width: maxX - minX, height: max(bodyBottom - bodyTop, 1)), isTabular: isTabular)
    }

    static func scriptPosition(of char: PageChar, lineSize: CGFloat, bodyMiddle: CGFloat, bodyBaseline: CGFloat? = nil) -> LayoutRun.Script {
        guard lineSize > 0, char.fontSize < lineSize * scriptSize else { return .none }
        if let baseline = char.baseline, let bodyBaseline {
            let shift = baseline - bodyBaseline
            if shift < -lineSize * 0.1 { return .superscript }
            if shift > lineSize * 0.1 { return .subscript }
            return .none
        }
        let shift = char.frame.midY - bodyMiddle
        if shift < -lineSize * scriptShift { return .superscript }
        if shift > lineSize * scriptShift { return .subscript }
        return .none
    }

    // MARK: Figures

    /// Clusters of painted paths (and picture-font glyphs) big enough to be a drawing. Thin rules
    /// (table lines, fraction bars, header rules) stay out, and so do framed tables full of text.
    static func figureRegions(paths: [CGRect], chars: [PageChar], pageSize: CGSize) -> [CGRect] {
        let boxes = paths.filter { $0.width < pageSize.width * 0.95 || $0.height < pageSize.height * 0.95 }
        let clusters = cluster(boxes, tolerance: 3)
        let pageArea = pageSize.width * pageSize.height
        return clusters.filter { region in
            guard region.width >= 36, region.height >= 24, region.width * region.height < pageArea * 0.7 else { return false }
            let text = chars.filter { region.insetBy(dx: -1, dy: -1).contains($0.frame.center) }.count
            return text <= 40
        }.map { $0.insetBy(dx: -2, dy: -2) }
    }

    /// Merges rectangles that touch or sit within `tolerance` of each other, until none do.
    static func cluster(_ rects: [CGRect], tolerance: CGFloat) -> [CGRect] {
        var clusters: [CGRect] = []
        for rect in rects where !rect.isNull {
            var merged = rect
            var changed = true
            while changed {
                changed = false
                for (index, other) in clusters.enumerated().reversed() where other.insetBy(dx: -tolerance, dy: -tolerance).intersects(merged) {
                    merged = merged.union(other)
                    clusters.remove(at: index)
                    changed = true
                }
            }
            clusters.append(merged)
        }
        return clusters
    }

    // MARK: Equations

    private static let operatorNames: Set<String> = [
        "lim", "sin", "cos", "tan", "cot", "sec", "csc", "log", "exp", "max", "min", "sup", "inf", "det", "arg",
        "deg", "dim", "ker", "mod", "gcd", "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan", "liminf", "limsup", "Pr", "hom",
    ]

    enum LineRole: Equatable {
        /// Running text (possibly with inline math).
        case prose
        /// Mostly math: part of a display equation.
        case math
        /// A few characters with no words, like a limit "k=1" or an equation number: math if next to math.
        case fragment
    }

    static func isMathChar(_ char: PageChar) -> Bool {
        if PDFFontClass.isMath(char.fontName) { return true }
        return char.text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .mathSymbol || (0x0370...0x03FF).contains(scalar.value)
                || (0x2200...0x22FF).contains(scalar.value) || (0x2190...0x21FF).contains(scalar.value)
        }
    }

    static func role(of chars: [PageChar]) -> LineRole {
        let visible = chars.filter { !$0.isSpace }
        guard !visible.isEmpty else { return .prose }
        // Words: runs of three or more letters in text fonts, other than operator names like "lim".
        var words = 0
        var current = ""
        func endWord() {
            if current.count >= 3, !operatorNames.contains(current) { words += 1 }
            current = ""
        }
        for char in chars {
            if !char.isSpace, !PDFFontClass.isMath(char.fontName), char.text.allSatisfy(\.isLetter) {
                current += char.text
            } else {
                endWord()
            }
        }
        endWord()
        let math = visible.filter(isMathChar).count
        if words <= 1, math >= 2, Double(math) >= Double(visible.count) * 0.3 { return .math }
        if words == 0, visible.count <= 6 { return .fragment }
        return .prose
    }

    /// Display equations: math lines plus the fragments around them (limits, stacked fractions, the
    /// number), grouped by position within one column. Returns them as items, and the lines left.
    static func equationRegions(lines: [[PageChar]], paths: [CGRect], columns: ColumnLayout) -> ([PageItem], [[PageChar]]) {
        let roles = lines.map(role)
        let frames = lines.map { union($0.filter { !$0.isSpace }.map(\.frame)) }
        let bodySize = TextLayoutAnalyzer.median(lines.flatMap { $0.filter { !$0.isSpace }.map(\.fontSize) }) ?? 10
        var groups: [[Int]] = []
        var assigned = Set<Int>()

        for seed in lines.indices where roles[seed] == .math && !assigned.contains(seed) {
            var group = [seed]
            assigned.insert(seed)
            var region = frames[seed]
            var grew = true
            while grew {
                grew = false
                for index in lines.indices where !assigned.contains(index) && roles[index] != .prose {
                    guard columns.column(of: frames[index]) == columns.column(of: region) || !columns.isTwoColumn else { continue }
                    let near = region.insetBy(dx: -bodySize, dy: -bodySize * 0.6).intersects(frames[index])
                    let sameRow = verticalOverlap(region, frames[index]) > min(region.height, frames[index].height) * 0.5
                        && horizontalGap(region, frames[index]) < bodySize * 15
                    if near || sameRow {
                        group.append(index)
                        assigned.insert(index)
                        region = region.union(frames[index])
                        grew = true
                    }
                }
            }
            groups.append(group)
        }

        let proseFrames = lines.indices.filter { !assigned.contains($0) }.compactMap { index -> CGRect? in
            layoutLine(lines[index])?.frame
        }
        var items: [PageItem] = []
        for group in groups {
            var chars = group.flatMap { lines[$0] }.filter { !$0.isSpace }
            let number = equationNumber(in: group.map { lines[$0] })
            if let number {
                chars.removeAll { number.chars.contains($0) }
            }
            var region = union(chars.map(\.frame))
            for path in paths where path.intersects(region.insetBy(dx: -1, dy: -1)) && path.width <= region.width * 1.5 {
                region = region.union(path)
            }
            region = clipped(region, around: proseFrames, columns: columns).insetBy(dx: -2, dy: -1)
            items.append(.equation(region, number: number?.text))
        }
        let remaining = lines.indices.filter { !assigned.contains($0) }.map { lines[$0] }
        return (items, remaining)
    }

    /// A single equation number like "(3)" or "(2.1a)", set apart at the right of a row. With more than
    /// one (aligned equations), the numbers stay in the picture.
    static func equationNumber(in lines: [[PageChar]]) -> (text: String, chars: [PageChar])? {
        var found: [(String, [PageChar])] = []
        for line in lines {
            let visible = line.filter { !$0.isSpace }
            guard let close = visible.last, close.text == ")",
                  let openIndex = visible.lastIndex(where: { $0.text == "(" })
            else { continue }
            let candidate = Array(visible[openIndex...])
            let text = candidate.map(\.text).joined()
            guard text.wholeMatch(of: /\(\d+(\.\d+)*[a-z]?\)/) != nil else { continue }
            if openIndex > 0 {
                let gap = candidate[0].frame.minX - visible[openIndex - 1].frame.maxX
                guard gap > candidate[0].fontSize * 1.5 else { continue }
            }
            found.append((text, candidate))
        }
        guard found.count == 1, let only = found.first else { return nil }
        return (only.0, only.1)
    }

    /// Tall glyph boxes (∑, ∫) can reach into the lines above and below: stop at them.
    static func clipped(_ region: CGRect, around prose: [CGRect], columns: ColumnLayout) -> CGRect {
        var top = region.minY
        var bottom = region.maxY
        for frame in prose where horizontalOverlap(frame, region) > 0 && columns.column(of: frame) == columns.column(of: region) {
            if frame.midY < region.midY, frame.maxY > top {
                top = min(frame.maxY + 0.5, region.midY)
            } else if frame.midY > region.midY, frame.minY < bottom {
                bottom = max(frame.minY - 0.5, region.midY)
            }
        }
        return CGRect(x: region.minX, y: top, width: region.width, height: max(bottom - top, 1))
    }

    // MARK: Geometry

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    static func horizontalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
    }

    // MARK: Running headers and footers

    /// Lines near the top or bottom that repeat on most pages (page numbers read as "#"), like a
    /// journal's running head or "Page 3". Returns the pages without them.
    static func removingRunningLines(_ pages: [PlannedPage], pageHeights: [CGFloat]) -> [PlannedPage] {
        guard pages.count >= 2 else { return pages }
        func key(_ line: LayoutLine) -> String {
            line.text.lowercased().replacing(/\d+/, with: "#").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        }
        func isMargin(_ line: LayoutLine, height: CGFloat) -> Bool {
            line.frame.maxY < height * 0.1 || line.frame.minY > height * 0.9
        }
        var counts: [String: Int] = [:]
        for (page, height) in zip(pages, pageHeights) {
            let keys = Set(page.items.compactMap { item -> String? in
                guard case let .line(line) = item, isMargin(line, height: height) else { return nil }
                return key(line)
            })
            for key in keys where !key.isEmpty {
                counts[key, default: 0] += 1
            }
        }
        let repeated = Set(counts.filter { $0.value >= 2 && Double($0.value) >= Double(pages.count) * 0.5 }.keys)
        guard !repeated.isEmpty else { return pages }
        return zip(pages, pageHeights).map { page, height in
            var copy = page
            copy.items.removeAll { item in
                guard case let .line(line) = item else { return false }
                return isMargin(line, height: height) && repeated.contains(key(line))
            }
            return copy
        }
    }
}

/// One or two columns, found from where the lines of text sit.
struct ColumnLayout: Equatable, Sendable {
    enum Column: Equatable { case full, left, right }

    var isTwoColumn: Bool
    var middle: CGFloat

    init(isTwoColumn: Bool, middle: CGFloat) {
        self.isTwoColumn = isTwoColumn
        self.middle = middle
    }

    /// Two columns when several lines of words sit wholly in each half of the text area.
    init(lines: [[PageChar]]) {
        let frames = lines.map { PageLayoutPlanner.union($0.filter { !$0.isSpace }.map(\.frame)) }.filter { !$0.isNull }
        let left = frames.map(\.minX).min() ?? 0
        let right = frames.map(\.maxX).max() ?? 0
        let middle = (left + right) / 2
        self.middle = middle
        let wordy = zip(lines, frames).filter { line, _ in
            line.map(\.text).joined().split(whereSeparator: \.isWhitespace).count >= 4
        }.map(\.1)
        let leftCount = wordy.filter { $0.maxX < middle + 2 }.count
        let rightCount = wordy.filter { $0.minX > middle - 2 }.count
        isTwoColumn = leftCount >= 3 && rightCount >= 3 && leftCount + rightCount >= wordy.count / 2
    }

    func column(of frame: CGRect) -> Column {
        guard isTwoColumn else { return .full }
        if frame.minX < middle - 5, frame.maxX > middle + 5 { return .full }
        return frame.midX < middle ? .left : .right
    }

    /// Top to bottom; on two-column pages, everything between two full-width items is read down the
    /// left column, then down the right.
    func ordered(_ items: [PageItem]) -> [PageItem] {
        let sorted = items.sorted { a, b in
            a.frame.minY != b.frame.minY ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
        }
        guard isTwoColumn else { return sorted }
        var result: [PageItem] = []
        var left: [PageItem] = []
        var right: [PageItem] = []
        for item in sorted {
            switch column(of: item.frame) {
            case .full:
                result += left + right
                left = []
                right = []
                result.append(item)
            case .left: left.append(item)
            case .right: right.append(item)
            }
        }
        return result + left + right
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
