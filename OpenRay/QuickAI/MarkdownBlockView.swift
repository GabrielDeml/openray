import OpenRayCore
import SwiftUI

/// Draws one block of an answer (docs/DESIGN.md §4.6.6). Core's `MarkdownBlockParser` has
/// found the blocks; what is left for here is the formatting inside a line, which
/// `AttributedString` reads, and how each kind of block looks.
///
/// The text cannot be selected. A selectable text can take the keyboard from the search
/// field, where the next question is typed. Copy Answer and the button on a code block are
/// the ways to get text out.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// For the copy button of a code block.
    let model: QuickAIChatModel

    private static let textSize: CGFloat = 14
    private static let codeSize: CGFloat = 12

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(inlineText)
                .font(.system(size: Self.textSize))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading:
            Text(inlineText)
                .font(.system(size: Self.textSize, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

        case .listItem(let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker(forItemNumbered: number))
                    .font(.system(size: Self.textSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(inlineText)
                    .font(.system(size: Self.textSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)

        case .quote:
            Text(inlineText)
                .font(.system(size: Self.textSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 3)
                }

        case .code(let language):
            codeBlock(language: language)
        }
    }

    private func codeBlock(language: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language {
                    Text(verbatim: language)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.copyCode(of: block)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Copy Code")
                .accessibilityLabel("Copy Code")
            }
            // Long lines wrap. A code block that scrolled sideways could not be read to its
            // end from the keyboard.
            Text(verbatim: block.text)
                .font(.system(size: Self.codeSize, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The block's text with its bold, italic, inline code and links read as Markdown.
    private var inlineText: AttributedString {
        // Line breaks are kept as the model wrote them. An answer is often cut off in the
        // middle of a mark while it arrives, and what can be read of it is still shown.
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = try? AttributedString(markdown: block.text, options: options)
        return parsed ?? AttributedString(block.text)
    }

    private func marker(forItemNumbered number: Int?) -> String {
        guard let number else { return "•" }
        return "\(number)."
    }

    // Written by hand so that it can be `nonisolated`, as `ResultRow` has it. The transcript
    // wraps blocks in `.equatable()`: while an answer arrives only its last block changes, and
    // the Markdown of the others is not read again.
    nonisolated static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.block == rhs.block && lhs.model === rhs.model
    }
}
