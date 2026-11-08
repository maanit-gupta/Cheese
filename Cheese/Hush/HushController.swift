import AppKit
import os

/// Hush: keeps notifications from showing while the screen is shared, and on demand for a while.
/// Notifications are held back by turning on Focus through the user's two Hush shortcuts. Cheese
/// only turns Focus off again if it was the one that turned it on.
@MainActor
@Observable
final class HushController {
    typealias ShowToast = @MainActor (_ message: String, _ systemImage: String, _ action: CheeseToast.Action?) -> Void

    enum SetupState: Equatable {
        case unknown
        case checking
        case ready
        case missing([String])
    }

    /// How long Cheese waits before asking Shortcuts again after a failed attempt, so a missing
    /// shortcut isn't retried on every check.
    static let retryDelay: TimeInterval = 60

    private(set) var policy = HushPolicy()
    /// Focus is on because Hush asked for it (or was already on when it did).
    private(set) var isEngaged = false
    private(set) var isSwitching = false
    private(set) var setup = SetupState.unknown
    private(set) var lastError: String?
    private(set) var isRunning = false
    /// Cheese is recording the screen, which counts as sharing.
    private(set) var isCheeseRecording = false

    /// Called after anything the menu bar indicator shows may have changed.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let switcher: any FocusSwitching
    @ObservationIgnored private let detector: any ShareDetecting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let showToast: ShowToast
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let pollInterval: Duration
    /// The On shortcut found a Focus already on, so Hush leaves it on afterwards.
    @ObservationIgnored private var leavesFocusOn = false
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(
        switcher: any FocusSwitching = ShortcutsFocusSwitcher(),
        detector: any ShareDetecting = ScreenShareDetector(),
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { .now },
        showToast: @escaping ShowToast = { CheeseToast.show($0, systemImage: $1, action: $2) },
        openSettings: @escaping @MainActor () -> Void = {},
        pollInterval: Duration = .seconds(2)
    ) {
        self.switcher = switcher
        self.detector = detector
        self.defaults = defaults
        self.now = now
        self.showToast = showToast
        self.openSettings = openSettings
        self.pollInterval = pollInterval
        policy.automatic = Preferences(defaults: defaults).hushAutomatically
    }

    var reason: HushReason? { policy.reason(at: now()) }
    var manual: ManualHush? { policy.manual }
    var automatic: Bool { policy.automatic }
    var indicatorText: String? { policy.indicatorText(at: now()) }

    /// Beside the Cheese icon while hushed by hand: "Hush 42m", or "Hush ∞" with no end time. Nothing
    /// during an automatic Hush, which shouldn't draw attention on a shared screen.
    var menuBarText: String? {
        guard isEngaged, case .manual = reason else { return nil }
        return "Hush \(indicatorText ?? "∞")"
    }

    /// What the Hush menu's first line says.
    var statusText: String {
        if isSwitching { return isEngaged ? "Turning notifications back on…" : "Hushing notifications…" }
        switch reason {
        case let .manual(manual):
            return manual.deadline == nil ? "Hushed until you turn it off" : "Hushed \(manual.duration.phrase())"
        case let .sharing(source):
            return "Hushed: \(source.title)"
        case .grace:
            return "Sharing ended · notifications back shortly"
        case nil:
            if lastError != nil { return "Hush isn't set up" }
            return policy.automatic ? "Notifications on · hushes while you share" : "Notifications on"
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Cheese quit or crashed with Focus on: turn it back off.
        if defaults.bool(forKey: PreferenceKey.hushEngagedByCheese) {
            defaults.removeObject(forKey: PreferenceKey.hushEngagedByCheese)
            Logger.hush.notice("Turning off the Focus a previous run left on")
            Task { [switcher] in _ = await switcher.turnOff() }
        }
        loop = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Module off or Cheese quitting: notifications come back before this returns.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        loop?.cancel()
        loop = nil
        if isEngaged, !leavesFocusOn {
            switcher.turnOffNow()
        }
        isEngaged = false
        leavesFocusOn = false
        defaults.removeObject(forKey: PreferenceKey.hushEngagedByCheese)
        let automatic = policy.automatic
        policy = HushPolicy()
        policy.automatic = automatic
        onChange?()
    }

    // MARK: What the user asks for

    func hush(_ duration: CaffeinateDuration) {
        policy.manual = ManualHush(duration: duration, startedAt: now())
        failedAt = nil
        Logger.hush.notice("Manual Hush \(duration.phrase())")
        evaluate()
    }

    /// Notifications back now; an automatic Hush stays off until the current share ends.
    func turnOff() {
        policy.turnOff(at: now())
        evaluate()
    }

    func setAutomatic(_ isOn: Bool) {
        policy.automatic = isOn
        defaults.set(isOn, forKey: PreferenceKey.hushAutomatically)
        poll()
    }

    /// Cheese's own screen recordings count as sharing.
    func setCheeseRecording(_ isRecording: Bool) {
        isCheeseRecording = isRecording
        poll()
    }

    // MARK: Checking

    /// Looks at what's sharing the screen, then hushes or unhushes to match.
    func poll() {
        guard isRunning else { return }
        let source: ShareSource? = if isCheeseRecording && policy.automatic {
            .cheeseRecording
        } else if policy.automatic {
            detector.detect()
        } else {
            nil
        }
        if source != policy.sharing {
            Logger.hush.notice("Sharing: \(source?.title ?? "none")")
        }
        policy.observe(source, at: now())
        evaluate()
    }

    func evaluate() {
        if let manual = policy.manual, manual.isOver(at: now()) {
            policy.manual = nil
        }
        onChange?()
        applyIfNeeded()
    }

    private func applyIfNeeded() {
        guard isRunning, !isSwitching else { return }
        let wanted = policy.shouldHush(at: now())
        guard wanted != isEngaged else { return }
        if wanted, policy.manual == nil, let failedAt, now().timeIntervalSince(failedAt) < Self.retryDelay {
            return
        }
        isSwitching = true
        onChange?()
        Task { await self.switchFocus(on: wanted) }
    }

    private func switchFocus(on: Bool) async {
        if on {
            switch await switcher.turnOn() {
            case let .on(focusWasAlreadyOn):
                isEngaged = true
                leavesFocusOn = focusWasAlreadyOn
                failedAt = nil
                lastError = nil
                defaults.set(!focusWasAlreadyOn, forKey: PreferenceKey.hushEngagedByCheese)
                Logger.hush.notice("Focus on\(focusWasAlreadyOn ? " (it already was)" : "")")
                if !isRunning, !focusWasAlreadyOn {
                    // Switched off while Shortcuts ran.
                    _ = await switcher.turnOff()
                    isEngaged = false
                    defaults.removeObject(forKey: PreferenceKey.hushEngagedByCheese)
                }
            case let .failed(message):
                failedAt = now()
                lastError = message
                setup = .unknown
                Logger.hush.error("Couldn't hush: \(message)")
                if policy.manual != nil {
                    policy.manual = nil
                    showToast("Set up Hush first", "bell.slash", CheeseToast.Action(title: "Set Up…") { [openSettings] in
                        openSettings()
                    })
                }
            }
        } else {
            if !leavesFocusOn {
                _ = await switcher.turnOff()
            }
            isEngaged = false
            leavesFocusOn = false
            defaults.removeObject(forKey: PreferenceKey.hushEngagedByCheese)
            Logger.hush.notice("Notifications back on")
        }
        isSwitching = false
        onChange?()
        applyIfNeeded()
    }

    // MARK: Setup

    func checkSetup() async {
        setup = .checking
        let missing = await switcher.missingShortcuts()
        setup = missing.isEmpty ? .ready : .missing(missing)
        if missing.isEmpty {
            failedAt = nil
            lastError = nil
        }
    }

    /// Settings' Test button: both shortcuts exist, and On then Off run.
    func test() async -> String {
        await checkSetup()
        guard setup == .ready else {
            if case let .missing(names) = setup {
                return "Missing: " + names.map { "“\($0)”" }.joined(separator: " and ")
            }
            return "Couldn't read your shortcuts."
        }
        guard !isEngaged, !isSwitching else { return "Both shortcuts are set up." }
        switch await switcher.turnOn() {
        case let .on(focusWasAlreadyOn):
            if !focusWasAlreadyOn {
                _ = await switcher.turnOff()
            }
            return "Works: Focus turned on and back off."
        case let .failed(message):
            lastError = message
            return message
        }
    }
}
