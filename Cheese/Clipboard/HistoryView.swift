import AppKit
import SwiftUI

/// The history panel: search field on top, list on the left, preview on the right.
struct HistoryView: View {
    static let size = CGSize(width: 720, height: 460)

    @Bindable var model: HistoryViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let items = model.visibleItems
        let selected = model.selection(in: items)

        VStack(spacing: 0) {
            searchField
            Divider()
            HStack(spacing: 0) {
                list(items, selectedID: selected?.id)
                    .frame(width: 300)
                Divider()
                Group {
                    if let selected {
                        HistoryPreview(item: selected, imageURL: model.imageURL(for: selected))
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { isSearchFocused = true }
        .onChange(of: model.focusRequest) { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func list(_ items: [ClipItem], selectedID: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
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
                .padding(6)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
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
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let number: Int?
    let isSelected: Bool
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            HistoryItemIcon(item: item, imageURL: imageURL)
                .frame(width: 20, height: 20)
            Text(item.title.isEmpty ? " " : item.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .accessibilityLabel("Pinned")
            }
            if let number {
                Text("⌘\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }
}

private struct HistoryItemIcon: View {
    let item: ClipItem
    let imageURL: URL?

    var body: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
        case .richText:
            Image(systemName: "doc.richtext")
        case .image:
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "photo")
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        case .files:
            if let path = item.filePaths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
            }
        }
    }
}
