import Foundation

/// Rebuilds a link copied out of a terminal: strips escape codes and enclosing brackets/quotes, joins
/// a URL that the terminal broke across lines at its column width, and drops a shell prompt that was
/// selected along with it. Pure (Foundation only), unit-tested.
enum TerminalLinkNormalizer {
    /// Longest prompt that may precede the link (`user@mac ~ %`), like Terminal Trace's prompt prefix.
    static let maxPromptLength = 80
    /// Copies bigger than this are output, not a link; they're left alone without scanning.
    static let maxInputLength = 16 * 1024

    private static let promptEnds: Set<Character> = ["$", "%", "#", ">", "❯", "➜", "λ", "→"]
    private static let enclosures: [(Character, Character)] = [("<", ">"), ("(", ")"), ("[", "]"), ("'", "'"), ("\"", "\"")]
    private static let enclosureCharacters: Set<Character> = ["<", ">", "(", ")", "[", "]", "'", "\""]
    private static let schemePattern = "https?://"

    /// The single http(s) link in `text`, rebuilt across line wraps, or nil when the text isn't just a link.
    ///
    /// - Parameter fromTerminal: the copy came from a terminal host. Then a shell prompt before the link
    ///   is allowed (and dropped); otherwise the text must start with the link and nothing may follow it.
    static func link(in text: String, fromTerminal: Bool) -> String? {
        guard text.utf8.count <= maxInputLength else { return nil }
        let cleaned = stripEnclosure(
            stripEscapes(text)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !fromTerminal {
            guard cleaned.range(of: "^" + schemePattern, options: [.regularExpression, .caseInsensitive]) != nil
            else { return nil }
        }
        let joined = unwrap(cleaned)

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let whole = NSRange(joined.startIndex..., in: joined)
        let links = detector.matches(in: joined, range: whole).compactMap { match -> Range<String.Index>? in
            guard let range = Range(match.range, in: joined) else { return nil }
            let candidate = joined[range]
            guard candidate.range(of: "^" + schemePattern, options: [.regularExpression, .caseInsensitive]) != nil
            else { return nil }
            return range
        }
        guard links.count == 1, let range = links.first else { return nil }

        let link = String(joined[range])
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }

        let before = trimmedRemainder(joined[..<range.lowerBound])
        let after = trimmedRemainder(joined[range.upperBound...])
        guard after.isEmpty else { return nil }
        if before.isEmpty { return link }
        // Only a terminal's prompt may come before the link: one short line ending in a prompt symbol.
        guard fromTerminal,
              !before.contains("\n"),
              before.count <= maxPromptLength,
              let last = before.last, promptEnds.contains(last)
        else { return nil }
        return link
    }

    /// Removes ANSI CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` / `ESC ] … ESC \`) sequences and other
    /// control characters except newlines and tabs.
    static func stripEscapes(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar.value {
            case 0x1B:
                guard let kind = scalars.next() else { break }
                if kind == "[" {
                    // Parameters and intermediates, then one final byte in 0x40…0x7E.
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                } else if kind == "]" {
                    while let next = scalars.next() {
                        if next.value == 0x07 { break }
                        if next.value == 0x1B { _ = scalars.next(); break }
                    }
                }
            case 0x0A, 0x09, 0x0D:
                output.append(scalar)
            case 0x00..<0x20, 0x7F:
                continue
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// Strips matching brackets or quotes wrapped around the whole text, repeatedly.
    static func stripEnclosure(_ text: String) -> String {
        var current = text
        while current.count >= 2,
              let first = current.first, let last = current.last,
              enclosures.contains(where: { $0.0 == first && $0.1 == last }) {
            current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    /// Joins a URL the terminal wrapped onto following lines. The URL must run to the end of its line,
    /// and each continuation line (indentation trimmed) must be non-empty, contain no whitespace and not
    /// start another link, so a list of URLs or a URL followed by prose stays apart.
    static func unwrap(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.range(of: schemePattern, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return text }

        var head = lines[start].trimmingTrailingWhitespace()
        guard let scheme = head.range(of: schemePattern, options: [.regularExpression, .caseInsensitive]),
              !head[scheme.lowerBound...].contains(where: \.isWhitespace)
        else { return text }

        var next = start + 1
        while next < lines.count {
            let piece = lines[next].trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty,
                  !piece.contains(where: \.isWhitespace),
                  !piece.contains("://")
            else { break }
            head += piece
            next += 1
        }
        lines.replaceSubrange(start..<next, with: [head])
        return lines.joined(separator: "\n")
    }

    private static func trimmedRemainder(_ text: Substring) -> String {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = current.last, enclosureCharacters.contains(last) {
            current.removeLast()
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let first = current.first, enclosureCharacters.contains(first) {
            current.removeFirst()
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }
}

extension TerminalLinkNormalizer {
    /// `clip` with a terminal-wrapped or prompt-prefixed link rebuilt into a plain link, or nil when
    /// there's nothing to rebuild (not text, not a link, or already exactly the link).
    static func linkClip(from clip: CapturedClip, fromTerminal: Bool) -> CapturedClip? {
        guard case let .text(plain, _, _) = clip else { return nil }
        let looksWrapped = plain.range(of: "^\\s*" + schemePattern, options: [.regularExpression, .caseInsensitive]) != nil
            && plain.contains(where: \.isNewline)
        guard fromTerminal || looksWrapped,
              let link = link(in: plain, fromTerminal: fromTerminal),
              link != plain
        else { return nil }
        let data = Data(link.utf8)
        let item = PasteboardItemContent(representations: [
            PasteboardRepresentation(type: PasteboardTypeID.plainText, data: data),
            PasteboardRepresentation(type: PasteboardTypeID.url, data: data),
        ])
        return .text(plain: link, items: [item], isRich: false)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy.removeLast() }
        return copy
    }
}
