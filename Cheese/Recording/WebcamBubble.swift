@preconcurrency import AVFoundation
import AppKit

/// The camera in a mirrored circle over the recording. It starts in the bottom-right corner of
/// the recorded area, can be dragged anywhere (its spot is remembered), and its right-click menu
/// picks Small, Medium or Large. It's part of the recording.
@MainActor
final class WebcamBubble {
    enum Size: Int, CaseIterable {
        case small = 120
        case medium = 180
        case large = 240

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }

        var points: CGFloat { CGFloat(rawValue) }
    }

    static let positionKey = "webcam"

    private var window: NSPanel?
    private var feed: CameraFeed?
    private var moveObserver: NSObjectProtocol?

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    var isShowing: Bool { window != nil }

    /// Shows the camera over `region` (AppKit global points). False when there's no camera.
    @discardableResult
    func show(over region: CGRect) -> Bool {
        guard window == nil else { return true }
        guard let feed = CameraFeed() else { return false }
        self.feed = feed
        let size = Self.storedSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: CGSize(width: size.points, height: size.points)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Before `level`: setting it afterwards would put the level back to `.floating`.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = WebcamView(session: feed.session) { [weak self] size in self?.resize(to: size) }
        view.frame = CGRect(origin: .zero, size: CGSize(width: size.points, height: size.points))
        panel.contentView = view
        panel.setFrameOrigin(Self.origin(for: size.points, over: region))
        panel.orderFrontRegardless()
        window = panel
        feed.start()

        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                if let panel { PanelPositions.save(panel.frame.origin, forKey: Self.positionKey) }
            }
        }
        return true
    }

    func hide() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = nil
        feed?.stop()
        feed = nil
        window?.close()
        window = nil
    }

    /// Where the user last put it, if that's inside the recorded area; otherwise its bottom-right
    /// corner, 24 pt in.
    static func origin(for side: CGFloat, over region: CGRect) -> CGPoint {
        if let saved = PanelPositions.origin(forKey: positionKey),
           region.contains(CGRect(origin: saved, size: CGSize(width: side, height: side))) {
            return saved
        }
        let inset = DesignTokens.Spacing.xxxLarge
        return CGPoint(x: region.maxX - side - inset, y: region.minY + inset)
    }

    static var storedSize: Size {
        Size(rawValue: UserDefaults.standard.integer(forKey: PreferenceKey.webcamSize)) ?? .medium
    }

    private func resize(to size: Size) {
        UserDefaults.standard.set(size.rawValue, forKey: PreferenceKey.webcamSize)
        guard let window else { return }
        // Grows and shrinks around its bottom-right corner, which is where it usually sits.
        let old = window.frame
        let side = size.points
        window.setFrame(CGRect(x: old.maxX - side, y: old.minY, width: side, height: side), display: true)
    }
}

/// A camera session, run off the main thread as AVFoundation asks.
private final class CameraFeed: @unchecked Sendable {
    let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.maanitgupta.cheese.webcam")

    init?() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        self.session = session
    }

    func start() {
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }
}

/// The round, mirrored preview, with the size menu on right-click.
private final class WebcamView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let onResize: (WebcamBubble.Size) -> Void

    init(session: AVCaptureSession, onResize: @escaping (WebcamBubble.Size) -> Void) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        self.onResize = onResize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 3
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer?.addSublayer(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        preview.frame = bounds
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let current = WebcamBubble.storedSize
        for size in WebcamBubble.Size.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size.rawValue
            item.state = size == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let size = WebcamBubble.Size(rawValue: sender.tag) {
            onResize(size)
        }
    }
}
