import OpenRayCore
import SwiftUI
import UniformTypeIdentifiers

extension SettingsPane {
    static let scriptsID = "scripts"
}

/// Settings › Scripts: the folders scripts are read from, and the environment they run with
/// (docs/DESIGN.md §4.10). What it shows and does is `ScriptsSettingsModel`'s.
struct ScriptsSettingsView: View {
    @Bindable var model: ScriptsSettingsModel

    var body: some View {
        Form {
            foldersSection
            environmentSection
            notesSection
        }
        .formStyle(.grouped)
        // Again whenever the list changes: a folder that was just added may have a problem.
        .task(id: folderPaths) {
            await model.refresh()
        }
        // The model opens the panel, not a button of this view alone: "Add Script Folder…"
        // in the launcher sets `isChoosingFolder` too, before the pane is on screen.
        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) {
            result in
            // A failure means that the panel gave no folder, and then there is none to add.
            if case .success(let folder) = result {
                model.add(folder: folder)
            }
        }
        .fileDialogConfirmationLabel(Text("Add"))
    }

    private var folderPaths: [String] {
        model.folders.map(\.path)
    }

    private var foldersSection: some View {
        Section {
            ForEach(model.folders) { folder in
                FolderRow(folder: folder) {
                    model.remove(folder)
                }
            }
            Button("Add Folder…") {
                model.requestFolderPicker()
            }
        } header: {
            Text("Folders")
        } footer: {
            Text(
                "OpenRay reads the files in these folders and in the folders one level below them. A file becomes a command when it has @openray lines at its top. The name of a subfolder is shown beside its scripts."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var environmentSection: some View {
        Section {
            HStack {
                Text(verbatim: model.environmentStatus)
                Spacer()
                Button("Reload") {
                    Task { await model.reloadEnvironment() }
                }
                .disabled(model.isReloadingEnvironment)
            }
        } header: {
            Text("Shell Environment")
        } footer: {
            Text(
                "Scripts run with the environment variables of your login shell, so that they find the tools you use in Terminal. Reload after you have changed your shell's startup files. OpenRay keeps the variables in memory only."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesSection: some View {
        Section {
            Text(
                "Scripts run as you, without a sandbox: a script can do everything you can do on this Mac. OpenRay never runs one unless you ask for it, and does not run a file that other users of this Mac can change."
            )
            Text(
                "A file that should be a command and is not is listed under Script Diagnostics in the launcher, with the reason."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One folder of the list, with what there is to say about it under its path.
private struct FolderRow: View {
    let folder: ScriptsSettingsModel.Folder
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: folder.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if folder.isDefault {
                    Text("OpenRay's own folder. Open Scripts Folder in the launcher shows it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let location = folder.protectedLocation {
                    Label {
                        Text(Self.warning(for: location))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let problem = folder.problem {
                    Text(verbatim: problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if !folder.isDefault {
                Button("Remove", action: remove)
            }
        }
    }

    /// Reading a folder in one of these places makes macOS ask the user first.
    private static func warning(
        for location: ScriptFolders.ProtectedLocation
    ) -> LocalizedStringResource {
        switch location {
        case .desktop:
            "macOS may ask whether OpenRay may access your Desktop folder."
        case .documents:
            "macOS may ask whether OpenRay may access your Documents folder."
        case .downloads:
            "macOS may ask whether OpenRay may access your Downloads folder."
        case .iCloudDrive:
            "macOS may ask whether OpenRay may access iCloud Drive."
        }
    }
}
