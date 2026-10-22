import SwiftUI

/// A row of controls along a panel's edge: icon buttons on the leading side, text buttons trailing.
struct CheeseToolbar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            leading
            Spacer(minLength: DesignTokens.Spacing.small)
            trailing
        }
        .controlSize(.small)
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.small)
    }
}

extension CheeseToolbar where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading) { EmptyView() }
    }
}
