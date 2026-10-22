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
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: kindSymbol)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Size.rowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(kindName)
                    .font(DesignTokens.Typography.heading)
                Text("\(details) · copied \(item.lastCopiedAt, format: .relative(presentation: .named))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.small)
            if item.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, DesignTokens.Spacing.small)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(DesignTokens.Opacity.hoverTint), in: Capsule())
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .frame(height: 52)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            TextPreview(contentID: contentID, text: { plainAttributedText }, isRich: false)
        case .richText:
            TextPreview(contentID: contentID, text: { richAttributedText }, isRich: true)
        case .image:
            ImagePreview(url: imageURL)
                .padding(DesignTokens.Spacing.large)
        case .files:
            FilesPreview(paths: item.filePaths)
        }
    }

    /// Changes whenever the previewed content does, so the text view reloads only then.
    private var contentID: String {
        "\(item.id)-\(item.contentHash)"
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            shortcut("↩", "Paste")
            shortcut("⌥↩", "Plain")
            shortcut("⌘P", item.isPinned ? "Unpin" : "Pin")
            shortcut("⌘⌫", "Delete")
            Spacer(minLength: 0)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Spacing.large)
        .frame(height: 36)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxSmall) {
            Text(keys)
                .font(DesignTokens.Typography.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
    }

    private var kindName: String {
        switch item.kind {
        case .text: "Text"
        case .richText: "Rich Text"
        case .image: "Image"
        case .files: item.filePaths.count == 1 ? "File" : "Files"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .files: "doc"
        }
    }

    private var details: String {
        switch item.kind {
        case .text, .richText:
            let text = item.plainText ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return "\(words) words · \(text.count) characters"
        case .image:
            if let width = item.imagePixelWidth, let height = item.imagePixelHeight {
                return "\(width) × \(height) px"
            }
            return "Image"
        case .files:
            return item.filePaths.count == 1 ? "1 item" : "\(item.filePaths.count) items"
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
            // Not selectable, so clicks and arrow keys stay with the list.
            textView.isEditable = false
            textView.isSelectable = false
            textView.textContainerInset = NSSize(width: DesignTokens.Spacing.large, height: DesignTokens.Spacing.large)
            textView.textContainer?.widthTracksTextView = true
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
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
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

/// The image scaled to fit the pane, on a checkerboard so transparency reads as transparency.
private struct ImagePreview: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Checkerboard())
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            case .failure:
                CheeseEmptyState(symbol: "exclamationmark.triangle", title: "Image file is missing")
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.9)))
                }
            }
        }
    }
}
