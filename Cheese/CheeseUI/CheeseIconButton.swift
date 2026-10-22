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

/// A small borderless text button, like Clear or Stop: tinted text with a soft hover fill.
struct CheeseTextButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, tint: tint)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        let tint: Color
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(DesignTokens.Typography.secondary.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, DesignTokens.Spacing.small)
                .padding(.vertical, DesignTokens.Spacing.xxSmall)
                .background(
                    isHovered || configuration.isPressed ? tint.opacity(DesignTokens.Opacity.hoverTint) : .clear,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
