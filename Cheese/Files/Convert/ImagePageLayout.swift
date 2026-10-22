import CoreGraphics
import Foundation

enum PDFPageSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case fitToImage
    case a4
    case letter

    var id: Self { self }

    var title: String {
        switch self {
        case .fitToImage: "Fit to image"
        case .a4: "A4"
        case .letter: "Letter"
        }
    }

    /// Portrait size in points, or nil for "fit to image".
    var portraitSize: CGSize? {
        switch self {
        case .fitToImage: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }

    /// A4 in metric regions, Letter in the US and others using it.
    static var localeDefault: PDFPageSize {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }
}

enum PDFMargin: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case small
    case normal

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .small: "Small"
        case .normal: "Normal"
        }
    }

    var points: CGFloat {
        switch self {
        case .none: 0
        case .small: 18
        case .normal: 36
        }
    }
}

/// Where an image goes on its PDF page. Pure, so the layout rules are tested.
enum ImagePageLayout {
    /// PDF pages can't be larger than this many points on a side.
    static let maxPageSide: CGFloat = 14_400

    /// The page size and the rect the image fills on it. Fixed sizes turn landscape for landscape
    /// images; the image is scaled to fit inside the margins and centered.
    static func layout(imageSize: CGSize, pageSize: PDFPageSize, margin: PDFMargin) -> (page: CGSize, imageRect: CGRect) {
        let inset = margin.points
        guard imageSize.width > 0, imageSize.height > 0 else {
            return (CGSize(width: inset * 2 + 1, height: inset * 2 + 1), .zero)
        }
        guard let portrait = pageSize.portraitSize else {
            // Fit to image: the page is the image plus margins, shrunk if it would exceed the PDF limit.
            let limit = maxPageSide - inset * 2
            let factor = min(1, limit / imageSize.width, limit / imageSize.height)
            let fitted = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
            let page = CGSize(width: fitted.width + inset * 2, height: fitted.height + inset * 2)
            return (page, CGRect(origin: CGPoint(x: inset, y: inset), size: fitted))
        }
        let landscape = imageSize.width > imageSize.height
        let page = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let available = CGSize(width: page.width - inset * 2, height: page.height - inset * 2)
        let factor = min(available.width / imageSize.width, available.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        let origin = CGPoint(x: (page.width - fitted.width) / 2, y: (page.height - fitted.height) / 2)
        return (page, CGRect(origin: origin, size: fitted))
    }
}
