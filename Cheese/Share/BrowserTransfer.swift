import Foundation
import os

/// The no-app way in: a phone scans the Phone tile's QR code and gets a page where it can upload
/// files, photos and text to this Mac, and download what the Mac is offering. The link's random
/// token is the consent: anyone with it can use the page until Cheese Share stops listening, when
/// a new token is made.
@MainActor
final class BrowserTransfer {
    struct Hooks {
        var destination: @MainActor () -> URL
        var maxBytes: @MainActor () -> Int64
        var onText: @MainActor (_ text: String) -> Void
        var onFileReceived: @MainActor (_ file: URL) -> Void
    }

    /// Texts posted from the page larger than this are refused.
    static let maxTextBytes = 1 << 20

    private(set) var token = ShareRules.makeToken()
    /// What the page offers for download.
    private(set) var offered: [OutgoingItem] = []
    private let hooks: Hooks

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    /// A fresh token, so old links stop working. Called when Cheese Share stops.
    func reset() {
        token = ShareRules.makeToken()
        offered = []
    }

    func offer(_ items: [OutgoingItem]) {
        let new = items.filter { item in !offered.contains { $0.content == item.content } }
        offered.append(contentsOf: new)
    }

    func withdraw(_ id: OutgoingItem.ID) {
        offered.removeAll { $0.id == id }
    }

    func url(address: String, port: UInt16) -> URL? {
        URL(string: "http://\(address):\(port)/\(token)/")
    }

    /// The route under this session's token, or nil when the path isn't ours.
    nonisolated static func route(path: String, token: String) -> String? {
        let prefix = "/\(token)"
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        return rest.isEmpty ? "/" : rest
    }

    func handles(_ path: String) -> Bool {
        Self.route(path: path, token: token) != nil
    }

    func handle(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard let route = Self.route(path: request.path, token: token) else { return .status(404) }
        switch (request.method, route) {
        case ("GET", "/"):
            return .html(BrowserPage.html)
        case ("GET", "/items"):
            return .json(offered.map { BrowserPage.Item(id: $0.id.uuidString, name: $0.name, size: $0.size, text: Self.text(of: $0)) })
        case ("POST", "/text"):
            guard let data = try? await body.collect(limit: Self.maxTextBytes), let text = String(data: data, encoding: .utf8),
                  text.contains(where: { !$0.isWhitespace })
            else { return .status(400) }
            hooks.onText(text)
            return HTTPResponse(status: 204)
        case ("POST", "/upload"):
            return await upload(request, body: body)
        default:
            if request.method == "GET", route.hasPrefix("/download/") {
                return download(String(route.dropFirst("/download/".count)))
            }
            return .status(request.method == "GET" || request.method == "POST" ? 404 : 405)
        }
    }

    private static func text(of item: OutgoingItem) -> String? {
        if case let .text(text) = item.content { return text }
        return nil
    }

    private func download(_ id: String) -> HTTPResponse {
        guard let item = offered.first(where: { $0.id.uuidString == id }) else { return .status(404) }
        switch item.content {
        case let .file(url):
            guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { return .status(404) }
            return HTTPResponse(status: 200, headers: [
                ("Content-Type", item.mimeType),
                ("Content-Disposition", HTTPMessage.contentDisposition(attachmentName: url.lastPathComponent)),
                ("Cache-Control", "no-store"),
            ], body: .file(url))
        case let .text(text):
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(text.utf8)))
        }
    }

    private func upload(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard let name = request.query["name"], !name.isEmpty else { return .status(400) }
        let folder = hooks.destination()
        let partial = ReceivedFileWriter.partialURL(in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await ReceivedFileWriter.write(body, to: partial, expectedSize: body.declaredLength, maxSize: hooks.maxBytes(), sha256: nil) { _ in }
            let file = try ReceivedFileWriter.finish(partial, named: name, in: folder)
            hooks.onFileReceived(file)
            return HTTPResponse(status: 204)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            Logger.share.error("Browser upload failed: \(error.localizedDescription, privacy: .public)")
            return .status(error as? ReceiveError == .tooLarge ? 413 : 400)
        }
    }
}

/// The page phones see. Self-contained: no external scripts, fonts or images.
enum BrowserPage {
    struct Item: Codable, Equatable {
        var id: String
        var name: String
        var size: Int64
        /// Set for text items, shown inline with a Copy button.
        var text: String?
    }

    static let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Cheese Share</title>
        <style>
        :root { color-scheme: light dark; --accent: #f5b400; --line: #8884; }
        * { box-sizing: border-box; }
        body { font: 17px -apple-system, system-ui, sans-serif; margin: 0 auto; padding: 16px; max-width: 640px; }
        h1 { font-size: 22px; margin: 4px 0 16px; }
        h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .04em; opacity: .65; margin: 24px 0 8px; }
        .card { border: 1px solid var(--line); border-radius: 14px; padding: 14px; margin-bottom: 10px; }
        button, .button { display: block; width: 100%; font: 600 17px -apple-system, system-ui, sans-serif; padding: 13px;
          border: 0; border-radius: 12px; background: var(--accent); color: #222; text-align: center; text-decoration: none; }
        button.secondary { background: #8882; color: inherit; }
        textarea { width: 100%; height: 110px; font: inherit; padding: 10px; border-radius: 12px; border: 1px solid var(--line); margin-bottom: 10px; }
        input[type=file] { display: none; }
        .row { display: flex; gap: 10px; align-items: center; }
        .row .name { flex: 1; overflow-wrap: anywhere; }
        .size, .status { font-size: 14px; opacity: .65; }
        .row .button { width: auto; padding: 9px 14px; font-size: 15px; }
        progress { width: 100%; }
        </style>
        </head>
        <body>
        <h1>🧀 Cheese Share</h1>

        <h2>Send to Mac</h2>
        <div class="card">
          <label class="button" for="files">Choose Photos or Files</label>
          <input id="files" type="file" multiple>
          <div id="uploads"></div>
        </div>
        <div class="card">
          <textarea id="text" placeholder="Text or a link"></textarea>
          <button id="sendText" type="button">Send Text</button>
          <div id="textStatus" class="status"></div>
        </div>

        <h2>From Mac</h2>
        <div id="items"><div class="status">Nothing yet. Drop files on the Phone tile on your Mac.</div></div>

        <script>
        const base = location.pathname.endsWith("/") ? location.pathname : location.pathname + "/";
        const fmt = n => n < 1024 ? n + " B" : n < 1048576 ? (n / 1024).toFixed(0) + " KB" : n < 1073741824 ? (n / 1048576).toFixed(1) + " MB" : (n / 1073741824).toFixed(1) + " GB";
        const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };

        document.getElementById("files").addEventListener("change", e => {
          for (const file of e.target.files) upload(file);
          e.target.value = "";
        });

        function upload(file) {
          const row = el("div", "status", file.name);
          const bar = el("progress"); bar.max = 1; bar.value = 0;
          const box = el("div"); box.append(row, bar);
          document.getElementById("uploads").append(box);
          const xhr = new XMLHttpRequest();
          xhr.open("POST", base + "upload?name=" + encodeURIComponent(file.name));
          xhr.upload.onprogress = p => { if (p.lengthComputable) bar.value = p.loaded / p.total; };
          xhr.onload = () => { bar.remove(); row.textContent = (xhr.status < 300 ? "✓ Sent " : "✗ Couldn't send ") + file.name; };
          xhr.onerror = () => { bar.remove(); row.textContent = "✗ Couldn't send " + file.name; };
          xhr.send(file);
        }

        document.getElementById("sendText").addEventListener("click", async () => {
          const area = document.getElementById("text");
          const status = document.getElementById("textStatus");
          if (!area.value.trim()) return;
          try {
            const r = await fetch(base + "text", { method: "POST", body: area.value });
            status.textContent = r.ok ? "✓ Sent — it's on the Mac's clipboard" : "✗ Couldn't send";
            if (r.ok) area.value = "";
          } catch { status.textContent = "✗ Couldn't reach the Mac"; }
        });

        let shown = "";
        async function refresh() {
          try {
            const r = await fetch(base + "items", { cache: "no-store" });
            if (!r.ok) return;
            const items = await r.json();
            const key = JSON.stringify(items.map(i => i.id));
            if (key === shown) return;
            shown = key;
            const list = document.getElementById("items");
            list.replaceChildren();
            if (!items.length) { list.append(el("div", "status", "Nothing yet. Drop files on the Phone tile on your Mac.")); return; }
            for (const item of items) {
              const card = el("div", "card");
              if (item.text !== null && item.text !== undefined) {
                const area = el("textarea"); area.readOnly = true; area.value = item.text;
                const copy = el("button", "secondary", "Copy");
                copy.onclick = async () => { try { await navigator.clipboard.writeText(item.text); } catch { area.select(); document.execCommand("copy"); } copy.textContent = "Copied"; };
                card.append(area, copy);
              } else {
                const row = el("div", "row");
                const name = el("div", "name", item.name);
                const size = el("div", "size", fmt(item.size));
                const link = el("a", "button", "Download"); link.href = base + "download/" + item.id; link.download = item.name;
                row.append(name, size, link);
                card.append(row);
              }
              list.append(card);
            }
          } catch {}
        }
        refresh();
        setInterval(refresh, 3000);
        </script>
        </body>
        </html>
        """
}
