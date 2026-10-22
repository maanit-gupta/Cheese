import AppKit
import ScreenCaptureKit
import os

/// One display's image, frozen at the moment a capture started.
struct DisplaySnapshot: Sendable {
    var displayID: CGDirectDisplayID
    /// The display's frame in AppKit global coordinates (points).
    var frame: CGRect
    var captured: CapturedImage

    /// The part of the snapshot under `rect` (AppKit global points), at full pixel resolution.
    func crop(to rect: CGRect) -> CapturedImage? {
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let pixels = DisplayGeometry.pixelRect(forViewRect: local, viewSize: frame.size, imagePixelSize: captured.pixelSize)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let image = captured.image.cropping(to: pixels)
        else { return nil }
        return CapturedImage(image: image, scale: captured.scale)
    }
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "That display is no longer available."
        case .windowNotFound: "That window is no longer on screen."
        }
    }
}

/// Screen capture behind a protocol so features can be driven without ScreenCaptureKit in tests.
@MainActor
protocol ScreenCapturing {
    /// The whole display, without any of Cheese's own windows.
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CapturedImage
    /// One window, with its shadow.
    func captureWindow(_ windowID: CGWindowID) async throws -> CapturedImage
    /// Prepares repeated captures of one region (AppKit global points) of a display, for scrolling capture.
    func makeRegionCapturer(for rect: CGRect, displayID: CGDirectDisplayID) async throws -> any RegionCapturing
}


extension ScreenCapturing {
    /// Every connected display, for frozen selection overlays.
    func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let captured = try await captureDisplay(displayID)
            snapshots.append(DisplaySnapshot(displayID: displayID, frame: screen.frame, captured: captured))
        }
        return snapshots
    }

    func snapshotDisplay(_ screen: NSScreen) async throws -> DisplaySnapshot {
        guard let displayID = screen.displayID else { throw CaptureError.displayNotFound }
        return DisplaySnapshot(displayID: displayID, frame: screen.frame, captured: try await captureDisplay(displayID))
    }
}

/// ScreenCaptureKit-backed capture at each display's native backing scale.
@MainActor
final class CaptureService: ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        // Cheese's overlays, toasts and panels never appear in a capture.
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let cheese = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: cheese, exceptingWindows: [])
        return try await capture(filter)
    }

    func captureWindow(_ windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        return try await capture(SCContentFilter(desktopIndependentWindow: window))
    }

    func makeRegionCapturer(for rect: CGRect, displayID: CGDirectDisplayID) async throws -> any RegionCapturing {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let screen = Screens.screen(withDisplayID: displayID)
        else { throw CaptureError.displayNotFound }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let cheese = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: cheese, exceptingWindows: [])
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)

        let sourceRect = DisplayGeometry.displayLocalRect(fromAppKit: rect, displayFrame: screen.frame)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int((sourceRect.width * scale).rounded())
        configuration.height = Int((sourceRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        return SCRegionCapturer(filter: filter, configuration: configuration, scale: scale)
    }

    private func capture(_ filter: SCContentFilter) async throws -> CapturedImage {
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((info.contentRect.width * scale).rounded())
        configuration.height = Int((info.contentRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        Logger.capture.debug("Captured \(image.width)×\(image.height) px at \(scale)x")
        return CapturedImage(image: image, scale: scale)
    }
}

@MainActor
private final class SCRegionCapturer: RegionCapturing {
    let scale: CGFloat
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, scale: CGFloat) {
        self.filter = filter
        self.configuration = configuration
        self.scale = scale
    }

    func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
