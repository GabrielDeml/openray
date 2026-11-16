/// What a script has printed, as the lines the output screen shows (docs/DESIGN.md §4.10).
///
/// It keeps the newest output up to a fixed size. A script that prints without end loses its
/// oldest lines and never grows OpenRay's memory beyond that.
public struct ScriptOutputBuffer: Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        /// Counted from the first line the buffer made, and never given twice. Lines that
        /// were dropped keep their numbers, so the rows of a list do not change identity when
        /// the oldest ones go.
        public let id: Int
        public var text: String
        /// Whether the script printed no line end between the line before and this one. A
        /// line of the script that is longer than `maximumLineLength` is kept as several.
        public let continuesLine: Bool
    }

    /// What a line counts for besides its text. It stands for the memory of the `Line` and
    /// of its string, and it bounds how many lines there can be: without it a script that
    /// prints only empty lines would cost nothing, and with a cost of one byte it could
    /// leave millions of rows for the view. With this, 4 MB are 65,536 lines at most.
    static let lineOverhead = 64
    /// The longest text one line holds, in UTF-8 bytes. The view lays a line out as one
    /// paragraph, again after every piece that is added to it, and that takes seconds for a
    /// paragraph of some hundred kilobytes: minified JSON, or what `base64` prints.
    static let maximumLineLength = 4 * 1024

    /// Oldest first. The last one is still growing unless the output ended with a newline.
    public private(set) var lines: [Line] = []
    /// Whether the beginning of the output is gone because there was too much of it.
    public private(set) var hasDroppedOutput = false

    private let capacity: Int
    /// The UTF-8 bytes of `lines`, with `lineOverhead` more for each line.
    private var keptBytes = 0
    private var nextLineID = 0
    /// Whether the last line was ended, so that the next text begins a new one.
    private var lastLineIsFinished = true
    /// Whether the last thing that arrived was a CR. What it means depends on what follows,
    /// which may come with the next piece.
    private var endsWithCarriageReturn = false

    /// - Parameter capacity: How many bytes are kept, `lineOverhead` for each line included.
    ///   The line that is being written stays in any case, so a buffer made smaller than one
    ///   line keeps one line.
    public init(capacity: Int = 4 * 1024 * 1024) {
        self.capacity = max(capacity, 0)
    }

    public var isEmpty: Bool {
        lines.isEmpty
    }

    /// Everything that is kept, as one text with the line ends the script printed. This is
    /// what Copy Output copies.
    public var text: String {
        var text = ""
        for (index, line) in lines.enumerated() {
            if index > 0 && !line.continuesLine {
                text += "\n"
            }
            text += line.text
        }
        return text
    }

    /// - Parameter text: The next piece of output, without control codes (`AnsiStripper`).
    ///   A piece may end anywhere, also between a CR and its LF.
    public mutating func append(_ text: String) {
        // Cut at the bytes of LF and CR and not at characters: to Swift a CR LF is one
        // character, and it would have to be two when the pieces split it.
        let bytes = text.utf8
        var segmentStart = bytes.startIndex
        var index = bytes.startIndex

        while index < bytes.endIndex {
            let byte = bytes[index]
            let isLineFeed = byte == UInt8(ascii: "\n")
            let isCarriageReturn = byte == UInt8(ascii: "\r")
            if isLineFeed || isCarriageReturn {
                write(text[segmentStart..<index])
                if isLineFeed {
                    endLine()
                } else {
                    carriageReturn()
                }
                segmentStart = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        write(text[segmentStart...])

        dropOldestIfOverCapacity()
    }

    // MARK: Lines

    private mutating func write(_ segment: Substring) {
        if segment.isEmpty { return }

        if endsWithCarriageReturn {
            // A CR with text after it: the script writes over the line, as a progress bar
            // does.
            restartLine()
            endsWithCarriageReturn = false
        }
        if lastLineIsFinished {
            beginLine(continuingLine: false)
        }

        // The piece before this one may have ended inside a character: a letter whose accent
        // comes now, or the first half of a flag. The two are placed together, as they would
        // be had they arrived together.
        var rest = segment
        var rejoined = ""
        if let unfinished = unfinishedCharacter(before: segment) {
            lines[lines.count - 1].text.removeLast()
            keptBytes -= unfinished.utf8.count
            rejoined = String(unfinished) + segment
            rest = rejoined[...]
        }

        while !rest.isEmpty {
            let last = lines.count - 1
            let room = Self.maximumLineLength - lines[last].text.utf8.count
            var piece = Self.beginning(of: rest, fittingInto: room)

            if piece.isEmpty {
                if !lines[last].text.isEmpty {
                    // The line is full. The script's line goes on in the next one.
                    beginLine(continuingLine: true)
                    continue
                }
                // One character that is longer than a whole line, which only a pile of
                // combining marks is. It stays whole.
                piece = rest.prefix(1)
            }

            lines[last].text += piece
            keptBytes += piece.utf8.count
            rest = rest[piece.endIndex...]
        }
    }

    /// The last character of the line that is being written, when the segment begins with
    /// more of that same character.
    private func unfinishedCharacter(before segment: Substring) -> Character? {
        guard let lastCharacter = lines[lines.count - 1].text.last,
            let firstScalar = segment.unicodeScalars.first
        else { return nil }

        // Whether a scalar belongs to the character before it depends on that character and
        // on the scalar, and on nothing that follows.
        var joined = String(lastCharacter)
        joined.unicodeScalars.append(firstScalar)
        return joined.count == 1 ? lastCharacter : nil
    }

    /// As much of the beginning of the text as fits into this many UTF-8 bytes, in whole
    /// characters.
    private static func beginning(of text: Substring, fittingInto byteCount: Int) -> Substring {
        if text.utf8.count <= byteCount { return text }

        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let lengthWithNext = text.utf8.distance(from: text.startIndex, to: next)
            if lengthWithNext > byteCount { break }
            end = next
        }
        return text[..<end]
    }

    private mutating func endLine() {
        // After a CR this LF is the second half of a CR LF, which ends the line like an LF
        // alone.
        endsWithCarriageReturn = false

        if lastLineIsFinished {
            // Two line ends in a row: an empty line.
            beginLine(continuingLine: false)
        }
        lastLineIsFinished = true
    }

    private mutating func carriageReturn() {
        // Nothing is emptied yet: that waits for text to write over the line. Several CRs in
        // a row count as one, so the CR CR LF that a terminal layer makes of a CR LF still
        // ends a line with its text in it.
        endsWithCarriageReturn = true
    }

    private mutating func beginLine(continuingLine: Bool) {
        lines.append(Line(id: nextLineID, text: "", continuesLine: continuingLine))
        nextLineID += 1
        keptBytes += Self.lineOverhead
        lastLineIsFinished = false
    }

    /// Empties the line that is being written. It stays the same line, with the same ID.
    private mutating func restartLine() {
        if lastLineIsFinished { return }

        // Of a line that is kept as several, the first stays and is emptied.
        while lines.count > 1 && lines[lines.count - 1].continuesLine {
            let removed = lines.removeLast()
            keptBytes -= removed.text.utf8.count + Self.lineOverhead
        }

        let last = lines.count - 1
        keptBytes -= lines[last].text.utf8.count
        lines[last].text = ""
    }

    // MARK: The limit

    private mutating func dropOldestIfOverCapacity() {
        if keptBytes <= capacity { return }
        hasDroppedOutput = true

        // Down to three quarters and not just below the limit: removing lines from the front
        // of the array moves all the others, which must not happen for every line that
        // arrives from then on.
        let target = capacity * 3 / 4

        // The last line stays in any case; it may still be growing.
        var dropCount = 0
        var bytesLeft = keptBytes
        while dropCount < lines.count - 1 && bytesLeft > target {
            bytesLeft -= lines[dropCount].text.utf8.count + Self.lineOverhead
            dropCount += 1
        }
        lines.removeFirst(dropCount)
        keptBytes = bytesLeft
    }
}
