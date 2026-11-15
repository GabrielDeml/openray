import Foundation

/// The calculator's answer as a row at the top of root search (docs/DESIGN.md §4.4).
///
/// A query gets the row when it is a calculation: "2+2", "sqrt(2)", "5 km to mi". A number on
/// its own does not, and neither does anything the calculator cannot work out. The user is
/// typing the name of an app far more often than a sum, and a row that came and went with
/// every half-typed expression would be in the way.
public struct CalculatorSource: SearchSource {
    public static let feature = FeatureID(rawValue: "calculator")

    public let id = SourceID(rawValue: "calculator")
    public let latency = SourceLatency.inline

    private let locale: Locale

    /// - Parameter locale: How numbers are read and written. The default follows the user's
    ///   settings as they change.
    public init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        // First, and before the text is so much as trimmed: a file pasted into the search
        // field is not looked at.
        if Calculator.isTooLong(query.raw) { return nil }

        let expression = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Most queries are names, and a name without a digit is not looked at any further.
        guard expression.contains(where: CalcLexer.isDigit) else { return nil }

        // Whatever is wrong with the input, the answer is no row: the user is still typing.
        guard let result = try? Calculator.evaluate(expression, locale: locale),
            result.isCalculation
        else { return nil }

        let item = answerItem(for: result, expression: expression)
        return [ScoredItem(item: item, quality: 1, placement: .pinnedTop)]
    }

    private func answerItem(for result: CalcResult, expression: String) -> SearchItem {
        let title = CalcFormatter.displayText(
            for: result.value, isApproximate: result.isApproximate, locale: locale)
        let answerToCopy = CalcFormatter.copyText(
            for: result.value, isApproximate: result.isApproximate, locale: locale)
        let kindLabel = String(
            localized: "Calculator", bundle: .module,
            comment:
                "The kind of a search result that is the calculator's answer, shown at the end of its row."
        )
        return SearchItem(
            id: .command(Self.feature, "answer"),
            title: title,
            subtitle: expression,
            icon: .symbol("equal.square"),
            kindLabel: kindLabel,
            // No shortcuts: the launcher gives Return to the first and ⌘Return to the second.
            actions: [
                copyAnswerAction(for: answerToCopy),
                pasteAnswerAction(for: answerToCopy),
                copyExpressionAction(for: expression),
            ])
    }

    // MARK: Actions

    private func copyAnswerAction(for answerToCopy: String) -> ActionDescriptor {
        let title = String(
            localized: "Copy Answer", bundle: .module,
            comment: "The action that copies the calculator's answer to the clipboard.")

        return ActionDescriptor(id: ActionID(rawValue: "copy-answer"), title: title) { context in
            context.copy(.text(answerToCopy, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }

    private func pasteAnswerAction(for answerToCopy: String) -> ActionDescriptor {
        let title = String(
            localized: "Paste Answer", bundle: .module,
            comment: "The action that pastes the calculator's answer into the app the user was in."
        )

        return ActionDescriptor(id: ActionID(rawValue: "paste-answer"), title: title) { context in
            // The result is not looked at: the paste service itself tells the user when it
            // could only copy.
            _ = await context.paste(.text(answerToCopy, cursorOffsetFromEnd: nil))
            return .closeLauncher
        }
    }

    private func copyExpressionAction(for expression: String) -> ActionDescriptor {
        let title = String(
            localized: "Copy Expression", bundle: .module,
            comment: "The action that copies the calculation as the user typed it to the clipboard."
        )

        return ActionDescriptor(
            id: ActionID(rawValue: "copy-expression"), title: title
        ) { context in
            context.copy(.text(expression, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }
}
