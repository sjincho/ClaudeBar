import Foundation
import Security
import CryptoKit
import Domain

/// OAuth credentials loaded from Claude credential storage.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?  // Milliseconds since epoch
    public var subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Double? = nil,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }
}

/// Source of loaded credentials.
public enum CredentialSource: Sendable, Equatable {
    case environment
    case file
    case keychain
}

/// Result of loading credentials.
/// Note: fullData contains the raw JSON for persisting changes, marked @unchecked Sendable
/// because [String: Any] can't conform to Sendable but we only use it within a single context.
public struct ClaudeCredentialResult: @unchecked Sendable {
    public var oauth: ClaudeOAuthCredentials
    public let source: CredentialSource
    public var fullData: [String: Any]

    public init(oauth: ClaudeOAuthCredentials, source: CredentialSource, fullData: [String: Any]) {
        self.oauth = oauth
        self.source = source
        self.fullData = fullData
    }
}

/// Loads Claude OAuth credentials from file, Keychain, or environment.
///
/// Credential resolution order:
/// 1. File: `~/.claude/.credentials.json` (full-scope from `claude login`)
/// 2. Keychain: Service "Claude Code-credentials" (if enabled)
/// 3. Environment: `CLAUDE_CODE_OAUTH_TOKEN` env var (inference-only from `claude setup-token`)
public struct ClaudeCredentialLoader: Sendable {
    private let homeDirectory: String
    private let keychainService: String
    private let useKeychain: Bool
    private let environment: [String: String]

    /// Refresh buffer: 5 minutes before expiration
    private static let refreshBufferMs: Double = 5 * 60 * 1000

    /// When set, this loader targets an account-specific Claude config dir rather
    /// than the global `~/.claude`. Credentials then live at
    /// `<configDirectory>/.credentials.json` (if any) or in the Keychain under the
    /// per-config-dir service name (see `keychainServiceName(for:)`).
    private let configDirectory: String?

    public init(
        homeDirectory: String = NSHomeDirectory(),
        keychainService: String = "Claude Code-credentials",
        useKeychain: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configDirectory: String? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.useKeychain = useKeychain
        self.environment = environment
        self.configDirectory = configDirectory
        // The Claude CLI stores each CLAUDE_CONFIG_DIR profile's token in a
        // distinct Keychain item: `<base>-<first-8-hex-of-sha256(configDirPath)>`.
        // The global (~/.claude) profile uses the bare service name.
        if let configDirectory {
            self.keychainService = Self.keychainServiceName(base: keychainService, forConfigDirectory: configDirectory)
        } else {
            self.keychainService = keychainService
        }
    }

    /// The Keychain service name the Claude CLI uses for a given config directory:
    /// the base service suffixed with the first 8 hex chars of the SHA-256 of the
    /// directory's absolute path.
    public static func keychainServiceName(base: String = "Claude Code-credentials", forConfigDirectory path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(base)-\(hex.prefix(8))"
    }

    /// The path to the credentials file.
    public var credentialsFilePath: String {
        if let configDirectory {
            return (configDirectory as NSString).appendingPathComponent(".credentials.json")
        }
        return (homeDirectory as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    /// Loads credentials from file, Keychain, or environment.
    /// Returns nil if no valid credentials are found.
    ///
    /// Priority: file/keychain credentials (full-scope from `claude login`) are preferred
    /// over the `CLAUDE_CODE_OAUTH_TOKEN` env var (inference-only from `claude setup-token`).
    /// This ensures quota monitoring uses full-scope credentials when available,
    /// while still falling back to the env var token if nothing else exists.
    public func loadCredentials() -> ClaudeCredentialResult? {
        // Try file first (full-scope OAuth from `claude login`)
        if let fileResult = loadFromFile() {
            return fileResult
        }

        // Keychain (if enabled)
        if useKeychain, let keychainResult = loadFromKeychain() {
            return keychainResult
        }

        // Fallback to environment variable (setup-token, inference-only scope)
        if let envResult = loadFromEnvironment() {
            return envResult
        }

        return nil
    }

    /// Checks if the token needs to be refreshed (expired or within 5 minutes of expiry).
    public func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt else {
            return true
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + Self.refreshBufferMs >= expiresAt
    }

    /// Persists a refreshed token back to its source, touching ONLY the token.
    ///
    /// Critically, this re-reads the live on-disk blob at save time and merges the
    /// new access/refresh/expiry values into its existing `claudeAiOauth` — rather
    /// than writing the (up to 5 min stale) `fullData` snapshot wholesale. The
    /// shared `Claude Code-credentials` item also holds `mcpOAuth` (MCP server
    /// tokens, e.g. Slack), which the live `claude` agent rotates independently;
    /// writing a stale snapshot would silently revert those to an old copy and
    /// break the agent's MCP sessions until the user re-runs `/login`. Merging onto
    /// the freshest copy also preserves `claudeAiOauth` fields we don't manage
    /// (scopes, rateLimitTier, …) that the old rebuild dropped.
    public func saveCredentials(_ result: ClaudeCredentialResult) {
        // Environment credentials are read-only (set via env var, not persisted by us)
        guard result.source != .environment else { return }

        // Merge onto the live blob; fall back to the passed-in snapshot only if the
        // current copy can't be read (e.g. item just deleted).
        var merged = currentStoredData(for: result.source) ?? result.fullData

        var oauthDict = (merged["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauthDict["accessToken"] = result.oauth.accessToken
        if let refreshToken = result.oauth.refreshToken {
            oauthDict["refreshToken"] = refreshToken
        }
        if let expiresAt = result.oauth.expiresAt {
            oauthDict["expiresAt"] = expiresAt
        }
        if let subscriptionType = result.oauth.subscriptionType {
            oauthDict["subscriptionType"] = subscriptionType
        }
        merged["claudeAiOauth"] = oauthDict

        switch result.source {
        case .environment:
            return  // Already handled above, but satisfy exhaustive switch
        case .file:
            saveToFile(merged)
        case .keychain:
            saveToKeychain(merged)
        }
    }

    /// Reads the current raw credential blob from the given source without
    /// requiring a valid token (unlike `load*`). Used to merge a refreshed token
    /// onto the freshest on-disk copy at save time, so sibling sections we don't
    /// own (notably `mcpOAuth`) are never clobbered with a stale snapshot.
    private func currentStoredData(for source: CredentialSource) -> [String: Any]? {
        switch source {
        case .file:
            let path = credentialsFilePath
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        case .keychain:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        case .environment:
            return nil
        }
    }

    // MARK: - Private: Environment Operations

    private func loadFromEnvironment() -> ClaudeCredentialResult? {
        guard let rawToken = environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
            return nil
        }

        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }

        let oauth = ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil
        )

        return ClaudeCredentialResult(oauth: oauth, source: .environment, fullData: [:])
    }

    // MARK: - Private: File Operations

    private func loadFromFile() -> ClaudeCredentialResult? {
        let path = credentialsFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthDict = json["claudeAiOauth"] as? [String: Any],
                  let rawAccessToken = oauthDict["accessToken"] as? String else {
                return nil
            }

            let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty else { return nil }

            let oauth = ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: oauthDict["refreshToken"] as? String,
                expiresAt: oauthDict["expiresAt"] as? Double,
                subscriptionType: oauthDict["subscriptionType"] as? String
            )

            return ClaudeCredentialResult(oauth: oauth, source: .file, fullData: json)
        } catch {
            AppLog.credentials.error("Failed to load Claude credentials from file: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToFile(_ data: [String: Any]) {
        let path = credentialsFilePath
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            AppLog.credentials.info("Saved updated Claude credentials to file")
        } catch {
            AppLog.credentials.error("Failed to save Claude credentials to file: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Keychain Operations

    private func loadFromKeychain() -> ClaudeCredentialResult? {
        // Read in-process via the Security framework rather than the `security`
        // CLI. The items are created by the `claude` CLI, so the first read from
        // any other reader triggers a keychain authorization prompt — reading as
        // ourselves makes that prompt name "ClaudeBar" (the app the user actually
        // grants), instead of the generic `/usr/bin/security` tool.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                AppLog.credentials.error("Failed to load Claude credentials from Keychain (status: \(status))")
            }
            return nil
        }
        guard let data = item as? Data,
              let jsonString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty,
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauthDict = json["claudeAiOauth"] as? [String: Any],
              let rawAccessToken = oauthDict["accessToken"] as? String else {
            return nil
        }

        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let oauth = ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauthDict["refreshToken"] as? String,
            expiresAt: oauthDict["expiresAt"] as? Double,
            subscriptionType: oauthDict["subscriptionType"] as? String
        )

        return ClaudeCredentialResult(oauth: oauth, source: .keychain, fullData: json)
    }

    private func saveToKeychain(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]) else {
            AppLog.credentials.error("Failed to serialize Claude credentials for Keychain")
            return
        }

        // Delete existing item first (ignore errors if not found), in-process so
        // every keychain operation runs as ClaudeBar rather than the `security` CLI.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new item via the Security framework rather than the `security`
        // CLI. `add-generic-password -w <token>` would place the secret in the
        // process arguments, briefly visible to `ps` for other local processes;
        // SecItemAdd keeps it out of any command line.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecValueData as String: jsonData,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            AppLog.credentials.info("Saved Claude credentials to Keychain")
        } else {
            AppLog.credentials.error("Failed to save Claude credentials to Keychain (status: \(status))")
        }
    }
}
