import Foundation

/// The link on the clipboard and its cleaned form, behind "Copy clean link automatically". Pure:
/// the controller decides when to write; this only says what the link is and what to write.
struct ClipboardLink: Equatable, Sendable {
    let original: URL
    let cleaned: URL

    /// Whether cleaning removes anything (tracking parameters, an Amazon `/ref=` suffix).
    var hasTrackers: Bool { original != cleaned }

    /// The link in `text`, which must be just a link (possibly in brackets/quotes or wrapped across lines).
    init?(text: String) {
        guard let found = LinkCleaner.extractAndCleanURL(from: text) else { return nil }
        original = found.original
        cleaned = found.cleaned
    }

    /// The link a copied clip holds. Only text clips can: images and files never count.
    init?(clip: CapturedClip) {
        guard case let .text(plain, _, _) = clip else { return nil }
        self.init(text: plain)
    }

    /// The cleaned link as a plain-text clip, which is what goes on the clipboard and into history.
    var cleanedClip: CapturedClip {
        let text = cleaned.absoluteString
        let item = PasteboardItemContent(representations: [
            PasteboardRepresentation(type: PasteboardTypeID.plainText, data: Data(text.utf8)),
        ])
        return .text(plain: text, items: [item], isRich: false)
    }

    /// The link once it's been cleaned: what the clipboard holds after Cheese replaced it.
    var afterCleaning: ClipboardLink {
        ClipboardLink(original: cleaned, cleaned: cleaned)
    }

    private init(original: URL, cleaned: URL) {
        self.original = original
        self.cleaned = cleaned
    }
}
