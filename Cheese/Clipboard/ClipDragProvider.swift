import CoreGraphics
import Foundation

/// One pasteboard item of a drag out of clipboard history: each type it offers, with its data.
struct ClipDragItem: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case string(String)
        case data(Data)
        /// The bytes of this file, read when the drag starts: an image item's stored PNG.
        case contentsOf(URL)
    }

    struct Representation: Equatable, Sendable {
        var type: String
        var value: Value
    }

    var representations: [Representation]

    var types: [String] { representations.map(\.type) }
}

/// What a history item is made of, as far as dragging it goes.
struct ClipDragInput: Equatable, Sendable {
    var kind: ClipKind
    var plainText: String?
    var pasteboardItems: [PasteboardItemContent] = []
    var imageURL: URL?
    var fileURLs: [URL] = []
}

/// The drag payloads for history items. Each item offers every form a drop target might take, so
/// the same drag works in native apps (Messages, Notes, Finder) and in web chats (Slack, Discord,
/// WhatsApp in a browser):
/// - Images: the stored PNG's file URL **and** its PNG bytes.
/// - Text: UTF-8 plain text, plus the copied RTF/HTML while the text is unedited. A live edit drops
///   those (see `ClipStore.updateText`), so the edited text is what lands.
/// - Files and folders: their file URLs, one pasteboard item each.
enum ClipDragProvider {
    static func items(for input: ClipDragInput) -> [ClipDragItem] {
        switch input.kind {
        case .text, .richText:
            guard let text = input.plainText, !text.isEmpty else { return [] }
            var representations = [ClipDragItem.Representation(type: PasteboardTypeID.plainText, value: .string(text))]
            if input.kind == .richText, let stored = input.pasteboardItems.first {
                representations += stored.representations
                    .filter { PasteboardTypeID.richTextTypes.contains($0.type) }
                    .map { .init(type: $0.type, value: .data($0.data)) }
            }
            return [ClipDragItem(representations: representations)]

        case .image:
            guard let url = input.imageURL else { return [] }
            return [ClipDragItem(representations: [
                .init(type: PasteboardTypeID.fileURL, value: .string(url.absoluteString)),
                .init(type: PasteboardTypeID.png, value: .contentsOf(url)),
            ])]

        case .files:
            return input.fileURLs.map { url in
                ClipDragItem(representations: [.init(type: PasteboardTypeID.fileURL, value: .string(url.absoluteString))])
            }
        }
    }

    /// Whether the history popover fades out of the way: once the pointer has left it, so the chat
    /// box underneath shows. AppKit screen coordinates.
    static func fadesPopover(pointer: CGPoint, popoverFrame: CGRect) -> Bool {
        !popoverFrame.contains(pointer)
    }

    /// How see-through the popover gets while a drag is outside it.
    static let fadedAlpha: CGFloat = 0.15
}

extension ClipDragInput {
    @MainActor
    init(item: ClipItem, imageURL: URL?) {
        self.init(
            kind: item.kind,
            plainText: item.plainText,
            pasteboardItems: item.kind == .richText ? item.pasteboardItems : [],
            imageURL: imageURL,
            fileURLs: item.fileURLs
        )
    }
}
