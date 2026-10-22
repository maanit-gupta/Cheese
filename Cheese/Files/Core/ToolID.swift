import Foundation

/// How a tool is filed in the drop menu and the Finder submenu.
enum ToolGroup: String, CaseIterable, Sendable {
    case pdf
    case convert
    case images

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .convert: "Convert"
        case .images: "Images"
        }
    }
}

/// Every Files tool. Shared with the Finder extension, so it stays Foundation-only.
enum ToolID: String, CaseIterable, Codable, Sendable {
    case mergePDFs
    case splitPDF
    case editPages
    case compressPDF
    case watermarkPDF
    case numberPages
    case imagesToPDF
    case wordToPDF
    case excelToPDF
    case powerPointToPDF
    case webToPDF
    case pdfToImages
    case pdfToWord
    case pdfToExcel
    case markdownToWord
    case convertImage
    case resizeImage
    case compressImage
    case removeBackground

    var title: String {
        switch self {
        case .mergePDFs: "Merge PDFs"
        case .splitPDF: "Split PDF"
        case .editPages: "Edit Pages"
        case .compressPDF: "Compress PDF"
        case .watermarkPDF: "Add Watermark"
        case .numberPages: "Add Page Numbers"
        case .imagesToPDF: "Images to PDF"
        case .wordToPDF: "Word to PDF"
        case .excelToPDF: "Excel to PDF"
        case .powerPointToPDF: "PowerPoint to PDF"
        case .webToPDF: "HTML, Markdown or Text to PDF"
        case .pdfToImages: "PDF to Images"
        case .pdfToWord: "PDF to Word"
        case .pdfToExcel: "PDF to Excel"
        case .markdownToWord: "Markdown or HTML to Word"
        case .convertImage: "Convert Image Format"
        case .resizeImage: "Resize Images"
        case .compressImage: "Compress Images"
        case .removeBackground: "Remove Background"
        }
    }

    /// SF Symbol name.
    var symbol: String {
        switch self {
        case .mergePDFs: "doc.on.doc"
        case .splitPDF: "scissors"
        case .editPages: "square.grid.2x2"
        case .compressPDF: "arrow.down.right.and.arrow.up.left"
        case .watermarkPDF: "drop"
        case .numberPages: "number"
        case .imagesToPDF: "photo.on.rectangle"
        case .wordToPDF: "doc.richtext"
        case .excelToPDF: "tablecells"
        case .powerPointToPDF: "rectangle.on.rectangle.angled"
        case .webToPDF: "doc.plaintext"
        case .pdfToImages: "photo.stack"
        case .pdfToWord: "doc.text"
        case .pdfToExcel: "tablecells.badge.ellipsis"
        case .markdownToWord: "text.document"
        case .convertImage: "arrow.triangle.2.circlepath"
        case .resizeImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .compressImage: "arrow.down.circle"
        case .removeBackground: "person.crop.rectangle"
        }
    }

    var group: ToolGroup {
        switch self {
        case .mergePDFs, .splitPDF, .editPages, .compressPDF, .watermarkPDF, .numberPages: .pdf
        case .imagesToPDF, .wordToPDF, .excelToPDF, .powerPointToPDF, .webToPDF,
             .pdfToImages, .pdfToWord, .pdfToExcel, .markdownToWord: .convert
        case .convertImage, .resizeImage, .compressImage, .removeBackground: .images
        }
    }

    /// The kinds of file the tool takes. A selection qualifies only if every file is one of them.
    var acceptedKinds: Set<FileKind> {
        switch self {
        case .mergePDFs, .splitPDF, .editPages, .compressPDF, .watermarkPDF, .numberPages,
             .pdfToImages, .pdfToWord, .pdfToExcel: [.pdf]
        case .imagesToPDF, .convertImage, .resizeImage, .compressImage, .removeBackground: [.image]
        case .wordToPDF: [.word]
        case .excelToPDF: [.excel]
        case .powerPointToPDF: [.powerPoint]
        case .webToPDF: [.html, .markdown, .plainText]
        case .markdownToWord: [.markdown, .html]
        }
    }

    /// How many files the tool takes at once.
    var fileCount: ClosedRange<Int> {
        switch self {
        case .mergePDFs: 2...Int.max
        case .editPages: 1...1
        default: 1...Int.max
        }
    }

    /// Verbs for progress and notifications: "Merging 3 PDFs…", "Merged 3 PDFs".
    var verbs: (present: String, past: String) {
        switch self {
        case .mergePDFs: ("Merging", "Merged")
        case .splitPDF: ("Splitting", "Split")
        case .editPages: ("Saving", "Saved")
        case .compressPDF, .compressImage: ("Compressing", "Compressed")
        case .watermarkPDF: ("Watermarking", "Watermarked")
        case .numberPages: ("Numbering", "Numbered")
        case .resizeImage: ("Resizing", "Resized")
        case .removeBackground: ("Removing background from", "Removed background from")
        case .imagesToPDF, .wordToPDF, .excelToPDF, .powerPointToPDF, .webToPDF,
             .pdfToImages, .pdfToWord, .pdfToExcel, .markdownToWord, .convertImage: ("Converting", "Converted")
        }
    }
}
