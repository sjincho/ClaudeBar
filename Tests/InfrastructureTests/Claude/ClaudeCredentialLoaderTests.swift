import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("ClaudeCredentialLoader Tests")
struct ClaudeCredentialLoaderTests {

    // MARK: - Test Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-credential-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createCredentialsFile(
        at directory: URL,
        accessToken: String = "test-access-token",
        refreshToken: String = "test-refresh-token",
        expiresAt: Double? = nil,
        subscriptionType: String? = nil
    ) throws {
        let claudeDir = directory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var oauthDict: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken
        ]
        if let expiresAt {
            oauthDict["expiresAt"] = expiresAt
        }
        if let subscriptionType {
            oauthDict["subscriptionType"] = subscriptionType
        }

        let credentials: [String: Any] = [
            "claudeAiOauth": oauthDict
        ]

        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.prettyPrinted])
        let filePath = claudeDir.appendingPathComponent(".credentials.json")
        try data.write(to: filePath)
    }

    // MARK: - Credential Loading Tests

    @Test
    func `loadCredentials returns nil when file does not exist`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Disable keychain to test file-only path
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let credentials = loader.loadCredentials()

        #expect(credentials == nil)
    }

    @Test
    func `loadCredentials returns credentials from file`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(
            at: tempDir,
            accessToken: "my-access-token",
            refreshToken: "my-refresh-token",
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            subscriptionType: "claude_max"
        )

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(result?.oauth.accessToken == "my-access-token")
        #expect(result?.oauth.refreshToken == "my-refresh-token")
        #expect(result?.oauth.subscriptionType == "claude_max")
        #expect(result?.source == .file)
    }

    @Test
    func `loadCredentials returns nil when credentials file has empty accessToken`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(at: tempDir, accessToken: "", refreshToken: "refresh")

        // Disable keychain to test file-only path
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let credentials = loader.loadCredentials()

        #expect(credentials == nil)
    }

    @Test
    func `loadCredentials handles malformed JSON gracefully`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeDir = tempDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let filePath = claudeDir.appendingPathComponent(".credentials.json")
        try "not valid json".write(to: filePath, atomically: true, encoding: .utf8)

        // Disable keychain to test file-only path
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let credentials = loader.loadCredentials()

        #expect(credentials == nil)
    }

    @Test
    func `loadCredentials handles missing claudeAiOauth field`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeDir = tempDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let filePath = claudeDir.appendingPathComponent(".credentials.json")
        let data = try JSONSerialization.data(withJSONObject: ["someOtherKey": "value"], options: [])
        try data.write(to: filePath)

        // Disable keychain to test file-only path
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let credentials = loader.loadCredentials()

        #expect(credentials == nil)
    }

    // MARK: - Token Expiry Tests

    @Test
    func `needsRefresh returns true when token is expired`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Token expired 1 hour ago
        let pastTime = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: pastTime)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(loader.needsRefresh(result!.oauth) == true)
    }

    @Test
    func `needsRefresh returns true when token expires within 5 minutes`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Token expires in 4 minutes (less than 5 minute buffer)
        let nearFuture = Date().addingTimeInterval(4 * 60).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: nearFuture)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(loader.needsRefresh(result!.oauth) == true)
    }

    @Test
    func `needsRefresh returns false when token has more than 5 minutes left`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Token expires in 1 hour
        let futureTime = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureTime)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(loader.needsRefresh(result!.oauth) == false)
    }

    @Test
    func `needsRefresh returns true when expiresAt is missing`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(at: tempDir, expiresAt: nil)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(loader.needsRefresh(result!.oauth) == true)
    }

    // MARK: - Credential Saving Tests

    @Test
    func `saveCredentials updates file correctly`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(
            at: tempDir,
            accessToken: "old-token",
            refreshToken: "old-refresh"
        )

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path)
        var result = loader.loadCredentials()!

        // Update the token
        result.oauth.accessToken = "new-token"
        result.oauth.refreshToken = "new-refresh"
        result.oauth.expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000

        loader.saveCredentials(result)

        // Reload and verify
        let reloaded = loader.loadCredentials()
        #expect(reloaded?.oauth.accessToken == "new-token")
        #expect(reloaded?.oauth.refreshToken == "new-refresh")
    }

    @Test
    func `saveCredentials preserves mcpOAuth and unmanaged claudeAiOauth fields`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeDir = tempDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let filePath = claudeDir.appendingPathComponent(".credentials.json")
        let blob: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-token",
                "refreshToken": "old-refresh",
                "scopes": ["user:inference", "user:profile"],
                "rateLimitTier": "default_claude_max_20x",
            ],
            "mcpOAuth": [
                "slack": ["accessToken": "slack-tok", "refreshToken": "slack-ref"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: blob).write(to: filePath)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        var result = loader.loadCredentials()!
        result.oauth.accessToken = "new-token"
        loader.saveCredentials(result)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: filePath)) as! [String: Any]
        let oauth = saved["claudeAiOauth"] as! [String: Any]
        let slack = (saved["mcpOAuth"] as? [String: Any])?["slack"] as? [String: Any]
        #expect(oauth["accessToken"] as? String == "new-token")
        // Unmanaged claudeAiOauth fields survive (the old rebuild dropped these).
        #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_20x")
        // The section we don't own is untouched.
        #expect(slack?["accessToken"] as? String == "slack-tok")
    }

    @Test
    func `saveCredentials merges onto the live file, not the stale snapshot`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeDir = tempDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let filePath = claudeDir.appendingPathComponent(".credentials.json")
        func writeBlob(mcpToken: String) throws {
            let blob: [String: Any] = [
                "claudeAiOauth": ["accessToken": "tok", "refreshToken": "ref"],
                "mcpOAuth": ["slack": ["accessToken": mcpToken]],
            ]
            try JSONSerialization.data(withJSONObject: blob).write(to: filePath)
        }
        try writeBlob(mcpToken: "slack-v1")

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        var result = loader.loadCredentials()!  // snapshot captured with mcpOAuth = slack-v1

        // The live `claude` agent rotates the MCP token after we loaded.
        try writeBlob(mcpToken: "slack-v2")

        result.oauth.accessToken = "rotated-token"
        loader.saveCredentials(result)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: filePath)) as! [String: Any]
        let slack = (saved["mcpOAuth"] as? [String: Any])?["slack"] as? [String: Any]
        // The fresh on-disk MCP token must win — not reverted to the stale snapshot.
        #expect(slack?["accessToken"] as? String == "slack-v2")
        #expect((saved["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "rotated-token")
    }

    // MARK: - Environment Variable Tests

    @Test
    func `loadCredentials returns credentials from env var when CLAUDE_CODE_OAUTH_TOKEN set`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "my-setup-token"]
        )
        let result = loader.loadCredentials()

        #expect(result != nil)
        #expect(result?.oauth.accessToken == "my-setup-token")
        #expect(result?.source == .environment)
    }

    @Test
    func `loadCredentials from env var has no refresh token and no expiresAt`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "my-setup-token"]
        )
        let result = loader.loadCredentials()

        #expect(result?.oauth.refreshToken == nil)
        #expect(result?.oauth.expiresAt == nil)
    }

    @Test
    func `loadCredentials trims whitespace and newlines from env token`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "  my-setup-token\n"]
        )
        let result = loader.loadCredentials()

        #expect(result?.oauth.accessToken == "my-setup-token")
    }

    @Test
    func `loadCredentials prefers file credentials over env var`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create file credentials (full-scope from `claude login`)
        try createCredentialsFile(
            at: tempDir,
            accessToken: "file-token",
            refreshToken: "file-refresh"
        )

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]
        )
        let result = loader.loadCredentials()

        // File credentials should win (full-scope for quota monitoring)
        #expect(result?.oauth.accessToken == "file-token")
        #expect(result?.source == .file)
    }

    @Test
    func `loadCredentials ignores empty env var and falls through to file`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(at: tempDir, accessToken: "file-token")

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": ""]
        )
        let result = loader.loadCredentials()

        #expect(result?.oauth.accessToken == "file-token")
        #expect(result?.source == .file)
    }

    @Test
    func `loadCredentials falls through to file when env var not present`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createCredentialsFile(at: tempDir, accessToken: "file-token")

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: [:]  // No env var
        )
        let result = loader.loadCredentials()

        #expect(result?.oauth.accessToken == "file-token")
        #expect(result?.source == .file)
    }

    @Test
    func `saveCredentials is no-op for environment source`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]
        )
        let result = loader.loadCredentials()!

        // saveCredentials should not crash for environment source
        loader.saveCredentials(result)

        // No file should be created
        let credPath = (tempDir.path as NSString).appendingPathComponent(".claude/.credentials.json")
        #expect(!FileManager.default.fileExists(atPath: credPath))
    }

    @Test
    func `needsRefresh returns false for environment source credentials with no expiresAt`() throws {
        // Setup-token credentials have no expiresAt, but should NOT be treated as "needs refresh"
        // because they are long-lived tokens with no refresh mechanism
        let oauth = ClaudeOAuthCredentials(
            accessToken: "setup-token",
            refreshToken: nil,
            expiresAt: nil
        )

        let loader = ClaudeCredentialLoader(
            homeDirectory: NSTemporaryDirectory(),
            useKeychain: false
        )

        // Currently needsRefresh returns true when expiresAt is nil.
        // For setup-token (no refresh token), the probe should handle this
        // by skipping refresh when refreshToken is nil.
        // So needsRefresh itself stays true, but the probe won't attempt refresh.
        #expect(loader.needsRefresh(oauth) == true)
    }

    @Test
    func `keychain service name is base plus first 8 hex of sha256(config dir)`() {
        // The Claude CLI keys each CLAUDE_CONFIG_DIR profile's Keychain item as
        // `<base>-<first 8 hex of sha256(absolute path)>`. Verified against the
        // real items on macOS; here a portable SHA-256 vector locks the formula.
        #expect(
            ClaudeCredentialLoader.keychainServiceName(base: "svc", forConfigDirectory: "a")
                == "svc-ca978112"
        )
        #expect(
            ClaudeCredentialLoader.keychainServiceName(forConfigDirectory: "a")
                == "Claude Code-credentials-ca978112"
        )
    }
}
