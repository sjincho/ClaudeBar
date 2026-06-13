import Testing
import Foundation
import Mockable
@testable import Domain

@Suite("ClaudeProvider Tests")
struct ClaudeProviderTests {

    private func makeSettingsRepository() -> MockProviderSettingsRepository {
        let mock = MockProviderSettingsRepository()
        given(mock).isEnabled(forProvider: .any, defaultValue: .any).willReturn(true)
        given(mock).isEnabled(forProvider: .any).willReturn(true)
        given(mock).setEnabled(.any, forProvider: .any).willReturn()
        return mock
    }

    // MARK: - Identity

    @Test
    func `claude provider has correct id`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.id == "claude")
    }

    @Test
    func `claude provider has correct name`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.name == "Claude")
    }

    @Test
    func `claude provider has correct cliCommand`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.cliCommand == "claude")
    }

    @Test
    func `claude provider has dashboard URL pointing to anthropic`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.dashboardURL != nil)
        #expect(claude.dashboardURL?.host?.contains("anthropic") == true)
    }

    @Test
    func `claude provider is enabled by default`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.isEnabled == true)
    }

    // MARK: - State

    @Test
    func `claude provider starts with no snapshot`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.snapshot == nil)
    }

    @Test
    func `claude provider starts not syncing`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.isSyncing == false)
    }

    @Test
    func `claude provider starts with no error`() {
        let settings = makeSettingsRepository()
        let claude = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(claude.lastError == nil)
    }

    // MARK: - Delegation

    @Test
    func `claude provider delegates isAvailable to probe`() async {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).isAvailable().willReturn(true)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        let isAvailable = await claude.isAvailable()
        #expect(isAvailable == true)
    }

    @Test
    func `isAvailable returns false in API mode when API unavailable and CLI fallback disabled`() async {
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: false)
        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(false)
        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        #expect(await claude.isAvailable() == false)
    }

    @Test
    func `isAvailable returns true in API mode when API unavailable but CLI fallback enabled`() async {
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)
        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(false)
        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        #expect(await claude.isAvailable() == true)
    }

    @Test
    func `claude provider delegates refresh to probe`() async throws {
        let settings = makeSettingsRepository()
        let expectedSnapshot = UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date())
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(expectedSnapshot)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        let snapshot = try await claude.refresh()
        #expect(snapshot.quotas.isEmpty)
    }

    // MARK: - Snapshot Storage

    @Test
    func `claude provider stores snapshot after refresh`() async throws {
        let settings = makeSettingsRepository()
        let expectedSnapshot = UsageSnapshot(
            providerId: "claude",
            quotas: [UsageQuota(percentRemaining: 50, quotaType: .session, providerId: "claude")],
            capturedAt: Date()
        )
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(expectedSnapshot)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.snapshot == nil)
        _ = try await claude.refresh()
        #expect(claude.snapshot != nil)
        #expect(claude.snapshot?.quotas.first?.percentRemaining == 50)
    }

    // MARK: - Error Handling

    @Test
    func `claude provider stores error on refresh failure`() async {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willThrow(ProbeError.timeout)
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.lastError == nil)
        do {
            _ = try await claude.refresh()
        } catch {
            // Expected
        }
        #expect(claude.lastError != nil)
    }

    // MARK: - Syncing State

    @Test
    func `claude provider resets isSyncing after refresh completes`() async throws {
        let settings = makeSettingsRepository()
        let mockProbe = MockUsageProbe()
        given(mockProbe).probe().willReturn(UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date()))
        let claude = ClaudeProvider(probe: mockProbe, settingsRepository: settings)

        #expect(claude.isSyncing == false)
        _ = try await claude.refresh()
        #expect(claude.isSyncing == false)
    }

    // MARK: - Equality via ID

    @Test
    func `two claude providers have same id`() {
        let settings = makeSettingsRepository()
        let provider1 = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        let provider2 = ClaudeProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(provider1.id == provider2.id)
    }

    // MARK: - Error Propagation When Both Probes Fail

    @Test
    func `refresh does not invoke CLI fallback when API returns rateLimited`() async {
        // When the API probe is rate-limited, the CLI probe talks to the
        // same Anthropic backend (subject to the same per-token throttle)
        // AND it's currently broken in the field. The rate-limit error
        // should surface immediately without the CLI probe being touched.
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)

        let retryAt = Date().addingTimeInterval(300)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(true)
        given(apiProbe).probe().willThrow(ProbeError.rateLimited(retryAt: retryAt))

        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)

        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        do {
            _ = try await claude.refresh()
            Issue.record("Expected refresh to throw")
        } catch let error as ProbeError {
            #expect(error == .rateLimited(retryAt: retryAt))
        } catch {
            Issue.record("Expected ProbeError, got \(error)")
        }

        // The CLI probe must never be invoked when the primary error is
        // an upstream rate-limit; fallback would amplify the throttle.
        verify(cliProbe).probe().called(0)
    }

    @Test
    func `refresh surfaces primary API error when CLI fallback also fails`() async {
        // API mode with CLI fallback enabled: API probe throws .rateLimited
        // (the real root cause), CLI fallback throws .parseFailed (a red
        // herring caused by the broken /usage stdout capture). The user
        // should see the rate-limit error, not the parse failure.
        let settings = FakeClaudeSettings(probeMode: .api, cliFallbackEnabled: true)

        let retryAt = Date().addingTimeInterval(300)
        let apiProbe = MockUsageProbe()
        given(apiProbe).isAvailable().willReturn(true)
        given(apiProbe).probe().willThrow(ProbeError.rateLimited(retryAt: retryAt))

        let cliProbe = MockUsageProbe()
        given(cliProbe).isAvailable().willReturn(true)
        given(cliProbe).probe().willThrow(ProbeError.parseFailed("Could not find session usage"))

        let claude = ClaudeProvider(cliProbe: cliProbe, apiProbe: apiProbe, settingsRepository: settings)

        do {
            _ = try await claude.refresh()
            Issue.record("Expected refresh to throw")
        } catch let error as ProbeError {
            #expect(error == .rateLimited(retryAt: retryAt))
            #expect(claude.lastError as? ProbeError == .rateLimited(retryAt: retryAt))
        } catch {
            Issue.record("Expected ProbeError, got \(error)")
        }
    }

    // MARK: - Background Refresh Floor (issue #204)

    @Test
    func `background refresh floor is 15 minutes in API mode`() {
        let settings = FakeClaudeSettings(probeMode: .api)
        let claude = ClaudeProvider(
            cliProbe: MockUsageProbe(),
            apiProbe: MockUsageProbe(),
            settingsRepository: settings
        )

        // API mode floors the background cadence to the API snapshot-cache TTL.
        #expect(claude.backgroundRefreshFloor == .seconds(900))
    }

    @Test
    func `background refresh floor is nil in CLI mode`() {
        let settings = FakeClaudeSettings(probeMode: .cli)
        let claude = ClaudeProvider(
            cliProbe: MockUsageProbe(),
            apiProbe: MockUsageProbe(),
            settingsRepository: settings
        )

        // CLI mode imposes no floor — it keeps the user's chosen interval.
        #expect(claude.backgroundRefreshFloor == nil)
    }

    // MARK: - Multi-Account Support

    @Test
    func `multi-account provider exposes configured accounts`() {
        let settings = FakeMultiAccountClaudeSettings(accounts: [
            ProviderAccountConfig(
                accountId: "work",
                label: "Work",
                email: "me@work.example",
                organization: "Work Org",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/work"]
            ),
            ProviderAccountConfig(
                accountId: "personal",
                label: "Personal",
                email: "me@example.com",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/personal"]
            ),
        ])
        let claude = ClaudeProvider(probe: StaticUsageProbe(email: "default@example.com"), settingsRepository: settings)

        // The default (global) account is always present alongside configured ones.
        #expect(claude.accounts.map(\.accountId) == ["default", "work", "personal"])
        // With no active account persisted, the default stays active.
        #expect(claude.activeAccount.accountId == "default")
    }

    @Test
    func `refreshAllAccounts stores snapshots for each configured account`() async {
        let settings = FakeMultiAccountClaudeSettings(accounts: [
            ProviderAccountConfig(
                accountId: "work",
                label: "Work",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/work"]
            ),
            ProviderAccountConfig(
                accountId: "personal",
                label: "Personal",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/personal"]
            ),
        ])
        let claude = ClaudeProvider(
            probe: StaticUsageProbe(email: "default@example.com"),
            settingsRepository: settings,
            cliProbeFactory: { config in
                StaticUsageProbe(email: "\(config.accountId)@example.com")
            }
        )

        await claude.refreshAllAccounts()

        #expect(claude.accountSnapshots["work"]?.accountEmail == "work@example.com")
        #expect(claude.accountSnapshots["personal"]?.accountEmail == "personal@example.com")
        // Active stays the default account (nothing switched), so its snapshot is exposed.
        #expect(claude.snapshot?.accountEmail == "default@example.com")
    }

    @Test
    func `switchAccount persists active account and updates snapshot`() async {
        let settings = FakeMultiAccountClaudeSettings(accounts: [
            ProviderAccountConfig(
                accountId: "work",
                label: "Work",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/work"]
            ),
            ProviderAccountConfig(
                accountId: "personal",
                label: "Personal",
                probeConfig: [ClaudeAccountProbeConfig.claudeConfigDir: "/tmp/personal"]
            ),
        ])
        let claude = ClaudeProvider(
            probe: StaticUsageProbe(email: "default@example.com"),
            settingsRepository: settings,
            cliProbeFactory: { config in
                StaticUsageProbe(email: "\(config.accountId)@example.com")
            }
        )

        await claude.refreshAllAccounts()
        let switched = claude.switchAccount(to: "personal")

        #expect(switched)
        #expect(settings.activeAccountId(forProvider: "claude") == "personal")
        #expect(claude.activeAccount.accountId == "personal")
        #expect(claude.snapshot?.accountEmail == "personal@example.com")
    }

    @Test
    func `addCLIAccount persists a Claude config directory account`() {
        let settings = FakeMultiAccountClaudeSettings()
        let claude = ClaudeProvider(probe: StaticUsageProbe(email: "default@example.com"), settingsRepository: settings)

        let added = claude.addCLIAccount(
            label: "Work Main",
            configDirectoryPath: "/private/tmp/claude-usage-poc-config/work-main"
        )

        #expect(added)
        #expect(settings.accounts(forProvider: "claude").count == 1)
        #expect(settings.accounts(forProvider: "claude").first?.accountId == "work-main")
        #expect(settings.accounts(forProvider: "claude").first?.probeConfig[ClaudeAccountProbeConfig.claudeConfigDir] == "/private/tmp/claude-usage-poc-config/work-main")
        // Adding an account does NOT steal the active selection; default stays active.
        #expect(settings.activeAccountId(forProvider: "claude") == nil)
        #expect(claude.accounts.map(\.accountId) == ["default", "work-main"])
    }
}

// MARK: - Test Helpers

private struct StaticUsageProbe: UsageProbe {
    let email: String

    func probe() async throws -> UsageSnapshot {
        UsageSnapshot(
            providerId: "claude",
            quotas: [
                UsageQuota(
                    percentRemaining: 50,
                    quotaType: .session,
                    providerId: "claude"
                )
            ],
            capturedAt: Date(),
            accountEmail: email
        )
    }

    func isAvailable() async -> Bool {
        true
    }
}

private final class FakeClaudeSettings: ClaudeSettingsRepository, @unchecked Sendable {
    var probeMode: ClaudeProbeMode
    var cliFallbackEnabled: Bool

    init(probeMode: ClaudeProbeMode = .cli, cliFallbackEnabled: Bool = true) {
        self.probeMode = probeMode
        self.cliFallbackEnabled = cliFallbackEnabled
    }

    func isEnabled(forProvider id: String) -> Bool { true }
    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { true }
    func setEnabled(_ enabled: Bool, forProvider id: String) {}
    func customCardURL(forProvider id: String) -> String? { nil }
    func setCustomCardURL(_ url: String?, forProvider id: String) {}
    func claudeProbeMode() -> ClaudeProbeMode { probeMode }
    func setClaudeProbeMode(_ mode: ClaudeProbeMode) { probeMode = mode }
    func claudeCliFallbackEnabled() -> Bool { cliFallbackEnabled }
    func setClaudeCliFallbackEnabled(_ enabled: Bool) { cliFallbackEnabled = enabled }
}

private final class FakeMultiAccountClaudeSettings: ClaudeSettingsRepository, MultiAccountSettingsRepository, @unchecked Sendable {
    var probeMode: ClaudeProbeMode
    var cliFallbackEnabled: Bool
    private var accountConfigs: [ProviderAccountConfig]
    private var activeAccount: String?

    init(
        probeMode: ClaudeProbeMode = .cli,
        cliFallbackEnabled: Bool = true,
        accounts: [ProviderAccountConfig] = [],
        activeAccountId: String? = nil
    ) {
        self.probeMode = probeMode
        self.cliFallbackEnabled = cliFallbackEnabled
        self.accountConfigs = accounts
        self.activeAccount = activeAccountId
    }

    func isEnabled(forProvider id: String) -> Bool { true }
    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { true }
    func setEnabled(_ enabled: Bool, forProvider id: String) {}
    func customCardURL(forProvider id: String) -> String? { nil }
    func setCustomCardURL(_ url: String?, forProvider id: String) {}
    func claudeProbeMode() -> ClaudeProbeMode { probeMode }
    func setClaudeProbeMode(_ mode: ClaudeProbeMode) { probeMode = mode }
    func claudeCliFallbackEnabled() -> Bool { cliFallbackEnabled }
    func setClaudeCliFallbackEnabled(_ enabled: Bool) { cliFallbackEnabled = enabled }

    func accounts(forProvider id: String) -> [ProviderAccountConfig] {
        accountConfigs
    }

    func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        accountConfigs.removeAll { $0.accountId == config.accountId }
        accountConfigs.append(config)
    }

    func removeAccount(accountId: String, forProvider id: String) {
        accountConfigs.removeAll { $0.accountId == accountId }
        if activeAccount == accountId {
            activeAccount = accountConfigs.first?.accountId
        }
    }

    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        if let index = accountConfigs.firstIndex(where: { $0.accountId == config.accountId }) {
            accountConfigs[index] = config
        } else {
            accountConfigs.append(config)
        }
    }

    func activeAccountId(forProvider id: String) -> String? {
        activeAccount
    }

    func setActiveAccountId(_ accountId: String?, forProvider id: String) {
        activeAccount = accountId
    }
}
