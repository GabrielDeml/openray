import SwiftUI

/// One page of the settings window.
nonisolated struct SettingsPane: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let systemImage: String
    /// Position in the sidebar, lowest first.
    let order: Int
    let makeView: @MainActor () -> AnyView
}
