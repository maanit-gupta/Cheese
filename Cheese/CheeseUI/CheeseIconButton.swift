import SwiftUI

/// A borderless SF Symbol button, like the draw rail's: accent-tinted while active, with a tooltip.
struct CheeseIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: DesignTokens.Size.iconButton.width, height: DesignTokens.Size.iconButton.height)
                .background(background, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isActive { return .accentColor.opacity(DesignTokens.Opacity.activeTint) }
        return isHovered ? .primary.opacity(DesignTokens.Opacity.hoverTint) : .clear
    }
}
