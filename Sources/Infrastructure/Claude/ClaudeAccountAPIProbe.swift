import Foundation
import Domain

/// Probes an account-specific Claude profile via the OAuth usage API — reading
/// that profile's token straight from its per-config-dir Keychain item — instead
/// of spawning a `claude /usage` CLI process. This is dramatically faster (a
/// single HTTP call vs a cold CLI start + TUI scrape).
///
/// The usage API doesn't return account identity, so the email/organization are
/// resolved separately from the profile's `<configDir>/.claude.json`.
public struct ClaudeAccountAPIProbe: UsageProbe {
    private let apiProbe: ClaudeAPIUsageProbe
    private let resolver: ClaudeAccountInfoResolver

    public init(configDirectory: URL) {
        self.apiProbe = ClaudeAPIUsageProbe(
            credentialLoader: ClaudeCredentialLoader(configDirectory: configDirectory.path)
        )
        self.resolver = ClaudeAccountInfoResolver(configDirectory: configDirectory)
    }

    public func probe() async throws -> UsageSnapshot {
        let snapshot = try await apiProbe.probe()
        let info = resolver.resolve()
        return snapshot.withAccountIdentity(email: info?.email, organization: info?.organization)
    }

    public func isAvailable() async -> Bool {
        await apiProbe.isAvailable()
    }
}
