import AppKit

/// The launcher's only text input. AppKit rather than SwiftUI, so the shell decides first
/// responder with `makeFirstResponder`.
final class ShellSearchField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 20)
        textColor = .labelColor
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        // ⌘Z reaches the field through the Edit menu and does nothing without this.
        (cell as? NSTextFieldCell)?.allowsUndo = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether an input method is composing text in the field.
    var hasMarkedText: Bool {
        // There is a field editor only while the field is being edited.
        guard let editor = currentEditor() as? NSTextView else { return false }
        return editor.hasMarkedText()
    }
}

/// The top of the launcher: a search icon and the search field.
final class SearchBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 56

    let field = ShellSearchField()
    /// Called when the user edits the text, not when `text` is set.
    var onTextChange: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        field.placeholderString = String(localized: "Search for apps and commands…")
        // The placeholder names the field only while it is empty. The label goes on the cell,
        // which is the field's accessibility element.
        field.cell?.setAccessibilityLabel(String(localized: "Search"))
        field.delegate = self

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String {
        get { field.stringValue }
        set {
            guard field.stringValue != newValue else { return }
            field.stringValue = newValue
            // Replacing the text of a field that is being edited selects it all. Put the
            // insertion point at the end instead.
            let endOfText = NSRange(location: newValue.utf16.count, length: 0)
            field.currentEditor()?.selectedRange = endOfText
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(field.stringValue)
    }
}
