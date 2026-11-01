import Foundation
import Testing
@testable import Cheese

@MainActor
struct CaffeinateControllerTests {
    @Test func aLidOpenSessionHoldsTimedAssertionsAndNeverTouchesTheHelper() {
        let harness = CaffeinateHarness(lidClosed: false)
        harness.controller.start(.preset(.oneHour))

        #expect(harness.controller.session == .init(duration: .preset(.oneHour), deadline: harness.clock.now.addingTimeInterval(3600)))
        #expect(harness.assertions.holds == [3600])
        #expect(harness.helper.requests.isEmpty && harness.helper.installs == 0)
        #expect(harness.indicator == "1h")
        #expect(harness.toasts == ["Caffeinating for 1 hour"])
    }

    @Test func indefiniteAssertionsHaveNoTimeout() {
        let harness = CaffeinateHarness(lidClosed: false)
        harness.controller.start(.indefinitely)
        #expect(harness.assertions.holds == [nil])
        #expect(harness.indicator == "∞")
    }

    @Test func aLidClosedSessionAsksTheHelperAndSaysSo() async {
        let harness = CaffeinateHarness(batteryFloor: 15)
        harness.controller.start(.preset(.thirtyMinutes))
        await harness.settle()

        #expect(harness.helper.installs == 0)
        #expect(harness.helper.requests.map(\.floor) == [15])
        #expect(harness.helper.requests.first?.deadline == harness.clock.now.addingTimeInterval(1800))
        #expect(harness.controller.session?.coversLid == true)
        #expect(harness.indicator == "Lid 30m")
        #expect(harness.toasts == ["Caffeinating for 30 minutes, even with the lid closed"])
    }

    @Test func theFirstLidClosedSessionInstallsTheHelperOnce() async {
        let harness = CaffeinateHarness()
        harness.helper.status = .notInstalled
        harness.controller.start(.indefinitely)
        await harness.settle()
        harness.controller.start(.preset(.twoHours))
        await harness.settle()

        #expect(harness.helper.installs == 1)
        #expect(harness.helper.requests.count == 2)
        #expect(harness.helper.requests.last?.deadline == harness.clock.now.addingTimeInterval(7200))
        #expect(harness.controller.session?.coversLid == true)
    }

    @Test func anOutdatedHelperIsReinstalled() async {
        let harness = CaffeinateHarness()
        harness.helper.status = .outdated
        harness.controller.start(.indefinitely)
        await harness.settle()
        #expect(harness.helper.installs == 1)
        #expect(harness.controller.session?.coversLid == true)
    }

    @Test func cancellingThePasswordKeepsALidOpenSession() async {
        let harness = CaffeinateHarness()
        harness.helper.status = .notInstalled
        harness.helper.installResult = .cancelled
        harness.controller.start(.preset(.oneHour))
        await harness.settle()

        #expect(harness.controller.isActive)
        #expect(harness.controller.session?.coversLid == false)
        #expect(harness.helper.requests.isEmpty)
        #expect(harness.assertions.isHeld)
        #expect(harness.toasts == ["Caffeinating for 1 hour. Closing the lid will still sleep the Mac."])
    }

    @Test func aHelperMacOSWontRunIsReportedAndWithdrawn() async {
        let harness = CaffeinateHarness()
        harness.helper.takesEffect = false
        harness.controller.start(.indefinitely)
        await harness.settle()

        #expect(harness.controller.isHelperBlocked)
        #expect(harness.controller.session?.coversLid == false)
        #expect(harness.helper.withdrawals == [false])
        #expect(harness.toasts.last?.contains("isn't letting Cheese's helper run") == true)
    }

    @Test func turningOffWithdrawsWithoutSleeping() async {
        let harness = CaffeinateHarness()
        harness.controller.start(.indefinitely)
        await harness.settle()
        harness.controller.turnOff()

        #expect(!harness.controller.isActive)
        #expect(harness.helper.withdrawals == [false])
        #expect(!harness.assertions.isHeld)
        #expect(harness.indicator == nil)
        #expect(harness.toasts.last == "Caffeinate is off")
    }

    @Test func runningOutEndsAsExpiredSoAShutMacSleeps() async {
        let harness = CaffeinateHarness()
        harness.controller.start(.preset(.thirtyMinutes))
        await harness.settle()

        harness.clock.advance(29 * 60 + 30)
        #expect(harness.controller.checkSession() == 1)
        #expect(harness.indicator == "Lid 30s")

        harness.clock.advance(30)
        #expect(harness.controller.checkSession() == nil)
        #expect(!harness.controller.isActive)
        #expect(harness.helper.withdrawals == [true])
        #expect(harness.toasts.last == "Caffeinate ended")
    }

    @Test func theBatteryFloorEndsTheSessionAsExpired() async {
        let harness = CaffeinateHarness(batteryFloor: 10)
        harness.battery.state = BatteryState(isOnBattery: true, percent: 40)
        harness.controller.start(.indefinitely)
        await harness.settle()
        #expect(harness.controller.checkSession() == 60)

        harness.battery.state = BatteryState(isOnBattery: true, percent: 10)
        #expect(harness.controller.checkSession() == nil)
        #expect(harness.helper.withdrawals == [true])
        #expect(harness.toasts.last == "Caffeinate ended: battery at 10%")
    }

    @Test func chargingIgnoresTheFloorAndALowBatteryWontStart() {
        let charging = CaffeinateHarness(lidClosed: false, batteryFloor: 10)
        charging.battery.state = BatteryState(isOnBattery: false, percent: 5)
        charging.controller.start(.indefinitely)
        #expect(charging.controller.isActive)

        let low = CaffeinateHarness(lidClosed: false, batteryFloor: 10)
        low.battery.state = BatteryState(isOnBattery: true, percent: 8)
        low.controller.start(.indefinitely)
        #expect(!low.controller.isActive)
        #expect(low.toasts.first?.hasPrefix("Battery is at 8%") == true)
    }

    @Test func theLidToggleAppliesToTheRunningSession() async {
        let harness = CaffeinateHarness(lidClosed: false)
        harness.controller.start(.indefinitely)
        harness.controller.setCoversLid(true)
        await harness.settle()
        #expect(harness.controller.session?.coversLid == true)
        #expect(harness.defaults.bool(forKey: PreferenceKey.caffeinateLidClosed))

        harness.controller.setCoversLid(false)
        #expect(harness.controller.session?.coversLid == false)
        #expect(harness.helper.withdrawals == [false])
        #expect(harness.indicator == "∞")
        #expect(harness.controller.isActive)
    }

    @Test func aPasswordAnsweredAfterTurningOffChangesNothing() async {
        let harness = CaffeinateHarness()
        harness.helper.status = .notInstalled
        harness.helper.holdsInstall = true
        harness.controller.start(.indefinitely)
        try? await Task.sleep(for: .milliseconds(10))
        harness.controller.turnOff()
        harness.helper.finishInstall()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(harness.helper.requests.isEmpty)
        #expect(!harness.controller.isActive)
    }

    @Test func stoppingEndsQuietly() async {
        let harness = CaffeinateHarness()
        harness.controller.start(.indefinitely)
        await harness.settle()
        let toasts = harness.toasts.count
        harness.controller.stop()
        #expect(!harness.controller.isActive)
        #expect(harness.helper.withdrawals == [false])
        #expect(harness.toasts.count == toasts)
    }

    @Test func removingTheHelperStopsCoveringTheLid() async {
        let harness = CaffeinateHarness()
        harness.controller.start(.indefinitely)
        await harness.settle()
        await harness.controller.removeHelper()

        #expect(harness.helper.uninstalls == 1)
        #expect(harness.controller.helperStatus == .notInstalled)
        #expect(!harness.controller.wantsLid)
        #expect(harness.controller.session?.coversLid == false)
    }

    @Test func aTimeAlreadyPassedDoesNothing() {
        let harness = CaffeinateHarness()
        harness.controller.start(.until(harness.clock.now.addingTimeInterval(-5)))
        #expect(!harness.controller.isActive)
        #expect(harness.assertions.holds.isEmpty)
    }

    @Test func failedAssertionsLeaveItOff() {
        let harness = CaffeinateHarness()
        harness.assertions.succeeds = false
        harness.controller.start(.indefinitely)
        #expect(!harness.controller.isActive)
        #expect(harness.toasts == ["Couldn't keep your Mac awake"])
    }

    @Test func readsTheInternalBattery() {
        let descriptions: [[String: Any]] = [
            ["Type": "UPS", "Current Capacity": 1, "Max Capacity": 100],
            ["Type": "InternalBattery", "Current Capacity": 37, "Max Capacity": 100, "Power Source State": "Battery Power"],
        ]
        #expect(BatteryState.from(descriptions: descriptions) == BatteryState(isOnBattery: true, percent: 37))
        #expect(BatteryState.from(descriptions: []) == nil)
        #expect(BatteryState(isOnBattery: true, percent: 10).isAtOrBelow(floor: 10))
        #expect(!BatteryState(isOnBattery: true, percent: 10).isAtOrBelow(floor: 0))
    }

    @Test func durationsAndPhrases() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(CaffeinateDuration.preset(.twoHours).deadline(from: start) == Date(timeIntervalSince1970: 7200))
        #expect(CaffeinateDuration.indefinitely.deadline(from: start) == nil)
        #expect(CaffeinateDuration.indefinitely.phrase() == "until you turn it off")
        #expect(CaffeinateDuration.preset(.thirtyMinutes).phrase() == "for 30 minutes")
    }
}
