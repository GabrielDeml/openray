/// Names one secret: the service it is for and the account with that service.
public struct SecretAccount: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

extension SecretAccount {
    /// The user's Anthropic API key, the one secret OpenRay keeps. Debug and Release builds
    /// have different bundle identifiers, so each keeps a key of its own.
    public static let anthropicAPIKey = SecretAccount(
        service: AppInfo.bundleIdentifier + ".anthropic", account: "api-key")
}

/// Where secrets are kept (docs/DESIGN.md §4.6.5). The app target implements it with the
/// Keychain. Core has no implementation: a secret is never kept in a file or a preference.
public protocol SecretStore: Sendable {
    /// The stored secret, or nil when there is none.
    func read(_ account: SecretAccount) async throws -> String?
    func write(_ value: String, for account: SecretAccount) async throws
    func delete(_ account: SecretAccount) async throws
}
