import SwiftUI

/// A small heading above a group of rows or cards, with an optional symbol and trailing control.
struct CheeseSectionHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(DesignTokens.Typography.heading)
            Spacer(minLength: DesignTokens.Spacing.small)
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension CheeseSectionHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

/// A quieter heading in small capitals, for groups inside a compact panel: PDF, CONVERT, IMAGES.
struct CheeseSectionCaps: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(DesignTokens.Typography.caption.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.top, DesignTokens.Spacing.xxSmall)
            .accessibilityAddTraits(.isHeader)
    }
}
