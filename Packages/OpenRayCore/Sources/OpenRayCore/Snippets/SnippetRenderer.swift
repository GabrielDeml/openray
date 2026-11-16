import Foundation

/// Turns the text of a snippet into what is pasted (docs/DESIGN.md §4.9).
///
/// The placeholders are `{date}`, `{time}`, `{datetime}`, `{clipboard}` and `{cursor}`, written
/// exactly so and in lower case. The three for date and time take a pattern:
/// `{date format="yyyy-MM-dd"}`. A placeholder in doubled braces is the way to write one out:
/// `{{date}}` gives the text `{date}`. Every other brace stays as it was typed, so a snippet of
/// JSON, of a template or of a workflow file with `${{ secrets.TOKEN }}` comes out whole.
public enum SnippetRenderer {
    public struct Rendered: Sendable, Equatable {
        public var text: String
        /// How many characters of `text` come after the place of `{cursor}`; nil for a snippet
        /// without one. This is what `PasteContent.text` takes.
        public var cursorOffsetFromEnd: Int?

        public init(text: String, cursorOffsetFromEnd: Int?) {
            self.text = text
            self.cursorOffsetFromEnd = cursorOffsetFromEnd
        }
    }

    /// - Parameters:
    ///   - clipboard: What `{clipboard}` becomes. It is put in as it is: a placeholder in
    ///     text the user copied somewhere is not one of the snippet's. nil counts as no text.
    public static func render(
        _ body: String, now: Date, locale: Locale, timeZone: TimeZone, clipboard: String?
    ) -> Rendered {
        var beforeCursor = ""
        var afterCursor = ""
        var hasCursor = false

        for piece in pieces(of: body) {
            let text: String
            switch piece {
            case .text(let literal):
                text = String(literal)
            case .dateTime(let parts, let pattern):
                text = format(now, parts, pattern: pattern, locale: locale, timeZone: timeZone)
            case .clipboard:
                text = clipboard ?? ""
            case .cursor:
                // Only the first {cursor} is a place. The editor does not save a snippet with
                // two, but one that got in some other way still has to paste, and the others
                // render as nothing.
                hasCursor = true
                continue
            }

            if hasCursor {
                afterCursor += text
            } else {
                beforeCursor += text
            }
        }

        // Counted in characters as Swift counts them, one for an emoji of several scalars and
        // one for a CR LF, because that is how far one press of ← moves the caret.
        let offset = hasCursor ? afterCursor.count : nil
        return Rendered(text: beforeCursor + afterCursor, cursorOffsetFromEnd: offset)
    }

    /// Whether rendering the snippet needs the clipboard's text. Only then is the clipboard
    /// read at all (§4.9).
    public static func usesClipboard(_ body: String) -> Bool {
        pieces(of: body).contains { piece in
            if case .clipboard = piece { return true }
            return false
        }
    }

    /// How many `{cursor}` placeholders the snippet has. The editor refuses more than one.
    static func cursorCount(in body: String) -> Int {
        var count = 0
        for piece in pieces(of: body) {
            if case .cursor = piece {
                count += 1
            }
        }
        return count
    }

    // MARK: Reading the body

    private enum DateParts: String, CaseIterable {
        case date
        case time
        case dateAndTime = "datetime"
    }

    private enum Piece {
        case text(Substring)
        /// - Parameter pattern: What `format="…"` gave; nil for the locale's own format.
        case dateTime(DateParts, pattern: String?)
        case clipboard
        case cursor
    }

    /// The longest pattern `format="…"` may hold. A limit keeps the search for the closing
    /// quote short, however long the body is and however many braces it has.
    private static let longestPattern = 100

    /// The body as text and placeholders, in order. One pass from left to right: nothing
    /// that was produced is looked at again.
    private static func pieces(of body: String) -> [Piece] {
        var pieces: [Piece] = []
        var textStart = body.startIndex
        var index = body.startIndex

        while index < body.endIndex {
            guard body[index] == "{" else {
                index = body.index(after: index)
                continue
            }

            // {{date}}: the placeholder inside, written out with its single braces.
            let inner = body.index(after: index)
            let hasSecondBrace = inner < body.endIndex && body[inner] == "{"
            if hasSecondBrace, let innerPlaceholder = placeholder(in: body, at: inner) {
                let innerEnd = innerPlaceholder.end
                let isClosedTwice = innerEnd < body.endIndex && body[innerEnd] == "}"
                if isClosedTwice {
                    pieces.append(.text(body[textStart..<index]))
                    pieces.append(.text(body[inner..<innerEnd]))
                    index = body.index(after: innerEnd)
                    textStart = index
                    continue
                }
            }

            if let (piece, end) = placeholder(in: body, at: index) {
                pieces.append(.text(body[textStart..<index]))
                pieces.append(piece)
                index = end
                textStart = index
                continue
            }

            // A brace that begins nothing known is text like any other.
            index = body.index(after: index)
        }

        pieces.append(.text(body[textStart...]))
        return pieces
    }

    /// The placeholder whose `{` is at `start`, with the index after its `}`. nil when the
    /// text there is not exactly a placeholder.
    private static func placeholder(
        in body: String, at start: String.Index
    ) -> (piece: Piece, end: String.Index)? {
        let rest = body[start...]

        let clipboard = "{clipboard}"
        if rest.hasPrefix(clipboard) {
            return (.clipboard, body.index(start, offsetBy: clipboard.count))
        }
        let cursor = "{cursor}"
        if rest.hasPrefix(cursor) {
            return (.cursor, body.index(start, offsetBy: cursor.count))
        }

        for parts in DateParts.allCases {
            let opening = "{" + parts.rawValue
            guard rest.hasPrefix(opening) else { continue }
            // A name that only begins another, as "date" begins "datetime", is no match:
            // what follows the name has to be the brace or a space.
            let afterName = body.index(start, offsetBy: opening.count)
            if let (pattern, end) = patternAndEnd(in: body, at: afterName) {
                return (.dateTime(parts, pattern: pattern), end)
            }
        }
        return nil
    }

    /// What follows the name of a date placeholder: the closing brace, or spaces and
    /// `format="…"` before it.
    ///
    /// - Returns: The pattern, nil when there is none, and the index after the `}`. nil when
    ///   the text at `index` is neither of the two forms.
    private static func patternAndEnd(
        in body: String, at index: String.Index
    ) -> (pattern: String?, end: String.Index)? {
        guard index < body.endIndex else { return nil }
        if body[index] == "}" {
            return (nil, body.index(after: index))
        }

        var afterSpaces = index
        while afterSpaces < body.endIndex, body[afterSpaces] == " " {
            afterSpaces = body.index(after: afterSpaces)
        }
        if afterSpaces == index { return nil }

        let attribute = "format=\""
        guard body[afterSpaces...].hasPrefix(attribute) else { return nil }
        let patternStart = body.index(afterSpaces, offsetBy: attribute.count)

        // The pattern is everything up to the next quote, so it cannot hold one.
        var patternEnd = patternStart
        var length = 0
        while patternEnd < body.endIndex, body[patternEnd] != "\"" {
            length += 1
            if length > longestPattern { return nil }
            patternEnd = body.index(after: patternEnd)
        }
        guard patternEnd < body.endIndex, length > 0 else { return nil }

        let closingBrace = body.index(after: patternEnd)
        guard closingBrace < body.endIndex, body[closingBrace] == "}" else { return nil }
        return (String(body[patternStart..<patternEnd]), body.index(after: closingBrace))
    }

    // MARK: Dates

    private static func format(
        _ date: Date, _ parts: DateParts, pattern: String?, locale: Locale, timeZone: TimeZone
    ) -> String {
        // `DateFormatter` and not `Date.FormatStyle`: a style takes no pattern, and its short
        // time is "9:41" in German, where the clock in the menu bar says "09:41".
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone

        if let pattern {
            // There is no pattern the formatter traps on; one it cannot read gives odd text.
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }

        // Which fields to show; the locale puts them in its order with its punctuation.
        // "j" is the hour as the locale writes it, with AM and PM or without.
        let fields: String
        switch parts {
        case .date: fields = "yMd"
        case .time: fields = "jm"
        case .dateAndTime: fields = "yMdjm"
        }
        formatter.setLocalizedDateFormatFromTemplate(fields)
        return formatter.string(from: date)
    }
}
