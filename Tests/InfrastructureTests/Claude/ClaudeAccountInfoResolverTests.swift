import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite
struct ClaudeAccountInfoResolverTests {

    @Test
    func `resolves email and displayName from oauthAccount`() {
        let resolver = makeResolverWithConfig("""
        {
            "oauthAccount": {
                "accountUuid": "abc-123",
                "emailAddress": "user@example.com",
                "organizationUuid": "org-456",
                "displayName": "testuser",
                "billingType": "stripe_subscription"
            }
        }
        """)

        let result = resolver.resolve()

        #expect(result?.email == "user@example.com")
        #expect(result?.organization == "testuser")
    }

    @Test
    func `prefers organizationName over displayName`() {
        let resolver = makeResolverWithConfig("""
        {
            "oauthAccount": {
                "emailAddress": "user@example.com",
                "organizationName": "Acme",
                "displayName": "testuser"
            }
        }
        """)

        let result = resolver.resolve()

        #expect(result?.email == "user@example.com")
        #expect(result?.organization == "Acme")
    }

    @Test
    func `resolves email only when displayName is absent`() {
        let resolver = makeResolverWithConfig("""
        {
            "oauthAccount": {
                "emailAddress": "user@example.com"
            }
        }
        """)

        let result = resolver.resolve()

        #expect(result?.email == "user@example.com")
        #expect(result?.organization == nil)
    }

    @Test
    func `resolves displayName only when email is absent`() {
        let resolver = makeResolverWithConfig("""
        {
            "oauthAccount": {
                "displayName": "testuser"
            }
        }
        """)

        let result = resolver.resolve()

        #expect(result?.email == nil)
        #expect(result?.organization == "testuser")
    }

    @Test
    func `returns nil when config file does not exist`() {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let resolver = ClaudeAccountInfoResolver(configURL: bogusURL)

        let result = resolver.resolve()

        #expect(result == nil)
    }

    @Test
    func `returns nil when oauthAccount section is missing`() {
        let resolver = makeResolverWithConfig("""
        { "numStartups": 100 }
        """)

        let result = resolver.resolve()

        #expect(result == nil)
    }

    @Test
    func `returns nil when oauthAccount has neither email nor displayName`() {
        let resolver = makeResolverWithConfig("""
        {
            "oauthAccount": {
                "accountUuid": "abc-123",
                "organizationUuid": "org-456"
            }
        }
        """)

        let result = resolver.resolve()

        #expect(result == nil)
    }

    @Test
    func `returns nil when config file is invalid JSON`() {
        let resolver = makeResolverWithConfig("not valid json {{{")

        let result = resolver.resolve()

        #expect(result == nil)
    }

    // MARK: - Rate-limit tier

    @Test
    func `parses the Nx multiplier from rate-limit tiers`() {
        #expect(ClaudeAccountInfoResolver.rateLimitMultiplier(from: "default_claude_max_20x") == 20)
        #expect(ClaudeAccountInfoResolver.rateLimitMultiplier(from: "default_claude_max_5x") == 5)
        #expect(ClaudeAccountInfoResolver.rateLimitMultiplier(from: "default_raven") == nil)
        #expect(ClaudeAccountInfoResolver.rateLimitMultiplier(from: nil) == nil)
    }

    @Test
    func `prefers per-user tier, falls back to org tier for the budget weight`() {
        // Team seat: userRateLimitTier (5x) wins over the org's non-Nx tier.
        let team = makeResolverWithConfig(#"""
        {"oauthAccount":{"emailAddress":"u@x.com","organizationName":"Org",
          "organizationRateLimitTier":"default_raven","userRateLimitTier":"default_claude_max_5x"}}
        """#)
        #expect(team.resolve()?.budgetWeight == 5)

        // Max account: no userRateLimitTier, so the org tier (20x) is used.
        let max = makeResolverWithConfig(#"""
        {"oauthAccount":{"emailAddress":"u@x.com","organizationName":"Org",
          "organizationRateLimitTier":"default_claude_max_20x"}}
        """#)
        #expect(max.resolve()?.budgetWeight == 20)
    }

    // MARK: - Helpers

    private func makeResolverWithConfig(_ json: String) -> ClaudeAccountInfoResolver {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configFile = tempDir.appendingPathComponent(".claude.json")
        try! json.data(using: .utf8)!.write(to: configFile)
        return ClaudeAccountInfoResolver(configURL: configFile)
    }
}
