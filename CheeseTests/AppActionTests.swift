import Testing
@testable import Cheese

struct AppActionTests {
    @Test(arguments: Hotkey.allCases)
    func hotkeyRoundTrips(_ hotkey: Hotkey) {
        #expect(AppAction(hotkey).hotkey == hotkey)
    }

    @Test(arguments: [AppAction.clearHistory, .clearAll, .openSettings, .quit])
    func menuOnlyActionsHaveNoHotkey(_ action: AppAction) {
        #expect(action.hotkey == nil)
        #expect(action.requiredPermissions.isEmpty)
    }

    @Test(arguments: [AppAction.captureRegion, .captureFullScreen, .captureWindow, .ocrRegion])
    func captureNeedsScreenRecording(_ action: AppAction) {
        #expect(action.requiredPermissions == [.screenRecording])
    }

    @Test(arguments: [AppAction.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow])
    func snappingNeedsAccessibility(_ action: AppAction) {
        #expect(action.requiredPermissions == [.accessibility])
    }

    @Test func scrollingCaptureNeedsBoth() {
        #expect(AppAction.scrollingCapture.requiredPermissions == [.screenRecording, .accessibility])
    }

    @Test func openingHistoryNeedsNothing() {
        // Without Accessibility, history still opens and pasting falls back to copy-only.
        #expect(AppAction.openHistory.requiredPermissions.isEmpty)
    }
}
