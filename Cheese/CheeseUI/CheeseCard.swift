import SwiftUI

/// A rounded tile that groups related content: a shelf item, a device, a tool group in the welcome picker.
struct CheeseCard<Content: View>: View {
    var isHighlighted = false
    var padding: CGFloat = DesignTokens.Spacing.medium
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(DesignTokens.Opacity.activeTint)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                    .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 1.5)
            )
    }
}
