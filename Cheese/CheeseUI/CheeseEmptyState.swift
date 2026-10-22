import SwiftUI

/// What a panel shows when there's nothing in it, or something went wrong: a large symbol, a title
/// and one line of detail, centered.
struct CheeseEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.Size.emptyStateSymbol))
                .foregroundStyle(.secondary)
            Text(title)
                .font(DesignTokens.Typography.panelTitle)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
                .padding(.top, DesignTokens.Spacing.xxSmall)
        }
        .padding(.vertical, DesignTokens.Spacing.xxxLarge)
    }
}

extension CheeseEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}
