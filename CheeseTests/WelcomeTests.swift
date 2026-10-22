import Testing
@testable import Cheese

struct WelcomeTests {
    @Test func stepsRunInOrder() {
        var step = WelcomeStep.intro
        var visited = [step]
        while let next = step.next {
            step = next
            visited.append(step)
        }
        #expect(visited == WelcomeStep.allCases)
    }

    @Test func firstAndLastSteps() {
        #expect(WelcomeStep.intro.isFirst)
        #expect(WelcomeStep.intro.previous == nil)
        #expect(WelcomeStep.permissions.isLast)
        #expect(WelcomeStep.permissions.next == nil)
        #expect(WelcomeStep.tools.previous == .intro)
    }

    @Test func atMostThreeScreens() {
        #expect(WelcomeStep.allCases.count <= 3)
    }
}

struct VerbTests {
    @Test func everyToolSitsUnderExactlyOneVerb() {
        let grouped = Verb.allCases.flatMap(\.modules)
        #expect(grouped.count == ModuleID.allCases.count)
        #expect(Set(grouped) == Set(ModuleID.allCases))
    }

    @Test func verbsMatchTheBrandTable() {
        #expect(Verb.copy.modules == [.clipboard, .qr])
        #expect(Verb.capture.modules == [.screenshots, .ocr, .scrollingCapture])
        #expect(Verb.draw.modules == [.drawOnScreen])
        #expect(Verb.convert.modules == [.files])
        #expect(Verb.share.modules == [.shelf, .share])
        #expect(Verb.control.modules == [.windowSnapping, .keepAwake, .appHotkeys, .commandPalette, .appSweep])
    }

    @Test func everyToolHasABlurb() {
        #expect(ModuleID.allCases.allSatisfy { !$0.blurb.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func brandNeverCountsFeatures() {
        let text = [Brand.tagline, Brand.subline, Brand.privacy] + ModuleID.allCases.map(\.blurb)
        let counted = text.filter { $0.range(of: #"\b\d+[- ]?(in-1|tools|features)\b"#, options: .regularExpression) != nil }
        #expect(counted.isEmpty)
    }
}

struct PermissionPlanTests {
    @Test func asksOnlyForWhatEnabledToolsNeed() {
        #expect(PermissionPlan.plan(for: []).isEmpty)
        #expect(PermissionPlan.plan(for: [.keepAwake, .qr, .shelf]).isEmpty)
        #expect(PermissionPlan.plan(for: [.screenshots]) == [.screenRecording])
        #expect(PermissionPlan.plan(for: [.windowSnapping, .clipboard]) == [.accessibility])
        #expect(PermissionPlan.plan(for: [.share]) == [.notifications, .localNetwork])
        #expect(PermissionPlan.plan(for: [.files]) == [.notifications, .finderExtension])
    }

    @Test func eachNeedOnceInAFixedOrder() {
        let all = PermissionPlan.plan(for: Set(ModuleID.allCases))
        #expect(all == PermissionNeed.allCases)
        #expect(PermissionPlan.plan(for: [.scrollingCapture, .ocr]) == [.screenRecording, .accessibility])
    }

    @Test func namesTheToolsThatNeedEachPermission() {
        let enabled: Set<ModuleID> = [.screenshots, .ocr, .clipboard, .share]
        #expect(PermissionPlan.tools(needing: .screenRecording, among: enabled) == [.screenshots, .ocr])
        #expect(PermissionPlan.tools(needing: .localNetwork, among: enabled) == [.share])
        #expect(PermissionPlan.tools(needing: .finderExtension, among: enabled).isEmpty)
    }
}

struct StartupSetupTests {
    @Test func asksOnlyForWhatsStillOff() {
        #expect(StartupSetupItem.pending(accessibilityGranted: false, launchAtLoginEnabled: false, skipped: false) == [.accessibility, .launchAtLogin])
        #expect(StartupSetupItem.pending(accessibilityGranted: true, launchAtLoginEnabled: false, skipped: false) == [.launchAtLogin])
        #expect(StartupSetupItem.pending(accessibilityGranted: false, launchAtLoginEnabled: true, skipped: false) == [.accessibility])
        #expect(StartupSetupItem.pending(accessibilityGranted: true, launchAtLoginEnabled: true, skipped: false).isEmpty)
    }

    @Test func dontAskAgainSilencesIt() {
        #expect(StartupSetupItem.pending(accessibilityGranted: false, launchAtLoginEnabled: false, skipped: true).isEmpty)
    }
}
