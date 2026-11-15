import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let generalID = "general"

    static func general(hotKey: LauncherHotKey) -> SettingsPane {
        SettingsPane(
            id: generalID, title: "General", systemImage: "gearshape", order: 0,
            makeView: { AnyView(GeneralSettingsView(hotKey: hotKey)) })
    }
}

struct GeneralSettingsView: View {
    let hotKey: LauncherHotKey

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }

    private var fallbackNote: LocalizedStringResource {
        let fallback = HotKeyFormatter.string(for: LauncherHotKey.fallback)
        let refused = HotKeyFormatter.string(for: .launcherDefault)
        return "Until OpenRay quits, \(fallback) opens the launcher in place of \(refused). OpenRay tries \(refused) again the next time it starts."
    }

    private func message(for failure: LauncherHotKey.Failure) -> LocalizedStringResource {
        let chord = HotKeyFormatter.string(for: failure.hotKey)
        switch failure.error {
        case .inUseByAnotherApp:
            return "\(chord) is in use by another app."
        case .rejected(let status):
            // As text, because a number would be shown with a thousands separator ("-9,868").
            return "macOS could not register \(chord) (error \(String(status)))."
        }
    }
}
