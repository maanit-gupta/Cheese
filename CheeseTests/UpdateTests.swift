import Foundation
import Testing
@testable import Cheese

// MARK: - Versions

struct AppVersionTests {
    @Test func comparesTwoAndThreePartVersions() {
        #expect(UpdateService.isVersion("v2.4", newerThan: "2.3"))
        #expect(UpdateService.isVersion("2.3.1", newerThan: "2.3"))
        #expect(!UpdateService.isVersion("2.3", newerThan: "2.3.0"))
        #expect(!UpdateService.isVersion("2.2", newerThan: "2.3"))
        #expect(UpdateService.isVersion("2.10", newerThan: "2.9"))
        #expect(UpdateService.isVersion("3", newerThan: "2.99.99"))
        #expect(!UpdateService.isVersion("v2.3.0", newerThan: "V2.3"))
    }

    @Test func ignoresSuffixesAndRejectsJunk() {
        #expect(AppVersion("v2.4-beta.1")?.description == "2.4")
        #expect(AppVersion(" 2.3.1+12 ")?.description == "2.3.1")
        #expect(AppVersion("2.3") == AppVersion("2.3.0"))
        for junk in ["", "v", "latest", "2..3", "2.x", "-1.0", "1.2.3.4.5", "٢.٣"] {
            #expect(AppVersion(junk) == nil, "\(junk)")
        }
        #expect(!UpdateService.isVersion("nightly", newerThan: "2.3"))
    }
}

// MARK: - Planning

struct UpdatePlannerTests {
    private func release(
        tag: String = "v2.4", draft: Bool = false, prerelease: Bool = false, assets: Bool = true, body: String? = "## New\n**Thing**"
    ) throws -> GitHubRelease {
        let assetsJSON = assets ? """
            [{"name": "Cheese.zip", "size": 5606860, "browser_download_url": "https://github.com/maanit-gupta/Cheese/releases/download/\(tag)/Cheese.zip"},
             {"name": "Cheese.zip.sha256", "size": 77, "browser_download_url": "https://github.com/maanit-gupta/Cheese/releases/download/\(tag)/Cheese.zip.sha256"}]
            """ : "[]"
        let bodyJSON = try body.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        let json = """
            {"tag_name": "\(tag)", "name": "Cheese \(tag)", "body": \(bodyJSON), "html_url": "https://github.com/maanit-gupta/Cheese/releases/tag/\(tag)",
             "draft": \(draft), "prerelease": \(prerelease), "assets": \(assetsJSON), "extra": {"ignored": true}}
            """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    @Test func offersANewerPublishedRelease() throws {
        let offer = try #require(UpdatePlanner.offer(from: release(), currentVersion: "2.3"))
        #expect(offer.version == "2.4")
        #expect(offer.archive.absoluteString == "https://github.com/maanit-gupta/Cheese/releases/download/v2.4/Cheese.zip")
        #expect(offer.checksum.lastPathComponent == "Cheese.zip.sha256")
        #expect(offer.releasePage?.absoluteString == "https://github.com/maanit-gupta/Cheese/releases/tag/v2.4")
        #expect(offer.notes == "New\nThing")
    }

    @Test func offersNothingOlderSameDraftOrPrerelease() throws {
        #expect(try UpdatePlanner.offer(from: release(tag: "v2.3"), currentVersion: "2.3") == nil)
        #expect(try UpdatePlanner.offer(from: release(tag: "v2.3.0"), currentVersion: "2.3") == nil)
        #expect(try UpdatePlanner.offer(from: release(tag: "v2.2.1"), currentVersion: "2.3") == nil)
        #expect(try UpdatePlanner.offer(from: release(draft: true), currentVersion: "2.3") == nil)
        #expect(try UpdatePlanner.offer(from: release(prerelease: true), currentVersion: "2.3") == nil)
        #expect(try UpdatePlanner.offer(from: release(tag: "nightly"), currentVersion: "2.3") == nil)
    }

    @Test func fallsBackToTheTagsDownloadURLs() throws {
        let offer = try #require(UpdatePlanner.offer(from: release(tag: "v2.4.1", assets: false, body: nil), currentVersion: "2.4"))
        #expect(offer.archive.absoluteString == "https://github.com/maanit-gupta/Cheese/releases/download/v2.4.1/Cheese.zip")
        #expect(offer.checksum.absoluteString == "https://github.com/maanit-gupta/Cheese/releases/download/v2.4.1/Cheese.zip.sha256")
        #expect(offer.notes.isEmpty)
    }

    @Test func decodesTheLiveReleaseShape() throws {
        // As api.github.com returned it for v2.3, trimmed.
        let json = #"""
            {"url": "https://api.github.com/repos/maanit-gupta/Cheese/releases/1", "tag_name": "v2.3", "target_commitish": "main",
             "name": "Cheese 2.3", "draft": false, "prerelease": false, "created_at": "2026-10-30T12:00:00Z",
             "html_url": "https://github.com/maanit-gupta/Cheese/releases/tag/v2.3",
             "assets": [{"name": "Cheese.zip", "size": 5606860, "content_type": "application/zip",
                         "browser_download_url": "https://github.com/maanit-gupta/Cheese/releases/download/v2.3/Cheese.zip"}],
             "body": "## New\r\n\r\n**Terminal Trace** (⌃⌥⇧T)"}
            """#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v2.3")
        #expect(UpdatePlanner.offer(from: release, currentVersion: "2.3") == nil)
        #expect(UpdatePlanner.offer(from: release, currentVersion: "2.2.1")?.notes == "New\n\nTerminal Trace (⌃⌥⇧T)")
    }

    @Test func announcesEachVersionOnceUnlessSkippedOrAskedFor() throws {
        let offer = try #require(UpdatePlanner.offer(from: release(), currentVersion: "2.3"))
        #expect(UpdatePlanner.shouldAnnounce(offer, skippedVersion: nil, announcedVersion: nil, userInitiated: false))
        #expect(!UpdatePlanner.shouldAnnounce(offer, skippedVersion: "2.4", announcedVersion: nil, userInitiated: false))
        #expect(!UpdatePlanner.shouldAnnounce(offer, skippedVersion: nil, announcedVersion: "2.4", userInitiated: false))
        #expect(UpdatePlanner.shouldAnnounce(offer, skippedVersion: "2.4", announcedVersion: "2.4", userInitiated: true))
        // Skipping 2.4 doesn't silence 2.4.1.
        #expect(UpdatePlanner.shouldAnnounce(offer, skippedVersion: "2.3.9", announcedVersion: nil, userInitiated: false))
    }

    @Test func checksAreDueEvery12Hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdatePlanner.isCheckDue(lastCheck: nil, now: now))
        #expect(!UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(-11 * 3600), now: now))
        #expect(UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(-12 * 3600), now: now))
        #expect(UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    @Test func notesBecomePlainShortLines() {
        let markdown = "## What's Changed\r\n* Fix `paste` by **me**\n- Two\n\n\n\n**Full Changelog**: https://github.com/x/compare/v2.3...v2.4\n"
        #expect(UpdatePlanner.plainNotes(markdown) == "What's Changed\n• Fix paste by me\n• Two")

        let long = (1...100).map { "Line \($0) of the notes" }.joined(separator: "\n")
        let short = UpdatePlanner.plainNotes(long, limit: 60)
        #expect(short.hasSuffix("\n…"))
        #expect(short.count <= 63)
        #expect(short.hasPrefix("Line 1 of the notes\nLine 2"))
    }

    @Test func readsShasumFiles() {
        let digest = String(repeating: "aB3", count: 21) + "f"
        #expect(UpdatePlanner.checksum(in: "\(digest)  Cheese.zip\n") == digest.lowercased())
        #expect(UpdatePlanner.checksum(in: "\(digest) *Cheese.zip") == digest.lowercased())
        #expect(UpdatePlanner.checksum(in: digest) == digest.lowercased())
        #expect(UpdatePlanner.checksum(in: "\(digest)  Other.zip") == nil)
        #expect(UpdatePlanner.checksum(in: "deadbeef  Cheese.zip") == nil)
        #expect(UpdatePlanner.checksum(in: "<html>Not Found</html>") == nil)
    }

    @Test func refusesLocationsItCantReplace() {
        let ok = UpdatePlanner.installLocationProblem(bundlePath: "/Applications/Cheese.app", isOnReadOnlyVolume: false, isFolderWritable: true, isBundleWritable: true)
        #expect(ok == nil)
        let translocated = UpdatePlanner.installLocationProblem(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Cheese.app", isOnReadOnlyVolume: true, isFolderWritable: false, isBundleWritable: false
        )
        #expect(translocated == .translocated)
        let dmg = UpdatePlanner.installLocationProblem(bundlePath: "/Volumes/Cheese/Cheese.app", isOnReadOnlyVolume: true, isFolderWritable: false, isBundleWritable: false)
        #expect(dmg == .readOnlyVolume)
        let standardUser = UpdatePlanner.installLocationProblem(bundlePath: "/Applications/Cheese.app", isOnReadOnlyVolume: false, isFolderWritable: false, isBundleWritable: true)
        #expect(standardUser == .notWritable(folder: "/Applications"))
        let rootOwnedApp = UpdatePlanner.installLocationProblem(bundlePath: "/Applications/Cheese.app", isOnReadOnlyVolume: false, isFolderWritable: true, isBundleWritable: false)
        #expect(rootOwnedApp == .notWritable(folder: "/Applications"))
    }

    @Test func requiresTheSameTeamWhenThereIsOne() {
        #expect(UpdatePlanner.signingRequirement(bundleIdentifier: "com.maanitgupta.cheese", teamIdentifier: "8H5274FWRC")
            == #"anchor apple generic and identifier "com.maanitgupta.cheese" and certificate leaf[subject.OU] = "8H5274FWRC""#)
        #expect(UpdatePlanner.signingRequirement(bundleIdentifier: "com.maanitgupta.cheese", teamIdentifier: nil)
            == #"identifier "com.maanitgupta.cheese""#)
        #expect(UpdatePlanner.signingRequirement(bundleIdentifier: #"a"b"#, teamIdentifier: "")
            == #"identifier "a\"b""#)
    }

    @Test func reportsHowTheLastUpdateWent() {
        #expect(UpdatePlanner.launchResult(currentVersion: "2.4", pendingVersion: nil) == nil)
        #expect(UpdatePlanner.launchResult(currentVersion: "2.4", pendingVersion: "2.4") == .installed(version: "2.4"))
        #expect(UpdatePlanner.launchResult(currentVersion: "2.3", pendingVersion: "2.4") == .failed(version: "2.4"))
        #expect(UpdatePlanner.isFirstLaunchAfterUpgrade(previousVersion: "2.3", currentVersion: "2.4"))
        #expect(!UpdatePlanner.isFirstLaunchAfterUpgrade(previousVersion: nil, currentVersion: "2.4"))
        #expect(!UpdatePlanner.isFirstLaunchAfterUpgrade(previousVersion: "2.4", currentVersion: "2.4"))
    }
}

// MARK: - Checking a download

struct UpdateBundleCheckTests {
    private func makeApp(in folder: URL, bundleID: String = "com.maanitgupta.cheese", version: String = "99.0", executable: Bool = true) throws -> URL {
        let app = folder.appending(path: "Cheese.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Cheese", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        if executable {
            let binary = macOS.appending(path: "Cheese")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return app
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "UpdateBundleCheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func refusesBrokenOrForeignBundles() throws {
        let current = Bundle.main.bundleURL
        let id = "com.maanitgupta.cheese"
        #expect(throws: UpdateError.bundleMissingInArchive) {
            try SystemUpdateInstaller.validateBundle(at: try scratch().appending(path: "Cheese.app"), currentApp: current, currentBundleID: id)
        }
        #expect(throws: UpdateError.bundleIdentifierMismatch(expected: id, found: "com.example.evil")) {
            try SystemUpdateInstaller.validateBundle(at: try makeApp(in: scratch(), bundleID: "com.example.evil"), currentApp: current, currentBundleID: id)
        }
        #expect(throws: UpdateError.notNewer(found: "1.0")) {
            try SystemUpdateInstaller.validateBundle(at: try makeApp(in: scratch(), version: "1.0"), currentApp: current, currentBundleID: id)
        }
        #expect(throws: UpdateError.missingExecutable) {
            try SystemUpdateInstaller.validateBundle(at: try makeApp(in: scratch(), executable: false), currentApp: current, currentBundleID: id)
        }
        // Everything right but unsigned: refused.
        let unsigned = #expect(throws: UpdateError.self) {
            try SystemUpdateInstaller.validateBundle(at: try makeApp(in: scratch()), currentApp: current, currentBundleID: id)
        }
        if case .signatureInvalid = unsigned {} else {
            Issue.record("expected a signature error, got \(String(describing: unsigned))")
        }
    }

    @Test func theRunningAppMeetsItsOwnRequirementAndNotAnotherTeams() throws {
        // The test host is the built Cheese.app, signed like a release.
        let app = Bundle.main.bundleURL
        let id = try #require(Bundle.main.bundleIdentifier)
        let team = SystemUpdateInstaller.teamIdentifier(of: app)
        try SystemUpdateInstaller.verifySignature(of: app, requirement: UpdatePlanner.signingRequirement(bundleIdentifier: id, teamIdentifier: team))
        #expect(throws: UpdateError.self) {
            try SystemUpdateInstaller.verifySignature(of: app, requirement: UpdatePlanner.signingRequirement(bundleIdentifier: id, teamIdentifier: "ZZZZZZZZZZ"))
        }
        #expect(throws: UpdateError.self) {
            try SystemUpdateInstaller.verifySignature(of: app, requirement: UpdatePlanner.signingRequirement(bundleIdentifier: "com.example.other", teamIdentifier: team))
        }
    }

    @Test func hashesFiles() throws {
        let file = try scratch().appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        #expect(try SystemUpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - The swap script, run for real in a temporary folder

struct UpdateSwapScriptTests {
    private struct Box {
        let root: URL
        let target: URL
        let new: URL
        let staging: URL
        let log: URL
        let opened: URL
        let opener: URL

        init(newCopy: Bool = true) throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory.appending(path: "UpdateSwap-\(UUID().uuidString)", directoryHint: .isDirectory)
            let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
            staging = root.appending(path: UpdateSwapScript.stagingPrefix + "test", directoryHint: .isDirectory)
            target = applications.appending(path: "Cheese.app", directoryHint: .isDirectory)
            new = staging.appending(path: "Unpacked/Cheese.app", directoryHint: .isDirectory)
            log = root.appending(path: "Update.log")
            opened = root.appending(path: "opened")
            opener = root.appending(path: "open")
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appending(path: "version"))
            if newCopy {
                try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
                try Data("new".utf8).write(to: new.appending(path: "version"))
            } else {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            }
            try Data("#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"\(opened.path)\"\n".utf8).write(to: opener)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        }

        var installed: String? {
            (try? Data(contentsOf: target.appending(path: "version"))).map { String(decoding: $0, as: UTF8.self) }
        }

        var openedPaths: [String] {
            ((try? String(contentsOf: opened, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        @discardableResult
        func run(pid: Int32, target: URL? = nil) throws -> Int32 {
            let script = root.appending(path: "swap.sh")
            try UpdateSwapScript.text.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [script.path, String(pid), (target ?? self.target).path, new.path, staging.path, log.path, opener.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// A pid that's no longer running.
    private func finishedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func swapsTheNewCopyInAndReopensIt() throws {
        let box = try Box()
        #expect(try box.run(pid: finishedPID()) == 0)
        #expect(box.installed == "new")
        #expect(!box.exists(URL(filePath: box.target.path + UpdateSwapScript.backupSuffix)))
        #expect(!box.exists(box.staging))
        #expect(box.openedPaths == [box.target.path])
        #expect(try String(contentsOf: box.log, encoding: .utf8).contains("installed"))
    }

    @Test func waitsForCheeseToQuitFirst() throws {
        let box = try Box()
        let cheese = Process()
        cheese.executableURL = URL(filePath: "/bin/sleep")
        cheese.arguments = ["0.6"]
        try cheese.run()
        let start = Date.now
        #expect(try box.run(pid: cheese.processIdentifier) == 0)
        #expect(Date.now.timeIntervalSince(start) >= 0.4)
        #expect(box.installed == "new")
    }

    @Test func keepsTheOldCopyWhenTheNewOneIsMissing() throws {
        let box = try Box(newCopy: false)
        #expect(try box.run(pid: finishedPID()) == 1)
        #expect(box.installed == "old")
        #expect(!box.exists(box.staging))
        #expect(box.openedPaths == [box.target.path])
    }

    @Test func refusesArgumentsThatArentCheese() throws {
        let box = try Box()
        #expect(try box.run(pid: finishedPID(), target: box.root.appending(path: "Applications")) == 2)
        #expect(box.installed == "old")
        // Nothing deleted, nothing opened.
        #expect(box.exists(box.new))
        #expect(box.openedPaths.isEmpty)
    }

    @Test func survivesPathsWithQuotesAndSpaces() throws {
        let box = try Box()
        let odd = box.root.appending(path: #"My "Apps" $(touch pwned) 'x'"#, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let target = odd.appending(path: "Cheese.app", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: box.target, to: target)
        #expect(try box.run(pid: finishedPID(), target: target) == 0)
        #expect(String(decoding: try Data(contentsOf: target.appending(path: "version")), as: UTF8.self) == "new")
        #expect(!box.exists(box.root.appending(path: "pwned")))
    }
}

// MARK: - The service, with fakes

private struct FakeFetcher: ReleaseFetching {
    var result: Result<GitHubRelease, UpdateError>
    func latestRelease() async throws -> GitHubRelease { try result.get() }
}

private final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    var failure: UpdateError?
    var staged: [String] = []
    var swapped = 0

    func stage(_ offer: UpdateOffer, replacing currentApp: URL) async throws -> StagedUpdate {
        if let failure { throw failure }
        staged.append(offer.version)
        return StagedUpdate(app: currentApp, folder: currentApp.deletingLastPathComponent())
    }

    func launchSwap(_ staged: StagedUpdate, replacing currentApp: URL) throws {
        swapped += 1
    }
}

@MainActor
private final class FakePresenter: UpdatePresenting {
    var choice = UpdatePromptChoice.later
    var prompts: [String] = []
    var announcements: [String] = []
    var upToDate = 0
    var errors: [String] = []
    var toasts: [String] = []

    func promptToInstall(_ offer: UpdateOffer, currentVersion: String) -> UpdatePromptChoice {
        prompts.append(offer.version)
        return choice
    }

    func announce(_ offer: UpdateOffer, open: @escaping @MainActor () -> Void) { announcements.append(offer.version) }
    func showUpToDate(currentVersion: String) { upToDate += 1 }
    func showError(title: String, message: String, releasePage: URL?) { errors.append(title) }
    func showToast(_ message: String, systemImage: String, action: CheeseToast.Action?) { toasts.append(message) }
}

private struct NoPermissions: PermissionChecking {
    var granted: Set<Permission> = []
    func isGranted(_ permission: Permission) -> Bool { granted.contains(permission) }
}

@MainActor
struct UpdateServiceTests {
    private let presenter = FakePresenter()
    private let installer = FakeInstaller()
    private let defaults = UserDefaults(suiteName: "UpdateServiceTests-\(UUID().uuidString)") ?? .standard

    private static func release(_ tag: String) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: nil, body: "Notes", htmlURL: "https://github.com/maanit-gupta/Cheese/releases/tag/\(tag)",
                      draft: false, prerelease: false, assets: [])
    }

    private func service(
        latest: Result<GitHubRelease, UpdateError> = .success(release("v2.4")),
        current: String = "2.3",
        permissions: NoPermissions = NoPermissions(),
        reset: @escaping @MainActor (Permission) -> Void = { _ in },
        terminate: @escaping @MainActor () -> Void = {}
    ) throws -> UpdateService {
        let folder = FileManager.default.temporaryDirectory.appending(path: "UpdateService-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = folder.appending(path: "Cheese.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return UpdateService(
            currentVersion: current, currentApp: app, fetcher: FakeFetcher(result: latest), installer: installer,
            presenter: presenter, defaults: defaults, permissions: permissions, resetPermission: reset, terminate: terminate
        )
    }

    @Test func anAutomaticCheckAnnouncesANewVersionOnce() async throws {
        let updates = try service()
        await updates.checkForUpdates(userInitiated: false)
        #expect(updates.updateAvailable)
        #expect(updates.latestVersion == "2.4")
        #expect(updates.downloadURL?.lastPathComponent == "Cheese.zip")
        #expect(presenter.announcements == ["2.4"])
        #expect(presenter.prompts.isEmpty)
        #expect(defaults.object(forKey: PreferenceKey.updaterLastCheck) != nil)

        await updates.checkForUpdates(userInitiated: false)
        #expect(presenter.announcements == ["2.4"])
    }

    @Test func askingAlwaysAnswers() async throws {
        let updates = try service()
        defaults.set("2.4", forKey: PreferenceKey.updaterSkippedVersion)
        await updates.checkForUpdates(userInitiated: true)
        #expect(presenter.prompts == ["2.4"])

        let current = try service(latest: .success(Self.release("v2.3")))
        await current.checkForUpdates(userInitiated: true)
        #expect(!current.updateAvailable)
        #expect(presenter.upToDate == 1)

        let offline = try service(latest: .failure(.badResponse(status: 500)))
        await offline.checkForUpdates(userInitiated: false)
        #expect(presenter.errors.isEmpty)
        await offline.checkForUpdates(userInitiated: true)
        #expect(presenter.errors == ["Couldn't Check for Updates"])
    }

    @Test func skippingSilencesThatVersion() async throws {
        let updates = try service()
        presenter.choice = .skip
        await updates.checkForUpdates(userInitiated: true)
        #expect(defaults.string(forKey: PreferenceKey.updaterSkippedVersion) == "2.4")

        let next = try service()
        await next.checkForUpdates(userInitiated: false)
        #expect(next.updateAvailable)
        #expect(presenter.announcements.isEmpty)
    }

    @Test func installingStagesSwapsAndQuits() async throws {
        var quit = 0
        let updates = try service(terminate: { quit += 1 })
        await updates.checkForUpdates(userInitiated: false)
        await updates.downloadAndInstallUpdate()
        #expect(installer.staged == ["2.4"])
        #expect(installer.swapped == 1)
        #expect(quit == 1)
        #expect(defaults.string(forKey: PreferenceKey.updaterPendingVersion) == "2.4")
    }

    @Test func aFailedInstallLeavesCheeseRunning() async throws {
        var quit = 0
        installer.failure = .checksumMismatch
        let updates = try service(terminate: { quit += 1 })
        await updates.checkForUpdates(userInitiated: false)
        await updates.downloadAndInstallUpdate()
        #expect(quit == 0)
        #expect(installer.swapped == 0)
        #expect(!updates.isInstalling)
        #expect(presenter.errors == ["Couldn't Install the Update"])
        #expect(defaults.string(forKey: PreferenceKey.updaterPendingVersion) == nil)
    }

    @Test func theNextLaunchSaysHowItWent() throws {
        defaults.set("2.4", forKey: PreferenceKey.updaterPendingVersion)
        try service(current: "2.4").configureOnLaunch()
        #expect(presenter.toasts == ["Updated to Cheese 2.4"])
        #expect(defaults.string(forKey: PreferenceKey.updaterPendingVersion) == nil)

        defaults.set("2.5", forKey: PreferenceKey.updaterPendingVersion)
        try service(current: "2.4").configureOnLaunch()
        #expect(presenter.toasts.last == "Cheese 2.5 couldn't be installed")
    }

    @Test func theFirstLaunchAfterAnUpgradeClearsStalePermissions() throws {
        var reset: [Permission] = []
        defaults.set(false, forKey: PreferenceKey.updaterAutoCheck)
        // First launch ever: nothing to tidy.
        try service(current: "2.3", reset: { reset.append($0) }).configureOnLaunch()
        #expect(reset.isEmpty)

        defaults.set("2.3", forKey: PreferenceKey.updaterSkippedVersion)
        try service(current: "2.4", permissions: NoPermissions(granted: [.screenRecording]), reset: { reset.append($0) }).configureOnLaunch()
        #expect(reset == [.accessibility])
        #expect(defaults.string(forKey: PreferenceKey.updaterSkippedVersion) == nil)
        #expect(defaults.string(forKey: PreferenceKey.updaterLastLaunchedVersion) == "2.4")

        // Same version again: left alone.
        try service(current: "2.4", reset: { reset.append($0) }).configureOnLaunch()
        #expect(reset == [.accessibility])
    }

    @Test func automaticChecksFollowTheSetting() throws {
        let updates = try service()
        #expect(updates.autoCheckEnabled)
        updates.autoCheckEnabled = false
        #expect(defaults.object(forKey: PreferenceKey.updaterAutoCheck) as? Bool == false)
        #expect(try !service().autoCheckEnabled)
    }
}

// MARK: - End to end, opt-in

/// Stages a real release archive served over HTTP, then swaps it into a scratch copy of this app.
/// Build one newer than this app (`scripts/release.sh 2.4`, then put project.yml back), serve
/// `dist/` (`python3 -m http.server 8765 --bind 127.0.0.1 --directory dist`) and run with
/// `TEST_RUNNER_UPDATE_ARCHIVE_BASE=http://127.0.0.1:8765 … -only-testing:CheeseTests/UpdateEndToEndTests`.
struct UpdateEndToEndTests {
    private static let base = ProcessInfo.processInfo.environment["UPDATE_ARCHIVE_BASE"].flatMap(URL.init(string:))

    @Test(.enabled(if: base != nil)) func stagesVerifiesAndSwapsARealRelease() async throws {
        let base = try #require(Self.base)
        let current = Bundle.main.bundleURL
        let offer = UpdateOffer(
            version: "test", notes: "", releasePage: nil,
            archive: base.appending(path: UpdatePlanner.archiveName), checksum: base.appending(path: UpdatePlanner.checksumName)
        )
        let staged = try await SystemUpdateInstaller().stage(offer, replacing: current)
        let newVersion = try #require(Bundle(url: staged.app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(UpdatePlanner.isVersion(newVersion, newerThan: "2.3"))

        // A copy of this app in a scratch Applications folder stands in for /Applications/Cheese.app.
        let applications = FileManager.default.temporaryDirectory.appending(path: "UpdateE2E-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = applications.appending(path: "Cheese.app", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: current, to: target)

        let script = applications.appending(path: "swap.sh")
        try UpdateSwapScript.text.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path, "999999", target.path, staged.app.path, staged.folder.path, applications.appending(path: "log").path, "/usr/bin/true"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == newVersion)
        #expect(!FileManager.default.fileExists(atPath: staged.folder.path))
        let requirement = UpdatePlanner.signingRequirement(bundleIdentifier: "com.maanitgupta.cheese", teamIdentifier: SystemUpdateInstaller.teamIdentifier(of: current))
        try SystemUpdateInstaller.verifySignature(of: target, requirement: requirement)
    }
}

/// Asks the real GitHub API, as the app does: `TEST_RUNNER_UPDATE_LIVE=1 … -only-testing:CheeseTests/UpdateLiveTests`.
struct UpdateLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UPDATE_LIVE"] == "1"))
    func decodesTheLatestPublishedRelease() async throws {
        let release = try await GitHubReleaseFetcher(currentVersion: "0.1").latestRelease()
        #expect(AppVersion(release.tagName) != nil)
        #expect(release.assets.contains { $0.name == UpdatePlanner.archiveName })
        #expect(release.assets.contains { $0.name == UpdatePlanner.checksumName })
        let offer = try #require(UpdatePlanner.offer(from: release, currentVersion: "0.1"))
        #expect(offer.archive.absoluteString.hasSuffix("/\(release.tagName)/Cheese.zip"))
        #expect(UpdatePlanner.offer(from: release, currentVersion: offer.version) == nil)
    }
}
