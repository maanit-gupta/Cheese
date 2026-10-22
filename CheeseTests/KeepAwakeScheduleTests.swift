import Foundation
import Testing
@testable import Cheese

struct KeepAwakeScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
    }

    @Test func laterTodayStaysToday() {
        let target = KeepAwakeSchedule.targetDate(hour: 18, minute: 30, after: date(22, 14, 5), calendar: calendar)
        #expect(target == date(22, 18, 30))
    }

    @Test func earlierTimeMeansTomorrow() {
        let target = KeepAwakeSchedule.targetDate(hour: 9, minute: 0, after: date(22, 14, 5), calendar: calendar)
        #expect(target == date(23, 9, 0))
    }

    @Test func theCurrentMinuteMeansTomorrow() {
        let target = KeepAwakeSchedule.targetDate(hour: 14, minute: 5, after: date(22, 14, 5, 30), calendar: calendar)
        #expect(target == date(23, 14, 5))
    }

    @Test func midnightRollsOverTheMonth() {
        let target = KeepAwakeSchedule.targetDate(hour: 0, minute: 15, after: date(31, 23, 50), calendar: calendar)
        #expect(target == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 15)))
    }

    @Test(arguments: [
        (4_320.0, "1h 12m"),
        (4_290.0, "1h 12m"),
        (3_600.0, "1h"),
        (3_601.0, "1h 1m"),
        (7_200.0, "2h"),
        (2_520.0, "42m"),
        (2_490.0, "42m"),
        (61.0, "2m"),
        (60.0, "60s"),
        (42.3, "43s"),
        (0.4, "1s"),
        (0.0, "0s"),
    ])
    func indicatorText(_ remaining: TimeInterval, _ expected: String) {
        #expect(KeepAwakeSchedule.indicatorText(remaining: remaining) == expected)
    }

    @Test(arguments: [
        (4_320.0, 60.0),
        (4_290.0, 30.0),
        (125.0, 5.0),
        (60.0, 1.0),
        (42.25, 0.25),
        (0.0, 0.0),
    ])
    func refreshesWhenTheTextWouldChange(_ remaining: TimeInterval, _ expected: TimeInterval) {
        #expect(abs(KeepAwakeSchedule.nextRefresh(remaining: remaining) - expected) < 0.0001)
    }

    @Test func textChangesExactlyAtEachRefresh() {
        var remaining: TimeInterval = 3_725.5
        while remaining > 0 {
            let before = KeepAwakeSchedule.indicatorText(remaining: remaining)
            let step = KeepAwakeSchedule.nextRefresh(remaining: remaining)
            #expect(step > 0)
            // Just before the refresh the text hasn't changed; at it, it has.
            #expect(KeepAwakeSchedule.indicatorText(remaining: remaining - step + 0.001) == before)
            remaining -= step
            if remaining > 0 {
                #expect(KeepAwakeSchedule.indicatorText(remaining: remaining) != before)
            }
        }
    }
}
