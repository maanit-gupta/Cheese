import AVFoundation
import AppKit
import ImageIO
import CoreGraphics
import Foundation
import Testing
@testable import Cheese

@MainActor
final class FakeScreenRecorder: ScreenRecording {
    var startError: Error?
    private(set) var requests: [RecordingRequest] = []
    private(set) var events: [String] = []
    let folder = FileManager.default.temporaryDirectory.appending(path: "CheeseRecording-\(UUID().uuidString)")

    func start(_ request: RecordingRequest) async throws {
        if let startError { throw startError }
        requests.append(request)
        events.append("start")
    }

    func pause() async throws { events.append("pause") }
    func resume() async throws { events.append("resume") }

    func stop() async throws -> URL {
        events.append("stop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "Recording.mp4")
        try Data("movie".utf8).write(to: movie)
        return movie
    }

    func discard() async { events.append("discard") }
}

@MainActor
final class FakeRecordingPresenter: RecordingPresenting {
    private(set) var events: [String] = []
    private(set) var countdowns: [Int] = []
    private(set) var previews: [URL] = []
    var hasCamera = true
    var setupCancel: (() -> Void)?

    func showSetup(_ model: RecordingBarModel, around region: CGRect, onCancel: @escaping () -> Void) {
        events.append("setup")
        setupCancel = onCancel
    }
    func closeSetup() { events.append("closeSetup") }
    func showCountdown(_ number: Int, in region: CGRect) { countdowns.append(number) }
    func closeCountdown() {}
    func showRecordingChrome(_ model: RecordingBarModel, region: CGRect, showsBorder: Bool) {
        events.append(showsBorder ? "chrome+border" : "chrome")
    }
    func closeRecordingChrome() { events.append("closeChrome") }
    func showHalo(onDisplay displayID: CGDirectDisplayID) { events.append("halo") }
    func hideHalo() {}
    func showWebcam(over region: CGRect) -> Bool {
        events.append("webcam")
        return hasCamera
    }
    func hideWebcam() {}
    var includedWindowIDs: [CGWindowID] { [7] }
    func showPreview(_ url: URL, format: RecordingFormat) { previews.append(url) }
}

struct RecordingModelTests {
    @Test func optionsDefaultToNothingButTheCursorHalo() {
        let options = RecordingOptions()
        #expect(!options.microphone && !options.systemAudio && !options.camera)
        #expect(options.cursorHalo)
        #expect(options.format == .mp4)
        #expect(!options.recordsAudio)
    }

    @Test func optionsAreRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingModelTests"))
        defaults.removePersistentDomain(forName: "RecordingModelTests")
        #expect(RecordingOptions.stored(in: defaults) == RecordingOptions())
        var options = RecordingOptions()
        options.microphone = true
        options.format = .gif
        options.store(in: defaults)
        #expect(RecordingOptions.stored(in: defaults) == options)
        // GIFs have no sound.
        #expect(!options.recordsAudio)
    }

    @Test func planIsRetinaSizedAndEven() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let plan = RecordingPlan(region: CGRect(x: 100, y: 100, width: 401.5, height: 300.25), displayFrame: display, scale: 2)
        #expect(plan.pixelWidth == 802)
        #expect(plan.pixelHeight == 600)
        #expect(plan.pixelWidth % 2 == 0 && plan.pixelHeight % 2 == 0)
        // Top-left origin within the display.
        #expect(plan.sourceRect.origin == CGPoint(x: 100, y: 982 - 100 - 300.25))
        #expect(plan.minimumFrameInterval == CMTime(value: 1, timescale: 60))
    }

    @Test func planOnASecondDisplayIsLocalToIt() {
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let plan = RecordingPlan(region: display, displayFrame: display, scale: 1)
        #expect(plan.sourceRect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(plan.pixelWidth == 1920 && plan.pixelHeight == 1080)
    }

    @Test func clockSkipsPauses() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = RecordingClock()
        clock.start(at: start)
        #expect(clock.elapsed(at: start + 10) == 10)
        clock.pause(at: start + 10)
        #expect(clock.elapsed(at: start + 60) == 10)
        clock.start(at: start + 60)
        #expect(clock.elapsed(at: start + 65) == 15)
        #expect(RecordingClock.text(42) == "0:42")
        #expect(RecordingClock.text(725) == "12:05")
        #expect(RecordingClock.text(3723) == "1:02:03")
        #expect(RecordingClock.indicator(42, paused: false) == "● 0:42")
        #expect(RecordingClock.indicator(42, paused: true) == "❚❚ 0:42")
    }

    @Test func gifPlanSamplesAtItsFrameRateAndNeverEnlarges() {
        let plan = GIFPlan(duration: 2, sourceSize: CGSize(width: 1920, height: 1080), settings: GIFSettings())
        #expect(plan.times.count == 30)
        #expect(plan.times.first == 0)
        #expect(abs(plan.frameDelay - 1.0 / 15) < 0.0001)
        #expect(plan.size == CGSize(width: 960, height: 540))
        #expect(GIFPlan.outputSize(for: CGSize(width: 600, height: 400), maxWidth: 960) == CGSize(width: 600, height: 400))
        #expect(GIFPlan.outputSize(for: CGSize(width: 1000, height: 333), maxWidth: 0) == CGSize(width: 1000, height: 334))
        #expect(GIFPlan(duration: 0.01, sourceSize: CGSize(width: 10, height: 10), settings: GIFSettings()).times.count == 1)
    }

    @Test func gifSettingsFallBackToDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "GIFSettingsTests"))
        defaults.removePersistentDomain(forName: "GIFSettingsTests")
        #expect(GIFSettings.stored(in: defaults) == GIFSettings(frameRate: 15, maxWidth: 960))
        defaults.set(24, forKey: PreferenceKey.gifFrameRate)
        defaults.set(7, forKey: PreferenceKey.gifMaxWidth)
        #expect(GIFSettings.stored(in: defaults) == GIFSettings(frameRate: 24, maxWidth: 960))
    }

    @Test func recordingsAreNamedLikeScreenshots() {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let date = Date(timeIntervalSince1970: 1_772_874_302)
        let folder = URL(filePath: "/tmp/Cheese", directoryHint: .isDirectory)
        let url = ScreenshotNaming.uniqueURL(in: folder, date: date, prefix: "Cheese Recording", fileExtension: "mp4", timeZone: utc) { _ in false }
        #expect(url.lastPathComponent == "Cheese Recording 2026-03-07 at 09.05.02.mp4")
        var taken = true
        let second = ScreenshotNaming.uniqueURL(in: folder, date: date, prefix: "Cheese Recording", fileExtension: "gif", timeZone: utc) { _ in
            defer { taken = false }
            return taken
        }
        #expect(second.lastPathComponent == "Cheese Recording 2026-03-07 at 09.05.02 (2).gif")
    }
}

@MainActor
struct RecordingControllerTests {
    let recorder = FakeScreenRecorder()
    let presenter = FakeRecordingPresenter()
    let clock = FakeClock()
    let defaults: UserDefaults
    let log = Log()
    let folder = FileManager.default.temporaryDirectory.appending(path: "CheeseRecordingTests-\(UUID().uuidString)")
    let controller: RecordingController
    let region = CGRect(x: 100, y: 100, width: 640, height: 400)

    final class Log {
        var indicator: String?
        var recording: [Bool] = []
        var toasts: [String] = []
        var asked: [AVMediaType] = []
        var granted = true
    }

    init() {
        let suite = "RecordingControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let log = log
        let clock = clock
        let folder = folder
        let target = RecordingTarget(
            region: region, displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, isFullScreen: false
        )
        let full = RecordingTarget(
            region: CGRect(x: 0, y: 0, width: 1440, height: 900), displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, isFullScreen: true
        )
        controller = RecordingController(
            services: RecordingController.Services(
                pickRegion: { target },
                fullScreenTarget: { full },
                drawWindowIDs: { [42] },
                requestAccess: { type in
                    log.asked.append(type)
                    return log.granted
                },
                explainDenied: { _ in },
                setIndicator: { log.indicator = $0 },
                recordingChanged: { log.recording.append($0) },
                showToast: { message, _, _ in log.toasts.append(message) },
                saveFolder: { folder }
            ),
            recorder: recorder, presenter: presenter, defaults: defaults,
            now: { clock.now }, countdownStep: .zero
        )
    }

    /// Lets the countdown and the recorder's async calls finish.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<500 where !done() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func regionGoesThroughSetupCountdownAndRecording() async {
        await controller.beginRegion()
        #expect(controller.phase == .setup)
        #expect(presenter.events == ["setup"])

        controller.record()
        await settle { controller.phase == .recording }
        #expect(presenter.countdowns == [3, 2, 1])
        #expect(controller.phase == .recording)
        #expect(presenter.events.contains("halo"))
        #expect(presenter.events.contains("chrome+border"))
        #expect(log.recording == [true])
        #expect(log.indicator == "● 0:00")

        let request = recorder.requests.first
        #expect(request?.plan.pixelWidth == 1280)
        #expect(request?.includedWindowIDs == [7, 42])
        #expect(request?.systemAudio == false && request?.microphone == false)
    }

    @Test func fullScreenHasNoBorder() async {
        controller.beginFullScreen()
        controller.record()
        await settle { controller.phase == .recording }
        #expect(presenter.events.contains("chrome"))
        #expect(!presenter.events.contains("chrome+border"))
    }

    @Test func pauseResumeAndStopSaveAnMP4AndShowIt() async throws {
        await controller.beginRegion()
        controller.record()
        await settle { controller.phase == .recording }

        clock.advance(5)
        await controller.pauseOrResume()
        #expect(controller.phase == .paused)
        #expect(log.indicator == "❚❚ 0:05")
        clock.advance(30)
        await controller.pauseOrResume()
        #expect(controller.phase == .recording)
        clock.advance(2)

        await controller.stop()
        #expect(recorder.events == ["start", "pause", "resume", "stop"])
        #expect(controller.phase == .idle)
        #expect(log.recording == [true, false])
        #expect(log.indicator == nil)
        let saved = try #require(controller.lastSaved)
        #expect(saved.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(saved.lastPathComponent.hasPrefix("Cheese Recording "))
        #expect(saved.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: recorder.folder.path(percentEncoded: false)))
        #expect(presenter.previews == [saved])
        #expect(log.toasts.last?.hasPrefix("Recording saved as") == true)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func discardSavesNothing() async {
        await controller.beginRegion()
        controller.record()
        await settle { controller.phase == .recording }
        await controller.discard()
        #expect(recorder.events == ["start", "discard"])
        #expect(controller.phase == .idle)
        #expect(controller.lastSaved == nil)
        #expect(log.recording == [true, false])
        #expect(log.toasts == ["Recording discarded"])
    }

    @Test func restartStartsOverWithTheSameSettings() async {
        await controller.beginRegion()
        controller.record()
        await settle { controller.phase == .recording }
        clock.advance(20)
        await controller.restart()
        #expect(recorder.events == ["start", "discard", "start"])
        #expect(recorder.requests.count == 2)
        #expect(log.indicator == "● 0:00")
    }

    @Test func cancellingSetupRecordsNothing() async {
        await controller.beginRegion()
        controller.cancelSetup()
        #expect(controller.phase == .idle)
        #expect(recorder.requests.isEmpty)
        #expect(log.recording.isEmpty)
    }

    @Test func theHotkeyAgainStops() async {
        await controller.beginRegion()
        #expect(!controller.stopIfRecording())
        controller.record()
        await settle { controller.phase == .recording }
        #expect(controller.stopIfRecording())
        await settle { controller.phase == .idle }
        #expect(recorder.events.last == "stop")
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func audioIsAskedForOnlyWhenTurnedOnAndRefusalTurnsItBackOff() async {
        await controller.beginRegion()
        #expect(log.asked.isEmpty)
        log.granted = false
        controller.bar.update { $0.microphone = true }
        await settle { !controller.bar.options.microphone }
        #expect(log.asked == [.audio])
        #expect(!controller.bar.options.microphone)
    }

    @Test func microphoneAndSystemAudioReachTheRecorder() async {
        await controller.beginRegion()
        controller.bar.update {
            $0.microphone = true
            $0.systemAudio = true
            $0.microphoneID = "mic-2"
        }
        await settle { !log.asked.isEmpty }
        controller.record()
        await settle { controller.phase == .recording }
        let request = recorder.requests.first
        #expect(request?.microphone == true && request?.systemAudio == true)
        #expect(request?.microphoneID == "mic-2")
    }

    @Test func turningTheCameraOnShowsTheWebcam() async {
        await controller.beginRegion()
        controller.bar.update { $0.camera = true }
        await settle { presenter.events.contains("webcam") }
        #expect(log.asked == [.video])
        #expect(presenter.events.contains("webcam"))
    }

    @Test func aFailedStartSaysSo() async {
        recorder.startError = RecordingError.couldNotStart("No permission")
        await controller.beginRegion()
        controller.record()
        await settle { controller.phase == .idle }
        #expect(controller.phase == .idle)
        #expect(log.toasts.first == "Couldn't start recording: No permission")
        #expect(log.recording.isEmpty)
    }

    @Test func moduleActionsAndShortcuts() {
        let module = ScreenRecordingModule(controller: controller)
        let actions = Dictionary(uniqueKeysWithValues: module.actions.map { ($0.id, $0) })
        #expect(actions[.recordRegion]?.shortcut == .recordRegion)
        #expect(actions[.recordFullScreen]?.shortcut == .recordFullScreen)
        #expect(actions[.recordRegion]?.requiredPermissions == [.screenRecording])
        #expect(actions[.stopRecording]?.precondition() == false)
        #expect(actions[.stopRecording]?.shortcut == nil)
    }
}

/// Records a few real seconds of the main display (`TEST_RUNNER_RECORDING_LIVE=1`; needs Screen
/// Recording for the test host): pause, resume and stop join the parts, system audio gets its own
/// track, and the GIF encoder reads the movie.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RECORDING_LIVE"] == "1"))
struct RecordingLiveTests {
    @Test func recordsPausesAndJoins() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let region = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 640, height: 360)
        let recorder = SCKScreenRecorder()
        try await recorder.start(RecordingRequest(
            displayID: displayID,
            plan: RecordingPlan(region: region, displayFrame: screen.frame, scale: screen.backingScaleFactor),
            includedWindowIDs: [], systemAudio: true, microphone: false, microphoneID: nil
        ))
        try await Task.sleep(for: .seconds(1.5))
        try await recorder.pause()
        try await Task.sleep(for: .seconds(0.5))
        try await recorder.resume()
        try await Task.sleep(for: .seconds(1.5))
        let movie = try await recorder.stop()

        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        print("LIVE duration=\(duration) video=\(video.count) audio=\(audio.count) size=\(try await video.first?.load(.naturalSize) ?? .zero)")
        #expect(video.count == 1)
        #expect(duration > 2.5 && duration < 4.5)

        let gif = movie.deletingLastPathComponent().appending(path: "Recording.gif")
        try await GIFEncoder.makeGIF(from: movie, to: gif, settings: GIFSettings())
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        print("LIVE gif frames=\(CGImageSourceGetCount(source))")
        #expect(CGImageSourceGetCount(source) >= 30)
        try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
    }
}
