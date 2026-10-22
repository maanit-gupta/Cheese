import Foundation
import Testing
@testable import Cheese

struct BrowserSharePageRendererTests {
    private typealias Renderer = BrowserSharePageRenderer
    private let base = "/0123456789abcdef0123456789abcdef/"

    private func page(_ items: [Renderer.Item] = [], downloadAll: String? = nil, uploads: Bool = false, expiresIn: Int? = nil) -> Renderer.Page {
        Renderer.Page(deviceName: "MacBook Pro", basePath: base, items: items, downloadAllHref: downloadAll, acceptsUploads: uploads, expiresIn: expiresIn)
    }

    private func file(_ name: String, size: Int64? = 2_400_000, type: String = "application/pdf", href: String? = "download/1") -> Renderer.Item {
        .file(.init(name: name, size: size, mimeType: type, href: href))
    }

    @Test func singleFileDownloads() {
        let html = Renderer.html(page([file("Report.pdf")]))
        #expect(html.contains("<span class=\"nm\">Report.pdf</span><span class=\"sz\">2.4 MB</span>"))
        #expect(html.contains("href=\"\(base)download/1\" download=\"Report.pdf\""))
        #expect(html.contains("Download File</a>"))
        #expect(!html.contains("Download All"))
        #expect(html.contains("Connected to <b>MacBook Pro</b>"))
    }

    @Test func severalFilesDownloadAsOneZip() {
        let html = Renderer.html(page([file("a.pdf"), file("b.pdf", href: "download/2")], downloadAll: "download-all"))
        #expect(html.contains("href=\"\(base)download-all\" download>"))
        #expect(html.contains("Download All (.zip)</a>"))
        // Each row still downloads on its own, with an arrow to say so.
        #expect(html.contains("download=\"b.pdf\""))
        #expect(html.contains("class=\"dl\""))
    }

    @Test func zippedSharesListTheirContents() {
        let folder = Renderer.html(page([file("Photos", size: nil, href: nil)], downloadAll: "download"))
        #expect(folder.contains("Download Folder (.zip)"))
        #expect(folder.contains("<span class=\"sz\">Folder</span>"))
        #expect(!folder.contains("download=\"Photos\""))
    }

    @Test func imagesShowAPreview() {
        let html = Renderer.html(page([file("Shot.png", type: "image/png", href: "download")]))
        #expect(html.contains("<img src=\"\(base)download\" alt=\"\" loading=\"lazy\">"))
        // Without a link of its own, an image gets an icon instead.
        #expect(!Renderer.html(page([file("Shot.png", type: "image/png", href: nil)])).contains("<img"))
    }

    @Test func textHasCopyAndLinksOpen() {
        let text = Renderer.html(page([.text("Meet at 6")]))
        #expect(text.contains("<div class=\"txt\">Meet at 6</div>"))
        #expect(text.contains("data-copy>Copy Text</button>"))
        #expect(!text.contains("Open Link"))

        let link = Renderer.html(page([.text("  https://example.com/a?b=1&c=2\n")]))
        #expect(link.contains("href=\"https://example.com/a?b=1&amp;c=2\" target=\"_blank\" rel=\"noopener noreferrer\">Open Link ↗</a>"))
    }

    @Test func onlyWebLinksOpen() {
        #expect(Renderer.link(in: "http://192.168.1.4:8080/x") == "http://192.168.1.4:8080/x")
        #expect(Renderer.link(in: "javascript:alert(1)") == nil)
        #expect(Renderer.link(in: "JAVASCRIPT://example.com/%0aalert(1)") == nil)
        #expect(Renderer.link(in: "data:text/html,<b>") == nil)
        #expect(Renderer.link(in: "https://a.com and more") == nil)
        #expect(Renderer.link(in: "example.com") == nil)
        #expect(Renderer.link(in: "") == nil)
    }

    @Test func copyWorksWithoutASecureContext() {
        let html = Renderer.html(page([.text("x")]))
        // Plain-HTTP LAN pages have no navigator.clipboard, so the page falls back to execCommand.
        #expect(html.contains("isSecureContext"))
        #expect(html.contains("document.execCommand(\"copy\")"))
        #expect(html.contains("Copied ✓"))
    }

    @Test func receiveOnlySessionShowsTheUploader() {
        let html = Renderer.html(page(uploads: true))
        #expect(html.contains("<input id=\"files\" type=\"file\" multiple>"))
        #expect(html.contains("Tap to choose photos or files"))
        #expect(html.contains("placeholder=\"Paste text or a link to copy to your Mac…\""))
        #expect(html.contains("Nothing from your Mac yet."))
        #expect(html.contains("upload.onprogress"))
        #expect(!html.contains("class=\"cta\""))
    }

    @Test func linkSharesDontTakeUploads() {
        let html = Renderer.html(page([.text("x")]))
        #expect(!html.contains("id=\"files\""))
        #expect(!html.contains("id=\"to\""))
    }

    @Test func escapesEverythingItShows() {
        let evil = "<img src=x onerror=alert(1)>\"'&"
        let html = Renderer.html(Renderer.Page(
            deviceName: "<script>alert(1)</script>",
            basePath: base,
            items: [file(evil + ".png", type: "image/png"), .text("</div><script>alert(2)</script>")],
            acceptsUploads: true
        ))
        #expect(!html.contains("<img src=x"))
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;&quot;&#39;&amp;.png"))
        #expect(html.contains("&lt;/div&gt;&lt;script&gt;alert(2)&lt;/script&gt;"))
        #expect(html.contains("Connected to <b>&lt;script&gt;alert(1)&lt;/script&gt;</b>"))
    }

    @Test func countsDownWhenTheLinkExpires() {
        #expect(Renderer.html(page(expiresIn: 582)).contains("data-expires=\"582\""))
        #expect(Renderer.html(page(expiresIn: -4)).contains("data-expires=\"0\""))
        #expect(!Renderer.html(page()).contains("data-expires"))
        #expect(Renderer.html(page()).contains("Expired — Reopen Share on your Mac"))
        #expect(Renderer.state(page(expiresIn: -4)).expiresIn == 0)
        #expect(Renderer.state(page()).expiresIn == nil)
    }

    @Test func stateMatchesThePageAndChangesWithIt() {
        let one = page([file("a.pdf")])
        let state = Renderer.state(one)
        #expect(Renderer.html(one).contains("<div id=\"mac\" data-v=\"\(state.version)\">\(state.html)</div>"))
        #expect(Renderer.state(page([file("b.pdf")])).version != state.version)
        #expect(Renderer.state(one) == state)
    }

    @Test func staysSmallAndLoadsNothingRemote() {
        let items = (1...12).map { file("File number \($0) with a long name.pdf", href: "download/\($0)") } + [.text(String(repeating: "word ", count: 40))]
        let html = Renderer.html(page(items, downloadAll: "download-all", uploads: true, expiresIn: 600))
        #expect(html.utf8.count < Renderer.sizeBudget)
        #expect(Renderer.html(page(uploads: true)).utf8.count < 20 * 1024)
        for remote in ["http://", "https://", "<script src", "<link", "@import", "url(", "//fonts", "<iframe"] {
            #expect(!html.contains(remote), "page references \(remote)")
        }
    }

    @Test(arguments: [
        (Int64(0), "0 B"), (999, "999 B"), (1_000, "1.0 KB"), (2_400, "2.4 KB"), (15_300, "15 KB"),
        (999_400, "999 KB"), (999_600, "1.0 MB"), (2_400_000, "2.4 MB"), (18_000_000_000, "18 GB"),
    ])
    func formatsSizesLikeFinder(_ bytes: Int64, _ text: String) {
        #expect(Renderer.formatSize(bytes) == text)
    }
}

struct ShareLinkPathTests {
    private let token = String(repeating: "c", count: 32)

    @Test func parsesTheLinksResources() {
        #expect(ShareRules.parse(path: "/\(token)")?.resource == .page)
        #expect(ShareRules.parse(path: "/\(token)/")?.resource == .page)
        #expect(ShareRules.parse(path: "/\(token)/state")?.resource == .state)
        #expect(ShareRules.parse(path: "/\(token)/download")?.token == token)
        #expect(ShareRules.parse(path: "/\(token)/download/") == nil)
        #expect(ShareRules.parse(path: "/\(token)/../x") == nil)
        #expect(ShareRules.parse(path: "/\(token.uppercased())") == nil)
        #expect(ShareRules.parse(path: "/") == nil)
        #expect(ShareRules.parse(path: "") == nil)
        #expect(ShareRules.parse(path: token) == nil)
    }
}
