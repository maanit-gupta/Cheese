import CoreGraphics
import Testing
@testable import Cheese

/// Multi-display layouts, in AppKit coordinates, with the expected Quartz equivalents.
enum Layouts {
    static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Sits above the primary, shifted left.
    static let above = CGRect(x: -240, y: 900, width: 1920, height: 1080)
    /// Sits below the primary.
    static let below = CGRect(x: 0, y: -800, width: 1280, height: 800)
    /// Sits left of the primary, taller and lower.
    static let left = CGRect(x: -2560, y: -270, width: 2560, height: 1440)
    /// Sits right of the primary.
    static let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    static let all = [primary, above, below, left, right]
}

struct DisplayGeometryTests {
    private let height = Layouts.primary.height

    @Test func primaryHeightComesFromTheDisplayAtOrigin() {
        #expect(DisplayGeometry.primaryDisplayHeight(appKitFrames: [Layouts.above, Layouts.primary]) == 900)
        #expect(DisplayGeometry.primaryDisplayHeight(appKitFrames: []) == 0)
    }

    @Test func primaryDisplayFlipsOntoItself() {
        #expect(DisplayGeometry.quartzRect(fromAppKit: Layouts.primary, primaryDisplayHeight: height) == Layouts.primary)
    }

    @Test(arguments: [
        (Layouts.above, CGRect(x: -240, y: -1080, width: 1920, height: 1080)),
        (Layouts.below, CGRect(x: 0, y: 900, width: 1280, height: 800)),
        (Layouts.left, CGRect(x: -2560, y: -270, width: 2560, height: 1440)),
        (Layouts.right, CGRect(x: 1440, y: -180, width: 1920, height: 1080)),
    ])
    func secondaryDisplaysConvert(appKit: CGRect, quartz: CGRect) {
        #expect(DisplayGeometry.quartzRect(fromAppKit: appKit, primaryDisplayHeight: height) == quartz)
        #expect(DisplayGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: height) == appKit)
    }

    @Test func windowRectsRoundTrip() {
        // A window straddling the primary and the display above it.
        let window = CGRect(x: 100, y: 800, width: 600, height: 400)
        let quartz = DisplayGeometry.quartzRect(fromAppKit: window, primaryDisplayHeight: height)
        #expect(quartz == CGRect(x: 100, y: -300, width: 600, height: 400))
        #expect(DisplayGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: height) == window)
    }

    @Test func pointsConvert() {
        #expect(DisplayGeometry.quartzPoint(fromAppKit: CGPoint(x: 10, y: 0), primaryDisplayHeight: height) == CGPoint(x: 10, y: 900))
        #expect(DisplayGeometry.appKitPoint(fromQuartz: CGPoint(x: -5, y: -100), primaryDisplayHeight: height) == CGPoint(x: -5, y: 1000))
    }

    @Test func negativeSizedRectsAreStandardized() {
        let rect = CGRect(x: 100, y: 100, width: -50, height: -20)
        #expect(DisplayGeometry.quartzRect(fromAppKit: rect, primaryDisplayHeight: height) == CGRect(x: 50, y: 800, width: 50, height: 20))
    }

    @Test func findsDisplayContainingPoint() {
        let frames = Layouts.all
        #expect(DisplayGeometry.indexOfDisplay(containing: CGPoint(x: 10, y: 10), frames: frames) == 0)
        #expect(DisplayGeometry.indexOfDisplay(containing: CGPoint(x: 0, y: 1500), frames: frames) == 1)
        #expect(DisplayGeometry.indexOfDisplay(containing: CGPoint(x: 10, y: -10), frames: frames) == 2)
        #expect(DisplayGeometry.indexOfDisplay(containing: CGPoint(x: -1000, y: 0), frames: frames) == 3)
        // In the gap right of the display below: nearest is the primary or the right display, never empty.
        #expect(DisplayGeometry.indexOfDisplay(containing: CGPoint(x: 1400, y: -10), frames: frames) != nil)
        #expect(DisplayGeometry.indexOfDisplay(containing: .zero, frames: []) == nil)
    }

    @Test func picksDisplayHoldingMostOfAWindow() {
        let frames = Layouts.all
        let mostlyAbove = CGRect(x: 0, y: 850, width: 400, height: 300)
        #expect(DisplayGeometry.indexOfDisplay(bestMatching: mostlyAbove, frames: frames) == 1)
        let offscreen = CGRect(x: 10_000, y: 10_000, width: 10, height: 10)
        #expect(DisplayGeometry.indexOfDisplay(bestMatching: offscreen, frames: frames) != nil)
    }
}
