import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let updatesID = "updates"
}

extension UpdatesModel {
    /// Why the update settings cannot be changed, in a build that cannot update itself.
    var unavailableNote: LocalizedStringResource? {
        switch availability {
        case .available:
            return nil
        case .developmentBuild:
            return "Not available in a development build, which never updates itself."
        case .notConfigured:
            return
                "Not available in this build. It was made without the key that updates are checked against."
        }
    }

    /// What a check sends. Onboarding and Settings › Updates say it in the same words, and
    /// PRIVACY.md says it at length.
    var whatACheckSends: LocalizedStringResource {
        "To check, OpenRay downloads its list of releases from GitHub. The request says which version of OpenRay and of its updater is asking, and OpenRay adds nothing else about you or this Mac."
    }
}

/// Settings › Updates: whether OpenRay looks for updates on its own, whether it installs them
/// without asking, and a button to look now (docs/DESIGN.md §4.3.5, §6.4). The settings are
/// kept by the updater; `UpdatesModel` reads and writes them.
struct UpdatesSettingsView: View {
    let updates: UpdatesModel

    var body: some View {
        Form {
            automaticSection
            checkNowSection
        }
        .formStyle(.grouped)
        // The updater may have asked about automatic checks with a prompt of its own since
        // the pane was last shown.
        .onAppear {
            updates.refresh()
        }
    }

    private var automaticSection: some View {
        Section {
            Toggle(
                "Check for updates automatically",
                isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { isOn in updates.setChecksAutomatically(isOn) })
            )
            .disabled(!updates.isAvailable)
            // The updater installs nothing on its own while it does not check on its own.
            Toggle(
                "Download and install updates automatically",
                isOn: Binding(
                    get: { updates.installsAutomatically },
                    set: { isOn in updates.setInstallsAutomatically(isOn) })
            )
            .disabled(!updates.isAvailable || !updates.checksAutomatically)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let unavailableNote = updates.unavailableNote {
                    // In the primary colour: this is why nothing here can be changed.
                    Text(unavailableNote).foregroundStyle(.primary)
                }
                Text(updates.whatACheckSends)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var checkNowSection: some View {
        Section {
            LabeledContent("Last checked") {
                if let lastCheck = updates.lastCheck {
                    Text(lastCheck, format: .dateTime.day().month().year().hour().minute())
                } else {
                    Text("Never")
                }
            }
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheck)
        }
    }
}
