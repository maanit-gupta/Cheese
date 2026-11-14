import Foundation

/// Joins several .docx packages into one, for Merge Files' Word output. Real content, not
/// `altChunk` (which Pages and LibreOffice don't render reliably): each later document's body is
/// appended to the first's, with its pictures and links re-linked under new relationship IDs, its
/// list numbering copied under new IDs, the styles it uses copied when the first lacks them (same
/// IDs use the first document's), and its section settings, headers and footers dropped: the first
/// document's stay. Footnotes, endnotes and comments of later documents aren't carried over, and
/// embedded objects (charts, SmartArt) that can't be re-linked are left out. Pure edits on parts.
enum DocxMerger {
    struct Document: Sendable {
        var parts: [String: Data]
        /// Shown on divider headings: the source file's name.
        var title: String
    }

    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// `dividers`: each document starts with a Heading 1 of its name (and every one after the first
    /// on a new page, as they do anyway). `pageNumbers`: a PAGE field in the footer.
    static func merge(_ documents: [Document], dividers: Bool, pageNumbers: Bool) throws -> [String: Data] {
        guard var base = documents.first?.parts else { throw FileToolError.message("Nothing to merge.") }
        let paths = try PackagePaths(base)
        var document = try text(base, paths.document)
        var relationships = (try? text(base, paths.relationships)) ?? emptyRelationships
        var styles = try? text(base, paths.styles)
        var numbering = try? text(base, paths.numbering)
        var contentTypes = try text(base, "[Content_Types].xml")

        guard let bodyOpen = document.firstMatch(of: /<w:body\b[^>]*>/), let bodyClose = document.range(of: "</w:body>", options: .backwards) else {
            throw FileToolError.message("A Word document is missing its body.")
        }
        var (content, sectPr) = splitSection(String(document[bodyOpen.range.upperBound..<bodyClose.lowerBound]))
        var drawingID = 10_000
        content = renumberDrawings(content, from: &drawingID)
        if dividers, let first = documents.first {
            content = heading(first.title, newPage: false) + content
        }
        var rootNamespaces = namespaces(in: document)

        for (offset, piece) in documents.dropFirst().enumerated() {
            let index = offset + 1
            let piecePaths = try PackagePaths(piece.parts)
            let pieceDocument = try text(piece.parts, piecePaths.document)
            guard let open = pieceDocument.firstMatch(of: /<w:body\b[^>]*>/),
                  let close = pieceDocument.range(of: "</w:body>", options: .backwards)
            else { throw FileToolError.message("\(piece.title) is missing its body.") }
            var body = splitSection(String(pieceDocument[open.range.upperBound..<close.lowerBound])).content
            body = removingSections(body)
            body = removingNotesAndComments(body)

            // Pictures and links.
            let pieceRelationships = parseRelationships((try? text(piece.parts, piecePaths.relationships)) ?? "")
            var map: [String: String] = [:]
            for relation in pieceRelationships {
                let newID = "rIdM\(index)x\(relation.id)"
                if relation.type == relationshipType + "image", relation.mode != "External" {
                    let source = resolve(relation.target, from: piecePaths.directory)
                    guard let data = piece.parts[source] else { continue }
                    let name = "media/merged\(index)-\((source as NSString).lastPathComponent)"
                    base[paths.directory + name] = data
                    relationships = adding(relationship: newID, type: relation.type, target: name, mode: nil, to: relationships)
                    contentTypes = ensuringDefault(for: (name as NSString).pathExtension, in: contentTypes)
                    map[relation.id] = newID
                } else if relation.type == relationshipType + "hyperlink" {
                    relationships = adding(relationship: newID, type: relation.type, target: relation.target, mode: relation.mode, to: relationships)
                    map[relation.id] = newID
                }
            }
            body = relinking(body, map: map)
            body = renumberDrawings(body, from: &drawingID)
            body = body.replacing(/(<w:bookmark(?:Start|End)\b[^>]*\bw:id=")(\d+)(")/) { match in
                "\(match.1)\((Int(match.2) ?? 0) + index * 100_000)\(match.3)"
            }

            // List numbering.
            if body.contains("<w:numId "), let pieceNumbering = try? text(piece.parts, piecePaths.numbering) {
                let (definitions, numMap) = renumbered(pieceNumbering, offset: index * 1000)
                if numbering == nil {
                    numbering = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:numbering xmlns:w=\"\(wordNamespace)\"></w:numbering>"
                    base[paths.numbering] = Data()
                    relationships = adding(relationship: "rIdCheeseNumbering", type: relationshipType + "numbering", target: (paths.numbering as NSString).lastPathComponent, mode: nil, to: relationships)
                    contentTypes = ensuringOverride("/" + paths.numbering, type: "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml", in: contentTypes)
                }
                numbering = inserting(definitions, into: numbering ?? "")
                body = body.replacing(/(<w:numId w:val=")(\d+)(")/) { match in
                    "\(match.1)\(numMap[String(match.2)] ?? String(match.2))\(match.3)"
                }
            }

            // Styles the first document doesn't have.
            if let pieceStyles = try? text(piece.parts, piecePaths.styles) {
                styles = copyingMissingStyles(usedIn: body, from: pieceStyles, into: styles)
            }
            for (prefix, uri) in namespaces(in: pieceDocument) where rootNamespaces[prefix] == nil {
                rootNamespaces[prefix] = uri
                document = document.replacing(/<w:document\b/, with: "<w:document xmlns:\(prefix)=\"\(uri)\"", maxReplacements: 1)
            }

            content += dividers ? heading(piece.title, newPage: true) : pageBreak
            content += body
        }

        if dividers {
            styles = ensuringHeadingStyle(in: styles)
        }
        if pageNumbers {
            let footer = "word/footerCheesePageNumber.xml"
            base[paths.directory + (footer as NSString).lastPathComponent] = Data(footerXML.utf8)
            relationships = adding(relationship: "rIdCheeseFooter", type: relationshipType + "footer", target: (footer as NSString).lastPathComponent, mode: nil, to: relationships)
            contentTypes = ensuringOverride(
                "/" + paths.directory + (footer as NSString).lastPathComponent,
                type: "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml", in: contentTypes
            )
            sectPr = withFooter("rIdCheeseFooter", in: sectPr)
            if rootNamespaces["r"] == nil {
                document = document.replacing(/<w:document\b/, with: "<w:document xmlns:r=\"\(relationshipNamespace)\"", maxReplacements: 1)
            }
        }

        // Rebuild document.xml around the merged content (the root may have gained namespaces).
        guard let newOpen = document.firstMatch(of: /<w:body\b[^>]*>/), let newClose = document.range(of: "</w:body>", options: .backwards) else {
            throw FileToolError.message("A Word document is missing its body.")
        }
        document = String(document[..<newOpen.range.upperBound]) + content + sectPr + String(document[newClose.lowerBound...])
        base[paths.document] = Data(document.utf8)
        base[paths.relationships] = Data(relationships.utf8)
        base["[Content_Types].xml"] = Data(contentTypes.utf8)
        if let styles {
            if base[paths.styles] == nil {
                base = addingPart(paths.styles, type: "styles", contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml", to: base, paths: paths)
            }
            base[paths.styles] = Data(styles.utf8)
        }
        if let numbering {
            base[paths.numbering] = Data(numbering.utf8)
        }
        return base
    }

    // MARK: Package

    /// Where the main document and its parts live, from the package's root relationships.
    struct PackagePaths {
        var document: String
        var directory: String
        var relationships: String
        var styles: String
        var numbering: String

        init(_ parts: [String: Data]) throws {
            let root = parts["_rels/.rels"].map { String(decoding: $0, as: UTF8.self) } ?? ""
            let main = DocxMerger.parseRelationships(root).first { $0.type.hasSuffix("/officeDocument") }?.target ?? "word/document.xml"
            document = main.hasPrefix("/") ? String(main.dropFirst()) : main
            guard parts[document] != nil else { throw FileToolError.message("A Word document is missing its body.") }
            let folder = (document as NSString).deletingLastPathComponent
            let directory = folder.isEmpty ? "" : folder + "/"
            self.directory = directory
            let relationships = directory + "_rels/" + (document as NSString).lastPathComponent + ".rels"
            self.relationships = relationships
            let related = DocxMerger.parseRelationships(parts[relationships].map { String(decoding: $0, as: UTF8.self) } ?? "")
            styles = related.first { $0.type.hasSuffix("/styles") }.map { DocxMerger.resolve($0.target, from: directory) } ?? directory + "styles.xml"
            numbering = related.first { $0.type.hasSuffix("/numbering") }.map { DocxMerger.resolve($0.target, from: directory) } ?? directory + "numbering.xml"
        }
    }

    struct Relationship: Equatable {
        var id: String
        var type: String
        var target: String
        var mode: String?
    }

    static func parseRelationships(_ xml: String) -> [Relationship] {
        xml.matches(of: /<Relationship\b[^>]*>/).compactMap { match in
            let tag = String(match.0)
            guard let id = attribute("Id", in: tag), let type = attribute("Type", in: tag), let target = attribute("Target", in: tag) else { return nil }
            return Relationship(id: id, type: type, target: target, mode: attribute("TargetMode", in: tag))
        }
    }

    /// A relationship target relative to the main document's folder, as a part path.
    static func resolve(_ target: String, from directory: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        var components = directory.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." {
                _ = components.popLast()
            } else if piece != "." {
                components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }

    private static let emptyRelationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#

    private static func text(_ parts: [String: Data], _ path: String) throws -> String {
        guard let data = parts[path] else { throw FileToolError.message("A Word document is missing \(path).") }
        return String(decoding: data, as: UTF8.self)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("\\b\(name)=\"([^\"]*)\""), let match = tag.firstMatch(of: regex), let value = match.output[1].substring else {
            return nil
        }
        return HTMLForDocx.decodeEntities(String(value))
    }

    private static func adding(relationship id: String, type: String, target: String, mode: String?, to xml: String) -> String {
        let escapedTarget = DocxTableEmbedder.escaped(target)
        let modeAttribute = mode.map { " TargetMode=\"\($0)\"" } ?? ""
        return xml.replacing("</Relationships>", with: "<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(escapedTarget)\"\(modeAttribute)/></Relationships>")
    }

    private static func addingPart(_ path: String, type: String, contentType: String, to parts: [String: Data], paths: PackagePaths) -> [String: Data] {
        var parts = parts
        let relationships = parts[paths.relationships].map { String(decoding: $0, as: UTF8.self) } ?? emptyRelationships
        parts[paths.relationships] = Data(adding(relationship: "rIdCheese\(type)", type: relationshipType + type, target: (path as NSString).lastPathComponent, mode: nil, to: relationships).utf8)
        let types = parts["[Content_Types].xml"].map { String(decoding: $0, as: UTF8.self) } ?? ""
        parts["[Content_Types].xml"] = Data(ensuringOverride("/" + path, type: contentType, in: types).utf8)
        return parts
    }

    static func ensuringDefault(for ext: String, in types: String) -> String {
        let lower = ext.lowercased()
        guard !lower.isEmpty, !types.contains("Extension=\"\(lower)\"") else { return types }
        let mime = switch lower {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "svg": "image/svg+xml"
        case "emf": "image/x-emf"
        case "wmf": "image/x-wmf"
        default: "application/octet-stream"
        }
        return types.replacing("</Types>", with: "<Default Extension=\"\(lower)\" ContentType=\"\(mime)\"/></Types>")
    }

    static func ensuringOverride(_ part: String, type: String, in types: String) -> String {
        guard !types.contains("PartName=\"\(part)\"") else { return types }
        return types.replacing("</Types>", with: "<Override PartName=\"\(part)\" ContentType=\"\(type)\"/></Types>")
    }

    /// `xmlns:` declarations on the root element.
    static func namespaces(in document: String) -> [String: String] {
        guard let root = document.firstMatch(of: /<w:document\b[^>]*>/) else { return [:] }
        var result: [String: String] = [:]
        for match in String(root.0).matches(of: /xmlns:([A-Za-z0-9]+)="([^"]*)"/) {
            result[String(match.1)] = String(match.2)
        }
        return result
    }

    // MARK: Body

    /// The body's content and its final section properties (page size, margins, headers).
    static func splitSection(_ body: String) -> (content: String, sectPr: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: /(?s)<w:sectPr\b(?:[^>]*\/>|[^>]*>.*?<\/w:sectPr>)\s*$/) {
            return (String(trimmed[..<match.range.lowerBound]), String(match.0))
        }
        return (trimmed, "")
    }

    /// Section breaks inside a later document would bring its headers and page setup along.
    static func removingSections(_ body: String) -> String {
        body.replacing(/(?s)<w:sectPr\b[^>]*\/>|<w:sectPr\b[^>]*>.*?<\/w:sectPr>/, with: "")
    }

    static func removingNotesAndComments(_ body: String) -> String {
        body.replacing(/<w:(?:footnoteReference|endnoteReference|commentReference|commentRangeStart|commentRangeEnd)\b[^>]*\/>/, with: "")
    }

    /// Points relationship attributes at their new IDs, and leaves out drawings and objects whose
    /// part wasn't carried over (a chart, an embedded file), so Word never meets a broken link.
    static func relinking(_ body: String, map: [String: String]) -> String {
        let blocks = /(?s)<w:drawing>.*?<\/w:drawing>|<w:object\b.*?<\/w:object>|<w:pict>.*?<\/w:pict>/
        var result = body.replacing(blocks) { match in
            let block = String(match.0)
            let ids = block.matches(of: /\br:(?:id|embed|link|pict|dm|lo|qs|cs)="([^"]+)"/).map { String($0.1) }
            return ids.allSatisfy { map[$0] != nil } ? block : ""
        }
        result = result.replacing(/(\br:(?:id|embed|link|pict)=")([^"]+)(")/) { match in
            if let mapped = map[String(match.2)] {
                return "\(match.1)\(mapped)\(match.3)"
            }
            return ""
        }
        return result
    }

    /// Drawing IDs must be unique in a document.
    static func renumberDrawings(_ body: String, from counter: inout Int) -> String {
        var next = counter
        let result = body.replacing(/(<(?:wp:docPr|pic:cNvPr)\b[^>]*?\bid=")(\d+)(")/) { match in
            next += 1
            return "\(match.1)\(next)\(match.3)"
        }
        counter = next
        return result
    }

    /// A later document's abstract numbering definitions and numbering instances under new IDs.
    static func renumbered(_ numbering: String, offset: Int) -> (definitions: (abstract: String, instances: String), map: [String: String]) {
        var abstract = ""
        for match in numbering.matches(of: /(?s)<w:abstractNum\b[^>]*>.*?<\/w:abstractNum>/) {
            abstract += String(match.0).replacing(/(w:abstractNumId=")(\d+)(")/) { id in "\(id.1)\((Int(id.2) ?? 0) + offset)\(id.3)" }
        }
        var map: [String: String] = [:]
        var instances = ""
        for match in numbering.matches(of: /(?s)<w:num\b[^>]*>.*?<\/w:num>/) {
            var block = String(match.0)
            if let id = attribute("w:numId", in: String(block.prefix { $0 != ">" })) {
                let newID = String((Int(id) ?? 0) + offset)
                map[id] = newID
                if let opening = block.firstMatch(of: /(<w:num\b[^>]*w:numId=")(\d+)(")/) {
                    block.replaceSubrange(opening.range, with: "\(opening.1)\(newID)\(opening.3)")
                }
            }
            block = block.replacing(/(<w:abstractNumId w:val=")(\d+)(")/) { id in "\(id.1)\((Int(id.2) ?? 0) + offset)\(id.3)" }
            instances += block
        }
        return ((abstract, instances), map)
    }

    /// Abstract definitions go before the first `w:num`, instances at the end, as the schema wants.
    static func inserting(_ definitions: (abstract: String, instances: String), into numbering: String) -> String {
        var result = numbering
        if let firstNum = result.firstMatch(of: /<w:num\b/) {
            result.insert(contentsOf: definitions.abstract, at: firstNum.range.lowerBound)
        } else if let close = result.range(of: "</w:numbering>", options: .backwards) {
            result.insert(contentsOf: definitions.abstract, at: close.lowerBound)
        }
        if let close = result.range(of: "</w:numbering>", options: .backwards) {
            result.insert(contentsOf: definitions.instances, at: close.lowerBound)
        }
        return result
    }

    /// Copies the styles `body` uses (and the styles they're based on) that `styles` doesn't define.
    static func copyingMissingStyles(usedIn body: String, from source: String, into styles: String?) -> String? {
        guard var styles else { return nil }
        let existing = Set(styles.matches(of: /<w:style\b[^>]*\bw:styleId="([^"]+)"/).map { String($0.1) })
        var definitions: [String: String] = [:]
        for match in source.matches(of: /(?s)<w:style\b[^>]*\bw:styleId="([^"]+)"[^>]*>.*?<\/w:style>/) {
            definitions[String(match.1)] = String(match.0)
        }
        var wanted = body.matches(of: /<w:(?:pStyle|rStyle|tblStyle) w:val="([^"]+)"\/>/).map { String($0.1) }
        var copied = Set<String>()
        while let id = wanted.popLast() {
            guard !existing.contains(id), !copied.contains(id), let definition = definitions[id] else { continue }
            copied.insert(id)
            styles = styles.replacing("</w:styles>", with: definition + "</w:styles>")
            wanted += definition.matches(of: /<w:(?:basedOn|next|link) w:val="([^"]+)"\/>/).map { String($0.1) }
        }
        return styles
    }

    static func ensuringHeadingStyle(in styles: String?) -> String? {
        guard let styles, !styles.contains("w:styleId=\"Heading1\"") else { return styles }
        let heading = """
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
        """
        return styles.replacing("</w:styles>", with: heading + "</w:styles>")
    }

    static let pageBreak = #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#

    /// A divider: the file's name as Heading 1, on a new page unless it's the first.
    static func heading(_ title: String, newPage: Bool) -> String {
        let pageBreak = newPage ? "<w:pageBreakBefore/>" : ""
        return #"<w:p><w:pPr><w:pStyle w:val="Heading1"/>"# + pageBreak + #"</w:pPr><w:r><w:t xml:space="preserve">"#
            + DocxTableEmbedder.escaped(title) + "</w:t></w:r></w:p>"
    }

    static let footerXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="\(wordNamespace)"><w:p><w:pPr><w:jc w:val="center"/></w:pPr>\
    <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>\
    <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>
    """

    /// The section's default footer becomes `id` (headers stay); a missing section gets Letter with 1-inch margins.
    static func withFooter(_ id: String, in sectPr: String) -> String {
        let reference = "<w:footerReference w:type=\"default\" r:id=\"\(id)\"/>"
        guard !sectPr.isEmpty else {
            return "<w:sectPr>\(reference)<w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        }
        var result = sectPr.replacing(/<w:footerReference\b[^>]*w:type="default"[^>]*\/>/, with: "")
        if result.hasSuffix("/>"), !result.contains("</w:sectPr>") {
            result = String(result.dropLast(2)) + ">" + "</w:sectPr>"
        }
        if let lastHeader = result.ranges(of: /<w:headerReference\b[^>]*\/>/).last {
            result.insert(contentsOf: reference, at: lastHeader.upperBound)
        } else if let open = result.firstMatch(of: /<w:sectPr\b[^>]*>/) {
            result.insert(contentsOf: reference, at: open.range.upperBound)
        }
        return result
    }
}
