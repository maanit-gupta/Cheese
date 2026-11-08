/// Screen recording: a region or the whole display, to an MP4 or a GIF, with an optional cursor
/// highlight, webcam, microphone and system audio.
@MainActor
final class ScreenRecordingModule: CheeseModule {
    let id = ModuleID.screenRecording
    let controller: RecordingController

    init(controller: RecordingController) {
        self.controller = controller
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .recordRegion, title: "Record Region", symbol: "record.circle", module: id,
                paletteTitle: "Capture: Record Region",
                shortcut: .recordRegion, requiredPermissions: [.screenRecording], featureName: "Screen recording"
            ) { [controller] _ in
                // Either recording shortcut stops a recording that's running.
                guard !controller.stopIfRecording() else { return }
                Task { await controller.beginRegion() }
            },
            CheeseAction(
                id: .recordFullScreen, title: "Record Full Screen", symbol: "menubar.dock.rectangle.badge.record", module: id,
                paletteTitle: "Capture: Record Full Screen",
                shortcut: .recordFullScreen, requiredPermissions: [.screenRecording], featureName: "Screen recording"
            ) { [controller] _ in
                guard !controller.stopIfRecording() else { return }
                controller.beginFullScreen()
            },
            CheeseAction(
                id: .stopRecording, title: "Stop Recording", symbol: "stop.circle", module: id,
                paletteTitle: "Capture: Stop Recording",
                precondition: { [controller] in controller.isRecording }
            ) { [controller] _ in
                _ = controller.stopIfRecording()
            },
        ]
    }

    // Nothing runs until a recording starts.
    func start() {}

    /// Saves a recording that's running.
    func stop() {
        Task { [controller] in await controller.shutDown() }
    }
}
