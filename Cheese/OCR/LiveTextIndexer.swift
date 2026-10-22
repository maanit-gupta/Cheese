import CoreGraphics
import Foundation
import ImageIO
import os

/// Recognizes text in clipboard-history images, one at a time at background priority, so search can match it.
/// Failures are logged and reported as empty text: they never affect the clipboard and aren't retried.
@MainActor
final class LiveTextIndexer {
    private let ocr: OCRService
    private let onRecognized: (UUID, String) -> Void
    private var queue: [(id: UUID, url: URL)] = []
    private var queued: Set<UUID> = []
    private var isRunning = false

    init(ocr: OCRService, onRecognized: @escaping (UUID, String) -> Void) {
        self.ocr = ocr
        self.onRecognized = onRecognized
    }

    var isIdle: Bool { !isRunning && queue.isEmpty }

    func enqueue(_ id: UUID, imageURL: URL) {
        guard queued.insert(id).inserted else { return }
        queue.append((id, imageURL))
        guard !isRunning else { return }
        isRunning = true
        Task(priority: .background) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let text = await Self.recognize(next.url, using: ocr)
            queued.remove(next.id)
            onRecognized(next.id, text)
        }
        isRunning = false
    }

    @concurrent
    private static func recognize(_ url: URL, using ocr: OCRService) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Logger.ocr.notice("Live Text skipped an unreadable image")
            return ""
        }
        do {
            return try await ocr.indexText(in: image)
        } catch {
            Logger.ocr.error("Live Text failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
