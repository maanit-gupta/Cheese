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

    /// `StrokeBuilder` is a Swift port of perfect-freehand's outline algorithm.
    static let perfectFreehandLicense = """
        MIT License

        Copyright (c) 2021 Stephen Ruiz Ltd

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
        associated documentation files (the "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the \
        following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial \
        portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
        LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO \
        EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE \
        USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

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

/// Icon, name, tagline, version, license, acknowledgements and the GitHub link. Shown in the About
/// window and in Settings → About.
struct AboutView: View {
    private let acknowledgements = Acknowledgements.load()

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: DesignTokens.Spacing.xLarge) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                        Text(Brand.name).font(.title2.weight(.semibold))
                        Text(Brand.tagline)
                        Text(Self.version).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                        Text("Open source under the MIT License.").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                if let repository = Brand.repository {
                    Link(destination: repository) {
                        Label("Cheese on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            } footer: {
                Text(Brand.privacy)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(acknowledgements) { item in
                    DisclosureGroup {
                        ScrollView {
                            Text(item.text)
                                .font(DesignTokens.Typography.code)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                    } label: {
                        LabeledContent("\(item.name) \(item.version)", value: item.license)
                    }
                }
                DisclosureGroup {
                    ScrollView {
                        Text(Acknowledgements.perfectFreehandLicense)
                            .font(DesignTokens.Typography.code)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                } label: {
                    LabeledContent("perfect-freehand (ported to Swift)", value: "MIT")
                }
                LabeledContent("KeyboardShortcuts", value: "MIT")
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("The Files tools render documents with these libraries, bundled with Cheese and run offline. Draw on screen's ink outlines follow perfect-freehand.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
