import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Cheese

/// An in-memory pasteboard for driving `ClipReader` and `PasteboardMonitor`.
@MainActor
final class FakePasteboard: PasteboardReading {
    private(set) var changeCount = 0
    private var items: [[String: Data]] = []
    private var typeOrder: [[String]] = []
    private(set) var dataRequests: [String] = []

    var itemTypes: [[String]] { typeOrder }

    func set(_ items: [[(String, Data)]]) {
        self.items = items.map { Dictionary($0, uniquingKeysWith: { first, _ in first }) }
        typeOrder = items.map { $0.map(\.0) }
        dataRequests = []
        changeCount += 1
    }

    func setString(_ string: String) {
        set([[(PasteboardTypeID.plainText, Data(string.utf8))]])
    }

    func data(forType type: String, itemAt index: Int) -> Data? {
        dataRequests.append(type)
        guard items.indices.contains(index) else { return nil }
        return items[index][type]
    }
}

enum TestImages {
    /// A solid-color image encoded in the given format.
    static func encoded(width: Int = 4, height: Int = 3, gray: UInt8 = 128, type: UTType = .png) -> Data {
        let pixels = [UInt8](repeating: gray, count: width * height)
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "CheeseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
