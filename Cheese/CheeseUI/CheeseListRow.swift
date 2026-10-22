import SwiftUI

/// One row of a list in a panel: symbol, title, grey detail and an optional trailing accessory.
/// Selected rows fill with the accent color and turn their text white, like the palette and history.
struct CheeseListRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var isSelected = false
    var isDimmed = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Image(systemName: symbol)
                .frame(width: DesignTokens.Size.rowIcon)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .primary)
            if let detail {
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.small)
            accessory
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
        }
        .opacity(isDimmed ? 0.5 : 1)
        .padding(.horizontal, DesignTokens.Spacing.medium)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .contentShape(Rectangle())
    }
}

extension CheeseListRow where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, isSelected: Bool = false, isDimmed: Bool = false) {
        self.init(symbol: symbol, title: title, detail: detail, isSelected: isSelected, isDimmed: isDimmed) { EmptyView() }
    }
}

/// A shortcut or key shown as a small rounded cap: `⌃⌥V`.
struct CheeseKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.keycap)
            .padding(.horizontal, DesignTokens.Spacing.small)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
    }
}
