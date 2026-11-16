import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let windowManagementID = "window-management"
}

/// Settings › Window Management: the space the window commands leave around windows and for
/// Stage Manager's strip (docs/DESIGN.md §4.7). Both are plain preferences.
struct WindowManagementSettingsView: View {
    let preferences: Preferences

    var body: some View {
        Form {
            gapSection
            stageManagerSection
            notesSection
        }
        .formStyle(.grouped)
    }

    private var gapSection: some View {
        Section {
            TextField("Gap in points", value: gap, format: .number)
        } footer: {
            Text(
                "The space the window commands leave around a window and between two windows side by side. With 0, windows touch each other and the edges of the screen."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stageManagerSection: some View {
        Section {
            TextField("Room for Stage Manager in points", value: stageStripInset, format: .number)
        } footer: {
            Text(
                "The width the window commands leave free at the side of the screen for Stage Manager's recent apps. It is left free only while Stage Manager is on."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesSection: some View {
        Section {
            Text(
                "Window commands such as Left Half or Maximize Window move the front window of the app you opened OpenRay over. They need the Accessibility permission, which you grant in Settings › General."
            )
            Text(
                "They have no keyboard shortcuts of their own. Open OpenRay and type the name of a command, or an alias you gave it in Settings › Commands."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// A negative gap means nothing, so it is stored as 0, which is also what the layout
    /// would make of it.
    private var gap: Binding<Double> {
        Binding(
            get: { preferences.windowGap },
            set: { newValue in preferences.windowGap = max(0, newValue) })
    }

    /// As for the gap.
    private var stageStripInset: Binding<Double> {
        Binding(
            get: { preferences.windowStageStripInset },
            set: { newValue in preferences.windowStageStripInset = max(0, newValue) })
    }
}
