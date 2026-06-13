import Testing
import Foundation
@testable import Infrastructure

@Suite("ClaudeAccountActivator Tests")
struct ClaudeAccountActivatorTests {

    private final class InMemoryStore: ClaudeKeychainDataStore, @unchecked Sendable {
        var items: [String: Data] = [:]
        func read(service: String) -> Data? { items[service] }
        @discardableResult func write(_ data: Data, service: String) -> Bool {
            items[service] = data
            return true
        }
    }

    @Test
    func `activate swaps the account token into the global item, preserving mcpOAuth`() throws {
        let store = InMemoryStore()
        let base = "Claude Code-credentials"
        let configDir = "/Users/test/.claude-profiles/work"
        let sourceService = ClaudeCredentialLoader.keychainServiceName(base: base, forConfigDirectory: configDir)

        store.items[sourceService] = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "WORK-TOKEN", "subscriptionType": "team"],
        ])
        store.items[base] = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "OLD-GLOBAL-TOKEN"],
            "mcpOAuth": ["server": ["accessToken": "MCP-TOKEN"]],
        ])

        let activator = ClaudeAccountActivator(store: store, baseService: base)
        #expect(activator.activate(configDirectory: configDir) == true)

        let global = try #require(
            try JSONSerialization.jsonObject(with: store.items[base]!) as? [String: Any]
        )
        let oauth = try #require(global["claudeAiOauth"] as? [String: Any])
        // The account token replaced the global one...
        #expect(oauth["accessToken"] as? String == "WORK-TOKEN")
        #expect(oauth["subscriptionType"] as? String == "team")
        // ...while the global item's MCP tokens were preserved.
        #expect(global["mcpOAuth"] as? [String: Any] != nil)
    }

    @Test
    func `activate returns false when the source account has no stored credentials`() {
        let store = InMemoryStore()
        let activator = ClaudeAccountActivator(store: store, baseService: "Claude Code-credentials")
        #expect(activator.activate(configDirectory: "/Users/test/.claude-profiles/missing") == false)
    }
}
