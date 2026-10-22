import AppKit
import SwiftUI

/// What the Share and QR panels say about a link, kept pure so it's tested.
enum ShareLinkText {
    /// `192.168.1.42:54812/3f9a2c…`: the host, port and the start of the token.
    static func short(_ url: URL) -> String {
        let host = url.host() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path(percentEncoded: false).split(separator: "/").first.map(String.init) ?? ""
        let token = path.count > 6 ? String(path.prefix(6)) + "…" : path
        return host + port + (token.isEmpty ? "" : "/" + token)
    }

    /// `Same Wi-Fi · Expires in 9:58`, or, while the link lasts as long as Share is open,
    /// `Same Wi-Fi · Live while Share is open`.
    static func status(expiresAt: Date?, now: Date) -> String {
        guard let expiresAt else { return "Same Wi-Fi · Live while Share is open" }
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return "Same Wi-Fi · Expires in \(remaining / 60):" + String(format: "%02d", remaining % 60)
    }
}

/// The QR code and its link: a crisp code on a white quiet zone, the link with Copy Link, and a
/// footer with the countdown and Stop. Without a link (text encoded straight into the code) it
/// shows just the code and a caption.
struct ShareLinkCard: View {
    let code: CGImage
    /// The code's side in points.
    var side: CGFloat = 180
    var link: URL?
    var caption: String?
    var expiresAt: Date?
    var onStop: (() -> Void)?
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @State private var copied = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.medium) {
            Image(decorative: code, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: side, height: side)
                // White quiet zone, whatever the appearance.
                .padding(DesignTokens.Spacing.medium)
                .background(.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
                .accessibilityLabel("QR code")
            if let caption {
                Text(caption)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let link {
                linkPill(link)
                footer
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func linkPill(_ link: URL) -> some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            Text(ShareLinkText.short(link))
                .font(DesignTokens.Typography.code)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(link.absoluteString)
            Spacer(minLength: DesignTokens.Spacing.xxSmall)
            Button {
                copy(link.absoluteString)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied ✓" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 84)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.leading, DesignTokens.Spacing.medium)
        .padding(.trailing, DesignTokens.Spacing.xxSmall)
        .padding(.vertical, DesignTokens.Spacing.xxSmall)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            LiveDot()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ShareLinkText.status(expiresAt: expiresAt, now: context.date))
                    .monospacedDigit()
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Spacing.xxSmall)
            if let onStop {
                Button("Stop", role: .destructive, action: onStop)
                    .buttonStyle(CheeseTextButtonStyle(tint: .red))
                    .help("Stop sharing. The link stops working.")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xxSmall)
    }
}

/// A green dot that breathes while a link is live, still with Reduce Motion on.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color(red: 0.19, green: 0.82, blue: 0.35))
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}
