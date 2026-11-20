import SwiftUI
import Perception

/// A search field drawn as one: a magnifying glass, the field, and a button that clears it.
/// For sheets and panels, where the toolbar's own search field doesn't belong.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    /// Changed to put the cursor in the field; it also takes the cursor when it appears.
    var focusRequest = 0
    var onSubmit: () -> Void = {}
    var onMove: ((Int) -> Bool)?
    var onEscape: (() -> Bool)?

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            CommandTextField(text: $text, placeholder: prompt, focusRequest: focusRequest,
                             onSubmit: onSubmit, onMove: onMove, onEscape: onEscape)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator) }
    } }
}
