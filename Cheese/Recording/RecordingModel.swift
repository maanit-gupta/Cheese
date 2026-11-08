import CoreGraphics
import CoreMedia
import Foundation

/// What a recording is saved as.
enum RecordingFormat: String, Codable, CaseIterable, Sendable {
    case mp4
    case gif

    var title: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        }
    }

    var fileExtension: String { rawValue }
}

/// The choices in the bar before a recording starts. Remembered between recordings.
struct RecordingOptions: Codable, Equatable, Sendable {
    var microphone = false
    /// The input device; nil is the system default.
    var microphoneID: String?
    var systemAudio = false
    var camera = false
    var cursorHalo = true
    var format = RecordingFormat.mp4

    /// GIFs have no sound, so the audio switches don't apply to them.
    var recordsAudio: Bool { format == .mp4 && (microphone || systemAudio) }

    static func stored(in defaults: UserDefaults) -> RecordingOptions {
        guard let data = defaults.data(forKey: PreferenceKey.recordingOptions),
              let options = try? JSONDecoder().decode(RecordingOptions.self, from: data)
        else { return RecordingOptions() }
        return options
    }

    func store(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: PreferenceKey.recordingOptions)
        }
    }
}

/// How a GIF is made from a recording: frame rate and largest width.
struct GIFSettings: Equatable, Sendable {
    static let frameRates = [10, 15, 24]
    /// 0 keeps the recording's own width.
    static let maxWidths = [640, 960, 1280, 0]
    static let defaultFrameRate = 15
    static let defaultMaxWidth = 960

    var frameRate = defaultFrameRate
    var maxWidth = defaultMaxWidth

    static func stored(in defaults: UserDefaults) -> GIFSettings {
        let rate = defaults.object(forKey: PreferenceKey.gifFrameRate) as? Int ?? defaultFrameRate
        let width = defaults.object(forKey: PreferenceKey.gifMaxWidth) as? Int ?? defaultMaxWidth
        return GIFSettings(
            frameRate: frameRates.contains(rate) ? rate : defaultFrameRate,
            maxWidth: maxWidths.contains(width) ? width : defaultMaxWidth
        )
    }
}

/// The frames of a GIF: when each is taken from the movie, how long it shows, and its size. Pure.
struct GIFPlan: Equatable, Sendable {
    let times: [Double]
    let frameDelay: Double
    let size: CGSize

    init(duration: Double, sourceSize: CGSize, settings: GIFSettings) {
        let rate = max(settings.frameRate, 1)
        let count = max(Int((duration * Double(rate)).rounded(.down)), 1)
        times = (0..<count).map { Double($0) / Double(rate) }
        frameDelay = 1 / Double(rate)
        size = Self.outputSize(for: sourceSize, maxWidth: settings.maxWidth)
    }

    /// Scaled down to `maxWidth` (never up), keeping the aspect ratio, in whole even pixels.
    static func outputSize(for source: CGSize, maxWidth: Int) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = maxWidth > 0 ? min(CGFloat(maxWidth) / source.width, 1) : 1
        let width = max((source.width * scale / 2).rounded() * 2, 2)
        let height = max((source.height * scale / 2).rounded() * 2, 2)
        return CGSize(width: width, height: height)
    }
}

/// The stream settings for recording `region` of a display. Pure.
struct RecordingPlan: Equatable, Sendable {
    static let framesPerSecond: Int32 = 60

    /// The region within its display, in points from the display's top-left corner.
    let sourceRect: CGRect
    /// Output size in pixels: Retina resolution, rounded to even numbers for H.264.
    let pixelWidth: Int
    let pixelHeight: Int

    /// `region` and `displayFrame` in AppKit global points; `scale` is the display's pixels per point.
    init(region: CGRect, displayFrame: CGRect, scale: CGFloat) {
        let clipped = region.intersection(displayFrame)
        let local = DisplayGeometry.displayLocalRect(fromAppKit: clipped.isNull ? displayFrame : clipped, displayFrame: displayFrame)
        sourceRect = local
        pixelWidth = Self.even(local.width * scale)
        pixelHeight = Self.even(local.height * scale)
    }

    var minimumFrameInterval: CMTime { CMTime(value: 1, timescale: Self.framesPerSecond) }

    private static func even(_ value: CGFloat) -> Int {
        max(Int((value / 2).rounded(.down)) * 2, 2)
    }
}

/// Time recorded so far, not counting pauses. Pure.
struct RecordingClock: Equatable, Sendable {
    private var finished: TimeInterval = 0
    private var runningSince: Date?

    var isRunning: Bool { runningSince != nil }

    mutating func start(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    mutating func pause(at date: Date) {
        guard let runningSince else { return }
        finished += max(date.timeIntervalSince(runningSince), 0)
        self.runningSince = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        finished + (runningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// "0:42", "12:05", "1:02:03".
    static func text(_ elapsed: TimeInterval) -> String {
        let total = max(Int(elapsed.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(seconds))" : "\(minutes):\(pad(seconds))"
    }

    /// Next to the menu bar icon while recording.
    static func indicator(_ elapsed: TimeInterval, paused: Bool) -> String {
        (paused ? "❚❚ " : "● ") + text(elapsed)
    }
}

/// Where a recording is in its life.
enum RecordingPhase: Equatable, Sendable {
    case idle
    /// The bar is up; nothing is recorded yet.
    case setup
    case countdown(Int)
    case recording
    case paused
    /// Joining the parts and saving, or making the GIF.
    case finishing
}
