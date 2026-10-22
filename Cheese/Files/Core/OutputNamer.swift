import Foundation

/// Names for tool outputs, written next to the original and never over anything.
/// `Report.pdf` → `Report (compressed).pdf`; conversions keep the base name (`Report.docx`);
/// multi-file outputs go into `Report (images)/Report-001.png`; collisions get ` 2`, ` 3`…
enum OutputNamer {
    /// `Report` + `compressed` + `pdf` → `Report (compressed).pdf`. A nil suffix keeps the base name.
    static func fileName(base: String, suffix: String?, extension ext: String) -> String {
        let stem = suffix.map { "\(base) (\($0))" } ?? base
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// The input's name without its extension.
    static func baseName(of input: URL) -> String {
        input.deletingPathExtension().lastPathComponent
    }

    /// The first free file URL in `folder` for this name, appending ` 2`, ` 3`… before the extension.
    static func uniqueFile(named name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appending(path: name, directoryHint: .notDirectory)
        var counter = 2
        while exists(candidate) {
            let numbered = "\(stem) \(counter)"
            candidate = folder.appending(path: ext.isEmpty ? numbered : "\(numbered).\(ext)", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }

    /// The first free folder URL in `folder` for this name: `Report (images)`, `Report (images) 2`…
    static func uniqueFolder(named name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appending(path: name, directoryHint: .isDirectory)
        var counter = 2
        while exists(candidate) {
            candidate = folder.appending(path: "\(name) \(counter)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
    }

    /// The output for one input: `Report (compressed).pdf`, or `Report.docx` for a conversion.
    static func output(for input: URL, suffix: String?, extension ext: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        uniqueFile(named: fileName(base: baseName(of: input), suffix: suffix, extension: ext), in: folder, exists: exists)
    }

    /// The `n`th of `total` files inside a multi-file output folder: `Report-001.png`.
    /// Numbers are zero-padded to at least three digits, more when there are over 999 files.
    static func numberedFile(base: String, index: Int, total: Int, extension ext: String) -> String {
        let width = max(3, String(total).count)
        let number = String(index)
        let padded = String(repeating: "0", count: max(0, width - number.count)) + number
        return "\(base)-\(padded).\(ext)"
    }
}
