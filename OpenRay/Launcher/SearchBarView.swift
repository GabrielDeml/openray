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

/// The top of the launcher: an icon and the search field, or the title of a screen that does
/// without the field.
final class SearchBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 56

    let field = ShellSearchField()
    /// Called when the user edits the text, not when `text` is set.
    var onTextChange: ((String) -> Void)?

    private let icon = NSImageView()
    /// Stands in the field's place while a screen hides the field.
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        // The placeholder names the field only while it is empty. The label goes on the cell,
        // which is the field's accessibility element.
        field.cell?.setAccessibilityLabel(String(localized: "Search"))
        field.delegate = self

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = field.font
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true

        for view in [icon, field, titleLabel] {
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
            titleLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Makes the bar look as the model asks: the placeholder, a back arrow on a screen, and the
    /// screen's title in place of a field the screen hides.
    func apply(_ appearance: SearchBarAppearance) {
        field.placeholderString = appearance.placeholder

        let isOnAScreen = appearance.screenTitle != nil
        let symbolName = isOnAScreen ? "chevron.left" : "magnifyingglass"
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

        titleLabel.stringValue = appearance.screenTitle ?? ""
        titleLabel.isHidden = !appearance.isFieldHidden

        let fieldWasHidden = field.isHidden
        field.isHidden = appearance.isFieldHidden
        if appearance.isFieldHidden {
            // A hidden field must not go on taking what is typed.
            window?.makeFirstResponder(nil)
        } else if fieldWasHidden {
            window?.makeFirstResponder(field)
            moveInsertionPointToEnd()
        }
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
            moveInsertionPointToEnd()
        }
    }

    private func moveInsertionPointToEnd() {
        let endOfText = NSRange(location: field.stringValue.utf16.count, length: 0)
        field.currentEditor()?.selectedRange = endOfText
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(field.stringValue)
    }
}
