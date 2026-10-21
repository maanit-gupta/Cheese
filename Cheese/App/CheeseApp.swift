import AppKit

@main
@MainActor
enum CheeseApp {
    // NSApplication holds its delegate weakly, so keep it alive here.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
