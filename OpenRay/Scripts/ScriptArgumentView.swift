import OpenRayCore
import SwiftUI

/// Shows which script the text in the search field is for, and the arguments it has been
/// given so far (docs/DESIGN.md §4.10). The argument that is asked for now is named by the
/// search field's placeholder.
struct ScriptArgumentView: View {
    let model: ScriptArgumentModel

    var body: some View {
        VStack(spacing: 12) {
            IconView(icon: ScriptSource.icon(of: model.script))
                .scaleEffect(2)
                .frame(width: 56, height: 56)
            Text(verbatim: model.script.metadata.title)
                .font(.system(size: 17, weight: .semibold))
            if let description = model.script.metadata.description {
                Text(verbatim: description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !model.values.isEmpty {
                enteredValues
            }
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
            } else if model.currentArgumentIsOptional {
                Text("Optional. Press Return to leave it out.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The arguments that were entered, each with what the script calls it.
    private var enteredValues: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(model.values.indices, id: \.self) { index in
                GridRow {
                    Text(verbatim: ScriptArgumentModel.label(ofArgumentAt: index, of: model.script))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(verbatim: shownValue(at: index))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
    }

    /// An optional argument that was left out has no text to show.
    private func shownValue(at index: Int) -> String {
        let value = model.values[index]
        return value.isEmpty ? "—" : value
    }
}
