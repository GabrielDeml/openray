/// One event of a server-sent event stream.
public struct ServerSentEvent: Sendable, Equatable {
    /// The value of the `event` field, or nil when the event has none.
    public var event: String?
    /// The `data` lines, joined with a line feed.
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Reads server-sent events from bytes as they arrive, by the rules of the WHATWG HTML
/// standard (docs/DESIGN.md §4.6.2).
///
/// The bytes can be cut anywhere: inside a line, between a carriage return and its line feed,
/// or in the middle of a character. Nothing a server sends makes the parser trap; bytes that
/// are not UTF-8 become replacement characters.
public struct SSEParser: Sendable {
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The bytes of the line that has not ended yet.
    private var unfinishedLine: [UInt8] = []
    /// A carriage return ended the last line. A line feed that comes next belongs to it and
    /// starts no line of its own, even when it only arrives with the next chunk.
    private var lastByteWasCarriageReturn = false
    /// Nothing has been read yet. Only the stream's very first line may begin with a byte
    /// order mark.
    private var isFirstLine = true

    /// The fields of the event that no blank line has ended yet.
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Takes the next bytes of the stream and returns the events they complete.
    public mutating func consume(_ bytes: some Collection<UInt8>) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []

        for byte in bytes {
            if byte == Self.lineFeed && lastByteWasCarriageReturn {
                lastByteWasCarriageReturn = false
                continue
            }
            lastByteWasCarriageReturn = byte == Self.carriageReturn

            let endsLine = byte == Self.lineFeed || byte == Self.carriageReturn
            if !endsLine {
                unfinishedLine.append(byte)
                continue
            }

            if let event = takeLine() {
                events.append(event)
            }
        }
        return events
    }

    /// Tells the parser that the stream has ended. An event that no blank line ended is
    /// dropped, as the standard asks: the server was cut off before it had finished it.
    public mutating func finish() {
        self = SSEParser()
    }

    /// Reads the line that has just ended. Returns an event when the line was the blank one
    /// that ends it.
    private mutating func takeLine() -> ServerSentEvent? {
        var line = unfinishedLine[...]
        unfinishedLine.removeAll(keepingCapacity: true)

        if isFirstLine {
            isFirstLine = false
            if line.starts(with: Self.byteOrderMark) {
                line = line.dropFirst(Self.byteOrderMark.count)
            }
        }

        if line.isEmpty {
            return takeEvent()
        }
        if line.first == Self.colon {
            // A comment. Servers send them to keep the connection open.
            return nil
        }

        let name: ArraySlice<UInt8>
        var value: ArraySlice<UInt8> = []
        if let colonIndex = line.firstIndex(of: Self.colon) {
            name = line[..<colonIndex]
            value = line[line.index(after: colonIndex)...]
            // One space after the colon is part of the syntax, a second one part of the value.
            if value.first == Self.space {
                value = value.dropFirst()
            }
        } else {
            // A line without a colon is a field with an empty value.
            name = line
        }

        switch String(decoding: name, as: UTF8.self) {
        case "event":
            eventName = String(decoding: value, as: UTF8.self)
        case "data":
            dataLines.append(String(decoding: value, as: UTF8.self))
        default:
            // `id` and `retry` are for reconnecting, which a request for one reply never does.
            // Anything else the standard says to ignore.
            break
        }
        return nil
    }

    /// Ends the event whose fields have been collected. A blank line after no `data` line
    /// ends nothing.
    private mutating func takeEvent() -> ServerSentEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }

        if dataLines.isEmpty { return nil }

        var event = ServerSentEvent(data: dataLines.joined(separator: "\n"))
        // An empty name is the same as none.
        if let eventName, !eventName.isEmpty {
            event.event = eventName
        }
        return event
    }
}
