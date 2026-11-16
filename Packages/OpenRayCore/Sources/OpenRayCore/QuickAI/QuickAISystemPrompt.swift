import Foundation

/// The instructions every Quick AI request begins with (docs/DESIGN.md §4.6.3).
///
/// The text is not localised: it is read by the model, which is told to answer in the language
/// of the question.
public enum QuickAISystemPrompt {
    private static let instructions = """
        You answer questions typed into OpenRay, a macOS keyboard launcher. Answers appear in a \
        small panel and are often copied or pasted elsewhere. Lead with the answer: no preamble, \
        no restating the question, no sign-off. Default to one to four sentences or a short \
        list; go longer only when steps or code are needed. When asked to write or rewrite \
        text, output only that text. Put code in fenced blocks with a language tag. Use \
        Markdown sparingly: bold, inline code, lists, fenced code; no tables, headings or \
        images. If the question is ambiguous, answer the likeliest reading and state the \
        assumption in one clause. If the answer may have changed since your training data, say \
        so briefly. Reply in the language of the question.
        """

    /// The prompt for a thread that begins on `date`.
    ///
    /// A thread keeps the prompt it began with, also past midnight: the prompt cache only
    /// serves requests whose beginning has not changed.
    ///
    /// - Parameter timeZone: The zone the day is read in, the user's by default.
    public static func text(on date: Date, timeZone: TimeZone = .current) -> String {
        // Year, month and day in the Gregorian calendar as 2026-11-15, whatever calendar and
        // locale the user has set.
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "\(instructions) Today's date is \(day)."
    }
}
