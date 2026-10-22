import AppKit
import os

/// Copy Text from Screen: text, QR codes and barcodes from a selected region.
@MainActor
final class OCRModule: CheeseModule {
    let id = ModuleID.ocr
    private let capture: CaptureController

    init(capture: CaptureController) {
        self.capture = capture
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .ocrRegion, title: "Copy Text from Screen", symbol: "text.viewfinder", module: id,
                shortcut: .ocrRegion, requiredPermissions: [.screenRecording], featureName: "Copying text from the screen"
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.copyTextFromRegion() }
            },
        ]
    }

    // OCR only runs on demand, so there's nothing to start or stop.
    func start() {}
    func stop() {}

    /// Select a region, read codes or text from it, and copy the result.
    private func copyTextFromRegion() async {
        guard let selection = await capture.selectRegion() else { return }
        let image = selection.image
        selection.session.end(restoreFocus: true)
        guard let image else { return }

        let result = await OCRService.live.read(image.image)
        guard let text = result.copyText else {
            CheeseToast.show(result.summary, systemImage: "text.viewfinder")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if case let .codes(payloads) = result, let url = BarcodeReader.openableURL(from: payloads) {
            CheeseToast.show(result.summary, systemImage: "qrcode", action: CheeseToast.Action(title: "Open") {
                NSWorkspace.shared.open(url)
            })
        } else {
            CheeseToast.show(result.summary, systemImage: result == .nothing ? "text.viewfinder" : "text.quote")
        }
    }

    /// OCR for stitched pages, which are read in strips so small text survives.
    /// Used by the scrolling capture preview's OCR button.
    func copyText(fromTallImage image: CapturedImage) async {
        let service = OCRService.live
        var parts: [String] = []
        for tile in await ImageTiling.tiles(of: image.image) {
            do {
                let text = try await TextRecognizer.recognizeText(in: tile, languages: service.languages(), mode: service.lineBreakMode())
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            } catch {
                Logger.app.error("OCR of a strip failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let result: OCRResult = parts.isEmpty ? .nothing : .text(parts.joined(separator: "\n"))
        if let text = result.copyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        CheeseToast.show(result.summary, systemImage: result == .nothing ? "text.viewfinder" : "text.quote")
    }
}
