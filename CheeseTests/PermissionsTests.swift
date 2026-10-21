import Testing
@testable import Cheese

private struct FakePermissions: PermissionChecking {
    let granted: Set<Permission>

    func isGranted(_ permission: Permission) -> Bool {
        granted.contains(permission)
    }
}

struct PermissionsTests {
    @Test func missingKeepsRequiredOrder() {
        let none = FakePermissions(granted: [])
        #expect(none.missing(from: [.screenRecording, .accessibility]) == [.screenRecording, .accessibility])
    }

    @Test func missingSkipsGranted() {
        let screenOnly = FakePermissions(granted: [.screenRecording])
        #expect(screenOnly.missing(from: [.screenRecording, .accessibility]) == [.accessibility])
        #expect(screenOnly.missing(from: [.screenRecording]).isEmpty)
        #expect(screenOnly.missing(from: []).isEmpty)
    }

    @Test(arguments: Permission.allCases)
    func everyPermissionHasASettingsPane(_ permission: Permission) {
        #expect(permission.settingsURL?.scheme == "x-apple.systempreferences")
    }
}
