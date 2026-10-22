import CoreGraphics
import Foundation
import JavaScriptCore

/// An image to put into a .docx where a placeholder token stands in the text.
struct DocxImage: Sendable {
    var token: String
    var png: Data
    /// Display size in points.
    var size: CGSize

    /// A token Cocoa's writer keeps in one run: letters and digits only.
    static func token(_ number: Int) -> String {
        "CHEESEIMAGE" + String(format: "%04d", number) + "X"
    }
}

/// Cocoa's Office Open XML writer drops images, so Files writes a token paragraph where each image
/// goes and then swaps it for an inline picture: the PNG as a media part, a relationship, a PNG
/// content type, and a `w:drawing` in place of the token. Pure edits on the package's parts.
enum DocxImageEmbedder {
    static let documentPath = "word/document.xml"
    static let relationshipsPath = "word/_rels/document.xml.rels"
    static let contentTypesPath = "[Content_Types].xml"
    private static let emuPerPoint = 12_700.0

    static func embed(_ images: [DocxImage], into parts: inout [String: Data]) throws {
        guard !images.isEmpty else { return }
        guard var document = parts[documentPath].map({ String(decoding: $0, as: UTF8.self) }) else {
            throw FileToolError.message("The Word document is missing its body.")
        }
        var relationships = parts[relationshipsPath].map { String(decoding: $0, as: UTF8.self) }
            ?? #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#
        for (offset, image) in images.enumerated() {
            let number = offset + 1
            let relationship = "rIdCheeseImage\(number)"
            let media = "media/cheese-image-\(number).png"
            guard let regex = try? Regex("<w:t(\\s[^>]*)?>\(image.token)</w:t>"), document.contains(regex) else {
                throw FileToolError.message("An image couldn't be placed in the Word document.")
            }
            document = document.replacing(regex, with: drawing(relationship: relationship, number: number, size: image.size))
            parts["word/\(media)"] = image.png
            relationships = relationships.replacing(
                "</Relationships>",
                with: #"<Relationship Id="\#(relationship)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\#(media)"/></Relationships>"#
            )
        }
        parts[documentPath] = Data(document.utf8)
        parts[relationshipsPath] = Data(relationships.utf8)
        if var types = parts[contentTypesPath].map({ String(decoding: $0, as: UTF8.self) }), !types.contains(#"Extension="png""#) {
            types = types.replacing("</Types>", with: #"<Default Extension="png" ContentType="image/png"/></Types>"#)
            parts[contentTypesPath] = Data(types.utf8)
        }
    }

    /// An inline picture, sized in EMUs (12,700 per point).
    private static func drawing(relationship: String, number: Int, size: CGSize) -> String {
        let cx = Int((size.width * emuPerPoint).rounded())
        let cy = Int((size.height * emuPerPoint).rounded())
        return """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(1000 + number)" name="Picture \(number)"/>\
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:nvPicPr><pic:cNvPr id="\(1000 + number)" name="cheese-image-\(number).png"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
    }
}

/// Reads and writes ZIP packages (.docx, .xlsx) with SheetJS's bundled CFB library in a bare
/// `JSContext`: synchronous, offline, and no extra dependency.
enum ZipArchive {
    private static let helpers = """
    function cheeseZipRead(base64) {
        const zip = XLSX.CFB.read(base64, { type: "base64" });
        const entries = [];
        zip.FileIndex.forEach((file, index) => {
            if (file.type !== 2 || file.name === "\\u0001Sh33tJ5") return;
            entries.push({ path: zip.FullPaths[index].replace(/^[^/]*\\//, ""), bytes: new Uint8Array(file.content || []) });
        });
        return entries;
    }
    function cheeseZipWrite(entries) {
        const zip = XLSX.CFB.utils.cfb_new();
        entries.forEach((entry) => XLSX.CFB.utils.cfb_add(zip, "/" + entry.path, entry.bytes));
        return XLSX.CFB.write(zip, { fileType: "zip", type: "base64", compression: true });
    }
    """

    static func read(_ data: Data) throws -> [String: Data] {
        let context = try sheetJS()
        let entries = context.objectForKeyedSubscript("cheeseZipRead")?.call(withArguments: [data.base64EncodedString()])
        try JavaScriptRunner.check(context)
        guard let entries, let count = entries.objectForKeyedSubscript("length")?.toInt32() else {
            throw FileToolError.message("The package couldn't be read.")
        }
        var parts: [String: Data] = [:]
        for index in 0..<Int(count) {
            guard let entry = entries.atIndex(index), let path = entry.objectForKeyedSubscript("path")?.toString(),
                  let bytes = entry.objectForKeyedSubscript("bytes")
            else { continue }
            parts[path] = try self.bytes(of: bytes, in: context)
        }
        return parts
    }

    static func write(_ parts: [String: Data]) throws -> Data {
        let context = try sheetJS()
        // [Content_Types].xml first, as Office expects.
        let ordered = parts.keys.sorted { lhs, rhs in
            lhs == DocxImageEmbedder.contentTypesPath || (rhs != DocxImageEmbedder.contentTypesPath && lhs < rhs)
        }
        let entries = try ordered.map { path -> JSValue in
            guard let entry = JSValue(newObjectIn: context) else { throw FileToolError.message("The package couldn't be written.") }
            entry.setObject(path, forKeyedSubscript: "path" as NSString)
            entry.setObject(try typedArray(parts[path] ?? Data(), in: context), forKeyedSubscript: "bytes" as NSString)
            return entry
        }
        let result = context.objectForKeyedSubscript("cheeseZipWrite")?.call(withArguments: [entries])
        try JavaScriptRunner.check(context)
        guard let base64 = result?.toString(), let data = Data(base64Encoded: base64) else {
            throw FileToolError.message("The package couldn't be written.")
        }
        return data
    }

    private static func sheetJS() throws -> JSContext {
        let context = try JavaScriptRunner.context(loading: ["xlsx.full.min.js"])
        context.evaluateScript(helpers)
        try JavaScriptRunner.check(context)
        return context
    }

    private static func bytes(of array: JSValue, in context: JSContext) throws -> Data {
        var exception: JSValueRef?
        let ref = array.jsValueRef
        let length = JSObjectGetTypedArrayByteLength(context.jsGlobalContextRef, ref, &exception)
        guard exception == nil else { throw FileToolError.message("The package couldn't be read.") }
        guard length > 0, let pointer = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, ref, &exception) else { return Data() }
        return Data(bytes: pointer, count: length)
    }

    private static func typedArray(_ data: Data, in context: JSContext) throws -> JSValue {
        var exception: JSValueRef?
        let ctx = context.jsGlobalContextRef
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, data.count, &exception), exception == nil else {
            throw FileToolError.message("The package couldn't be written.")
        }
        if !data.isEmpty, let pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) {
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        guard let value = JSValue(jsValueRef: object, in: context) else { throw FileToolError.message("The package couldn't be written.") }
        return value
    }
}

/// Writes .xlsx workbooks with the vendored SheetJS in a `JSContext` (no WebView).
enum SheetJSWriter {
    struct Sheet: Sendable {
        var name: String
        var rows: [[CellValue]]
    }

    private static let helper = """
    function cheeseWriteWorkbook(sheets) {
        const book = XLSX.utils.book_new();
        const used = new Set();
        sheets.forEach((sheet) => {
            const rows = sheet.rows.map((row) => row.map((cell) => {
                switch (cell.t) {
                case "n": return { t: "n", v: cell.v };
                case "d": return { t: "n", v: cell.v, z: "yyyy-mm-dd" };
                case "s": return { t: "s", v: cell.v };
                default: return null;
                }
            }));
            let name = String(sheet.name).replace(/[\\[\\]:*?\\/\\\\]/g, " ").slice(0, 31) || "Sheet";
            for (let n = 2; used.has(name); n++) name = name.slice(0, 27) + " " + n;
            used.add(name);
            XLSX.utils.book_append_sheet(book, XLSX.utils.aoa_to_sheet(rows), name);
        });
        return XLSX.write(book, { type: "base64", bookType: "xlsx", compression: true });
    }
    """

    /// Excel's date serial: days since 1899-12-30.
    static func serial(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 25_569
    }

    static func workbook(_ sheets: [Sheet]) throws -> Data {
        let context = try JavaScriptRunner.context(loading: ["xlsx.full.min.js"])
        context.evaluateScript(helper)
        try JavaScriptRunner.check(context)
        let payload: [[String: Any]] = sheets.map { sheet in
            [
                "name": sheet.name,
                "rows": sheet.rows.map { row in
                    row.map { cell -> [String: Any] in
                        switch cell {
                        case .empty: ["t": "z"]
                        case let .text(text): ["t": "s", "v": text]
                        case let .number(number): ["t": "n", "v": number]
                        case let .date(date): ["t": "d", "v": serial(date)]
                        }
                    }
                },
            ]
        }
        let result = context.objectForKeyedSubscript("cheeseWriteWorkbook")?.call(withArguments: [payload])
        try JavaScriptRunner.check(context)
        guard let base64 = result?.toString(), let data = Data(base64Encoded: base64) else {
            throw FileToolError.message("The spreadsheet couldn't be written.")
        }
        return data
    }

    /// Reads a workbook back as text rows per sheet, for tests and checks.
    static func readRows(_ data: Data) throws -> [String: [[String]]] {
        let context = try JavaScriptRunner.context(loading: ["xlsx.full.min.js"])
        context.evaluateScript("""
        function cheeseReadWorkbook(base64) {
            const book = XLSX.read(base64, { type: "base64" });
            const out = {};
            book.SheetNames.forEach((name) => {
                out[name] = XLSX.utils.sheet_to_json(book.Sheets[name], { header: 1, raw: false, defval: "" });
            });
            return JSON.stringify(out);
        }
        """)
        let json = context.objectForKeyedSubscript("cheeseReadWorkbook")?.call(withArguments: [data.base64EncodedString()])?.toString()
        try JavaScriptRunner.check(context)
        guard let json, let decoded = try? JSONDecoder().decode([String: [[String]]].self, from: Data(json.utf8)) else {
            throw FileToolError.message("The spreadsheet couldn't be read.")
        }
        return decoded
    }
}
