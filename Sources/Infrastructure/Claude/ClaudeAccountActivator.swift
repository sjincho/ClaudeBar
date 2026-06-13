import Foundation
import Security

/// Reads/writes a raw Claude credential blob (the JSON value of a
/// `Claude Code-credentials[-<hash>]` Keychain item) by service name. Abstracted
/// so the swap logic can be unit-tested without touching the real Keychain.
public protocol ClaudeKeychainDataStore: Sendable {
    func read(service: String) -> Data?
    @discardableResult func write(_ data: Data, service: String) -> Bool
}

/// Real Keychain-backed store using the Security framework (no `security` CLI,
/// so secrets never appear in process arguments).
public struct SecItemKeychainDataStore: ClaudeKeychainDataStore {
    public init() {}

    public func read(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public func write(_ data: Data, service: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Makes the bare `claude` CLI authenticate as a specific account by copying that
/// account's OAuth token into the global Keychain item — so the user keeps their
/// `~/.claude` workspace (projects, history, sessions) but "continues with new
/// creds". Only the `claudeAiOauth` section is swapped; the global item's
/// `mcpOAuth` (MCP server tokens) is preserved.
public struct ClaudeAccountActivator: Sendable {
    private let store: any ClaudeKeychainDataStore
    private let baseService: String

    public init(
        store: any ClaudeKeychainDataStore = SecItemKeychainDataStore(),
        baseService: String = "Claude Code-credentials"
    ) {
        self.store = store
        self.baseService = baseService
    }

    /// Activates the account whose profile lives at `configDirectory` as the
    /// global default. Returns false if the source token can't be read.
    @discardableResult
    public func activate(configDirectory: String) -> Bool {
        let sourceService = ClaudeCredentialLoader.keychainServiceName(
            base: baseService,
            forConfigDirectory: configDirectory
        )
        guard let sourceData = store.read(service: sourceService),
              let source = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let sourceOauth = source["claudeAiOauth"] else {
            return false
        }

        // Preserve the global item's other sections (e.g. mcpOAuth); swap only
        // the account token.
        var global: [String: Any] = {
            if let data = store.read(service: baseService),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
            return [:]
        }()
        global["claudeAiOauth"] = sourceOauth

        guard JSONSerialization.isValidJSONObject(global),
              let out = try? JSONSerialization.data(withJSONObject: global) else {
            return false
        }
        return store.write(out, service: baseService)
    }
}
