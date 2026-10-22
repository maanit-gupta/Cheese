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
        #expect(WelcomeStep.finish.isLast)
        #expect(WelcomeStep.finish.next == nil)
        #expect(WelcomeStep.shortcuts.previous == .permissions)
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
