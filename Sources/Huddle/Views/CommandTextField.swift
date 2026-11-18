import AppKit
import SwiftUI

/// A plain one-line text field that hands the keys a search or picker field needs (Return,
/// the up and down arrows, Backspace with nothing typed, Escape) to its owner. A SwiftUI
/// `TextField` can't: its field editor takes those keys before `onKeyPress` sees them.
struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    /// Changed to put the cursor in the field.
    var focusRequest: Int = 0
    var onSubmit: () -> Void = {}
    /// ↑ (-1) or ↓ (+1); true if it was used.
    var onMove: ((Int) -> Bool)?
    /// Backspace with nothing typed.
    var onDeleteWhenEmpty: (() -> Void)?
    /// Escape; true if it was used, otherwise it goes on to the window (to close a sheet).
    var onEscape: (() -> Bool)?
    var accessibilityLabel: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandTextField
        var lastFocusRequest = -1

        init(_ parent: CommandTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove?(-1) ?? false
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove?(1) ?? false
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty, let delete = parent.onDeleteWhenEmpty else { return false }
                delete()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape?() ?? false
            default:
                return false
            }
        }
    }
}
