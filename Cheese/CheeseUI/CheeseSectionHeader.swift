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
