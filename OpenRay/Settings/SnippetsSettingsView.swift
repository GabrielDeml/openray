import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let snippetsID = "snippets"
}

/// Settings › Snippets: the list of snippets and the editor they are written in
/// (docs/DESIGN.md §4.9). What it shows and does is `SnippetsSettingsModel`'s.
struct SnippetsSettingsView: View {
    @Bindable var model: SnippetsSettingsModel
    /// The snippet the user is asked about before it is deleted.
    @State private var snippetToDelete: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            List(model.snippets) { snippet in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snippet.name)
                        Text(snippet.firstLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if let keyword = snippet.keyword {
                        Text(keyword)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Edit") {
                        model.edit(snippet)
                    }
                    Button("Delete", role: .destructive) {
                        snippetToDelete = snippet
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                }
            }

            // An error of the editor is shown in the editor.
            if let error = model.errorMessage, model.draft == nil {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
            }

            HStack {
                Button("New Snippet…") {
                    model.edit(nil)
                }
                Spacer()
                Text("Find a snippet in OpenRay by its name or keyword, or with Search Snippets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear {
            model.start()
        }
        // The model opens the editor, not a button of this view alone: "Edit Snippet…" and
        // "Create Snippet" in the launcher set the draft too.
        .sheet(item: $model.draft) { draft in
            SnippetEditor(model: model, lastDraft: draft)
        }
        // A dialog and not a question in the launcher's panel: this is the settings window.
        .confirmationDialog(
            deletionQuestion, isPresented: isAskingAboutDeletion, presenting: snippetToDelete
        ) { snippet in
            Button("Delete Snippet", role: .destructive) {
                Task { await model.delete(snippet.id) }
            }
        } message: { _ in
            Text("The snippet is deleted for good.")
        }
    }

    private var deletionQuestion: String {
        guard let snippetToDelete else { return "" }
        return String(localized: "Delete “\(snippetToDelete.name)”?")
    }

    private var isAskingAboutDeletion: Binding<Bool> {
        Binding(
            get: { snippetToDelete != nil },
            set: { isAsking in
                if !isAsking {
                    snippetToDelete = nil
                }
            })
    }
}

/// The sheet a snippet is written in.
///
/// Its fields edit the model's draft and keep no copy of their own. The sheet goes away with
/// the pane when Settings shows another one, and what was typed has to be there when it
/// comes back.
private struct SnippetEditor: View {
    let model: SnippetsSettingsModel
    /// What the sheet shows for the moment in which it closes, when the model's draft is
    /// already gone.
    let lastDraft: Snippet

    /// The snippet as the fields show it.
    private var snippet: Snippet {
        model.draft ?? lastDraft
    }

    var body: some View {
        let problem = model.problem(with: snippet)

        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: nameText)
                TextField(
                    "Keyword", text: keywordText,
                    prompt: Text("Optional: a short word the snippet is also found by"))
            }

            // ⌘V works here through the Edit menu of the hidden main menu (§4.1.1).
            TextEditor(text: bodyText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(.separator)
                }
                .accessibilityLabel("Text")

            Text(
                "{date}, {time} and {datetime} become the current date and time; {date format=\"yyyy-MM-dd\"} writes them your way. {clipboard} becomes the text you copied last. {cursor} is where the caret is left after pasting. To write a placeholder out, double its braces: {{date}}."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Preview") {
                Text(model.preview(of: snippet))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = model.errorMessage {
                // The store refused the snippet.
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelEditing()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // The model closes the sheet when the snippet is stored, and leaves it
                    // open with a message when the store refuses it.
                    Task { await model.save(snippet) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // The fields write through the optional draft. One that still reports a change while the
    // sheet closes finds no draft, and the change goes nowhere.

    private var nameText: Binding<String> {
        Binding(
            get: { snippet.name },
            set: { text in model.draft?.name = text })
    }

    /// An empty field stores no keyword.
    private var keywordText: Binding<String> {
        Binding(
            get: { snippet.keyword ?? "" },
            set: { text in model.draft?.keyword = text.isEmpty ? nil : text })
    }

    private var bodyText: Binding<String> {
        Binding(
            get: { snippet.body },
            set: { text in model.draft?.body = text })
    }
}
