import OpenRayCore
import SwiftUI

/// What a script has printed, with the newest line at the bottom, and under it where the
/// run stands (docs/DESIGN.md §4.10).
///
/// Nothing in it takes the keyboard. The model turns the arrow keys into requests to scroll,
/// and the screen's actions do the rest.
struct ScriptOutputView: View {
    let model: ScriptOutputModel

    var body: some View {
        if let run = model.run {
            VStack(spacing: 0) {
                OutputLinesView(run: run, scrollRequest: model.scrollRequest)
                    // A run that Run Again started begins at the bottom of its own output,
                    // wherever the one before was scrolled to.
                    .id(ObjectIdentifier(run))
                Divider()
                statusLine(isRunning: run.isRunning)
            }
        } else {
            Text(verbatim: model.status)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLine(isRunning: Bool) -> some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: model.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The lines of one run, scrolled to the bottom until the user scrolls away from it.
private struct OutputLinesView: View {
    let run: ScriptRun
    let scrollRequest: ScriptOutputModel.ScrollRequest?

    @State private var position = ScrollPosition(edge: .bottom)
    /// Where the output is scrolled to, as the scroll view last reported it.
    @State private var scrollMetrics = ScrollMetrics()

    /// How far one press of an arrow key scrolls, about four lines of output.
    private static let scrollStep: CGFloat = 60

    var body: some View {
        ScrollView {
            // The lines are read from the run here, in the body, and not kept in a copy: a
            // script can print a hundred pieces a second.
            LazyVStack(alignment: .leading, spacing: 0) {
                if run.output.hasDroppedOutput {
                    Text("Earlier output was dropped. Only the newest is kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 6)
                }
                ForEach(run.output.lines) { line in
                    // An empty text would have no height, and an empty line has to show.
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(geometry)
        } action: { _, metrics in
            scrollMetrics = metrics
        }
        .onChange(of: scrollRequest) { _, request in
            if let request {
                scroll(by: request.steps)
            }
        }
    }

    private func scroll(by steps: Int) {
        let wanted = scrollMetrics.offset + CGFloat(steps) * Self.scrollStep
        let target = min(max(wanted, 0), scrollMetrics.furthestOffset)
        // Not animated: a held arrow key repeats faster than an animation ends.
        position.scrollTo(y: target)
    }
}

/// How far the output is scrolled, and how far it can be.
private nonisolated struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var furthestOffset: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        furthestOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
    }
}
