import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let generalID = "general"

    static func general(
        hotKey: LauncherHotKey, loginItem: LoginItemModel, permissions: PermissionListModel
    ) -> SettingsPane {
        SettingsPane(
            id: generalID, title: "General", systemImage: "gearshape", order: 0,
            makeView: {
                AnyView(
                    GeneralSettingsView(
                        hotKey: hotKey, loginItem: loginItem, permissions: permissions))
            })
    }
}

struct GeneralSettingsView: View {
    let hotKey: LauncherHotKey
    let loginItem: LoginItemModel
    let permissions: PermissionListModel

    var body: some View {
        Form {
            hotKeySection
            loginItemSection
            if !permissions.rows.isEmpty {
                permissionsSection
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readSystemState)
        // The user changes the login item and the permissions in System Settings, and comes
        // back from there.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            readSystemState()
        }
    }

    private func readSystemState() {
        loginItem.refresh()
        Task { await permissions.refresh() }
    }

    // MARK: Hotkey

    private var hotKeySection: some View {
        Section {
            // Not `LabeledContent`: an AppKit view has no baseline for it to align with.
            HStack {
                Text("Launcher hotkey")
                Spacer()
                HotKeyRecorder(launcherHotKey: hotKey).fixedSize()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = hotKey.failure {
                    Label {
                        Text(message(for: failure))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
                if hotKey.usesFallback {
                    // In the primary colour: this is news, unlike the hints below it.
                    Text(fallbackNote).foregroundStyle(.primary)
                }
                if hotKey.hotKey.validate() == .optionShiftOnly {
                    Text("Some macOS versions refuse shortcuts whose only modifier is Option.")
                }
                Text(
                    "Click the shortcut, then type a new one. Esc cancels and Delete restores the default."
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fallbackNote: LocalizedStringResource {
        let fallback = HotKeyFormatter.string(for: LauncherHotKey.fallback)
        let refused = HotKeyFormatter.string(for: .launcherDefault)
        return
            "Until OpenRay quits, \(fallback) opens the launcher in place of \(refused). OpenRay tries \(refused) again the next time it starts."
    }

    private func message(for failure: HotKeyFailure) -> LocalizedStringResource {
        let chord = HotKeyFormatter.string(for: failure.hotKey)
        switch failure.error {
        case .inUseByAnotherApp:
            return HotKeyFormatter.inUseByAnotherAppMessage(chord: chord)
        case .rejected(let status):
            return HotKeyFormatter.rejectedMessage(chord: chord, status: status)
        case .heldBySlot:
            // The launcher is the only slot this pane records for, so the holder is a command.
            return HotKeyFormatter.heldByCommandMessage(chord: chord)
        }
    }

    // MARK: Launch at login

    private var loginItemSection: some View {
        Section {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { loginItem.isOn },
                    set: { isOn in loginItem.setEnabled(isOn) })
            )
            .disabled(!loginItem.canChange)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !loginItem.canChange {
                    Text(
                        "Not available in a development build, whose login item would point into the build folder."
                    )
                }
                if let error = loginItem.errorMessage {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
                if loginItem.status == .requiresApproval {
                    Text("macOS wants you to allow OpenRay in Login Items first.")
                    Button("Open Login Items") {
                        loginItem.openSystemSettings()
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(permissions.rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.permission.title)
                        Text(row.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.state.label)
                        .foregroundStyle(.secondary)
                    // The same decision the launcher makes before a command runs.
                    switch row.step {
                    case .proceed:
                        EmptyView()
                    case .request:
                        Button("Grant") {
                            Task { await permissions.grant(row.permission) }
                        }
                    case .explain:
                        Button("Open System Settings") {
                            Task { await permissions.grant(row.permission) }
                        }
                    }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("OpenRay asks for a permission when you first use a command that needs it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
