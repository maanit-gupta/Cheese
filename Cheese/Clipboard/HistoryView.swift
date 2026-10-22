import AppKit
import ImageIO
import SwiftUI

/// The history panel: search and list on the left, preview of the selected item on the right.
struct HistoryView: View {
    static let size = CGSize(width: 680, height: 460)
    static let listWidth: CGFloat = 280

    @Bindable var model: HistoryViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let items = model.visibleItems
        let selected = model.selection(in: items)

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                list(items, selectedID: selected?.id)
            }
            .frame(width: Self.listWidth)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            Group {
                if let selected {
                    HistoryPreview(item: selected, imageURL: model.imageURL(for: selected))
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { isSearchFocused = true }
        .onChange(of: model.focusRequest) { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            CheeseKeycap(text: "⌘1…9")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .help("Paste one of the first nine items")
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .padding(.vertical, DesignTokens.Spacing.xSmall)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .padding(DesignTokens.Spacing.medium)
    }

    private func list(_ items: [ClipItem], selectedID: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.xxSmall) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(
                            item: item,
                            number: index < 9 ? index + 1 : nil,
                            isSelected: item.id == selectedID,
                            imageURL: model.imageURL(for: item)
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedID = item.id
                            if NSApp.currentEvent?.clickCount == 2 {
                                model.perform(.paste(plainText: false))
                            }
                        }
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.small)
                .padding(.bottom, DesignTokens.Spacing.small)
            }
            .scrollIndicators(.automatic)
            .clipped()
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
            .onChange(of: model.query) {
                guard let first = items.first else { return }
                proxy.scrollTo(first.id, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { select(item, then: .paste(plainText: false)) }
        Button("Paste as Plain Text") { select(item, then: .paste(plainText: true)) }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { select(item, then: .togglePin) }
        Button("Delete", role: .destructive) { select(item, then: .delete) }
    }

    private func select(_ item: ClipItem, then command: HistoryCommand) {
        model.selectedID = item.id
        model.perform(command)
    }

    private var emptyState: some View {
        CheeseEmptyState(
            symbol: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
            title: model.query.isEmpty ? "Nothing copied yet" : "No matches",
            detail: model.query.isEmpty ? "Copy something and it shows up here." : "Try a different search."
        )
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let number: Int?
    let isSelected: Bool
    let imageURL: URL?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            HistoryItemIcon(item: item, imageURL: imageURL)
            Text(displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Pinned")
            }
            if let number {
                Text("⌘\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .frame(height: DesignTokens.Size.thumbnailRow)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .fill(Color.accentColor.opacity(DesignTokens.Opacity.selectedRowTint))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: DesignTokens.Size.selectionBar)
                            .padding(.vertical, DesignTokens.Spacing.small)
                    }
            }
        }
    }

    /// The title on one line: no surrounding whitespace, inner line breaks and tabs as spaces.
    private var displayTitle: String {
        let title = item.title
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? " " : title
    }
}

/// A 28 pt square: a thumbnail for images and files, a symbol for text.
private struct HistoryItemIcon: View {
    let item: ClipItem
    let imageURL: URL?

    private static let side = DesignTokens.Size.rowThumbnail

    var body: some View {
        Group {
            switch item.kind {
            case .text:
                symbol("text.alignleft")
            case .richText:
                symbol("doc.richtext")
            case .image:
                ClipThumbnail(url: imageURL, side: Self.side)
            case .files:
                if let path = item.filePaths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .scaledToFit()
                } else {
                    symbol("doc")
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .frame(width: Self.side, height: Self.side)
    }
}

/// A small, square-cropped thumbnail of an image file, decoded off the main actor at the size shown
/// rather than at full resolution.
struct ClipThumbnail: View {
    let url: URL?
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            // Room for a wide image to still fill the square once cropped.
            let pixels = Int(side * displayScale * 4)
            image = await Task.detached(priority: .userInitiated) {
                Self.thumbnail(of: url, maxPixelSize: pixels)
            }.value
        }
    }

    nonisolated private static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
