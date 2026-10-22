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
