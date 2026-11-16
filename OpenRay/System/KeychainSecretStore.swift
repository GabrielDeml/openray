import Foundation
import OpenRayCore
import Security

/// Keeps secrets in the user's login keychain (docs/DESIGN.md §4.6.5).
///
/// Each secret is a generic-password item that stays on this Mac. This is the file-based
/// keychain: the data-protection keychain wants an access group from a provisioning profile,
/// which a Debug or CI build does not have.
///
/// The SecItem calls talk to another process and can wait for the user to answer a prompt,
/// so every method is `@concurrent`.
nonisolated struct KeychainSecretStore: SecretStore {
    /// A SecItem call failed. It carries the status and never the secret.
    struct Failure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            return systemMessage ?? String(localized: "The Keychain reported error \(status).")
        }
    }

    @concurrent
    func read(_ account: SecretAccount) async throws -> String? {
        var query = Self.attributes(of: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = found as? Data else { throw Failure(status: errSecDecode) }
        return String(decoding: data, as: UTF8.self)
    }

    @concurrent
    func write(_ value: String, for account: SecretAccount) async throws {
        let secret = Data(value.utf8)

        var item = Self.attributes(of: account)
        item[kSecValueData] = secret
        var status = SecItemAdd(item as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let newData = [kSecValueData: secret] as CFDictionary
            status = SecItemUpdate(Self.attributes(of: account) as CFDictionary, newData)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    @concurrent
    func delete(_ account: SecretAccount) async throws {
        let status = SecItemDelete(Self.attributes(of: account) as CFDictionary)
        // Nothing to delete is what the caller wanted.
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// What names the item of `account`, for a search and for adding it.
    ///
    /// `kSecAttrAccessible` is left out: on macOS it applies to items that sync or live in the
    /// data-protection keychain, and this one does neither.
    private static func attributes(of account: SecretAccount) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: account.service,
            kSecAttrAccount: account.account,
            kSecAttrSynchronizable: false,
        ]
    }
}
