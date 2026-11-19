import Testing
@testable import Cheese

struct AppRelocationPlannerTests {
    private let target = "/Applications/Cheese.app"
    private let folders = ["/Users/t/Downloads", "/Users/t/Desktop", "/Applications"]

    private func input(
        current: String,
        original: String? = nil,
        version: String = "2.5",
        installedVersion: String? = "2.5",
        candidates: [String] = [],
        running: [String] = [],
        writable: Bool = true,
        debug: Bool = false,
        relaunched: Bool = false
    ) -> AppRelocationPlanner.Input {
        AppRelocationPlanner.Input(
            currentPath: current,
            translocatedOriginalPath: original,
            currentVersion: AppVersion(version),
            targetPath: target,
            installed: installedVersion.map { AppBundleCandidate(path: target, version: AppVersion($0)) },
            canWriteTarget: writable,
            cleanupFolders: folders,
            candidates: candidates.map { AppBundleCandidate(path: $0, version: AppVersion("2.5")) },
            runningPaths: running,
            isDebugBuild: debug,
            isRunningTests: false,
            wasRelaunched: relaunched
        )
    }

    @Test func installedCopyWithNoDuplicatesDoesNothing() {
        #expect(AppRelocationPlanner.plan(input(current: target, candidates: [target])) == .none)
    }

    @Test func downloadedCopyMovesAndTrashesItselfAndOtherDuplicates() {
        let plan = AppRelocationPlanner.plan(input(
            current: "/Users/t/Downloads/Cheese.app",
            candidates: [target, "/Users/t/Downloads/Cheese.app", "/Users/t/Downloads/Cheese 2.app", "/Users/t/Desktop/Cheese.app"]
        ))
        #expect(plan == .relocate(trash: [
            "/Users/t/Downloads/Cheese.app", "/Users/t/Downloads/Cheese 2.app", "/Users/t/Desktop/Cheese.app",
        ]))
    }

    @Test func translocatedCopyTrashesTheRealDownloadNotTheMount() {
        let mount = "/private/var/folders/ab/T/AppTranslocation/1234/d/Cheese.app"
        let plan = AppRelocationPlanner.plan(input(
            current: mount, original: "/Users/t/Downloads/Cheese.app", candidates: [mount]
        ))
        #expect(plan == .relocate(trash: ["/Users/t/Downloads/Cheese.app"]))
    }

    @Test func installedCopyCleansUpStrays() {
        let plan = AppRelocationPlanner.plan(input(current: target, candidates: ["/Users/t/Desktop/Cheese 3.app"]))
        #expect(plan == .cleanUp(trash: ["/Users/t/Desktop/Cheese 3.app"]))
    }

    @Test func neverTouchesBuildProductsRunningCopiesOrOtherFolders() {
        let plan = AppRelocationPlanner.plan(input(current: target, candidates: [
            "/Users/t/Library/Developer/Xcode/DerivedData/Cheese/Build/Products/Debug/Cheese.app",
            "/Users/t/Cheese/build/ReleaseData/Build/Products/Release/Cheese.app",
            "/Users/t/Cheese/dist/Cheese.app",
            "/Users/t/Projects/Cheese.app",
            "/Users/t/Downloads/Old/Cheese.app",
            "/Users/t/.Trash/Cheese.app",
            "/Users/t/Downloads/Cheese.app",
        ], running: ["/Users/t/Downloads/Cheese.app"]))
        #expect(plan == .none)
    }

    @Test func debugBuildsAndDevelopmentPathsAreLeftAlone() {
        #expect(AppRelocationPlanner.plan(input(current: "/Users/t/Downloads/Cheese.app", debug: true)) == .none)
        #expect(AppRelocationPlanner.plan(input(
            current: "/Users/t/Library/Developer/Xcode/DerivedData/X/Build/Products/Release/Cheese.app"
        )) == .none)
        #expect(AppRelocationPlanner.plan(input(current: "/Users/t/Cheese/build/ReleaseData/Build/Products/Release/Cheese.app")) == .none)
    }

    @Test func relaunchedCopyNeverLoops() {
        #expect(AppRelocationPlanner.plan(input(current: "/Users/t/Downloads/Cheese.app", relaunched: true)) == .none)
    }

    @Test func unwritableApplicationsLeavesTheCopyWhereItIs() {
        #expect(AppRelocationPlanner.plan(input(current: "/Users/t/Downloads/Cheese.app", writable: false)) == .none)
    }

    @Test func olderDownloadOpensTheNewerInstalledCopy() {
        let plan = AppRelocationPlanner.plan(input(
            current: "/Users/t/Downloads/Cheese.app", version: "2.4", installedVersion: "2.5"
        ))
        #expect(plan == .openInstalled(trash: ["/Users/t/Downloads/Cheese.app"]))
    }

    @Test func freshInstallWithoutAnExistingCopyRelocates() {
        let plan = AppRelocationPlanner.plan(input(current: "/Users/t/Desktop/Cheese.app", installedVersion: nil))
        #expect(plan == .relocate(trash: ["/Users/t/Desktop/Cheese.app"]))
    }
}
