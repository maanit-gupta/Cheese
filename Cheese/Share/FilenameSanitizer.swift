import Foundation

/// Makes a name a remote device sent safe to write: no folders, no `..`, no hidden or control
/// characters, a sane length. Collisions are left to `OutputNamer`, which never overwrites.
enum FilenameSanitizer {
    static let fallback = "File"
    /// APFS allows 255 UTF-8 bytes per name.
    static let maxBytes = 255

    static func sanitize(_ name: String) -> String {
        // Only the last path component, whichever separator the sender's OS uses.
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != ":" && scalar.value != 0
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // No hidden files and no `.`/`..`.
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return fallback }
        return truncated(cleaned)
    }

    /// Shortens the base name, keeping the extension, until the name fits `maxBytes`.
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        if suffix.isEmpty { base = name }
        while base.utf8.count + suffix.utf8.count > maxBytes, !base.isEmpty {
            base.removeLast()
        }
        return base.isEmpty ? fallback + suffix : base + suffix
    }

    /// Where a received file goes: the sanitized name in `folder`, numbered if taken.
    static func destination(for name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let url = OutputNamer.uniqueFile(named: sanitize(name), in: folder, exists: exists)
        // Belt and braces: never outside the folder.
        guard url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            == folder.standardizedFileURL.path(percentEncoded: false)
        else {
            return OutputNamer.uniqueFile(named: fallback, in: folder, exists: exists)
        }
        return url
    }
}
