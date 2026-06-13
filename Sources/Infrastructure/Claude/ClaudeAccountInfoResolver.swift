import Foundation
import Domain

/// Resolves Claude account identity from the config file (`~/.claude.json` → `oauthAccount`).
/// This is the primary source of account info for CLI v2.1.79+ where the tabbed TUI
/// no longer includes account details in the `/usage` output.
public final class ClaudeAccountInfoResolver: AccountInfoResolving, Sendable {
    private let configURL: URL

    public init(configURL: URL? = nil, configDirectory: URL? = nil) {
        self.configURL = configURL ?? {
            let configDir = configDirectory ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            return (configDir ?? FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent(".claude.json")
        }()
    }

    /// Resolves account info from `~/.claude.json` `oauthAccount` section.
    /// Returns `nil` if the file doesn't exist or has no usable account data.
    public func resolve() -> AccountInfo? {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = root["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let email = oauthAccount["emailAddress"] as? String
        let organization = oauthAccount["organizationName"] as? String
            ?? oauthAccount["displayName"] as? String

        guard email != nil || organization != nil else { return nil }

        // Prefer the per-user tier (Team seats carry `userRateLimitTier`, e.g.
        // `default_claude_max_5x`); fall back to the org tier (Max accounts carry
        // `organizationRateLimitTier`, e.g. `default_claude_max_20x`).
        let budgetWeight =
            Self.rateLimitMultiplier(from: oauthAccount["userRateLimitTier"] as? String)
            ?? Self.rateLimitMultiplier(from: oauthAccount["organizationRateLimitTier"] as? String)

        return AccountInfo(
            email: email,
            organization: organization,
            budgetWeight: budgetWeight
        )
    }

    /// Parses the `Nx` multiplier out of a rate-limit tier string, e.g.
    /// `default_claude_max_20x` → 20, `default_claude_max_5x` → 5. Returns nil for
    /// tiers without an `Nx` suffix (e.g. `default_raven`).
    static func rateLimitMultiplier(from tier: String?) -> Double? {
        guard let tier else { return nil }
        guard let range = tier.range(of: #"(\d+)x$"#, options: .regularExpression) else { return nil }
        let digits = tier[range].dropLast()  // strip trailing "x"
        return Double(digits)
    }
}
