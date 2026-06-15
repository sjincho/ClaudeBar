import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("ClaudeAPIUsageProbe Tests")
struct ClaudeAPIUsageProbeTests {

    // MARK: - Test Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-api-probe-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when credentials exist`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader)

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when credentials missing`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader)

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Snapshot Cache (TTL) Tests

    @Test
    func `probe serves cached snapshot on subsequent calls within TTL`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_max")

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "five_hour": { "utilization": 25.0, "resets_at": "2025-01-15T10:00:00Z" }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let first = try await probe.probe()
        let second = try await probe.probe()
        let third = try await probe.probe()

        // All three calls return the same cached snapshot...
        #expect(first.quotas.first?.percentRemaining == 75.0)
        #expect(second.quotas.first?.percentRemaining == 75.0)
        #expect(third.quotas.first?.percentRemaining == 75.0)
        // ...but only the first one actually hit the network.
        verify(mockNetwork).request(.any).called(1)
    }

    @Test
    func `probe bypasses cache when TTL is zero`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_max")

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "five_hour": { "utilization": 25.0, "resets_at": "2025-01-15T10:00:00Z" }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        // TTL=0 means every entry is immediately stale, so every probe re-fetches.
        let probe = ClaudeAPIUsageProbe(
            credentialLoader: loader,
            networkClient: mockNetwork,
            snapshotCacheTTL: 0
        )

        _ = try await probe.probe()
        _ = try await probe.probe()

        verify(mockNetwork).request(.any).called(2)
    }

    // MARK: - Rate Limit (HTTP 429) Tests

    @Test
    func `probe throws rateLimited when API returns 429 with Retry-After seconds`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]
        )!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let before = Date()
        do {
            _ = try await probe.probe()
            Issue.record("Expected rateLimited error to be thrown")
        } catch let error as ProbeError {
            guard case .rateLimited(let retryAt) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            let delta = retryAt.timeIntervalSince(before)
            #expect(delta >= 119 && delta <= 122)
        }
    }

    @Test
    func `probe defaults to 5 minute retry when 429 has no Retry-After header`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let before = Date()
        do {
            _ = try await probe.probe()
            Issue.record("Expected rateLimited error to be thrown")
        } catch let error as ProbeError {
            guard case .rateLimited(let retryAt) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            let delta = retryAt.timeIntervalSince(before)
            #expect(delta >= 299 && delta <= 302)
        }
    }

    @Test
    func `probe short-circuits subsequent calls within active rate-limit window`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "600"]
        )!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        // First call: hits the network and stores the rate-limit window
        _ = try? await probe.probe()
        // Second call: must throw immediately without re-hitting the network
        _ = try? await probe.probe()

        verify(mockNetwork).request(.any).called(1)
    }

    // MARK: - Retry-After Parsing Tests

    @Test
    func `parseRetryAfter accepts positive integer seconds`() {
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("120") == 120)
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("1") == 1)
    }

    @Test
    func `parseRetryAfter rejects zero seconds`() {
        // /api/oauth/usage has been observed returning Retry-After: 0 while
        // still 429ing (anthropics/claude-code#30930). Treat 0 as no usable
        // value so the caller applies its fallback window instead.
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("0") == nil)
    }

    @Test
    func `parseRetryAfter accepts HTTP-date in the future`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 2023-11-14 22:13:20 UTC + 60s = 2023-11-14 22:14:20 UTC
        let result = ClaudeAPIUsageProbe.parseRetryAfter(
            "Tue, 14 Nov 2023 22:14:20 GMT",
            now: now
        )
        #expect(result == 60)
    }

    @Test
    func `parseRetryAfter rejects past HTTP-dates`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = ClaudeAPIUsageProbe.parseRetryAfter(
            "Tue, 14 Nov 2023 22:00:00 GMT",
            now: now
        )
        #expect(result == nil)
    }

    @Test
    func `parseRetryAfter rejects malformed and empty values`() {
        #expect(ClaudeAPIUsageProbe.parseRetryAfter(nil) == nil)
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("") == nil)
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("   ") == nil)
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("not a number") == nil)
        #expect(ClaudeAPIUsageProbe.parseRetryAfter("-5") == nil)
    }

    // MARK: - Probe Authentication Tests

    @Test
    func `probe throws authenticationRequired when no credentials`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader)

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    // MARK: - Response Parsing Tests

    @Test
    func `probe parses session usage correctly`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_max")

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "five_hour": {
            "utilization": 25.5,
            "resets_at": "2025-01-15T10:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "claude")
        #expect(snapshot.accountTier == .claudeMax)

        let sessionQuota = snapshot.quotas.first { $0.quotaType == .session }
        #expect(sessionQuota != nil)
        #expect(sessionQuota?.percentRemaining == 74.5)  // 100 - 25.5
        #expect(sessionQuota?.resetsAt != nil)
    }

    @Test
    func `probe parses weekly usage correctly`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "five_hour": { "utilization": 10.0, "resets_at": "2025-01-15T10:00:00Z" },
          "seven_day": { "utilization": 45.0, "resets_at": "2025-01-20T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        let weeklyQuota = snapshot.quotas.first { $0.quotaType == .weekly }
        #expect(weeklyQuota != nil)
        #expect(weeklyQuota?.percentRemaining == 55.0)  // 100 - 45
    }

    @Test
    func `probe parses model-specific quotas correctly`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "five_hour": { "utilization": 10.0, "resets_at": "2025-01-15T10:00:00Z" },
          "seven_day_sonnet": { "utilization": 30.0, "resets_at": "2025-01-20T00:00:00Z" },
          "seven_day_opus": { "utilization": 60.0, "resets_at": "2025-01-20T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        let sonnetQuota = snapshot.quotas.first { $0.quotaType == .modelSpecific("sonnet") }
        #expect(sonnetQuota != nil)
        #expect(sonnetQuota?.percentRemaining == 70.0)  // 100 - 30

        let opusQuota = snapshot.quotas.first { $0.quotaType == .modelSpecific("opus") }
        #expect(opusQuota != nil)
        #expect(opusQuota?.percentRemaining == 40.0)  // 100 - 60
    }

    @Test
    func `probe parses extra usage correctly converting cents to dollars`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_pro")

        let mockNetwork = MockNetworkClient()
        // API returns used_credits and monthly_limit in cents
        let responseJSON = """
        {
          "five_hour": { "utilization": 10.0, "resets_at": "2025-01-15T10:00:00Z" },
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 541,
            "monthly_limit": 2000
          }
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        #expect(snapshot.accountTier == .claudePro)
        #expect(snapshot.costUsage != nil)
        // 541 cents -> $5.41
        #expect(snapshot.costUsage?.totalCost == Decimal(string: "5.41"))
        // 2000 cents -> $20.00
        #expect(snapshot.costUsage?.budget == Decimal(string: "20"))
    }

    @Test
    func `probe converts API cost from cents to dollars for large amounts`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_pro")

        let mockNetwork = MockNetworkClient()
        // Simulates the real scenario: $26.72 spent of $50 budget
        // API returns 2672 cents and 5000 cents
        let responseJSON = """
        {
          "five_hour": { "utilization": 10.0, "resets_at": "2025-01-15T10:00:00Z" },
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 2672,
            "monthly_limit": 5000
          }
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        #expect(snapshot.costUsage != nil)
        // 2672 cents -> $26.72 (NOT $2672.00)
        #expect(snapshot.costUsage?.totalCost == Decimal(string: "26.72"))
        // 5000 cents -> $50.00 (NOT $5000.00)
        #expect(snapshot.costUsage?.budget == Decimal(string: "50"))
        // Verify formatted output shows dollars, not cents
        #expect(snapshot.costUsage?.formattedCost.contains("26.72") == true)
    }

    @Test
    func `probe handles empty response with badge`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let responseJSON = "{}".data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        // Should succeed but have no quotas
        #expect(snapshot.quotas.isEmpty)
    }

    // MARK: - Account Tier Detection Tests

    @Test
    func `probe detects claude_max subscription type`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_max")

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        { "five_hour": { "utilization": 10.0 } }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()
        #expect(snapshot.accountTier == .claudeMax)
    }

    @Test
    func `probe detects claude_pro subscription type`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry, subscriptionType: "claude_pro")

        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        { "five_hour": { "utilization": 10.0 } }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()
        #expect(snapshot.accountTier == .claudePro)
    }

    // MARK: - Error Handling Tests

    @Test
    func `probe throws sessionExpired on 401 response`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((Data(), response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        await #expect(throws: ProbeError.sessionExpired()) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws authenticationRequired on 403 response`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((Data(), response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        // 403 triggers a token refresh attempt which also fails with 403 -> executionFailed
        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws parseFailed on invalid JSON`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn(("not json".data(using: .utf8)!, response))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed on network error`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureExpiry = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, expiresAt: futureExpiry)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willThrow(URLError(.notConnectedToInternet))

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }
}

// MARK: - Token Refresh Tests

@Suite("ClaudeAPIUsageProbe Token Refresh Tests")
struct ClaudeAPIUsageProbeTokenRefreshTests {

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-api-probe-refresh-tests-\(UUID().uuidString)", isDirectory: true)
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

    @Test
    func `probe refreshes token when expired and retries`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Token expired 1 hour ago
        let pastExpiry = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, accessToken: "old-token", expiresAt: pastExpiry)

        let mockNetwork = MockNetworkClient()

        // First call: refresh token request
        let refreshResponse = """
        {
          "access_token": "new-token",
          "refresh_token": "new-refresh-token",
          "expires_in": 3600
        }
        """.data(using: .utf8)!

        let refreshHTTP = HTTPURLResponse(
            url: URL(string: "https://platform.claude.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        // Second call: usage request with new token
        let usageResponse = """
        { "five_hour": { "utilization": 10.0 } }
        """.data(using: .utf8)!

        let usageHTTP = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        // Setup mock to return refresh response first, then usage response
        given(mockNetwork).request(.any).willProduce { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("oauth/token") {
                return (refreshResponse, refreshHTTP)
            } else {
                return (usageResponse, usageHTTP)
            }
        }

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "claude")
        #expect(snapshot.quotas.first?.percentRemaining == 90.0)
    }

    @Test
    func `probe never calls the OAuth token endpoint even when the token is expired`() async throws {
        // Pure reader: ClaudeBar must not refresh/rotate the token — the `claude`
        // CLI owns refresh. Even with an expired token, the probe only ever hits
        // the usage endpoint, never the OAuth token endpoint.
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pastExpiry = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, accessToken: "expired-token", expiresAt: pastExpiry)

        let mockNetwork = MockNetworkClient()
        var hitTokenEndpoint = false
        given(mockNetwork).request(.any).willProduce { request in
            if (request.url?.absoluteString ?? "").contains("oauth/token") {
                hitTokenEndpoint = true
            }
            let usageResponse = #"{ "five_hour": { "utilization": 15.0 } }"#.data(using: .utf8)!
            return (usageResponse, HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.first?.percentRemaining == 85.0)
        #expect(hitTokenEndpoint == false)
    }

    @Test
    func `probe with allowTokenRefresh refreshes an expired token and persists it`() async throws {
        // Profile accounts (allowTokenRefresh: true) DO refresh + persist, so they
        // stay live without the user running `claude` for them.
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pastExpiry = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        try createCredentialsFile(at: tempDir, accessToken: "old", refreshToken: "rt", expiresAt: pastExpiry)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willProduce { request in
            if (request.url?.absoluteString ?? "").contains("oauth/token") {
                let body = #"{ "access_token": "new-token", "refresh_token": "rt2", "expires_in": 3600 }"#.data(using: .utf8)!
                return (body, HTTPURLResponse(url: URL(string: "https://platform.claude.com")!,
                                              statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let usage = #"{ "five_hour": { "utilization": 30.0 } }"#.data(using: .utf8)!
            return (usage, HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, useKeychain: false)
        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork, allowTokenRefresh: true)

        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.first?.percentRemaining == 70.0) // 100 - 30
        // The rotated token was persisted back to the credential file.
        let path = tempDir.appendingPathComponent(".claude/.credentials.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        #expect((saved["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "new-token")
    }

}

// MARK: - Setup-Token (Environment) Tests

@Suite("ClaudeAPIUsageProbe Setup-Token Tests")
struct ClaudeAPIUsageProbeSetupTokenTests {

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-api-probe-setup-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test
    func `probe skips refresh when no refresh token and fetches successfully`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate setup-token: loaded from env var, no refresh token, no expiresAt
        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "setup-token-abc123"]
        )

        let mockNetwork = MockNetworkClient()
        let usageResponse = """
        {
          "five_hour": { "utilization": 20.0, "resets_at": "2025-01-15T10:00:00Z" },
          "seven_day": { "utilization": 40.0, "resets_at": "2025-01-20T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let usageHTTP = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        // Only the usage call should be made — NO refresh call
        given(mockNetwork).request(.any).willReturn((usageResponse, usageHTTP))

        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "claude")
        #expect(snapshot.quotas.count == 2)

        let sessionQuota = snapshot.quotas.first { $0.quotaType == .session }
        #expect(sessionQuota?.percentRemaining == 80.0)  // 100 - 20

        let weeklyQuota = snapshot.quotas.first { $0.quotaType == .weekly }
        #expect(weeklyQuota?.percentRemaining == 60.0)  // 100 - 40
    }

    @Test
    func `probe trims newline in setup-token before Authorization header`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "setup-token-abc123\n"]
        )

        let mockNetwork = MockNetworkClient()
        let usageResponse = """
        {
          "five_hour": { "utilization": 20.0, "resets_at": "2025-01-15T10:00:00Z" }
        }
        """.data(using: .utf8)!

        let usageHTTP = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        var capturedAuthorizationHeader: String?
        given(mockNetwork).request(.any).willProduce { request in
            capturedAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
            return (usageResponse, usageHTTP)
        }

        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        _ = try await probe.probe()

        #expect(capturedAuthorizationHeader == "Bearer setup-token-abc123")
    }

    @Test
    func `probe with setup-token throws authenticationRequired on 401 without attempting refresh`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "expired-setup-token"]
        )

        let mockNetwork = MockNetworkClient()
        let unauthorizedHTTP = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((Data(), unauthorizedHTTP))

        let probe = ClaudeAPIUsageProbe(credentialLoader: loader, networkClient: mockNetwork)

        // Should throw without attempting refresh (no refresh token available)
        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `isAvailable returns true when env var token is set`() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            useKeychain: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "my-setup-token"]
        )

        let probe = ClaudeAPIUsageProbe(credentialLoader: loader)

        #expect(await probe.isAvailable() == true)
    }
}
