import Foundation
import SwiftUI

enum PageNumberFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case plain
    case page
    case slash
    case pageOf

    var id: Self { self }

    var title: String {
        switch self {
        case .plain: "1"
        case .page: "Page 1"
        case .slash: "1 / N"
        case .pageOf: "Page 1 of N"
        }
    }

    func text(number: Int, total: Int) -> String {
        switch self {
        case .plain: "\(number)"
        case .page: "Page \(number)"
        case .slash: "\(number) / \(total)"
        case .pageOf: "Page \(number) of \(total)"
        }
    }
}

/// Which number each page shows. Pure, so numbering rules are tested.
enum PageNumbering {
    /// The number for page `index` (0-based), or nil when it's skipped. Numbering starts at
    /// `start` on the first numbered page; with `skipFirst`, the cover gets no number.
    static func number(forPage index: Int, start: Int, skipFirst: Bool) -> Int? {
        if skipFirst {
            return index == 0 ? nil : start + index - 1
        }
        return start + index
    }

    /// The "N" in "Page 1 of N": the last number shown.
    static func total(pageCount: Int, start: Int, skipFirst: Bool) -> Int {
        start + pageCount - 1 - (skipFirst ? 1 : 0)
    }
}

/// Adds page numbers in one of six positions. Pages stay vector and selectable.
struct PageNumbersTool: FileTool {
    enum Position: String, Codable, Sendable, CaseIterable, Identifiable {
        case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

        var id: Self { self }

        var anchor: OverlayLayout.Anchor {
            switch self {
            case .topLeft: .topLeft
            case .topCenter: .topCenter
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomCenter: .bottomCenter
            case .bottomRight: .bottomRight
            }
        }
    }

    struct Options: Codable, Sendable, Equatable {
        var format = PageNumberFormat.plain
        var position = Position.bottomCenter
        var start = 1
        var skipFirst = false
        var fontSize = 11.0
    }

    let id = ToolID.numberPages
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Format", selection: options.format) {
            ForEach(PageNumberFormat.allCases) { Text($0.title).tag($0) }
        }
        Picker("Position", selection: options.position) {
            ForEach(Position.allCases) { Text($0.anchor.title).tag($0) }
        }
        Stepper(value: options.start, in: 0...9999) {
            LabeledContent("Start at", value: "\(options.wrappedValue.start)")
        }
        Toggle("Skip the first page", isOn: options.skipFirst)
        LabeledContent("Font size") {
            Slider(value: options.fontSize, in: 6...36, step: 1)
            Text("\(Int(options.wrappedValue.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let output = context.outputURL(for: input, suffix: "numbered", extension: "pdf")
            try PDFOverlayRenderer.render(input, to: output) { pdf, page in
                guard let number = PageNumbering.number(forPage: page.index, start: options.start, skipFirst: options.skipFirst) else { return }
                let total = PageNumbering.total(pageCount: page.count, start: options.start, skipFirst: options.skipFirst)
                let line = OverlayText.line(
                    options.format.text(number: number, total: total),
                    fontName: "Helvetica", size: options.fontSize, color: RGBAColor.black.cgColor
                )
                let rect = OverlayLayout.rect(for: OverlayText.size(of: line), at: options.position.anchor, in: page.size, margin: 28)
                OverlayText.draw(line, centeredAt: CGPoint(x: rect.midX, y: rect.midY), rotation: 0, in: pdf)
            }
        }
    }
}
