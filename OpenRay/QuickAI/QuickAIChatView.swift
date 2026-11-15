import OpenRayCore
import SwiftUI

/// The Quick AI chat (docs/DESIGN.md §4.6.6): the thread as questions and answers, with the
/// newest at the bottom.
///
/// Nothing in it takes the keyboard. The next question is typed into the search field, and
/// the model turns the arrow keys into requests to scroll.
struct QuickAIChatView: View {
    let model: QuickAIChatModel

    @State private var position = ScrollPosition(edge: .bottom)
    /// Where the transcript is scrolled to, as the scroll view last reported it.
    @State private var scrollMetrics = ScrollMetrics()

    /// How far one press of an arrow key scrolls, about three lines of text.
    private static let scrollStep: CGFloat = 54

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.turns) { turn in
                    QuestionView(question: turn.question)
                    ForEach(turn.blocks) { block in
                        MarkdownBlockView(block: block, model: model).equatable()
                    }
                }
                latestReplyState
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // The view stays at the bottom while the answer below grows, until the user scrolls
        // away from it.
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(geometry)
        } action: { _, metrics in
            scrollMetrics = metrics
        }
        .onChange(of: model.scrollRequest) { _, request in
            if let request {
                scroll(by: request.steps)
            }
        }
        .onChange(of: model.turns.count) {
            // A new question is shown wherever the user had scrolled to.
            position.scrollTo(edge: .bottom)
        }
        .overlay {
            if model.turns.isEmpty {
                Text("Type a question and press Return.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        // The answers are Markdown, and `Text` would open any link in them.
        .environment(\.openURL, OpenURLAction(handler: openLink))
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        QuickAIChatModel.opensLink(to: url) ? .systemAction : .discarded
    }

    /// What is under the last answer: that the model is thinking, what there is to say about
    /// a reply that ended, and what it cost in tokens.
    @ViewBuilder private var latestReplyState: some View {
        if model.isThinking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Thinking…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(verbatim: notice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if model.noticeLeadsToSettings {
                    Button(QuickAIChatModel.openSettingsTitle) {
                        model.showSettings()
                    }
                    .focusable(false)
                }
            }
        }
        if let tokenLine = model.tokenLine {
            Text(verbatim: tokenLine)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func scroll(by steps: Int) {
        let wanted = scrollMetrics.offset + CGFloat(steps) * Self.scrollStep
        let target = min(max(wanted, 0), scrollMetrics.furthestOffset)
        // Not animated: a held arrow key repeats faster than an animation ends, and a jump
        // of three lines reads as scrolling.
        position.scrollTo(y: target)
    }
}

/// How far the transcript is scrolled, and how far it can be.
private nonisolated struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var furthestOffset: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        furthestOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
    }
}

/// A question the user asked, set apart from the answer under it.
private struct QuestionView: View {
    let question: String

    var body: some View {
        Text(verbatim: question)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityLabel("You asked: \(question)")
    }
}
