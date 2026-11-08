import AVFoundation
import AppKit
import ScreenCaptureKit
import Synchronization
import os

/// What to record: part of one display, which of Cheese's windows appear in it, and the audio.
struct RecordingRequest: Sendable {
    var displayID: CGDirectDisplayID
    var plan: RecordingPlan
    /// Cheese windows that belong in the video (the cursor halo, the webcam, Draw's canvases).
    /// Every other Cheese window stays out.
    var includedWindowIDs: [CGWindowID]
    var systemAudio: Bool
    var microphone: Bool
    var microphoneID: String?
}

enum RecordingError: LocalizedError {
    case displayNotFound
    case couldNotStart(String)
    case nothingRecorded
    case export(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The display isn't available"
        case let .couldNotStart(reason): reason
        case .nothingRecorded: "Nothing was recorded"
        case let .export(reason): reason
        }
    }
}

/// Records the screen to a movie, with pauses.
@MainActor
protocol ScreenRecording: AnyObject {
    func start(_ request: RecordingRequest) async throws
    func pause() async throws
    func resume() async throws
    /// Ends the recording and returns the movie: every part joined, in a temporary folder.
    func stop() async throws -> URL
    /// Ends the recording and throws it away.
    func discard() async
}

/// ScreenCaptureKit recording. Each stretch between pauses is a separate file written by
/// `SCRecordingOutput` (H.264, MPEG-4, system audio and microphone on tracks of their own);
/// stopping joins them, track by track.
@MainActor
final class SCKScreenRecorder: ScreenRecording {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var delegate: RecordingOutputDelegate?
    private var segments: [URL] = []
    private var folder: URL?

    func start(_ request: RecordingRequest) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
            throw RecordingError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let cheese = content.applications.filter { $0.processID == ownPID }
        let included = content.windows.filter { request.includedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: cheese, exceptingWindows: included)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = request.plan.sourceRect
        configuration.width = request.plan.pixelWidth
        configuration.height = request.plan.pixelHeight
        configuration.minimumFrameInterval = request.plan.minimumFrameInterval
        configuration.showsCursor = true
        configuration.queueDepth = 8
        configuration.capturesAudio = request.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = request.microphone
        if request.microphone, let id = request.microphoneID {
            configuration.microphoneCaptureDeviceID = id
        }

        let folder = FileManager.default.temporaryDirectory.appending(path: "CheeseRecording-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        segments = []

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream
        // Added before capture starts, so the very first frame is in the file.
        try addSegment(to: stream)
        do {
            try await stream.startCapture()
        } catch {
            await discard()
            throw RecordingError.couldNotStart(error.localizedDescription)
        }
        Logger.recording.notice("Recording started (\(request.plan.pixelWidth)×\(request.plan.pixelHeight) px)")
    }

    func pause() async throws {
        try await finishSegment()
    }

    func resume() async throws {
        guard let stream, output == nil else { return }
        try addSegment(to: stream)
    }

    func stop() async throws -> URL {
        try await finishSegment()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let parts = segments.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard let folder, !parts.isEmpty else { throw RecordingError.nothingRecorded }
        let movie = folder.appending(path: "Recording.mp4")
        try await Self.join(parts, into: movie)
        Logger.recording.notice("Recording finished in \(parts.count) part(s)")
        return movie
    }

    func discard() async {
        if let stream, let output {
            try? stream.removeRecordingOutput(output)
        }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        delegate = nil
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
        folder = nil
        segments = []
    }

    private func addSegment(to stream: SCStream) throws {
        guard let folder else { return }
        let url = folder.appending(path: "segment-\(segments.count).mp4")
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        configuration.videoCodecType = .h264
        let delegate = RecordingOutputDelegate()
        let output = SCRecordingOutput(configuration: configuration, delegate: delegate)
        do {
            try stream.addRecordingOutput(output)
        } catch {
            throw RecordingError.couldNotStart(error.localizedDescription)
        }
        segments.append(url)
        self.output = output
        self.delegate = delegate
    }

    /// Takes the recording output off the stream and waits until its file is written.
    private func finishSegment() async throws {
        guard let stream, let output, let delegate else { return }
        try stream.removeRecordingOutput(output)
        self.output = nil
        self.delegate = nil
        await delegate.waitUntilFinished(timeout: .seconds(10))
    }

    /// One movie from the parts, each kind of track kept separate (video, system audio,
    /// microphone), without re-encoding.
    @concurrent
    private static func join(_ parts: [URL], into movie: URL) async throws {
        if parts.count == 1 {
            try FileManager.default.moveItem(at: parts[0], to: movie)
            return
        }
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            for type in [AVMediaType.video, .audio] {
                for (index, source) in try await asset.loadTracks(withMediaType: type).enumerated() {
                    let key = "\(type.rawValue)-\(index)"
                    let track = tracks[key] ?? composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                    tracks[key] = track
                    let range = try await source.load(.timeRange)
                    try track?.insertTimeRange(CMTimeRange(start: range.start, duration: min(range.duration, duration)), of: source, at: cursor)
                }
            }
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.export("Couldn't join the recording")
        }
        do {
            try await export.export(to: movie, as: .mp4)
        } catch {
            throw RecordingError.export(error.localizedDescription)
        }
    }
}

/// Hears when a recording output has written its file.
private final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate, Sendable {
    private struct State {
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        markFinished()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Logger.recording.error("Recording output failed: \(error.localizedDescription, privacy: .public)")
        markFinished()
    }

    private func markFinished() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished(timeout: Duration) async {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.markFinished()
        }
        defer { timeoutTask.cancel() }
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
