import Foundation
import Observation

public enum ClaudeAccountProbeConfig {
    public static let claudeConfigDir = "claudeConfigDir"
    public static let claudeConfigDirEnv = "CLAUDE_CONFIG_DIR"
}

/// Claude AI provider - a rich domain model.
/// Observable class with its own state (isSyncing, snapshot, error).
/// Supports dual probe modes: CLI (default) and API.
@Observable
public final class ClaudeProvider: MultiAccountProvider, @unchecked Sendable {
    // MARK: - Identity (Protocol Requirement)

    public let id: String = "claude"
    public let name: String = "Claude"
    public let cliCommand: String = "claude"

    public var dashboardURL: URL? {
        URL(string: "https://console.anthropic.com/settings/billing")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.anthropic.com")
    }

    /// Whether the provider is enabled (persisted via settingsRepository)
    public var isEnabled: Bool {
        didSet {
            settingsRepository.setEnabled(isEnabled, forProvider: id)
        }
    }

    // MARK: - State (Observable)

    /// Whether the provider is currently syncing data
    public private(set) var isSyncing: Bool = false

    /// The current usage snapshot (nil if never refreshed or unavailable)
    public private(set) var snapshot: UsageSnapshot?

    /// Usage snapshots for each configured Claude account.
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]

    /// The last error that occurred during refresh
    public private(set) var lastError: Error?

    /// The current guest pass information (nil if never fetched)
    public private(set) var guestPass: ClaudePass?

    /// Whether the provider is currently fetching passes
    public private(set) var isFetchingPasses: Bool = false

    // MARK: - Probe Mode

    /// The current probe mode (CLI or API)
    public var probeMode: ClaudeProbeMode {
        get {
            // Only use ClaudeSettingsRepository if available
            if let claudeSettings = settingsRepository as? ClaudeSettingsRepository {
                return claudeSettings.claudeProbeMode()
            }
            return .cli
        }
        set {
            if let claudeSettings = settingsRepository as? ClaudeSettingsRepository {
                claudeSettings.setClaudeProbeMode(newValue)
            }
        }
    }

    /// Background poll cadence floor. In API mode, background refreshes are
    /// floored at 15 min to match `ClaudeAPIUsageProbe`'s snapshot-cache TTL:
    /// polling faster only re-serves the cache (or, once expired, risks 429s),
    /// so there's no benefit to a tighter background cadence (issue #204). CLI
    /// mode keeps the user's chosen interval (no floor).
    public var backgroundRefreshFloor: Duration? {
        switch probeMode {
        case .api: return .seconds(900)
        case .cli: return nil
        }
    }

    // MARK: - Internal

    /// The CLI probe for fetching usage data via `claude /usage`
    private let cliProbe: any UsageProbe

    /// Factory for account-specific probes.
    private let cliProbeFactory: @Sendable (ProviderAccountConfig) -> any UsageProbe

    /// Memoized account-specific probe instances, keyed by account ID. Probes are
    /// created once and reused across refreshes so their internal state (snapshot
    /// cache, rate-limit window) persists — otherwise every refresh would build a
    /// fresh probe with an empty cache and hammer the upstream API.
    private var accountProbes: [String: any UsageProbe] = [:]

    /// Resolves the global (`~/.claude`) account's identity (email/org) cheaply,
    /// without a probe. Lets the provider decide up front whether the global is a
    /// duplicate of a configured profile — and skip its slow CLI probe if so.
    private let defaultAccountInfoProvider: (@Sendable () -> (email: String?, organization: String?, budgetWeight: Double?)?)?
    private var cachedDefaultInfo: (email: String?, organization: String?, budgetWeight: Double?)?
    private var didResolveDefaultInfo = false

    private func resolvedDefaultAccountInfo() -> (email: String?, organization: String?, budgetWeight: Double?)? {
        if !didResolveDefaultInfo {
            cachedDefaultInfo = defaultAccountInfoProvider?()
            didResolveDefaultInfo = true
        }
        return cachedDefaultInfo
    }

    /// The API probe for fetching usage data via HTTP API (optional)
    private let apiProbe: (any UsageProbe)?

    /// The probe used to fetch guest pass data
    private let passProbe: (any ClaudePassProbing)?

    /// The settings repository for persisting provider settings
    private let settingsRepository: any ProviderSettingsRepository

    /// Optional analyzer for daily usage from JSONL session data
    private let dailyUsageAnalyzer: (any DailyUsageAnalyzing)?

    private var multiAccountSettingsRepository: (any MultiAccountSettingsRepository)? {
        settingsRepository as? (any MultiAccountSettingsRepository)
    }

    private var defaultAccountConfig: ProviderAccountConfig {
        ProviderAccountConfig(
            accountId: ProviderAccount.defaultAccountId,
            label: name
        )
    }

    private var accountConfigs: [ProviderAccountConfig] {
        guard let multiAccountSettingsRepository else {
            return [defaultAccountConfig]
        }
        // The default account (the global ~/.claude login) is ALWAYS present.
        // Configured CLI-profile accounts are added alongside it, never replace
        // it — otherwise adding one org would make the user's main login vanish.
        let configured = multiAccountSettingsRepository.accounts(forProvider: id)
            .filter { $0.accountId != ProviderAccount.defaultAccountId }
        return [defaultAccountConfig] + configured
    }

    /// Organization key used to dedupe the global account against profiles.
    /// Matches on organization name only — NOT email, since multiple orgs can
    /// share one email (e.g. several RIDI orgs under the same address).
    private func orgKey(for config: ProviderAccountConfig) -> String? {
        var org = config.organization ?? accountSnapshots[config.accountId]?.accountOrganization
        // The global account's org can be resolved cheaply (from ~/.claude.json)
        // even before it's probed, so a covered global can be deduped/skipped.
        if org == nil, config.accountId == ProviderAccount.defaultAccountId {
            org = resolvedDefaultAccountInfo()?.organization
        }
        let trimmed = org?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The configured profile whose organization matches the global (default)
    /// account's, if any. When present, the global account is redundant.
    private var profileMatchingDefaultOrg: ProviderAccountConfig? {
        guard let defaultKey = orgKey(for: defaultAccountConfig) else { return nil }
        return accountConfigs.first {
            $0.accountId != ProviderAccount.defaultAccountId && orgKey(for: $0) == defaultKey
        }
    }

    /// Accounts shown to the user. The synthesized global/default account is
    /// shown only when no configured profile already represents its org —
    /// "show primary only iff none matches".
    private var displayedAccountConfigs: [ProviderAccountConfig] {
        guard profileMatchingDefaultOrg != nil else { return accountConfigs }
        return accountConfigs.filter { $0.accountId != ProviderAccount.defaultAccountId }
    }

    private var activeAccountConfig: ProviderAccountConfig {
        let configs = accountConfigs
        let active: ProviderAccountConfig
        if let activeId = multiAccountSettingsRepository?.activeAccountId(forProvider: id),
           let found = configs.first(where: { $0.accountId == activeId }) {
            active = found
        } else {
            active = configs.first ?? defaultAccountConfig
        }
        // If the active resolves to the global account but it's hidden because a
        // profile represents the same org, surface that profile as active.
        if active.accountId == ProviderAccount.defaultAccountId,
           let match = profileMatchingDefaultOrg {
            return match
        }
        return active
    }

    public var accounts: [ProviderAccount] {
        let all = displayedAccountConfigs.map(providerAccount(from:))
        // Show the active (primary) account first.
        let activeId = activeAccount.accountId
        return all.filter { $0.accountId == activeId } + all.filter { $0.accountId != activeId }
    }

    public var activeAccount: ProviderAccount {
        providerAccount(from: activeAccountConfig)
    }

    /// Returns the active probe based on current mode
    private var activeProbe: any UsageProbe {
        switch probeMode {
        case .cli:
            return cliProbe
        case .api:
            // Fall back to CLI if API probe not available
            return apiProbe ?? cliProbe
        }
    }

    // MARK: - Initialization

    /// Creates a Claude provider with CLI probe only (legacy initializer)
    /// - Parameters:
    ///   - probe: The CLI probe to use for fetching usage data
    ///   - passProbe: The probe to use for fetching guest pass data (optional)
    ///   - settingsRepository: The repository for persisting settings
    public init(
        probe: any UsageProbe,
        passProbe: (any ClaudePassProbing)? = nil,
        settingsRepository: any ProviderSettingsRepository,
        dailyUsageAnalyzer: (any DailyUsageAnalyzing)? = nil,
        cliProbeFactory: (@Sendable (ProviderAccountConfig) -> any UsageProbe)? = nil,
        defaultAccountInfoProvider: (@Sendable () -> (email: String?, organization: String?, budgetWeight: Double?)?)? = nil
    ) {
        self.cliProbe = probe
        self.cliProbeFactory = cliProbeFactory ?? { _ in probe }
        self.apiProbe = nil
        self.passProbe = passProbe
        self.settingsRepository = settingsRepository
        self.dailyUsageAnalyzer = dailyUsageAnalyzer
        self.defaultAccountInfoProvider = defaultAccountInfoProvider
        // Load persisted enabled state (defaults to true)
        self.isEnabled = settingsRepository.isEnabled(forProvider: "claude")
    }

    /// Creates a Claude provider with both CLI and API probes
    /// - Parameters:
    ///   - cliProbe: The CLI probe for fetching usage via `claude /usage`
    ///   - apiProbe: The API probe for fetching usage via HTTP API
    ///   - passProbe: The probe to use for fetching guest pass data (optional)
    ///   - settingsRepository: The repository for persisting settings (must be ClaudeSettingsRepository for mode switching)
    public init(
        cliProbe: any UsageProbe,
        apiProbe: any UsageProbe,
        passProbe: (any ClaudePassProbing)? = nil,
        settingsRepository: any ClaudeSettingsRepository,
        dailyUsageAnalyzer: (any DailyUsageAnalyzing)? = nil,
        cliProbeFactory: (@Sendable (ProviderAccountConfig) -> any UsageProbe)? = nil,
        defaultAccountInfoProvider: (@Sendable () -> (email: String?, organization: String?, budgetWeight: Double?)?)? = nil
    ) {
        self.cliProbe = cliProbe
        self.cliProbeFactory = cliProbeFactory ?? { _ in cliProbe }
        self.apiProbe = apiProbe
        self.passProbe = passProbe
        self.settingsRepository = settingsRepository
        self.dailyUsageAnalyzer = dailyUsageAnalyzer
        self.defaultAccountInfoProvider = defaultAccountInfoProvider
        // Load persisted enabled state (defaults to true)
        self.isEnabled = settingsRepository.isEnabled(forProvider: "claude")
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        switch probeMode {
        case .cli:
            if await cliProbe.isAvailable() {
                return true
            }
            if let apiProbe, await apiProbe.isAvailable() {
                return true
            }
            return false
        case .api:
            if let apiProbe, await apiProbe.isAvailable() {
                return true
            }
            guard cliFallbackEnabled else { return false }
            return await cliProbe.isAvailable()
        }
    }

    /// Refreshes the usage data and updates the snapshot.
    /// Interactive refresh: delegates to the kind-aware implementation.
    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        try await refresh(.interactive)
    }

    /// Refreshes the usage data and updates the snapshot.
    /// Uses the active probe based on current probe mode.
    /// Sets isSyncing during refresh and captures any errors.
    ///
    /// The probe and fallback behaviour are identical for both kinds — CLI stays
    /// CLI, the rate-limit short-circuit still holds. The only difference is that
    /// a `.background` refresh skips the daily-usage JSONL scan
    /// (`attachDailyReport`), which the menu-bar label never shows; that scan
    /// runs only when the dropdown is open, which always refreshes interactively
    /// (issue #204).
    @discardableResult
    public func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        try await refreshAccount(activeAccount.accountId, kind: kind)
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        try await refreshAccount(accountId, kind: .interactive)
    }

    @discardableResult
    public func refreshAccount(_ accountId: String, kind: RefreshKind) async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        guard let config = accountConfigs.first(where: { $0.accountId == accountId }) else {
            let error = ProbeError.executionFailed("Claude account not found: \(accountId)")
            lastError = error
            throw error
        }

        do {
            let newSnapshot = try await refreshAccountConfig(config, kind: kind)
            accountSnapshots[accountId] = newSnapshot
            if activeAccount.accountId == accountId {
                snapshot = newSnapshot
            }
            lastError = nil
            return newSnapshot
        } catch {
            lastError = error
            throw error
        }
    }

    public func refreshAllAccounts() async {
        await refreshAllAccounts(.interactive)
    }

    public func refreshAllAccounts(_ kind: RefreshKind) async {
        isSyncing = true
        defer { isSyncing = false }

        didResolveDefaultInfo = false  // re-read the global account's identity this cycle

        let allConfigs = accountConfigs
        let profileConfigs = allConfigs.filter { $0.accountId != ProviderAccount.defaultAccountId }
        let defaultConfig = allConfigs.first { $0.accountId == ProviderAccount.defaultAccountId }

        // Materialize (and memoize) profile probes serially first, so the
        // concurrent tasks below only READ `accountProbes` (no data race) and so
        // per-account caches/rate-limit state survive across refreshes.
        for config in profileConfigs { _ = primaryProbe(for: config) }

        // Probe the configured profiles concurrently — these are fast API calls.
        let probed: [(String, Result<UsageSnapshot, Error>)] = await withTaskGroup(
            of: (String, Result<UsageSnapshot, Error>).self
        ) { group in
            for config in profileConfigs {
                group.addTask {
                    do { return (config.accountId, .success(try await self.probeAccountConfig(config))) }
                    catch { return (config.accountId, .failure(error)) }
                }
            }
            var out: [(String, Result<UsageSnapshot, Error>)] = []
            for await result in group { out.append(result) }
            return out
        }

        var refreshedAnyAccount = false
        var latestError: Error?
        for (accountId, result) in probed {
            switch result {
            case .success(let raw):
                accountSnapshots[accountId] = raw
                refreshedAnyAccount = true
            case .failure(let error):
                latestError = error
            }
        }

        // Probe the global ~/.claude account only when no configured profile
        // already represents its org. Otherwise it's a hidden duplicate, and its
        // ~10s CLI scrape would needlessly dominate the refresh. (`orgKey` resolves
        // the global's org cheaply from ~/.claude.json, so this decision needs no
        // probe of the global.)
        if let defaultConfig {
            if profileMatchingDefaultOrg == nil {
                do {
                    let raw = try await probeAccountConfig(defaultConfig)
                    // The global probe doesn't resolve the tier, so stamp the
                    // default account's budget weight (read cheaply from
                    // ~/.claude.json) onto its snapshot — otherwise the heaviest
                    // account (e.g. a Max 20x personal login) would count as
                    // weight 1 and the weighted Combined would be wrong.
                    let weight = resolvedDefaultAccountInfo()?.budgetWeight
                    accountSnapshots[defaultConfig.accountId] = weight == nil
                        ? raw
                        : raw.withAccountIdentity(email: nil, organization: nil, budgetWeight: weight)
                    refreshedAnyAccount = true
                } catch {
                    latestError = error
                }
            } else {
                accountSnapshots.removeValue(forKey: defaultConfig.accountId)
            }
        }

        // The active account is only known once orgs resolve (the dedup runs
        // post-probe). Attach the machine-wide daily report to the active
        // account only — it's the sole place that card renders, so the other
        // accounts skip the redundant JSONL scan entirely.
        let activeId = activeAccount.accountId
        if let raw = accountSnapshots[activeId] {
            accountSnapshots[activeId] = await report(for: raw, kind: kind)
        }
        snapshot = accountSnapshots[activeId]
        lastError = refreshedAnyAccount ? nil : latestError
    }

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard accountConfigs.contains(where: { $0.accountId == accountId }) else {
            return false
        }

        multiAccountSettingsRepository?.setActiveAccountId(accountId, forProvider: id)
        snapshot = accountSnapshots[accountId]
        return true
    }

    @discardableResult
    public func addCLIAccount(label: String, configDirectoryPath: String) -> Bool {
        guard let multiAccountSettingsRepository else { return false }

        let trimmedPath = configDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = trimmedLabel.isEmpty
            ? URL(fileURLWithPath: trimmedPath).lastPathComponent
            : trimmedLabel
        let accountId = uniqueAccountId(seed: displayLabel)
        let config = ProviderAccountConfig(
            accountId: accountId,
            label: displayLabel,
            probeConfig: [
                ClaudeAccountProbeConfig.claudeConfigDir: trimmedPath
            ]
        )

        // Adding an account must NOT change which account is active — the user's
        // current (default/global) login stays active until they explicitly switch.
        multiAccountSettingsRepository.addAccount(config, forProvider: id)
        return true
    }

    public func removeAccount(accountId: String) {
        guard accountId != ProviderAccount.defaultAccountId else { return }
        multiAccountSettingsRepository?.removeAccount(accountId: accountId, forProvider: id)
        accountSnapshots.removeValue(forKey: accountId)
        accountProbes.removeValue(forKey: accountId)
        snapshot = accountSnapshots[activeAccount.accountId]
    }

    private func refreshAccountConfig(
        _ config: ProviderAccountConfig,
        kind: RefreshKind
    ) async throws -> UsageSnapshot {
        let raw = try await probeAccountConfig(config)
        return await report(for: raw, kind: kind)
    }

    /// Runs the account's probe (with fallback) and returns the raw snapshot,
    /// without attaching the daily-usage report. Safe to call concurrently — it
    /// reads provider state but mutates none of it.
    private func probeAccountConfig(_ config: ProviderAccountConfig) async throws -> UsageSnapshot {
        let probe = primaryProbe(for: config)

        do {
            return try await probe.probe()
        } catch let primaryError {
            guard !usesAccountSpecificCLI(config),
                  Self.shouldAttemptFallback(after: primaryError),
                  let fallback = await fallbackProbe() else {
                throw primaryError
            }

            do {
                return try await fallback.probe()
            } catch {
                // Both probes failed. Surface the primary error — it is
                // the actual root cause (e.g. HTTP 429). The fallback's
                // failure is incidental and would otherwise mask it,
                // sending users chasing the wrong problem.
                throw primaryError
            }
        }
    }

    /// Decides whether the fallback probe should run after the primary fails.
    /// Rate-limit failures are an upstream per-token throttle: the CLI talks
    /// to the same Anthropic backend, so the fallback can't help and would
    /// just amplify the problem. Surface the rate-limit error immediately so
    /// the backoff window does its job. All other failure modes (auth,
    /// parse, network, etc.) still try the fallback — those can legitimately
    /// be recovered by the alternate probe path.
    private static func shouldAttemptFallback(after error: Error) -> Bool {
        if case ProbeError.rateLimited = error { return false }
        return true
    }

    /// Attaches the daily-usage report for interactive refreshes only.
    /// Background refreshes (the menu-bar poll) skip the JSONL scan to stay cheap
    /// — the menu-bar label never renders the daily report, and the dropdown that
    /// does always refreshes interactively (issue #204).
    private func report(for snapshot: UsageSnapshot, kind: RefreshKind) async -> UsageSnapshot {
        switch kind {
        case .interactive:
            return await attachDailyReport(to: snapshot)
        case .background:
            return snapshot
        }
    }

    private func providerAccount(from config: ProviderAccountConfig) -> ProviderAccount {
        let snapshot = accountSnapshots[config.accountId]
        let email = config.email ?? snapshot?.accountEmail
        let organization = config.organization ?? snapshot?.accountOrganization
        // The default (global) account carries a generic "Claude" label. Once its
        // snapshot resolves a real org/email, show that instead so it reads like
        // the configured profile accounts rather than a generic placeholder.
        var label = config.label
        if config.accountId == ProviderAccount.defaultAccountId,
           let resolved = organization ?? email {
            label = resolved
        }
        return ProviderAccount(
            accountId: config.accountId,
            providerId: id,
            label: label,
            email: email,
            organization: organization
        )
    }

    private func primaryProbe(for config: ProviderAccountConfig) -> any UsageProbe {
        guard usesAccountSpecificCLI(config) else { return primaryProbe() }
        if let existing = accountProbes[config.accountId] {
            return existing
        }
        let probe = cliProbeFactory(config)
        accountProbes[config.accountId] = probe
        return probe
    }

    private func usesAccountSpecificCLI(_ config: ProviderAccountConfig) -> Bool {
        claudeConfigDirectoryPath(for: config) != nil
    }

    private func claudeConfigDirectoryPath(for config: ProviderAccountConfig) -> String? {
        let path = config.probeConfig[ClaudeAccountProbeConfig.claudeConfigDir]
            ?? config.probeConfig[ClaudeAccountProbeConfig.claudeConfigDirEnv]
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPath, !trimmedPath.isEmpty else {
            return nil
        }
        return trimmedPath
    }

    private func uniqueAccountId(seed: String) -> String {
        let base = sanitizedAccountId(from: seed)
        let existing = Set(accountConfigs.map(\.accountId))
        guard existing.contains(base) else { return base }

        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private func sanitizedAccountId(from seed: String) -> String {
        let raw = seed
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let slug = String(raw)
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "account" : slug
    }

    /// Attaches daily usage report to snapshot if analyzer is available.
    private func attachDailyReport(to snapshot: UsageSnapshot) async -> UsageSnapshot {
        guard let analyzer = dailyUsageAnalyzer,
              let report = try? await analyzer.analyzeToday(),
              !report.today.isEmpty || !report.previous.isEmpty else {
            return snapshot
        }
        return UsageSnapshot(
            providerId: snapshot.providerId,
            quotas: snapshot.quotas,
            capturedAt: snapshot.capturedAt,
            accountEmail: snapshot.accountEmail,
            accountOrganization: snapshot.accountOrganization,
            loginMethod: snapshot.loginMethod,
            budgetWeight: snapshot.budgetWeight,
            accountTier: snapshot.accountTier,
            costUsage: snapshot.costUsage,
            bedrockUsage: snapshot.bedrockUsage,
            dailyUsageReport: report
        )
    }

    private func primaryProbe() -> any UsageProbe {
        switch probeMode {
        case .cli:
            return cliProbe
        case .api:
            return apiProbe ?? cliProbe
        }
    }

    private var cliFallbackEnabled: Bool {
        (settingsRepository as? ClaudeSettingsRepository)?
            .claudeCliFallbackEnabled() ?? true
    }

    private func fallbackProbe() async -> (any UsageProbe)? {
        switch probeMode {
        case .cli:
            guard let apiProbe, await apiProbe.isAvailable() else {
                return nil
            }
            return apiProbe
        case .api:
            guard cliFallbackEnabled else { return nil }
            return await cliProbe.isAvailable() ? cliProbe : nil
        }
    }

    // MARK: - Guest Pass

    /// Fetches the current guest pass information.
    /// Sets isFetchingPasses during fetch and captures any errors.
    @discardableResult
    public func fetchPasses() async throws -> ClaudePass {
        guard let passProbe else {
            throw PassError.probeNotConfigured
        }

        isFetchingPasses = true
        defer { isFetchingPasses = false }

        do {
            let pass = try await passProbe.probe()
            guestPass = pass
            lastError = nil
            return pass
        } catch {
            lastError = error
            throw error
        }
    }

    /// Whether guest passes feature is available
    public var supportsGuestPasses: Bool {
        passProbe != nil
    }

    /// Whether API mode is available (API probe was provided)
    public var supportsApiMode: Bool {
        apiProbe != nil
    }
}

// MARK: - Pass Error

public enum PassError: Error, LocalizedError {
    case probeNotConfigured

    public var errorDescription: String? {
        switch self {
        case .probeNotConfigured:
            return "Guest pass probe is not configured"
        }
    }
}
