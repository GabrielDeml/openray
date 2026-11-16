import AppKit
import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let commandsID = "commands"

    static func commands(model: CommandsSettingsModel) -> SettingsPane {
        SettingsPane(
            id: commandsID, title: "Commands", systemImage: "command", order: 10,
            makeView: { AnyView(CommandsSettingsView(model: model)) })
    }
}

/// Settings › Commands: which items show up in search and under which aliases, the quicklinks,
/// and the order of the fallback list.
struct CommandsSettingsView: View {
    private enum Tab: Hashable {
        case items
        case quicklinks
        case fallback
    }

    @Bindable var model: CommandsSettingsModel
    @State private var tab = Tab.items

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Items").tag(Tab.items)
                Text("Quicklinks").tag(Tab.quicklinks)
                Text("Fallback").tag(Tab.fallback)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch tab {
            case .items: CommandItemsList(model: model)
            case .quicklinks: QuicklinkList(model: model)
            case .fallback: FallbackList(model: model)
            }

            if let error = model.errorMessage {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
            }
        }
        .onAppear {
            model.start()
        }
        .onChange(of: model.itemToFocus) { _, item in
            // "Add Alias…" in the launcher opened the pane for one item, which is in the list
            // of items.
            if item != nil {
                tab = .items
            }
        }
    }
}

// MARK: - Items

private struct CommandItemsList: View {
    @Bindable var model: CommandsSettingsModel
    @FocusState private var focusedAliasField: ItemID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $model.scope) {
                    Text("Commands").tag(CommandsSettingsModel.Scope.commands)
                    Text("Applications").tag(CommandsSettingsModel.Scope.applications)
                }
                .labelsHidden()
                .fixedSize()
                TextField("Filter", text: $model.filter)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List(model.rows) { row in
                CommandItemRow(row: row, model: model, focusedAliasField: $focusedAliasField)
            }
            .listStyle(.inset)
        }
        // A quicklink added or deleted on the next tab changes what there is to list here.
        .onAppear {
            model.reloadItems()
        }
    }
}

private struct CommandItemRow: View {
    let row: CommandsSettingsModel.Row
    let model: CommandsSettingsModel
    var focusedAliasField: FocusState<ItemID?>.Binding

    /// What the alias field holds while it is being edited. The stored aliases replace it when
    /// they change.
    @State private var aliasText = ""

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: row.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                Text(row.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)

            TextField("Alias", text: $aliasText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .focused(focusedAliasField, equals: row.id)
                .onSubmit(saveAliases)
                .help("Short names this item is found by, separated by commas")

            Toggle("In Search", isOn: isShownInSearch)
                .help("Show this item in search results")
            Toggle("Enabled", isOn: isEnabled)
                .help("A disabled item is not available anywhere in OpenRay")
        }
        .toggleStyle(.checkbox)
        .onAppear {
            aliasText = row.aliasText
            takeFocusIfAskedFor()
        }
        .onChange(of: row.aliasText) { _, stored in
            aliasText = stored
        }
        .onChange(of: model.itemToFocus) { _, _ in
            takeFocusIfAskedFor()
        }
        // Leaving the field saves too, like pressing Return in it.
        .onChange(of: focusedAliasField.wrappedValue) { previous, _ in
            if previous == row.id {
                saveAliases()
            }
        }
    }

    /// "Add Alias…" in the launcher opens the pane for one item. Its row takes the keyboard,
    /// and does so from here because the row may only come to exist with the filter that the
    /// same request set.
    private func takeFocusIfAskedFor() {
        guard model.itemToFocus == row.id else { return }
        focusedAliasField.wrappedValue = row.id
        model.itemToFocus = nil
    }

    private func saveAliases() {
        if aliasText == row.aliasText { return }
        Task { await model.setAliases(aliasText, for: row.id) }
    }

    // The switches show what the store holds. A change goes to the store, and the row is
    // drawn again when the model has heard of it.

    private var isShownInSearch: Binding<Bool> {
        Binding(
            get: { !row.isHidden },
            set: { isShown in
                Task { await model.setHidden(!isShown, for: row.id) }
            })
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { row.isEnabled },
            set: { isEnabled in
                Task { await model.setEnabled(isEnabled, for: row.id) }
            })
    }
}

// MARK: - Quicklinks

private struct QuicklinkList: View {
    let model: CommandsSettingsModel
    /// The quicklink in the editor; nil while the editor is closed.
    @State private var draft: Quicklink?

    var body: some View {
        VStack(spacing: 0) {
            List(model.quicklinks) { quicklink in
                HStack(spacing: 8) {
                    IconView(icon: QuicklinkSource.icon(of: quicklink))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(quicklink.name)
                        Text(quicklink.template)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Edit") {
                        draft = quicklink
                    }
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteQuicklink(quicklink.id) }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Add Quicklink…") {
                    draft = Quicklink(name: "", template: "https://", createdAt: Date())
                }
                Spacer()
                Text("{query} in a link stands for what you type after the quicklink's name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .sheet(item: $draft) { quicklink in
            QuicklinkEditor(quicklink: quicklink, model: model) {
                draft = nil
            }
        }
    }
}

private struct QuicklinkEditor: View {
    @State var quicklink: Quicklink
    let model: CommandsSettingsModel
    let close: () -> Void

    var body: some View {
        let problem = model.problem(with: quicklink)

        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $quicklink.name)
                TextField("Link", text: $quicklink.template)
                TextField(
                    "Icon", text: iconText, prompt: Text("An emoji, or sf: and a symbol name"))
                LabeledContent("Open With") {
                    HStack {
                        Text(openWithName)
                            .foregroundStyle(quicklink.openWith == nil ? .secondary : .primary)
                        Spacer()
                        if quicklink.openWith != nil {
                            Button("Default App") {
                                quicklink.openWith = nil
                            }
                        }
                        Button("Choose…", action: chooseApp)
                    }
                }
            }

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await model.save(quicklink)
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// An empty field stores no icon, which gives the quicklink the default one.
    private var iconText: Binding<String> {
        Binding(
            get: { quicklink.icon ?? "" },
            set: { text in quicklink.icon = text.isEmpty ? nil : text })
    }

    private var openWithName: String {
        guard let bundleID = quicklink.openWith else {
            return String(localized: "Default app for the link")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // The app has been uninstalled; the link then opens with the default app.
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // An app without a bundle identifier cannot be stored, so the choice is left as it was.
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            quicklink.openWith = bundleID
        }
    }
}

// MARK: - Fallback

private struct FallbackList: View {
    let model: CommandsSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.fallbackRows) { row in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        if let title = row.title {
                            Text(title)
                            Spacer()
                            Button("Remove") {
                                Task { await model.removeFallback(row.id) }
                            }
                        } else {
                            // An entry for a feature of a later version keeps its place. It
                            // has no Remove button, because nothing here could add it back.
                            Text("\(row.id.local) (not available yet)")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .onMove { source, destination in
                    Task { await model.moveFallback(fromOffsets: source, toOffset: destination) }
                }
            }
            .listStyle(.inset)

            HStack {
                Menu("Add") {
                    ForEach(model.fallbackCandidates) { quicklink in
                        Button(quicklink.name) {
                            Task { await model.addFallback(quicklink.itemID) }
                        }
                    }
                }
                .fixedSize()
                .disabled(model.fallbackCandidates.isEmpty)
                Spacer()
                Text("Shown in this order when a search finds nothing. Drag to reorder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}
