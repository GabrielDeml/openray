/// One block of an answer, as the chat draws it (docs/DESIGN.md §4.6.6).
public struct MarkdownBlock: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case paragraph
        case heading
        /// An item of a list. `number` is what an ordered list wrote in front of it; a bullet
        /// has none.
        case listItem(number: Int?)
        /// Fenced code. `language` is the word after the opening fence, if there is one.
        case code(language: String?)
        case quote
    }

    /// The block's place in its answer, counted from 0. A block keeps it while the answer
    /// grows.
    public let id: Int
    public let kind: Kind
    /// The block's text without the marks that made it a block. Inline formatting is still
    /// in it; code is as it was written.
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Splits an answer into the blocks the chat draws one below the other: paragraphs, list
/// items, fenced code, quotes and headings.
///
/// This is not a Markdown parser. It knows the little that the system prompt lets the model
/// use, and reads everything else as text: a table or an image comes out as a paragraph. Lists
/// do not nest, an item inside an item is one more item. Inline formatting is left in the text
/// for the view.
///
/// The marks are chosen so that a line that has begun a block still begins one when more of it
/// arrives: a heading needs the space after its `#`, and a list item the space after its mark.
/// `StreamingMarkdown` depends on that.
public enum MarkdownBlockParser {
    public static func blocks(of text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for found in parse(lines(of: text)) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: found.kind, text: found.text))
        }
        return blocks
    }

    /// A block and the line it begins on, which is where `StreamingMarkdown` reads on from.
    struct FoundBlock {
        var kind: MarkdownBlock.Kind
        var text: String
        var firstLine: Int
    }

    /// What one line is, seen without the lines around it.
    private enum Line {
        case blank
        /// The line that opens a code block. `indentation` is how far it is indented, which
        /// the lines of the block are too when the block is part of a list item.
        case fence(length: Int, indentation: Int, language: String?)
        case heading(Substring)
        case listItem(number: Int?, text: Substring)
        case quote(Substring)
        case text(Substring)
    }

    private static let fenceCharacter: Character = "`"
    /// A longer run of digits is a number in a sentence and not the mark of a list item. It
    /// also keeps the number within what an `Int` holds.
    private static let longestItemNumber = 9

    static func lines(of text: String) -> [Substring] {
        // Not a split at "\n": to Swift a carriage return with its line feed is one character.
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// The blocks of `lines`, in order.
    ///
    /// Where a block ends depends only on its own lines and the one after them, and nothing is
    /// remembered from one block to the next. So reading on from the first line of any block
    /// finds the same blocks as reading from the top.
    static func parse(_ lines: [Substring]) -> [FoundBlock] {
        var blocks: [FoundBlock] = []
        var index = 0

        while index < lines.count {
            let firstLine = index
            let kind: MarkdownBlock.Kind
            var blockLines: [Substring] = []

            switch classify(lines[index]) {
            case .blank:
                index += 1
                continue

            case .fence(let length, let indentation, let language):
                kind = .code(language: language)
                index += 1
                // A fence that is never closed holds everything after it. While a reply is
                // arriving, that is the code written so far.
                while index < lines.count {
                    let line = lines[index]
                    index += 1
                    if closesFence(line, ofLength: length) { break }
                    blockLines.append(removingIndentation(indentation, from: line))
                }

            case .heading(let text):
                kind = .heading
                blockLines.append(text)
                index += 1

            case .listItem(let number, let text):
                kind = .listItem(number: number)
                blockLines.append(text)
                index += 1
                // Lines without a mark of their own go on with the item.
                while index < lines.count, case .text(let more) = classify(lines[index]) {
                    blockLines.append(more)
                    index += 1
                }

            case .quote(let text):
                kind = .quote
                blockLines.append(text)
                index += 1
                while index < lines.count, case .quote(let more) = classify(lines[index]) {
                    blockLines.append(more)
                    index += 1
                }

            case .text(let text):
                kind = .paragraph
                blockLines.append(text)
                index += 1
                while index < lines.count, case .text(let more) = classify(lines[index]) {
                    blockLines.append(more)
                    index += 1
                }
            }

            let text = blockLines.joined(separator: "\n")
            blocks.append(FoundBlock(kind: kind, text: text, firstLine: firstLine))
        }
        return blocks
    }

    // MARK: Lines

    private static func classify(_ line: Substring) -> Line {
        let content = trimmed(line)
        guard let first = content.first else { return .blank }

        switch first {
        case fenceCharacter:
            let fence = content.prefix(while: { $0 == fenceCharacter })
            if fence.count >= 3 {
                let indentation = line.prefix(while: \.isWhitespace).count
                // The first word names the language; some models add a file name after it.
                let afterFence = trimmed(content.dropFirst(fence.count))
                let language = afterFence.prefix(while: { !$0.isWhitespace })
                return .fence(
                    length: fence.count, indentation: indentation,
                    language: language.isEmpty ? nil : String(language))
            }

        case "#":
            let hashes = content.prefix(while: { $0 == "#" })
            let afterHashes = content.dropFirst(hashes.count)
            if hashes.count <= 6, let text = textAfterMark(afterHashes) {
                return .heading(text)
            }

        case "-", "*", "+":
            if let text = textAfterMark(content.dropFirst()) {
                return .listItem(number: nil, text: text)
            }

        case ">":
            return .quote(trimmed(content.dropFirst()))

        case "0"..."9":
            let digits = content.prefix(while: { ("0"..."9").contains($0) })
            let afterDigits = content.dropFirst(digits.count)
            let hasDelimiter = afterDigits.first == "." || afterDigits.first == ")"
            if digits.count <= longestItemNumber, hasDelimiter,
                let number = Int(digits), let text = textAfterMark(afterDigits.dropFirst())
            {
                return .listItem(number: number, text: text)
            }

        default:
            break
        }
        return .text(content)
    }

    /// What follows the mark of a heading or a list item, or nil when `rest` does not begin
    /// with the space that makes it one: "#hashtag" and "-5" are text.
    private static func textAfterMark(_ rest: Substring) -> Substring? {
        guard let separator = rest.first, separator == " " || separator == "\t" else {
            return nil
        }
        return trimmed(rest)
    }

    private static func closesFence(_ line: Substring, ofLength length: Int) -> Bool {
        let content = trimmed(line)
        return content.count >= length && content.allSatisfy { $0 == fenceCharacter }
    }

    /// The line without the indentation its fence had. A line that is indented less loses
    /// what it has.
    private static func removingIndentation(_ indentation: Int, from line: Substring) -> Substring {
        var rest = line
        var removed = 0
        while removed < indentation, let first = rest.first, first.isWhitespace {
            rest.removeFirst()
            removed += 1
        }
        return rest
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var result = text.drop(while: \.isWhitespace)
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}

/// The blocks of an answer that is still arriving.
///
/// Every block but the last is finished: no text that follows can change it, and it keeps its
/// `id`. Only the last block is read again when more text arrives, so a long answer does not
/// get slower to show as it grows.
public struct StreamingMarkdown: Sendable {
    /// The whole text so far.
    public private(set) var text = ""
    /// The same blocks `MarkdownBlockParser.blocks(of:)` finds in `text`.
    public private(set) var blocks: [MarkdownBlock] = []

    /// How many of `blocks` are finished.
    private var finishedCount = 0
    /// The text from the first line of the last block on.
    private var unfinishedText = ""

    public init() {}

    /// Brings the blocks in line with `newText`.
    ///
    /// Text that goes on from the text before is the usual case, and only what is new of it
    /// is read. Any other text is read from its start: a reply starts over when the provider
    /// had to send its request again.
    public mutating func update(to newText: String) {
        // Compared as UTF-8, which is exact and does not care where a character ends: a
        // reply can be cut between a letter and the accent that combines with it.
        if newText.utf8.starts(with: text.utf8) {
            let endOfKnownText = newText.utf8.index(newText.startIndex, offsetBy: text.utf8.count)
            unfinishedText += newText[endOfKnownText...]
        } else {
            blocks = []
            finishedCount = 0
            unfinishedText = newText
        }
        text = newText

        let lines = MarkdownBlockParser.lines(of: unfinishedText)
        let found = MarkdownBlockParser.parse(lines)

        blocks.removeSubrange(finishedCount...)
        for block in found {
            blocks.append(MarkdownBlock(id: blocks.count, kind: block.kind, text: block.text))
        }

        // The last block can still grow or turn out to be something else: "1" is a paragraph
        // until ". First" follows. The blocks before it ended on lines that are complete.
        if found.count > 1, let last = found.last {
            finishedCount = blocks.count - 1
            // `lines` are slices of `unfinishedText`, so the line's start is an index into it.
            let startOfLastBlock = lines[last.firstLine].startIndex
            unfinishedText = String(unfinishedText[startOfLastBlock...])
        }
    }
}
