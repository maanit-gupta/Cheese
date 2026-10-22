import AppKit
import SwiftUI

/// Opens annotation editor windows. Each image gets its own window.
@MainActor
final class AnnotationEditor {
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func open(_ image: CapturedImage) {
        let model = EditorModel(image: image)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.initialContentSize(for: image)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cheese Editor"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AnnotationEditorView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        window.setContentSize(Self.initialContentSize(for: image))
        window.center()

        let id = ObjectIdentifier(window)
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowWillClose(id)
            }
        }
        windows[id] = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func windowWillClose(_ id: ObjectIdentifier) {
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[id] = nil
    }

    /// The image at its natural point size plus the toolbar, limited to most of the screen.
    private static func initialContentSize(for image: CapturedImage) -> CGSize {
        let visible = (Screens.underMouse ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let toolbarHeight: CGFloat = 46
        let width = min(max(image.pointSize.width + 40, 640), visible.width * 0.9)
        let height = min(max(image.pointSize.height + toolbarHeight + 40, 420), visible.height * 0.9)
        return CGSize(width: width, height: height)
    }
}
