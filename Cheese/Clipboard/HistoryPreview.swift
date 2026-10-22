import AppKit
import SwiftUI

/// The right-hand pane: the selected item in full.
struct HistoryPreview: View {
    /// Previews show at most this much text; pasting always uses all of it.
    static let maxPreviewCharacters = 100_000

    let item: ClipItem
    let imageURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            TextPreview(contentID: contentID, text: { plainAttributedText }, isRich: false)
        case .richText:
            TextPreview(contentID: contentID, text: { richAttributedText }, isRich: true)
        case .image:
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit().padding(12)
                case .failure:
                    Label("Image file is missing", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
        case .files:
            FilesPreview(paths: item.filePaths)
        }
    }

    /// Changes whenever the previewed content does, so the text view reloads only then.
    private var contentID: String {
        "\(item.id)-\(item.contentHash)"
    }

    private var footer: some View {
        HStack {
            Text(details)
            Spacer()
            Text("Copied \(item.lastCopiedAt, format: .relative(presentation: .named))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var details: String {
        switch item.kind {
        case .text, .richText:
            let text = item.plainText ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return "\(words) words · \(text.count) characters"
        case .image:
            if let width = item.imagePixelWidth, let height = item.imagePixelHeight {
                return "\(width) × \(height) pixels"
            }
            return "Image"
        case .files:
            return item.filePaths.count == 1 ? "1 file" : "\(item.filePaths.count) files"
        }
    }

    private var plainAttributedText: NSAttributedString {
        NSAttributedString(
            string: String((item.plainText ?? "").prefix(Self.maxPreviewCharacters)),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
    }

    private var richAttributedText: NSAttributedString {
        let rendered = item.pasteboardItems.lazy.compactMap(RichText.attributedString(from:)).first
        guard let rendered else { return plainAttributedText }
        guard rendered.length > Self.maxPreviewCharacters else { return rendered }
        return rendered.attributedSubstring(from: NSRange(location: 0, length: Self.maxPreviewCharacters))
    }
}

/// Read-only, selectable text in an `NSTextView`, which copes with long texts far better than SwiftUI `Text`.
private struct TextPreview: NSViewRepresentable {
    let contentID: String
    /// Built only when the content changes; rendering rich text isn't free.
    let text: () -> NSAttributedString
    /// Rich text keeps its own colors, so it's shown on a white page to stay legible in Dark Mode.
    let isRich: Bool

    final class Coordinator {
        var contentID: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 10, height: 10)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.contentID != contentID,
              let textView = scrollView.documentView as? NSTextView
        else { return }
        context.coordinator.contentID = contentID
        textView.drawsBackground = isRich
        textView.backgroundColor = isRich ? .white : .clear
        textView.textStorage?.setAttributedString(text())
        textView.scrollToBeginningOfDocument(nil)
    }
}

private struct FilesPreview: View {
    let paths: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(filePath: path).lastPathComponent)
                                .font(.headline)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !FileManager.default.fileExists(atPath: path) {
                                Text("No longer exists")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
