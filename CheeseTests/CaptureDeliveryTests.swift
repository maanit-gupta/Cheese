import Foundation
import Testing
@testable import Cheese

struct CaptureDeliveryTests {
    @Test func destinationsCopyAndSaveAsNamed() {
        #expect(CaptureDestination.clipboard.copies && !CaptureDestination.clipboard.saves)
        #expect(!CaptureDestination.folder.copies && CaptureDestination.folder.saves)
        #expect(CaptureDestination.clipboardAndFolder.copies && CaptureDestination.clipboardAndFolder.saves)
    }

    @Test func toastSaysWhatHappened() {
        let name = "Cheese 2026-10-26 at 09.30.00.png"
        #expect(CaptureDeliveryOutcome(copied: true, savedName: nil, saveFailed: false).message(noun: "Screenshot")
            == "Screenshot copied")
        #expect(CaptureDeliveryOutcome(copied: false, savedName: name, saveFailed: false).message(noun: "Scrolling capture")
            == "Saved \(name)")
        #expect(CaptureDeliveryOutcome(copied: true, savedName: name, saveFailed: false).message(noun: "Snapshot")
            == "Snapshot copied and saved as \(name)")
    }

    @Test func aFailedSaveFallsBackToTheClipboard() {
        let outcome = CaptureDeliveryOutcome(copied: true, savedName: nil, saveFailed: true)
        #expect(outcome.message(noun: "Scrolling capture") == "Couldn't save the scrolling capture — copied it instead")
        #expect(outcome.isProblem)
        #expect(CaptureDeliveryOutcome(copied: false, savedName: nil, saveFailed: true).message(noun: "Screenshot") == nil)
    }

    @Test func preferenceDefaultsToTheClipboard() throws {
        let suite = "CaptureDeliveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults: defaults).captureDestination == .clipboard)
        defaults.set("folder", forKey: PreferenceKey.captureDestination)
        #expect(Preferences(defaults: defaults).captureDestination == .folder)
        defaults.set("printer", forKey: PreferenceKey.captureDestination)
        #expect(Preferences(defaults: defaults).captureDestination == .clipboard)
    }
}
