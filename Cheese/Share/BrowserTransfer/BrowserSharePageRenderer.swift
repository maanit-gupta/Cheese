import Foundation

/// The page a phone or browser opens from a Share link or a QR code: what this Mac is offering and,
/// in a Cheese Share session, a way to send photos, files and text back. Pure: the same page state
/// always renders the same bytes. Everything is inline, so the page never asks anything of any
/// server but its own.
enum BrowserSharePageRenderer {
    struct File: Equatable, Sendable {
        var name: String
        /// Nil for a folder.
        var size: Int64?
        var mimeType: String
        /// Where it downloads from, relative to the page's base path. Nil when it only comes as
        /// part of the zip of everything.
        var href: String?
    }

    enum Item: Equatable, Sendable {
        case file(File)
        case text(String)
    }

    struct Page: Equatable, Sendable {
        var deviceName: String
        /// The session's path, ending in `/`. Every request the page makes goes under it.
        var basePath: String
        var items: [Item] = []
        /// The zip of every file, relative to `basePath`.
        var downloadAllHref: String?
        /// Shows the Send to your Mac section.
        var acceptsUploads = false
        /// Seconds until the link stops working; nil while it lasts as long as Share is open on the Mac.
        var expiresIn: Int?
    }

    /// What the page polls for: the From your Mac section, its version and the time left.
    struct State: Codable, Equatable {
        var html: String
        var version: String
        var expiresIn: Int?
    }

    /// The whole page, styles and script included, stays under this.
    static let sizeBudget = 35 * 1024

    static func state(_ page: Page) -> State {
        let html = fromMacSection(page)
        return State(html: html, version: version(of: html), expiresIn: page.expiresIn.map { max(0, $0) })
    }

    static func html(_ page: Page) -> String {
        let section = fromMacSection(page)
        let expires = page.expiresIn.map { " data-expires=\"\(max(0, $0))\"" } ?? ""
        let upload = page.acceptsUploads ? uploadSection : ""
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
            <meta name="color-scheme" content="light dark">
            <title>Cheese Share</title>
            <style>\(css)</style>
            </head>
            <body data-base="\(escape(page.basePath))"\(expires)>
            <main>
            <header><div class="pill"><i class="dot"></i><span id="who">Connected to <b>\(escape(page.deviceName))</b></span><span id="left" class="left"></span></div></header>
            <section id="from"><h2>From your Mac</h2><div id="mac" data-v="\(version(of: section))">\(section)</div></section>
            \(upload)<div id="gone" class="gone" hidden>\(icon(clockIcon))<h1>Link expired</h1><p>Reopen Share on your Mac for a new link.</p></div>
            </main>
            <script>\(script)</script>
            </body>
            </html>
            """
    }

    /// The From your Mac section's contents: files with their download button, then text cards.
    static func fromMacSection(_ page: Page) -> String {
        let files = page.items.compactMap { item -> File? in
            if case let .file(file) = item { return file }
            return nil
        }
        let texts = page.items.compactMap { item -> String? in
            if case let .text(text) = item { return text }
            return nil
        }
        guard !files.isEmpty || !texts.isEmpty else {
            return "<p class=\"empty\">Nothing from your Mac yet. Drop files on the Share panel to send them here.</p>"
        }
        var html = ""
        if !files.isEmpty {
            html += "<div class=\"card\">"
            for file in files {
                html += row(for: file, page: page, showsArrow: files.count > 1)
            }
            html += "</div>"
            if let (label, href) = primaryDownload(files: files, page: page) {
                html += "<a class=\"cta\" href=\"\(escape(page.basePath + href))\" download>\(icon(downloadIcon))\(label)</a>"
            }
        }
        for text in texts {
            html += "<div class=\"card\"><div class=\"txt\">\(escape(text))</div><div class=\"acts\">"
            html += "<button class=\"btn\" type=\"button\" data-copy>Copy Text</button>"
            if let link = link(in: text) {
                html += "<a class=\"btn\" href=\"\(escape(link))\" target=\"_blank\" rel=\"noopener noreferrer\">Open Link ↗</a>"
            }
            html += "</div></div>"
        }
        return html
    }

    /// The big button under the file list, if there's something to download.
    static func primaryDownload(files: [File], page: Page) -> (label: String, href: String)? {
        if let all = page.downloadAllHref, let first = files.first {
            if files.count > 1 { return ("Download All (.zip)", all) }
            return (first.size == nil ? "Download Folder (.zip)" : "Download File", all)
        }
        if files.count == 1, let href = files[0].href {
            return ("Download File", href)
        }
        return nil
    }

    private static func row(for file: File, page: Page, showsArrow: Bool) -> String {
        let symbol: String
        if let href = file.href, file.mimeType.hasPrefix("image/") {
            symbol = "<img src=\"\(escape(page.basePath + href))\" alt=\"\" loading=\"lazy\">"
        } else {
            symbol = icon(file.size == nil ? folderIcon : file.mimeType.hasPrefix("image/") ? imageIcon : fileIcon)
        }
        let size = file.size.map(formatSize) ?? "Folder"
        let meta = "<span class=\"ic\">\(symbol)</span><span class=\"meta\"><span class=\"nm\">\(escape(file.name))</span><span class=\"sz\">\(size)</span></span>"
        guard let href = file.href else { return "<div class=\"row\">\(meta)</div>" }
        let arrow = showsArrow ? "<span class=\"dl\">\(icon(downloadIcon))</span>" : ""
        return "<a class=\"row\" href=\"\(escape(page.basePath + href))\" download=\"\(escape(file.name))\">\(meta)\(arrow)</a>"
    }

    // MARK: Pieces

    /// The text, if it's nothing but one web link. Other schemes (`javascript:` and friends) never link.
    static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return trimmed
    }

    /// Decimal units like Finder: `512 B`, `2.4 MB`, `18 GB`.
    static func formatSize(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return "\(max(0, bytes)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = value < 9.95 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return number + " " + units[unit]
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// FNV-1a of the section, so the page only redraws when something changed.
    static func version(of html: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in html.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(hash, radix: 16)
    }

    private static func icon(_ path: String) -> String {
        "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"\(path)\"/></svg>"
    }

    private static let fileIcon = "M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5"
    private static let imageIcon = "M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM4 16l5-5 4 4 3-3 4 4M15.5 8.5h.01"
    private static let folderIcon = "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"
    private static let downloadIcon = "M12 4v11M7 10l5 5 5-5M5 20h14"
    private static let uploadIcon = "M12 16V4M7 9l5-5 5 5M5 20h14"
    private static let clockIcon = "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2"

    private static let uploadSection = """
        <section id="to"><h2>Send to your Mac</h2>
        <label class="drop" id="drop"><input id="files" type="file" multiple>\(icon(uploadIcon))<span>Tap to choose photos or files</span><small>or drop them here</small></label>
        <div id="ups" class="card" hidden></div>
        <div class="card send"><textarea id="text" rows="1" placeholder="Paste text or a link to copy to your Mac…"></textarea><button id="sendText" class="btn pri" type="button">Send</button></div>
        <p id="note" class="note"></p></section>

        """

    private static let css = """
        :root{--bg:#F5F5F7;--card:#FFF;--fg:#1D1D1F;--mute:#6E6E73;--line:rgba(128,128,128,.16);--fill:rgba(128,128,128,.12);--pri:#1D1D1F;--on:#FFF;--ok:#30D158;--bad:#FF3B30;--acc:#0071E3}
        @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1C1C1E;--fg:#F5F5F7;--mute:#98989D;--pri:#F5F5F7;--on:#000;--bad:#FF453A;--acc:#0A84FF}}
        *{box-sizing:border-box;margin:0}
        html{-webkit-text-size-adjust:100%}
        body{background:var(--bg);color:var(--fg);font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
        button,textarea,input{font:inherit;color:inherit}
        main{max-width:440px;margin:0 auto;padding:20px 16px calc(28px + env(safe-area-inset-bottom))}
        header{display:flex;justify-content:center;margin:4px 0 24px}
        .pill{display:inline-flex;align-items:center;gap:8px;max-width:100%;padding:7px 14px;border-radius:99px;background:var(--card);border:1px solid var(--line);font-size:14px;color:var(--mute);white-space:nowrap}
        #who{overflow:hidden;text-overflow:ellipsis}
        .pill b{color:var(--fg);font-weight:600}
        .dot{width:8px;height:8px;border-radius:50%;flex:none;background:var(--ok);box-shadow:0 0 0 3px rgba(48,209,88,.22)}
        .left{font-variant-numeric:tabular-nums}
        .left:not(:empty)::before{content:"· "}
        section{margin-bottom:28px}
        h2{margin:0 4px 8px;font-size:13px;font-weight:600;letter-spacing:.03em;text-transform:uppercase;color:var(--mute)}
        .card{background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden}
        .card+.card,.cta+.card{margin-top:10px}
        .row{display:flex;align-items:center;gap:12px;padding:12px 14px;color:inherit;text-decoration:none}
        .row+.row,.up+.up{border-top:1px solid var(--line)}
        .ic{display:grid;place-items:center;flex:none;width:40px;height:40px;border-radius:10px;overflow:hidden;background:var(--fill);color:var(--mute)}
        .ic img{width:100%;height:100%;object-fit:cover}
        svg{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
        .meta{display:flex;flex-direction:column;flex:1;min-width:0}
        .nm{font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .sz,.note,.empty{font-size:13px;color:var(--mute)}
        .note,.empty{margin:10px 4px 0}
        .empty{margin-top:0}
        .dl{color:var(--acc)}
        .cta{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;margin-top:10px;padding:15px;border-radius:12px;background:var(--pri);color:var(--on);font-weight:600;text-decoration:none}
        .cta svg{width:18px;height:18px}
        .txt{max-height:220px;overflow:auto;padding:14px;white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.45 ui-monospace,"SF Mono",Menlo,monospace}
        .acts{display:flex;gap:8px;padding:0 14px 14px}
        .btn{flex:1;padding:11px 14px;border:0;border-radius:12px;background:var(--fill);color:inherit;font-weight:600;text-align:center;text-decoration:none;cursor:pointer}
        .btn.pri{flex:none;background:var(--pri);color:var(--on)}
        .drop{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;min-height:112px;padding:18px;border:1.5px dashed rgba(128,128,128,.4);border-radius:16px;background:var(--card);text-align:center;cursor:pointer;transition:border-color .15s,background-color .15s}
        .drop svg{width:28px;height:28px;margin-bottom:4px;color:var(--acc)}
        .drop span{font-weight:600}
        .drop small{font-size:13px;color:var(--mute)}
        .drop.over{border-color:var(--acc);background:color-mix(in srgb,var(--acc) 8%,var(--card))}
        .drop input{display:none}
        #ups{margin-top:10px}
        .up{padding:12px 14px}
        .upt{display:flex;justify-content:space-between;gap:10px;font-size:14px}
        .bar{height:4px;margin-top:8px;border-radius:2px;overflow:hidden;background:var(--fill)}
        .bar i{display:block;width:0;height:100%;background:var(--acc);transition:width .15s}
        .ok{color:var(--ok)}.err{color:var(--bad)}
        .send{display:flex;align-items:flex-end;gap:8px;margin-top:10px;padding:8px}
        .send textarea{flex:1;min-height:40px;max-height:160px;padding:9px 8px;border:0;outline:0;background:none;resize:none}
        .gone{padding:48px 16px;text-align:center;color:var(--mute)}
        .gone svg{width:40px;height:40px}
        .gone h1{margin:12px 0 6px;font-size:20px;color:var(--fg)}
        .expired .dot{background:var(--mute);box-shadow:none}
        .expired section{display:none}
        [hidden]{display:none!important}
        """

    private static let script = """
        const B=document.body,base=B.dataset.base,$=i=>document.getElementById(i);
        const el=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e};
        let left=B.dataset.expires==null?null:+B.dataset.expires,fails=0,v=$("mac").dataset.v;
        function tick(){if(left===null){$("left").textContent="";return}if(left<=0)return expire();$("left").textContent=Math.floor(left/60)+":"+String(left%60).padStart(2,"0")+" left";left--}
        function expire(){if(B.classList.contains("expired"))return;B.classList.add("expired");clearInterval(t1);clearInterval(t2);$("who").textContent="Expired — Reopen Share on your Mac";$("left").textContent="";$("gone").hidden=false}
        async function poll(){try{const r=await fetch(base+"state",{cache:"no-store"});if(!r.ok)throw 0;const s=await r.json();fails=0;left=s.expiresIn??null;if(s.version!==v){v=s.version;$("mac").innerHTML=s.html}}catch{if(++fails>=3)expire()}}
        const t1=setInterval(tick,1000),t2=setInterval(poll,3000);tick();
        document.addEventListener("click",async e=>{const b=e.target.closest("[data-copy]");if(!b)return;const t=b.closest(".card").querySelector(".txt").textContent;let ok=false;
        if(window.isSecureContext&&navigator.clipboard)try{await navigator.clipboard.writeText(t);ok=true}catch{}
        if(!ok){const a=el("textarea");a.value=t;a.readOnly=true;a.style.cssText="position:fixed;top:0;left:0;opacity:0";B.append(a);a.select();a.setSelectionRange(0,t.length);try{ok=document.execCommand("copy")}catch{}a.remove()}
        b.textContent=ok?"Copied ✓":"Couldn’t copy";setTimeout(()=>b.textContent="Copy Text",1500)});
        if($("files")){const drop=$("drop"),ups=$("ups"),ta=$("text");
        ["dragover","drop"].forEach(n=>document.addEventListener(n,e=>e.preventDefault()));
        drop.addEventListener("dragover",()=>drop.classList.add("over"));["dragleave","drop"].forEach(n=>drop.addEventListener(n,()=>drop.classList.remove("over")));
        drop.addEventListener("drop",e=>[...e.dataTransfer.files].forEach(up));$("files").onchange=e=>{[...e.target.files].forEach(up);e.target.value=""};
        function up(f){ups.hidden=false;const row=el("div","up"),top=el("div","upt"),st=el("span","sz","0%"),bar=el("div","bar"),fill=el("i");bar.append(fill);top.append(el("span","nm",f.name),st);row.append(top,bar);ups.append(row);
        const x=new XMLHttpRequest(),done=(m,ok)=>{bar.remove();st.textContent=m;st.className=ok?"ok":"err"};x.open("POST",base+"upload?name="+encodeURIComponent(f.name));
        x.upload.onprogress=p=>{if(p.lengthComputable){const n=Math.round(p.loaded/p.total*100);fill.style.width=n+"%";st.textContent=n+"%"}};
        x.onload=()=>done(x.status<300?"Sent to Mac ✓":x.status==413?"Too large for your Mac":"Couldn’t send",x.status<300);x.onerror=()=>done("Couldn’t send",false);x.send(f)}
        ta.oninput=()=>{ta.style.height="auto";ta.style.height=ta.scrollHeight+"px"};
        $("sendText").onclick=async()=>{const t=ta.value,n=$("note");if(!t.trim())return;try{const r=await fetch(base+"text",{method:"POST",body:t});n.textContent=r.ok?"Sent — it’s on your Mac’s clipboard ✓":"Couldn’t send";n.className="note "+(r.ok?"ok":"err");if(r.ok){ta.value="";ta.oninput()}}catch{n.textContent="Couldn’t reach your Mac";n.className="note err"}}}
        """
}
