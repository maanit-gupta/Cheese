import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit
import os

/// Laser, spotlight and zoom: transient layers over one canvas, never saved as items.
/// Coordinates are the canvas view's (points, y down).
@MainActor
final class PresenterLayers {
    /// How long a laser trail point lasts.
    static let laserLifetime: TimeInterval = 1
    static let lensDiameter: CGFloat = 240

    let container = CALayer()
    private let spotlight = CAShapeLayer()
    private let laserTrail = CAShapeLayer()
    private let laserDot = CAShapeLayer()
    private let lens = CALayer()
    /// The whole display, magnified and shifted so the pointer sits at the lens center.
    private let lensImage = CALayer()
    private var laserPoints: [(point: CGPoint, time: TimeInterval)] = []

    init() {
        container.masksToBounds = false
        spotlight.fillRule = .evenOdd
        spotlight.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
        spotlight.isHidden = true

        let laserColor = NSColor.systemRed
        laserTrail.strokeColor = laserColor.withAlphaComponent(0.55).cgColor
        laserTrail.fillColor = nil
        laserTrail.lineWidth = 5
        laserTrail.lineCap = .round
        laserTrail.lineJoin = .round
        laserDot.fillColor = laserColor.cgColor
        laserDot.shadowColor = laserColor.cgColor
        laserDot.shadowOpacity = 1
        laserDot.shadowRadius = 10
        laserDot.shadowOffset = .zero

        lens.masksToBounds = true
        lens.borderWidth = 3
        lens.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        lens.backgroundColor = NSColor.black.cgColor
        lens.isHidden = true
        lensImage.contentsGravity = .resize
        lensImage.magnificationFilter = .nearest
        lensImage.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        lens.addSublayer(lensImage)

        for layer in [spotlight, laserTrail, laserDot, lens] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            container.addSublayer(layer)
        }
        container.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    func hideAll() {
        spotlight.isHidden = true
        lens.isHidden = true
        lensImage.contents = nil
        laserPoints.removeAll()
        laserTrail.path = nil
        laserDot.path = nil
    }

    // MARK: Laser

    var hasLaserTrail: Bool { !laserPoints.isEmpty }

    func clearLaser() {
        laserPoints.removeAll()
        laserTrail.path = nil
        laserDot.path = nil
    }

    func addLaserPoint(_ point: CGPoint, at time: TimeInterval) {
        laserPoints.append((point, time))
        updateLaser(at: time)
    }

    /// Drops trail points older than a second; the dot stays at the newest point.
    func updateLaser(at time: TimeInterval) {
        laserPoints.removeAll { time - $0.time > Self.laserLifetime }
        guard let newest = laserPoints.last else {
            laserTrail.path = nil
            laserDot.path = nil
            return
        }
        let trail = CGMutablePath()
        trail.addLines(between: laserPoints.map(\.point))
        laserTrail.path = laserPoints.count > 1 ? trail : nil
        let radius: CGFloat = 7
        laserDot.path = CGPath(ellipseIn: CGRect(x: newest.point.x - radius, y: newest.point.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    // MARK: Spotlight

    /// Dims everything except a circle around `center`; nil dims the whole display.
    func showSpotlight(center: CGPoint?, radius: CGFloat, bounds: CGRect) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let center {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        spotlight.path = path
        spotlight.isHidden = false
    }

    func hideSpotlight() {
        spotlight.isHidden = true
    }

    // MARK: Zoom

    /// A magnifier centered on `center`, showing `surface` (a full-display frame) at `factor`.
    /// The frame is laid out as a layer rather than cropped with `contentsRect`, so it stays upright
    /// in the canvas's flipped coordinates.
    func showLens(center: CGPoint, viewSize: CGSize, factor: CGFloat, surface: IOSurface?) {
        let diameter = Self.lensDiameter
        lens.frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        lens.cornerRadius = diameter / 2
        if let surface {
            lensImage.contents = surface
        }
        lensImage.frame = CGRect(
            x: diameter / 2 - center.x * factor,
            y: diameter / 2 - center.y * factor,
            width: viewSize.width * factor,
            height: viewSize.height * factor
        )
        lens.isHidden = false
    }

    func hideLens() {
        lens.isHidden = true
    }
}

/// Live frames of one display for the zoom lens, from ScreenCaptureKit, without Cheese's own windows.
@MainActor
final class ZoomStream {
    private(set) var displayID: CGDirectDisplayID?
    private(set) var surface: IOSurface?
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    /// Called on the main actor with each new frame.
    var onFrame: () -> Void = {}

    func start(displayID: CGDirectDisplayID) async {
        guard self.displayID != displayID else { return }
        await stop()
        self.displayID = displayID
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard self.displayID == displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return }
            let ownProcess = ProcessInfo.processInfo.processIdentifier
            let cheese = content.applications.filter { $0.processID == ownProcess }
            let filter = SCContentFilter(display: display, excludingApplications: cheese, exceptingWindows: [])
            let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)

            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 4

            let receiver = FrameReceiver { [weak self] box in
                Task { @MainActor in
                    guard let self, self.displayID == displayID else { return }
                    self.surface = box.surface
                    self.onFrame()
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await stream.startCapture()
            self.receiver = receiver
            self.stream = stream
        } catch {
            Logger.draw.error("Zoom stream failed: \(error.localizedDescription, privacy: .public)")
            self.displayID = nil
        }
    }

    func stop() async {
        let stream = stream
        self.stream = nil
        receiver = nil
        displayID = nil
        surface = nil
        try? await stream?.stopCapture()
    }
}

/// An IOSurface handed from ScreenCaptureKit's queue to the main actor. The surface itself is
/// thread-safe; the box only exists because the Swift type isn't marked Sendable.
private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
}

private final class FrameReceiver: NSObject, SCStreamOutput, Sendable {
    let queue = DispatchQueue(label: "com.maanitgupta.cheese.zoom", qos: .userInteractive)
    private let deliver: @Sendable (SurfaceBox) -> Void

    init(deliver: @escaping @Sendable (SurfaceBox) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        deliver(SurfaceBox(surface: surface))
    }
}
