import Foundation
import Security
import os

/// Thin wrapper around the Security framework for generic-password items.
/// The Anthropic API key lives here — never in source, UserDefaults, or the repo.
enum KeychainStore {
    private static let service = "de.jonasgehring.notable"
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "keychain")

    static let anthropicAPIKeyAccount = "anthropic-api-key"

    /// What a read actually found. **"Absent" and "refused" are different
    /// answers and used to be the same one.**
    ///
    /// The signing identity of this app changed twice (ad-hoc → Apple
    /// Development → Developer ID, documented in `project.yml`), and a keychain
    /// item created under an earlier identity can answer `errSecAuthFailed` or
    /// `errSecInteractionNotAllowed` to the new one. Collapsing every `OSStatus`
    /// into `nil` turned that into "Kein API-Key im Schlüsselbund" — a message
    /// that sends the user off to create a second key for one that is sitting
    /// right there.
    enum ReadResult: Equatable {
        case value(String)
        case absent
        case denied(OSStatus)
    }

    static func read(account: String) -> String? {
        if case .value(let value) = readResult(account: account) { return value }
        return nil
    }

    static func readResult(account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return .denied(status)
            }
            return .value(value)
        case errSecItemNotFound:
            return .absent
        default:
            log.error("Schlüsselbund-Zugriff verweigert (OSStatus \(status, privacy: .public))")
            return .denied(status)
        }
    }

    /// Update-then-add rather than delete-then-add.
    ///
    /// The old order deleted the existing item first, so an `SecItemAdd` that
    /// then failed — a locked keychain, a denied ACL — left the user with no key
    /// at all, having entered a perfectly good one.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            log.error("Schlüsselbund-Update fehlgeschlagen (OSStatus \(update, privacy: .public))")
            return false
        }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        let add = SecItemAdd(attributes as CFDictionary, nil)
        if add != errSecSuccess {
            log.error("Schlüsselbund-Anlage fehlgeschlagen (OSStatus \(add, privacy: .public))")
        }
        return add == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
