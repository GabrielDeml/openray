import OpenRayCore
import SwiftUI

/// Quick AI (docs/DESIGN.md §4.6): "Ask AI" in search, Tab on a query, the chat screen they
/// open, and the pane of Settings where the key and the model are set.
final class QuickAIFeature: Feature {
    let id = QuickAISource.feature
    let tabFallback: ScreenRequest? = QuickAISource.chatScreenRequest()

    /// The one conversation. It is kept while the app runs, so that a reply goes on arriving
    /// behind a hidden launcher and "Continue AI chat" finds the thread again.
    private var session: QuickAISession?
    /// Every request goes through this one, a question's and a key's verification alike.
    private let transport = URLSessionByteTransport()

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let secrets = env.secrets
        let provider = ClaudeProvider(
            transport: transport,
            apiKey: {
                // The provider asks for the key when it is about to send a request and not
                // before, so a prompt from the Keychain follows something the user did.
                guard let key = try await secrets.read(.anthropicAPIKey) else { return nil }
                return APIKey(key)
            })
        let session = QuickAISession(
            provider: provider, preferences: env.preferences, now: { Date() })
        self.session = session
        return [QuickAISource(session: session)]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        // The sources are made before the panes, so the session is there.
        guard let session else { return nil }

        let transport = transport
        let settings = QuickAISettingsModel(
            secrets: env.secrets, preferences: env.preferences, session: session
        ) { candidate in
            // A key is verified before it is saved, so this provider is handed the key and
            // reads nothing from the Keychain.
            ClaudeProvider(transport: transport, apiKey: { candidate })
        }
        return SettingsPane(
            id: SettingsPane.quickAIID, title: "Quick AI", systemImage: "sparkles", order: 40,
            makeView: { AnyView(QuickAISettingsView(settings: settings)) })
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard request.screen == QuickAISource.chatScreen, let session else { return nil }

        let showSettings = env.showSettings
        let model = QuickAIChatModel(session: session, context: context) {
            showSettings(SettingsPane.quickAIID)
        }
        return ScreenSpec(
            title: String(localized: "Quick AI"),
            searchBar: .input(placeholder: String(localized: "Ask a follow-up")),
            body: .custom(AnyView(QuickAIChatView(model: model)), handleIntent: model.handleIntent))
    }
}
