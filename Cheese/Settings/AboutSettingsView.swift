import AppKit
import SwiftUI

/// Third-party code bundled with Cheese and its license, as recorded in Renderers/VENDORED.md.
struct Acknowledgement: Identifiable {
    var name: String
    var version: String
    var license: String
    var source: String
    var text: String

    var id: String { name }
}

enum Acknowledgements {
    private static let renderers: [(name: String, version: String, license: String, file: String, source: String)] = [
        ("marked", "18.1.1", "MIT", "marked.txt", "https://github.com/markedjs/marked"),
        ("JSZip", "3.10.2", "MIT", "jszip.txt", "https://github.com/Stuk/jszip"),
        ("docx-preview", "0.4.1", "Apache-2.0", "docx-preview.txt", "https://github.com/VolodymyrBaydalka/docxjs"),
        ("SheetJS Community Edition", "0.20.3", "Apache-2.0", "sheetjs.txt", "https://git.sheetjs.com/sheetjs/sheetjs"),
        ("pptx-to-html", "1.1.2", "MIT", "pptx-to-html.txt", "https://github.com/javier-mora/pptx-to-html"),
    ]

    /// The vendored renderers, with each license read from the bundle.
    static func load() -> [Acknowledgement] {
        renderers.compactMap { entry in
            guard let url = Renderers.folder?.appending(path: "licenses/\(entry.file)"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return Acknowledgement(name: entry.name, version: entry.version, license: entry.license, source: entry.source, text: text)
        }
    }
}

struct AboutSettingsView: View {
    private let acknowledgements = Acknowledgements.load()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cheese").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                        Text("Open source under the MIT License.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(acknowledgements) { item in
                    DisclosureGroup {
                        ScrollView {
                            Text(item.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                    } label: {
                        LabeledContent("\(item.name) \(item.version)", value: item.license)
                    }
                }
                LabeledContent("KeyboardShortcuts", value: "MIT")
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("The Files tools render documents with these libraries, bundled with Cheese and run offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
