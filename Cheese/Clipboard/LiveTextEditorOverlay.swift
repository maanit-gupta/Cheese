import SwiftUI

/// The one control in the bottom-right corner of a text preview. At rest it's a small pencil badge:
/// click it (or press ⌘E) to edit the text in place, or drag it to drop the text into any app.
/// While editing it becomes a pill with a drag handle, which saves the edit and drags it out, and
/// Done, which saves and goes back to the list.
struct LiveTextEditorOverlay: View {
    let model: HistoryViewModel
    let itemID: UUID
    let isEditing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isEditing {
                editingPill
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                pencilBadge
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(DesignTokens.animation(DesignTokens.Duration.standard, reduceMotion: reduceMotion), value: isEditing)
    }

    private var pencilBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 13, weight: .medium))
            .frame(width: DesignTokens.Size.floatingButton, height: DesignTokens.Size.floatingButton)
            .cheeseFloatingControl(in: Circle())
            .overlay {
                ClipDragHandle(
                    model: model,
                    itemID: itemID,
                    onClick: { [model] _ in model.perform(.toggleEdit) },
                    toolTip: "Edit text (⌘E)"
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Edit text")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.perform(.toggleEdit) }
    }

    private var editingPill: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 14))
                .frame(width: DesignTokens.Size.iconButton.width, height: DesignTokens.Size.iconButton.height)
                .overlay {
                    ClipDragHandle(model: model, itemID: itemID, toolTip: "Drag the edited text into any app", cursor: .openHand)
                }
                .accessibilityLabel("Drag the edited text")
            CheeseIconButton(symbol: "checkmark.circle.fill", help: "Done (⌘↩ saves and pastes)", isActive: true) {
                model.perform(.endEdit)
            }
        }
        .padding(DesignTokens.Spacing.hairline)
        .cheeseFloatingControl(in: Capsule())
    }
}
