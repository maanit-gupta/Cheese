import AppKit
import Foundation
import Testing
@testable import Cheese

private let cheeseID = "com.maanitgupta.cheese"
private let cheesePID: pid_t = 100

private func app(_ name: String, pid: pid_t, bundleID: String? = nil, regular: Bool = true, active: Bool = false) -> RunningAppInfo {
    RunningAppInfo(pid: pid, bundleID: bundleID ?? "com.example.\(name.lowercased())", name: name, isRegular: regular, isActive: active)
}

struct AppSweepPlannerTests {
    private let safari = app("Safari", pid: 1, active: true)
    private let slack = app("Slack", pid: 2)
    private let notes = app("Notes", pid: 3)
    private let finder = app("Finder", pid: 4, bundleID: AppSweepPlanner.finderBundleID)
    private let cheese = app("Cheese", pid: cheesePID, bundleID: cheeseID)
    private let helper = app("Helper", pid: 5, regular: false)
    private let noBundle = app("Script", pid: 6, bundleID: nil)

    private func plan(_ apps: [RunningAppInfo], protected: Set<String> = [], scope: SweepScope = .all) -> SweepPlan {
        AppSweepPlanner.plan(apps: apps, protectedBundleIDs: protected, scope: scope, ownBundleID: cheeseID, ownPID: cheesePID)
    }

    @Test func neverQuitsCheeseFinderOrHelpers() {
        let result = plan([safari, finder, cheese, helper, slack])
        #expect(result.targets == [safari, slack])
        #expect(result.protected.isEmpty)
    }

    @Test func cheeseIsSparedByPIDEvenWithoutABundleID() {
        let anonymousCheese = RunningAppInfo(pid: cheesePID, bundleID: nil, name: "Cheese", isRegular: true, isActive: false)
        #expect(plan([anonymousCheese, slack]).targets == [slack])
    }

    @Test func shieldedAppsAreSkippedAndReported() {
        let result = plan([safari, slack, notes], protected: [slack.bundleID ?? ""])
        #expect(result.targets == [safari, notes])
        #expect(result.protected == [slack])
    }

    @Test func keepFrontmostLeavesTheActiveAppAlone() {
        let result = plan([safari, slack, notes], scope: .keepFrontmost)
        #expect(result.targets == [slack, notes])
        // Kept because it's in front, not because of a shield.
        #expect(result.protected.isEmpty)
    }

    @Test func appsWithoutABundleIDCanStillBeSwept() {
        #expect(plan([noBundle]).targets == [noBundle])
        #expect(plan([noBundle], protected: [""]).targets == [noBundle])
    }

    @Test func listingShowsFinderButNotCheeseOrHelpers() {
        let listed = [safari, finder, cheese, helper].filter { AppSweepPlanner.isListed($0, ownBundleID: cheeseID, ownPID: cheesePID) }
        #expect(listed == [safari, finder])
        #expect(AppSweepPlanner.isAlwaysKept(finder))
        #expect(!AppSweepPlanner.isAlwaysKept(safari))
    }

    @Test func summaryAndButtonTitles() {
        #expect(AppSweepPlanner.summary(swept: 8, protected: 2) == "Swept 8 apps · 2 protected")
        #expect(AppSweepPlanner.summary(swept: 1, protected: 0) == "Swept 1 app")
        #expect(AppSweepPlanner.buttonTitle(count: 9, force: false) == "Kill All (9 Apps)")
        #expect(AppSweepPlanner.buttonTitle(count: 1, force: true) == "Force Kill All (1 App)")
    }
}

struct ProtectedAppsStoreTests {
    private let defaults: UserDefaults

    init() throws {
        let suite = "ProtectedAppsStoreTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func togglesAndPersists() {
        let store = ProtectedAppsStore(defaults: defaults)
        #expect(store.bundleIDs.isEmpty)
        store.toggle("com.tinyspeck.slackmacgap")
        store.setProtected(true, "com.apple.Notes")
        #expect(ProtectedAppsStore(defaults: defaults).bundleIDs == ["com.tinyspeck.slackmacgap", "com.apple.Notes"])

        store.toggle("com.tinyspeck.slackmacgap")
        store.setProtected(false, "com.never.added")
        #expect(store.bundleIDs == ["com.apple.Notes"])
        #expect(store.isProtected("com.apple.Notes"))
        #expect(!store.isProtected("com.tinyspeck.slackmacgap"))
    }
}

/// Apps that quit when asked, unless they're stubborn.
@MainActor
private final class FakeApps: AppTerminating {
    var apps: [RunningAppInfo] = []
    var stubborn: Set<pid_t> = []
    private(set) var running: Set<pid_t> = []
    private(set) var asked: [pid_t] = []
    private(set) var forced: [pid_t] = []

    init(_ apps: [RunningAppInfo]) {
        self.apps = apps
        running = Set(apps.map(\.pid))
    }

    func runningApps(activePID: pid_t?) -> [RunningAppInfo] {
        apps.filter { running.contains($0.pid) }.map { app in
            var app = app
            app.isActive = app.pid == activePID
            return app
        }
    }

    func terminate(_ pid: pid_t) {
        asked.append(pid)
        if !stubborn.contains(pid) { running.remove(pid) }
    }

    func forceTerminate(_ pid: pid_t) {
        forced.append(pid)
        running.remove(pid)
    }

    func isRunning(_ pid: pid_t) -> Bool {
        running.contains(pid)
    }
}

@MainActor
struct AppSweeperTests {
    private let slack = app("Slack", pid: 2)
    private let notes = app("Notes", pid: 3)
    private let word = app("Word", pid: 7)

    @Test func asksEveryAppAndForcesNothingByDefault() async {
        let apps = FakeApps([slack, notes, word])
        apps.stubborn = [word.pid]
        let result = await AppSweeper(apps: apps).sweep([slack, notes, word], forceAfter: nil)
        #expect(apps.asked == [slack.pid, notes.pid, word.pid])
        #expect(apps.forced.isEmpty)
        #expect(result == AppSweeper.Result(asked: 3, forced: 0))
    }

    @Test func forceSweepKillsOnlyWhatsStillOpenAfterTheGracePeriod() async {
        let apps = FakeApps([slack, notes, word])
        apps.stubborn = [word.pid]
        let sweeper = AppSweeper(apps: apps, pollInterval: .milliseconds(5))
        let result = await sweeper.sweep([slack, notes, word], forceAfter: .milliseconds(30))
        #expect(apps.forced == [word.pid])
        #expect(result == AppSweeper.Result(asked: 3, forced: 1))
        #expect(apps.runningApps(activePID: nil).isEmpty)
    }

    @Test func forceSweepReturnsEarlyWhenEverythingQuits() async {
        let apps = FakeApps([slack, notes])
        let started = ContinuousClock.now
        let result = await AppSweeper(apps: apps).sweep([slack, notes], forceAfter: .seconds(3))
        #expect(result.forced == 0)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func singleQuitHonorsOption() {
        let apps = FakeApps([slack, notes])
        let sweeper = AppSweeper(apps: apps)
        sweeper.quit(slack, force: false)
        sweeper.quit(notes, force: true)
        #expect(apps.asked == [slack.pid])
        #expect(apps.forced == [notes.pid])
    }
}

@MainActor
struct AppSweepPanelModelTests {
    private let defaults: UserDefaults

    init() throws {
        let suite = "AppSweepPanelModelTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(_ apps: [RunningAppInfo]) -> (AppSweepPanelModel, FakeApps) {
        let fake = FakeApps(apps)
        let model = AppSweepPanelModel(source: fake, protectedApps: ProtectedAppsStore(defaults: defaults)) { _ in nil }
        model.refresh()
        return (model, fake)
    }

    @Test func listsRegularAppsByNameWithoutCheese() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let (model, _) = model([
            app("Zoom", pid: 1),
            app("Cheese", pid: ownPID, bundleID: Bundle.main.bundleIdentifier),
            app("Helper", pid: 2, regular: false),
            app("arc", pid: 3),
        ])
        #expect(model.apps.map(\.name) == ["arc", "Zoom"])
    }

    @Test func shieldsUpdateTheKillAllCount() {
        let slack = app("Slack", pid: 2)
        let (model, _) = model([slack, app("Notes", pid: 3)])
        #expect(model.plan.targets.count == 2)
        model.toggleShield(slack)
        #expect(model.plan.targets.map(\.name) == ["Notes"])
        #expect(model.status(of: slack) == "Protected")
        #expect(ProtectedAppsStore(defaults: defaults).isProtected(slack.bundleID ?? ""))
    }

    @Test func killAllHandsOverThePlanWithOptionAsForce() {
        let (model, _) = model([app("Slack", pid: 2), app("Notes", pid: 3)])
        var received: (SweepPlan, Bool)?
        model.onKillAll = { received = ($0, $1) }
        model.killAll(force: true)
        #expect(received?.0.targets.count == 2)
        #expect(received?.1 == true)

        var quit: (String, Bool)?
        model.onQuit = { quit = ($0.name, $1) }
        model.isOptionHeld = true
        model.quit(app("Notes", pid: 3))
        #expect(quit?.0 == "Notes")
        #expect(quit?.1 == true)
    }

    @Test func finderIsListedButAlwaysKept() {
        let finder = app("Finder", pid: 4, bundleID: AppSweepPlanner.finderBundleID)
        let (model, _) = model([finder])
        #expect(model.apps == [finder])
        #expect(model.plan.targets.isEmpty)
        #expect(model.status(of: finder) == "Always kept")
    }
}
