import Foundation

/// How hard to re-render image-heavy pages.
struct CompressionParameters: Equatable, Hashable, Sendable {
    var dpi: Int
    var quality: Double
}

enum CompressionOutcome: Equatable, Sendable {
    /// Under the target. Nil parameters: PDFKit's own image optimization was enough.
    case reached(size: Int, parameters: CompressionParameters?)
    /// The target is out of reach; this is the smallest result.
    case floor(smallest: Int, parameters: CompressionParameters?)
}

/// Finds the gentlest compression that gets a PDF under a target size. The size of each attempt
/// comes from an injected function, so the search is tested without real PDFs.
enum CompressionPlanner {
    /// From gentle (200 DPI, quality 0.8) to strong (72 DPI, quality 0.4). Sizes shrink along it.
    static let ladder: [CompressionParameters] = {
        let steps = 9
        return (0..<steps).map { step in
            let t = Double(step) / Double(steps - 1)
            let dpi = Int((200 - 128 * t).rounded())
            let quality = ((0.8 - 0.4 * t) * 100).rounded() / 100
            return CompressionParameters(dpi: dpi, quality: quality)
        }
    }()

    /// - Parameters:
    ///   - stageOneSize: the size after PDFKit's JPEG and screen-resolution image options.
    ///   - sizeFor: renders with the given parameters and returns the resulting size.
    static func plan(
        target: Int,
        stageOneSize: Int,
        sizeFor: (CompressionParameters) async throws -> Int
    ) async throws -> CompressionOutcome {
        if stageOneSize <= target {
            return .reached(size: stageOneSize, parameters: nil)
        }
        guard let strongest = ladder.indices.last else {
            return .floor(smallest: stageOneSize, parameters: nil)
        }
        var sizes: [Int: Int] = [:]
        func size(at index: Int) async throws -> Int {
            if let known = sizes[index] {
                return known
            }
            let measured = try await sizeFor(ladder[index])
            sizes[index] = measured
            return measured
        }

        let floorSize = try await size(at: strongest)
        guard floorSize <= target else {
            return floorSize < stageOneSize
                ? .floor(smallest: floorSize, parameters: ladder[strongest])
                : .floor(smallest: stageOneSize, parameters: nil)
        }
        // The strongest step fits; find the gentlest one that still does.
        var low = 0
        var high = strongest
        while low < high {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            if try await size(at: mid) <= target {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return .reached(size: try await size(at: high), parameters: ladder[high])
    }

    static func unreachableMessage(target: Int, smallest: Int) -> String {
        "Couldn't reach \(megabytes(target)) — smallest possible is \(megabytes(smallest))"
    }

    /// "2 MB", "3.4 MB": decimal megabytes with at most one decimal, as the panel asks for.
    static func megabytes(_ bytes: Int) -> String {
        let value = (Double(bytes) / 100_000).rounded() / 10
        return value == value.rounded() ? "\(Int(value)) MB" : "\(value) MB"
    }
}
