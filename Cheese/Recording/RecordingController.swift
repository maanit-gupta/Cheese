import AVFoundation
import AppKit
import os

/// The part of a display to record, in AppKit global points.
struct RecordingTarget: Equatable {
    var region: CGRect
    var displayID: CGDirectDisplayID
    var displayFrame: CGRect
    var scale: CGFloat
    var isFullScreen: Bool

    var plan: RecordingPlan {
        RecordingPlan(region: region, displayFrame: displayFrame, scale: scale)
    }
}

/// The windows around a recording: the bars, the countdown, the border, the cursor halo, the
/// webcam and the preview afterwards. A protocol so tests can stand in for it.
@MainActor
protocol RecordingPresenting: AnyObject {
    func showSetup(_ model: RecordingBarModel, around region: CGRect, onCancel: @escaping () -> Void)
    func closeSetup()
    func showCountdown(_ number: Int, in region: CGRect)
    func closeCountdown()
    func showRecordingChrome(_ model: RecordingBarModel, region: CGRect, showsBorder: Bool)
    func closeRecordingChrome()
    func showHalo(onDisplay displayID: CGDirectDisplayID)
    func hideHalo()
    /// False when there's no camera.
    func showWebcam(over region: CGRect) -> Bool
    func hideWebcam()
    /// The halo and webcam windows, which belong in the video.
    var includedWindowIDs: [CGWindowID] { get }
    func showPreview(_ url: URL, format: RecordingFormat)
}

/// Screen recording: pick a region or a display, choose the extras in the bar, count down, record
/// with pauses, then save an MP4 or a GIF to the screenshot folder and show it.
@MainActor
@Observable
final class RecordingController {
    @MainActor
    struct Services {
        var pickRegion: @MainActor () async -> RecordingTarget?
        var fullScreenTarget: @MainActor () -> RecordingTarget?
        /// Draw's canvases, so ink drawn while recording is in the video.
        var drawWindowIDs: @MainActor () -> [CGWindowID] = { [] }
        var requestAccess: @MainActor (AVMediaType) async -> Bool = { await MediaPrivacy.requestAccess(for: $0) }
        var explainDenied: @MainActor (AVMediaType) -> Void = { MediaPrivacy.explainDenied($0) }
        /// "● 0:42" beside the menu bar icon; nil clears it.
        var setIndicator: @MainActor (String?) -> Void = { _ in }
        /// Recording started or ended, for Hush.
        var recordingChanged: @MainActor (Bool) -> Void = { _ in }
        var showToast: @MainActor (String, String, CheeseToast.Action?) -> Void = { CheeseToast.show($0, systemImage: $1, action: $2) }
        var saveFolder: @MainActor () -> URL = { Preferences().screenshotSaveFolder }
        var gifSettings: @MainActor () -> GIFSettings = { GIFSettings.stored(in: .standard) }
    }

    let bar = RecordingBarModel()
    private(set) var phase = RecordingPhase.idle
    private(set) var target: RecordingTarget?
    /// Where the last recording was saved.
    private(set) var lastSaved: URL?

    var isRecording: Bool { phase == .recording || phase == .paused }
    var isBusy: Bool { phase != .idle }

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let recorder: any ScreenRecording
    @ObservationIgnored private let presenter: any RecordingPresenting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let countdownStep: Duration
    @ObservationIgnored private var clock = RecordingClock()
    @ObservationIgnored private var request: RecordingRequest?
    /// `recordingChanged(true)` went out and its `false` hasn't yet.
    @ObservationIgnored private var hasAnnounced = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    init(
        services: Services,
        recorder: any ScreenRecording = SCKScreenRecorder(),
        presenter: any RecordingPresenting = SystemRecordingPresenter(),
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { .now },
        countdownStep: Duration = .seconds(1)
    ) {
        self.services = services
        self.recorder = recorder
        self.presenter = presenter
        self.defaults = defaults
        self.now = now
        self.countdownStep = countdownStep
        bar.onRecord = { [weak self] in self?.record() }
        bar.onCancel = { [weak self] in self?.cancelSetup() }
        bar.onOptionsChange = { [weak self] in self?.optionsChanged(to: $0) }
        bar.onStop = { [weak self] in Task { await self?.stop() } }
        bar.onPauseResume = { [weak self] in Task { await self?.pauseOrResume() } }
        bar.onRestart = { [weak self] in Task { await self?.restart() } }
        bar.onDiscard = { [weak self] in Task { await self?.discard() } }
    }

    // MARK: Starting

    func beginRegion() async {
        guard phase == .idle else { return }
        phase = .setup
        guard let target = await services.pickRegion() else {
            phase = .idle
            return
        }
        showSetup(for: target)
    }

    func beginFullScreen() {
        guard phase == .idle, let target = services.fullScreenTarget() else { return }
        phase = .setup
        showSetup(for: target)
    }

    private func showSetup(for target: RecordingTarget) {
        self.target = target
        bar.options = RecordingOptions.stored(in: defaults)
        bar.phase = .setup
        presenter.showSetup(bar, around: target.region) { [weak self] in self?.cancelSetup() }
        if bar.options.camera {
            Task { await self.turnOnCamera() }
        }
    }

    func cancelSetup() {
        guard phase == .setup || isCountingDown else { return }
        countdownTask?.cancel()
        countdownTask = nil
        presenter.closeSetup()
        presenter.closeCountdown()
        presenter.hideWebcam()
        target = nil
        setPhase(.idle)
    }

    private var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    /// The bar's switches: the camera shows straight away, and the camera and microphone are
    /// asked for the first time they're switched on.
    private func optionsChanged(to options: RecordingOptions) {
        let previous = RecordingOptions.stored(in: defaults)
        options.store(in: defaults)
        if options.camera, !previous.camera {
            Task { await turnOnCamera() }
        } else if !options.camera, previous.camera {
            presenter.hideWebcam()
        }
        if options.microphone, !previous.microphone {
            Task {
                guard await services.requestAccess(.audio) else {
                    bar.update { $0.microphone = false }
                    services.explainDenied(.audio)
                    return
                }
            }
        }
    }

    private func turnOnCamera() async {
        guard let target, phase == .setup else { return }
        guard await services.requestAccess(.video) else {
            bar.update { $0.camera = false }
            services.explainDenied(.video)
            return
        }
        if !presenter.showWebcam(over: target.region) {
            bar.update { $0.camera = false }
            services.showToast("No camera found", "video.slash", nil)
        }
    }

    /// Record: counts down, then starts.
    func record() {
        guard phase == .setup, let target else { return }
        presenter.closeSetup()
        bar.options.store(in: defaults)
        countdownTask = Task {
            for number in stride(from: 3, through: 1, by: -1) {
                setPhase(.countdown(number))
                presenter.showCountdown(number, in: target.region)
                try? await Task.sleep(for: countdownStep)
                guard !Task.isCancelled, isCountingDown else { return }
            }
            presenter.closeCountdown()
            await start(target)
        }
    }

    private func start(_ target: RecordingTarget) async {
        let options = bar.options
        if options.cursorHalo {
            presenter.showHalo(onDisplay: target.displayID)
        }
        if !options.camera {
            presenter.hideWebcam()
        }
        let request = RecordingRequest(
            displayID: target.displayID,
            plan: target.plan,
            includedWindowIDs: presenter.includedWindowIDs + services.drawWindowIDs(),
            systemAudio: options.format == .mp4 && options.systemAudio,
            microphone: options.format == .mp4 && options.microphone,
            microphoneID: options.microphoneID
        )
        self.request = request
        do {
            try await recorder.start(request)
        } catch {
            Logger.recording.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
            tearDown()
            services.showToast("Couldn't start recording: \(error.localizedDescription)", "exclamationmark.triangle.fill", nil)
            return
        }
        clock = RecordingClock()
        clock.start(at: now())
        setPhase(.recording)
        presenter.showRecordingChrome(bar, region: target.region, showsBorder: !target.isFullScreen)
        announce(true)
        startTicking()
    }

    // MARK: While recording

    func pauseOrResume() async {
        switch phase {
        case .recording:
            do {
                try await recorder.pause()
                clock.pause(at: now())
                setPhase(.paused)
            } catch {
                Logger.recording.error("Couldn't pause: \(error.localizedDescription, privacy: .public)")
            }
        case .paused:
            do {
                try await recorder.resume()
                clock.start(at: now())
                setPhase(.recording)
            } catch {
                Logger.recording.error("Couldn't resume: \(error.localizedDescription, privacy: .public)")
            }
        default:
            break
        }
        updateTime()
    }

    /// Throws away what's recorded so far and starts again straight away.
    func restart() async {
        guard isRecording, let request else { return }
        await recorder.discard()
        do {
            try await recorder.start(request)
        } catch {
            Logger.recording.error("Couldn't restart recording: \(error.localizedDescription, privacy: .public)")
            tearDown()
            services.showToast("Couldn't restart the recording", "exclamationmark.triangle.fill", nil)
            return
        }
        clock = RecordingClock()
        clock.start(at: now())
        setPhase(.recording)
        updateTime()
    }

    func discard() async {
        guard isRecording else { return }
        await recorder.discard()
        tearDown()
        services.showToast("Recording discarded", "trash", nil)
    }

    /// Stops, saves and shows the recording.
    func stop() async {
        guard isRecording else { return }
        setPhase(.finishing)
        let format = bar.options.format
        presenter.closeRecordingChrome()
        presenter.hideHalo()
        presenter.hideWebcam()
        stopTicking()
        services.setIndicator(nil)
        announce(false)
        request = nil
        do {
            let movie = try await recorder.stop()
            if format == .gif {
                services.showToast("Making GIF…", "photo.stack", nil)
            }
            let saved = try await Self.save(
                movie, as: format, in: services.saveFolder(), date: now(), gif: services.gifSettings()
            )
            lastSaved = saved
            tearDown()
            presenter.showPreview(saved, format: format)
            services.showToast("Recording saved as \(saved.lastPathComponent)", "checkmark.circle.fill", CheeseToast.Action(title: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            })
        } catch {
            Logger.recording.error("Couldn't save the recording: \(error.localizedDescription, privacy: .public)")
            await recorder.discard()
            tearDown()
            services.showToast("Couldn't save the recording: \(error.localizedDescription)", "exclamationmark.triangle.fill", nil)
        }
    }

    /// The hotkeys and the menu bar timer stop a recording that's running.
    func stopIfRecording() -> Bool {
        guard isRecording else { return false }
        Task { await stop() }
        return true
    }

    /// Module off: a running recording is saved, anything before it is dropped.
    func shutDown() async {
        if isRecording {
            await stop()
        } else {
            cancelSetup()
        }
    }

    // MARK: Helpers

    private func announce(_ isRecording: Bool) {
        guard isRecording != hasAnnounced else { return }
        hasAnnounced = isRecording
        services.recordingChanged(isRecording)
    }

    private func setPhase(_ phase: RecordingPhase) {
        self.phase = phase
        bar.phase = phase
    }

    private func tearDown() {
        countdownTask?.cancel()
        countdownTask = nil
        stopTicking()
        presenter.closeSetup()
        presenter.closeCountdown()
        presenter.closeRecordingChrome()
        presenter.hideHalo()
        presenter.hideWebcam()
        services.setIndicator(nil)
        announce(false)
        request = nil
        target = nil
        clock = RecordingClock()
        setPhase(.idle)
    }

    private func startTicking() {
        stopTicking()
        updateTime()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.updateTime()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func updateTime() {
        guard isRecording else { return }
        let elapsed = clock.elapsed(at: now())
        bar.elapsedText = RecordingClock.text(elapsed)
        services.setIndicator(RecordingClock.indicator(elapsed, paused: phase == .paused))
    }

    /// Puts the movie in `folder` as `Cheese Recording … .mp4`, or makes the GIF there, and
    /// removes the temporary files.
    @concurrent
    static func save(_ movie: URL, as format: RecordingFormat, in folder: URL, date: Date, gif: GIFSettings) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ScreenshotNaming.uniqueURL(
            in: folder, date: date, prefix: "Cheese Recording", fileExtension: format.fileExtension
        ) { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        switch format {
        case .mp4:
            try fileManager.moveItem(at: movie, to: url)
        case .gif:
            try await GIFEncoder.makeGIF(from: movie, to: url, settings: gif)
        }
        let temporary = movie.deletingLastPathComponent()
        if temporary.lastPathComponent.hasPrefix("CheeseRecording-") {
            try? fileManager.removeItem(at: temporary)
        }
        return url
    }
}
