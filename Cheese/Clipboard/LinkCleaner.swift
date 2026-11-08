import Foundation

/// Strips tracking parameters from http(s) links, offline: the global ad/social click IDs and `utm_*`
/// everywhere, plus a few host-specific ones (YouTube, Amazon, X, Spotify, LinkedIn, Google Search).
/// Functional parameters, the fragment and the original percent-encoding are kept; a link with nothing
/// to strip comes back byte-for-byte unchanged. Pure (Foundation only), unit-tested.
enum LinkCleaner {
    /// Removed from every host (compared lowercased).
    static let globalParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid", "ttclid", "yclid", "wickedid",
        "igshid", "igsh", "mc_cid", "mc_eid", "mkt_tok", "_hsenc", "_hsmi", "hsctatracking",
        "oly_enc_id", "oly_anon_id", "vero_id", "rb_clickid", "s_kwcid", "ref_src", "ref_url",
        "share_id", "rdt",
    ]
    /// Any parameter starting with this is removed (`utm_source`, `utm_medium`, …).
    static let globalPrefixes = ["utm_"]

    /// A host-specific rule: which hosts it covers and which extra parameters it removes.
    struct HostRule: Sendable {
        enum Match: Sendable {
            /// The host is `domain` or a subdomain of it (`m.youtube.com` for `youtube.com`).
            case domain(String)
            /// Any label of the host before the public suffix is `label` (`amazon.co.uk`, `www.google.de`).
            case brand(String)
        }

        let matches: [Match]
        let parameters: Set<String>
        /// Cut the path at the first `/ref=` segment (Amazon's `/dp/B0…/ref=sr_1_3`).
        var stripsRefPath = false

        func applies(to host: String) -> Bool {
            let labels = host.split(separator: ".").map(String.init)
            return matches.contains { match in
                switch match {
                case let .domain(domain):
                    return host == domain || host.hasSuffix("." + domain)
                case let .brand(label):
                    // The brand must not be the last label ("amazon" alone isn't a site).
                    return labels.dropLast().contains(label)
                }
            }
        }
    }

    static let hostRules: [HostRule] = [
        HostRule(matches: [.domain("youtube.com"), .domain("youtu.be")],
                 parameters: ["si", "feature", "pp", "ab_channel", "kw"]),
        HostRule(matches: [.brand("amazon")],
                 parameters: ["psc", "tag", "linkcode", "camp", "creative", "creativeasin", "crid", "sprefix",
                              "dib", "dib_tag", "qid", "sr", "keywords", "ref", "ref_"],
                 stripsRefPath: true),
        HostRule(matches: [.domain("x.com"), .domain("twitter.com")], parameters: ["s", "t", "cxt"]),
        HostRule(matches: [.domain("open.spotify.com")], parameters: ["si", "context", "pt"]),
        HostRule(matches: [.domain("linkedin.com")], parameters: ["trk", "trkinfo", "lipi", "licu", "rcm"]),
        HostRule(matches: [.brand("google")],
                 parameters: ["ei", "ved", "uact", "oq", "gs_lcp", "sclient", "sourceid", "biw", "bih"]),
    ]

    /// `urlString` without its tracking parameters, or `urlString` itself when it isn't an http(s)
    /// link or has nothing to strip.
    static func clean(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return urlString }

        let rules = hostRules.filter { $0.applies(to: host) }
        var changed = false

        if rules.contains(where: \.stripsRefPath),
           let ref = components.percentEncodedPath.range(of: "/ref=", options: .caseInsensitive) {
            components.percentEncodedPath = String(components.percentEncodedPath[..<ref.lowerBound])
            changed = true
        }

        if let items = components.percentEncodedQueryItems {
            let hostParameters = rules.reduce(into: Set<String>()) { $0.formUnion($1.parameters) }
            let kept = items.filter { item in
                let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
                if name.isEmpty && item.value == nil { return false }   // `&&` leftovers
                return !isTracking(name, hostParameters: hostParameters)
            }
            if kept.count != items.count {
                // An empty list would leave a trailing "?"; nil removes the query entirely.
                components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
                changed = true
            }
        }

        guard changed, let cleaned = components.string else { return urlString }
        return cleaned
    }

    /// Whether `urlString` carries anything `clean(_:)` would strip.
    static func containsTrackers(_ urlString: String) -> Bool {
        clean(urlString) != urlString
    }

    /// The link in `text` (which must be just a link, possibly wrapped in brackets/quotes or split
    /// across lines) and its cleaned form. Nil when the text isn't a single http(s) link.
    static func extractAndCleanURL(from text: String) -> (original: URL, cleaned: URL, didClean: Bool)? {
        guard let link = TerminalLinkNormalizer.link(in: text, fromTerminal: false),
              let original = URL(string: link)
        else { return nil }
        let cleanedString = clean(link)
        guard let cleaned = URL(string: cleanedString) else { return nil }
        return (original, cleaned, cleanedString != link)
    }

    private static func isTracking(_ name: String, hostParameters: Set<String>) -> Bool {
        globalParameters.contains(name)
            || hostParameters.contains(name)
            || globalPrefixes.contains(where: { name.hasPrefix($0) })
    }
}
