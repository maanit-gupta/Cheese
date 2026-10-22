import AppKit
import Synchronization
import WebKit
import os

/// A hidden WKWebView that can only see local content: a content rule list blocks every load that
/// isn't `file:`, `data:`, `blob:` or `about:`, navigation to anything else is cancelled, and the
/// data store is non-persistent. Used to render documents and print them to PDF.
@MainActor
final class LocalWebView: NSObject, WKNavigationDelegate {
    enum WebError: LocalizedError {
        case loadFailed(String)
        case printFailed
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .loadFailed(reason): "The document couldn't be rendered: \(reason)"
            case .printFailed: "The PDF couldn't be created."
            case .timedOut: "Rendering took longer than a minute, so it was stopped."
            }
        }
    }

    /// Blocks everything, then lets local schemes back in.
    nonisolated static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
    nonisolated static let allowedSchemes: Set<String> = ["file", "data", "blob", "about"]
    private static var compiledRules: WKContentRuleList?

    let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    /// The print system reports completion on its own thread.
    private nonisolated let printContinuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    /// - Parameters:
    ///   - width: the layout width in points.
    ///   - allowsJavaScript: off for user HTML; on for Cheese's own renderer page.
    ///   - configure: adds script message handlers and the like before the view is created.
    static func make(width: CGFloat, allowsJavaScript: Bool, configure: (WKWebViewConfiguration) -> Void = { _ in }) async throws -> LocalWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.userContentController.add(try await rules())
        configure(configuration)
        return LocalWebView(configuration: configuration, width: width)
    }

    private static func rules() async throws -> WKContentRuleList {
        if let compiledRules {
            return compiledRules
        }
        guard let store = WKContentRuleListStore.default(),
              let compiled = try await store.compileContentRuleList(forIdentifier: "CheeseLocalOnly", encodedContentRuleList: contentRules)
        else { throw WebError.loadFailed("the network block list couldn't be set up") }
        compiledRules = compiled
        return compiled
    }

    private init(configuration: WKWebViewConfiguration, width: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        webView = WKWebView(frame: frame, configuration: configuration)
        // Never shown: printing needs the view to be in a window.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func loadFile(_ url: URL, readAccess: URL) async throws {
        try await load { $0.loadFileURL(url, allowingReadAccessTo: readAccess) }
    }

    /// Loads markup with `baseURL` (a local folder) for relative resources.
    func loadHTML(_ html: String, baseURL: URL?) async throws {
        try await load { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    private func load(_ start: (WKWebView) -> WKNavigation?) async throws {
        loadContinuation?.resume(throwing: CancellationError())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                loadContinuation = continuation
                _ = start(webView)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webView.stopLoading()
                self?.finishLoad(.failure(CancellationError()))
            }
        }
    }

    private func finishLoad(_ result: Result<Void, any Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    /// Paginates the loaded page into a PDF at `url` with the print system.
    func printPDF(to url: URL, paperSize: CGSize, margin: CGFloat, landscape: Bool, fitToWidth: Bool = true) async throws {
        let info = NSPrintInfo()
        info.paperSize = paperSize
        info.orientation = landscape ? .landscape : .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = fitToWidth ? .fit : .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let printable = landscape ? paperSize.height : paperSize.width
        webView.setFrameSize(NSSize(width: printable - margin * 2, height: webView.frame.height))
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printContinuation.withLock { $0 = continuation }
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard succeeded, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw WebError.printFailed
        }
    }

    @objc private nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let continuation = printContinuation.withLock { pending in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: success)
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        finishLoad(.failure(CancellationError()))
        window.contentView = nil
        window.close()
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        guard Self.allowedSchemes.contains(scheme) else {
            Logger.files.info("Blocked a navigation to a \(scheme, privacy: .public) URL")
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoad(.failure(WebError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishLoad(.failure(WebError.loadFailed(error.localizedDescription)))
    }
}

/// Runs work with a time limit, throwing `LocalWebView.WebError.timedOut` when it's exceeded.
enum TimeLimit {
    static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LocalWebView.WebError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LocalWebView.WebError.timedOut }
            return first
        }
    }
}
