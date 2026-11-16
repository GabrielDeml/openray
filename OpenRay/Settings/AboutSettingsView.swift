import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let aboutID = "about"

    static func about() -> SettingsPane {
        SettingsPane(
            id: aboutID, title: "About", systemImage: "info.circle", order: 100,
            makeView: { AnyView(AboutSettingsView()) })
    }
}

/// Where the pane's link leads.
private enum AboutLinks {
    static let repository = URL(string: "https://github.com/GabrielDeml/openray")!
}

/// A library that ships inside OpenRay, and the file in the bundle that holds its licence.
private struct Acknowledgement: Identifiable {
    let name: String
    /// Without its extension, `.txt`. The files are in `OpenRay/Resources/Licenses`.
    let licenseFile: String

    var id: String { name }
}

/// Settings › About: the version, that OpenRay is open source, and the licences of the code
/// it ships with (docs/DESIGN.md §4.3.5, §5.2).
struct AboutSettingsView: View {
    // Each file is the library's own LICENSE at the pinned version, byte for byte. Replace it
    // when the pin changes. Sparkle's also holds the notices of the code Sparkle bundles
    // (bsdiff, sais-lite, Ed25519 and SUSignatureVerifier), which have to be reproduced too.
    private static let acknowledgements = [
        Acknowledgement(name: "GRDB.swift", licenseFile: "GRDB-LICENSE"),
        Acknowledgement(name: "Sparkle", licenseFile: "Sparkle-LICENSE"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    "Version",
                    value: AppInfo.versionLine(version: AppInfo.version, build: AppInfo.build))
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(AppInfo.name) is open source, released under the MIT License.")
                    Link("Source code on GitHub", destination: AboutLinks.repository)
                }
            } header: {
                Text(AppInfo.name)
            }

            Section {
                ForEach(Self.acknowledgements) { acknowledgement in
                    DisclosureGroup(acknowledgement.name) {
                        licenseText(of: acknowledgement)
                    }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("OpenRay is built with these open-source libraries. Thank you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func licenseText(of acknowledgement: Acknowledgement) -> some View {
        ScrollView {
            Text(Self.readLicense(of: acknowledgement))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 200)
    }

    private static func readLicense(of acknowledgement: Acknowledgement) -> String {
        guard
            let file = Bundle.main.url(
                forResource: acknowledgement.licenseFile, withExtension: "txt"),
            let text = try? String(contentsOf: file, encoding: .utf8)
        else {
            // Only if the file did not make it into the bundle, which is a mistake in the
            // build and not something a user can do anything about.
            return String(localized: "The license text is missing from this copy of OpenRay.")
        }
        return text
    }
}
