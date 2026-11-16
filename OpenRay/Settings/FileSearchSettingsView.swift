import AppKit
import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let fileSearchID = "file-search"
}

/// Settings › File Search: where "Search Files" looks, and the slower search for a Mac whose
/// Spotlight index is off (docs/DESIGN.md §4.8). Both are plain preferences.
struct FileSearchSettingsView: View {
    let preferences: Preferences

    var body: some View {
        Form {
            scopeSection
            if preferences.fileScope.kind == .folders {
                foldersSection
            }
            fallbackSection
            notesSection
        }
        .formStyle(.grouped)
    }

    private var scopeSection: some View {
        Section {
            Picker("Search in", selection: scopeKind) {
                Text("Home folder").tag(FileScope.Kind.home)
                Text("Chosen folders").tag(FileScope.Kind.folders)
                Text("Everywhere on this Mac").tag(FileScope.Kind.everywhere)
            }
        } footer: {
            Text(
                "Search Files finds files and folders by name. Applications are left out: they are found in the launcher itself."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(preferences.fileScope.folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Remove") {
                        remove(folder)
                    }
                }
            }
            Button("Add Folder…") {
                chooseFolder()
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("While this list is empty, Search Files looks in your home folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fallbackSection: some View {
        Section {
            Toggle("Search without Spotlight when its index is off", isOn: fallbackWalk)
        } footer: {
            Text(
                "Search Files asks Spotlight. If Spotlight indexing is switched off on this Mac, OpenRay can read the folders itself instead. That is slower and reaches only the first few levels of folders, and macOS may ask whether OpenRay may access your Desktop, Documents and Downloads folders when it does."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesSection: some View {
        Section {
            Text(
                "Files that macOS protects, such as those of Mail and Messages, may be missing from the results, and so is everything in folders you excluded from Spotlight in System Settings."
            )
            Text(
                "OpenRay never asks for Full Disk Access. It does not open the files it lists: the app you open a file with reads it."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var scopeKind: Binding<FileScope.Kind> {
        Binding(
            get: { preferences.fileScope.kind },
            set: { kind in preferences.fileScope.kind = kind })
    }

    private var fallbackWalk: Binding<Bool> {
        Binding(
            get: { preferences.fileFallbackWalk },
            set: { isOn in preferences.fileFallbackWalk = isOn })
    }

    private func remove(_ folder: String) {
        preferences.fileScope.folders.removeAll { existing in existing == folder }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path(percentEncoded: false)
        if !preferences.fileScope.folders.contains(path) {
            preferences.fileScope.folders.append(path)
        }
    }
}
