import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What the richer input list (Merge Files) shows about a file and how it sorts. Pure.
enum InputListInfo {
    enum SortOrder: String, CaseIterable, Identifiable {
        case name
        case dateModified

        var id: Self { self }
        var title: String {
            switch self {
            case .name: "Name"
            case .dateModified: "Date Modified"
            }
        }
    }

    /// A short type badge: "PDF", "DOCX", "JPG"…
    static func badge(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        switch FileKind(url: url) {
        case .markdown: return "MD"
        case .plainText: return "TXT"
        case .html: return "HTML"
        default: return ext.isEmpty ? "FILE" : String(ext.prefix(5))
        }
    }

    static func countText(_ count: Int, unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// Slides in a .pptx, from its part names.
    static func slideCount(partNames: some Sequence<String>) -> Int {
        partNames.filter { $0.wholeMatch(of: /ppt\/slides\/slide\d+\.xml/) != nil }.count
    }

    /// Sheets in an .xlsx's `xl/workbook.xml`.
    static func sheetCount(workbook: String) -> Int {
        workbook.matches(of: /<(?:\w+:)?sheet\b/).count
    }

    /// The page count Word saved in `docProps/app.xml`, if it did.
    static func wordPages(appProperties: String) -> Int? {
        appProperties.firstMatch(of: /<Pages>(\d+)<\/Pages>/).flatMap { Int($0.1) }
    }

    /// Supported files from a drop or a picker, without ones already listed.
    static func adding(_ urls: [URL], to inputs: [URL], accepted: Set<FileKind>) -> [URL] {
        let fresh = urls.filter { accepted.contains(FileKind(url: $0)) && !inputs.contains($0) }
        var seen = Set<URL>()
        return inputs + fresh.filter { seen.insert($0).inserted }
    }

    static func sorted(_ inputs: [URL], by order: SortOrder, modified: (URL) -> Date?) -> [URL] {
        switch order {
        case .name:
            inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .dateModified:
            inputs.sorted { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
        }
    }

    /// "12 pages", "8 slides", "3 sheets", or nil when it can't be known without converting.
    static func pageCount(of url: URL) -> String? {
        switch FileKind(url: url) {
        case .pdf:
            return CGPDFDocument(url as CFURL).map { countText($0.numberOfPages, unit: "page") }
        case .image:
            return countText(1, unit: "page")
        case .powerPoint:
            return (try? ZipArchive.read(Data(contentsOf: url))).map { countText(slideCount(partNames: $0.keys), unit: "slide") }
        case .excel:
            if url.pathExtension.lowercased() == "csv" { return countText(1, unit: "sheet") }
            guard let parts = try? ZipArchive.read(Data(contentsOf: url)), let workbook = parts["xl/workbook.xml"] else { return nil }
            return countText(sheetCount(workbook: String(decoding: workbook, as: UTF8.self)), unit: "sheet")
        case .word:
            guard let parts = try? ZipArchive.read(Data(contentsOf: url)), let app = parts["docProps/app.xml"],
                  let pages = wordPages(appProperties: String(decoding: app, as: UTF8.self))
            else { return nil }
            return countText(pages, unit: "page")
        case .html, .markdown, .plainText, .other:
            return nil
        }
    }
}

/// A row in the richer input list: thumbnail, name, type badge and page count.
struct RichInputRow: View {
    let url: URL
    let canRemove: Bool
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var pages: String?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))).resizable()
                }
            }
            .frame(width: DesignTokens.Size.rowThumbnail, height: DesignTokens.Size.rowThumbnail)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DesignTokens.Spacing.xxSmall) {
                    Text(InputListInfo.badge(for: url))
                        .font(DesignTokens.Typography.code)
                        .padding(.horizontal, DesignTokens.Spacing.xxSmall)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                    if let pages {
                        Text(pages)
                    }
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from this job")
                .accessibilityLabel("Remove \(url.lastPathComponent)")
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: url) {
            let url = url
            pages = await Task.detached(priority: .utility) { InputListInfo.pageCount(of: url) }.value
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: DesignTokens.Size.rowThumbnail, height: DesignTokens.Size.rowThumbnail),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = representation.nsImage
            }
        }
    }
}

/// The input list's own toolbar: add files, and sort.
struct InputListControls: View {
    let accepted: Set<FileKind>
    @Binding var inputs: [URL]

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            Menu {
                ForEach(InputListInfo.SortOrder.allCases) { order in
                    Button(order.title) {
                        inputs = InputListInfo.sorted(inputs, by: order) { url in
                            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort by name or date modified")
            Button {
                addFiles()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add files")
            .accessibilityLabel("Add files")
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = accepted.flatMap(\.contentTypes) + [UTType("net.daringfireball.markdown"), .plainText].compactMap(\.self)
        guard panel.runModal() == .OK else { return }
        inputs = InputListInfo.adding(panel.urls, to: inputs, accepted: accepted)
    }
}
