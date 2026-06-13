import Foundation
import Domain

/// Thread-safe TTL cache for a successful `UsageSnapshot`. Quota numbers
/// move on multi-hour timescales (5h session, 7d weekly), so returning the
/// most recent successful snapshot for a short window costs nothing in
/// freshness and dramatically reduces requests against the rate-limited
/// usage endpoint.
private final class SnapshotCache: @unchecked Sendable {
    private var cached: UsageSnapshot?
    private var cachedAt: Date?
    private let ttl: TimeInterval
    private let lock = NSLock()

    /// Creates a snapshot cache with the given maximum lifetime for a cached
    /// entry. A `ttl` of `0` effectively disables caching (every `get` misses).
    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// Returns the cached snapshot if it was stored within `ttl` of `now`;
    /// otherwise evicts the stale entry and returns `nil` so the caller knows
    /// to re-fetch.
    func get(now: Date = Date()) -> UsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached, let cachedAt else { return nil }
        // Inclusive comparison so `ttl == 0` is always immediately stale.
        // With `>`, a 0-TTL cache would still hit within the same instant.
        if now.timeIntervalSince(cachedAt) >= ttl {
            self.cached = nil
            self.cachedAt = nil
            return nil
        }
        return cached
    }

    /// Stores a fresh snapshot and stamps it with `now`, replacing any prior
    /// entry. The next `get` call within `ttl` of `now` will hit this entry.
    func set(_ snapshot: UsageSnapshot, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        self.cached = snapshot
        self.cachedAt = now
    }
}

/// Thread-safe holder for an active rate-limit window. When the API returns
/// HTTP 429, the probe stores `retryAt` here so subsequent calls short-circuit
/// without re-hitting the endpoint until the window has elapsed.
private final class RateLimitState: @unchecked Sendable {
    private var retryAt: Date?
    private let lock = NSLock()

    /// Returns `retryAt` only if it is still in the future; otherwise clears
    /// it and returns nil so the next probe is allowed through.
    func activeRetryAt(now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let retryAt else { return nil }
        if retryAt <= now {
            self.retryAt = nil
            return nil
        }
        return retryAt
    }

    /// Records a new rate-limit window expiring at `retryAt`. Subsequent
    /// `activeRetryAt` calls return this value until it falls into the past.
    func set(retryAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.retryAt = retryAt
    }
}

/// Thread-safe in-memory cache for Claude OAuth credentials with TTL.
/// Avoids repeated Keychain/CLI lookups on every probe cycle while ensuring
/// external credential changes (e.g. CLI re-login) are picked up.
private final class CredentialCache: @unchecked Sendable {
    private var cached: ClaudeCredentialResult?
    private var cachedAt: Date?
    private let lock = NSLock()

    /// Cache TTL: 5 minutes. Forces reload from file to detect external changes.
    /// 缓存生存时间：5分钟，确保能感知 CLI 等外部凭证变更
    static let ttl: TimeInterval = 5 * 60

    func get() -> ClaudeCredentialResult? {
        lock.lock()
        defer { lock.unlock() }
        // Invalidate if TTL expired
        // TTL 过期时自动失效，下次从文件重新加载
        if let cachedAt, Date().timeIntervalSince(cachedAt) > Self.ttl {
            cached = nil
            self.cachedAt = nil
            return nil
        }
        return cached
    }

    func set(_ credentials: ClaudeCredentialResult) {
        lock.lock()
        defer { lock.unlock() }
        cached = credentials
        cachedAt = Date()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        cachedAt = nil
    }
}

/// Claude API-based usage probe that fetches quota data directly from Anthropic's OAuth API.
///
/// This probe uses the user's OAuth credentials (from `~/.claude/.credentials.json` or Keychain)
/// to call the usage API endpoint. It automatically refreshes expired tokens.
///
/// Usage URL: `https://api.anthropic.com/api/oauth/usage`
/// Token Refresh URL: `https://platform.claude.com/v1/oauth/token`
public struct ClaudeAPIUsageProbe: UsageProbe, @unchecked Sendable {
    private let credentialLoader: ClaudeCredentialLoader
    private let networkClient: any NetworkClient
    private let timeout: TimeInterval
    private let cache = CredentialCache()
    private let rateLimit = RateLimitState()
    private let snapshotCache: SnapshotCache

    /// Fallback retry window applied when the API returns 429 without a
    /// usable `Retry-After` header. Five minutes is conservative enough to
    /// stop hammering a throttled endpoint while still picking back up
    /// reasonably quickly once the window opens.
    static let defaultRetryAfter: TimeInterval = 5 * 60

    /// Default TTL for the in-memory snapshot cache. Anthropic's
    /// /api/oauth/usage throttle has been observed handing out 1-hour
    /// Retry-After windows in response to even one call after a quiet
    /// period (see deferred memory + anthropics/claude-code#30930), so
    /// we err on the conservative side. 15 minutes drops the 60s monitor
    /// cadence to ~4 calls/hour — well under any reasonable threshold —
    /// while still keeping the displayed quotas fresh enough that a user
    /// glancing at the menu bar isn't looking at hour-old data.
    public static let defaultSnapshotCacheTTL: TimeInterval = 15 * 60

    // API endpoint (read-only usage probe; ClaudeBar never hits the OAuth token
    // endpoint — the `claude` CLI owns token refresh, see probe()).
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        credentialLoader: ClaudeCredentialLoader = ClaudeCredentialLoader(),
        networkClient: any NetworkClient = URLSession.shared,
        timeout: TimeInterval = 15,
        snapshotCacheTTL: TimeInterval = Self.defaultSnapshotCacheTTL
    ) {
        self.credentialLoader = credentialLoader
        self.networkClient = networkClient
        self.timeout = timeout
        self.snapshotCache = SnapshotCache(ttl: snapshotCacheTTL)
    }

    public func isAvailable() async -> Bool {
        if cache.get() != nil { return true }
        return credentialLoader.loadCredentials() != nil
    }

    public func probe() async throws -> UsageSnapshot {
        // Serve a fresh cached snapshot before doing anything else. This is
        // the dominant code path during normal monitor polling and means
        // we make ~1 actual HTTP call per cache TTL instead of one per
        // monitor tick — well under Anthropic's per-token throttle.
        if let cached = snapshotCache.get() {
            return cached
        }

        // Honor an active rate-limit window before doing any work so we stop
        // hammering the endpoint while Anthropic is throttling us.
        if let retryAt = rateLimit.activeRetryAt() {
            AppLog.probes.info("Claude API: Skipping probe — rate-limited until \(retryAt)")
            throw ProbeError.rateLimited(retryAt: retryAt)
        }

        // Check cache first, fall back to loading from file/keychain
        // Only update cache when loading from file (not from cache hit) to preserve TTL
        // 仅在从文件加载时更新缓存，避免滑动续期导致 TTL 永不过期
        let fromCache = cache.get()
        guard var credentials = fromCache ?? credentialLoader.loadCredentials() else {
            AppLog.probes.error("Claude API: No credentials found")
            throw ProbeError.authenticationRequired
        }
        if fromCache == nil {
            cache.set(credentials)
        }

        // Pure reader: ClaudeBar never refreshes or writes the OAuth token.
        // Rotating it would require persisting the new token back to the Keychain,
        // and any write to that `security`-CLI-created item resets its access
        // gating — which breaks the `claude` CLI's own credential reads (it reads
        // via `security find-generic-password`). The CLI owns refreshing; we only
        // ever READ. If our token looks stale, we re-read the latest one the CLI
        // wrote to disk/Keychain, but we never call the refresh endpoint ourselves.
        if credentialLoader.needsRefresh(credentials.oauth),
           let fresh = credentialLoader.loadCredentials(),
           fresh.oauth != credentials.oauth {
            credentials = fresh
            cache.set(credentials)
        }

        // Fetch usage data
        let usageData: UsageResponse
        do {
            usageData = try await fetchUsage(accessToken: credentials.oauth.accessToken)
        } catch let error as ProbeError where error == .authenticationRequired {
            // 401/403 — the token is expired/invalid. We do NOT refresh (that would
            // write the credential). Re-read once in case the CLI just refreshed it;
            // otherwise surface so the UI shows "re-auth via the CLI".
            cache.clear()
            if let fresh = credentialLoader.loadCredentials(),
               fresh.oauth != credentials.oauth,
               let retry = try? await fetchUsage(accessToken: fresh.oauth.accessToken) {
                cache.set(fresh)
                credentials = fresh
                usageData = retry
            } else {
                AppLog.probes.info("Claude API: token expired; ClaudeBar is read-only — run `claude` to refresh")
                throw ProbeError.sessionExpired(hint: "Run `claude` in terminal to refresh the token.")
            }
        }

        let snapshot = parseUsageResponse(usageData, subscriptionType: credentials.oauth.subscriptionType)
        snapshotCache.set(snapshot)
        return snapshot
    }

    // MARK: - Usage Fetch

    private func fetchUsage(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        AppLog.probes.debug("Claude API: Fetching usage...")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkClient.request(request)
        } catch {
            AppLog.probes.error("Claude API: Network error: \(error.localizedDescription)")
            throw ProbeError.executionFailed("Network error: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        AppLog.probes.debug("Claude API: Response status \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProbeError.authenticationRequired
        case 429:
            let retryAfter = Self.parseRetryAfter(
                httpResponse.value(forHTTPHeaderField: "Retry-After")
            ) ?? Self.defaultRetryAfter
            let retryAt = Date().addingTimeInterval(retryAfter)
            rateLimit.set(retryAt: retryAt)
            AppLog.probes.warning("Claude API: Rate limited (HTTP 429), retrying after \(Int(retryAfter))s")
            throw ProbeError.rateLimited(retryAt: retryAt)
        default:
            AppLog.probes.error("Claude API: HTTP error \(httpResponse.statusCode)")
            throw ProbeError.executionFailed("HTTP error: \(httpResponse.statusCode)")
        }

        // Log raw response for debugging
        if let rawString = String(data: data, encoding: .utf8) {
            AppLog.probes.debug("Claude API: Raw response: \(rawString.prefix(500))")
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            AppLog.probes.error("Claude API: Failed to parse response: \(error.localizedDescription)")
            throw ProbeError.parseFailed("Failed to parse usage response: \(error.localizedDescription)")
        }
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ response: UsageResponse, subscriptionType: String?) -> UsageSnapshot {
        var quotas: [UsageQuota] = []

        // Parse 5-hour session quota
        if let fiveHour = response.fiveHour, let utilization = fiveHour.utilization {
            let percentRemaining = 100.0 - utilization
            let resetsAt = parseISODate(fiveHour.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: percentRemaining,
                quotaType: .session,
                providerId: "claude",
                resetsAt: resetsAt,
                resetText: formatResetText(resetsAt)
            ))
        }

        // Parse 7-day weekly quota
        if let sevenDay = response.sevenDay, let utilization = sevenDay.utilization {
            let percentRemaining = 100.0 - utilization
            let resetsAt = parseISODate(sevenDay.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: percentRemaining,
                quotaType: .weekly,
                providerId: "claude",
                resetsAt: resetsAt,
                resetText: formatResetText(resetsAt)
            ))
        }

        // Parse model-specific quotas
        if let sonnet = response.sevenDaySonnet, let utilization = sonnet.utilization {
            let percentRemaining = 100.0 - utilization
            let resetsAt = parseISODate(sonnet.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: percentRemaining,
                quotaType: .modelSpecific("sonnet"),
                providerId: "claude",
                resetsAt: resetsAt,
                resetText: formatResetText(resetsAt)
            ))
        }

        if let opus = response.sevenDayOpus, let utilization = opus.utilization {
            let percentRemaining = 100.0 - utilization
            let resetsAt = parseISODate(opus.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: percentRemaining,
                quotaType: .modelSpecific("opus"),
                providerId: "claude",
                resetsAt: resetsAt,
                resetText: formatResetText(resetsAt)
            ))
        }

        // Parse extra usage
        // API returns used_credits and monthly_limit in cents, convert to dollars
        var costUsage: CostUsage?
        if let extra = response.extraUsage, extra.isEnabled == true {
            if let used = extra.usedCredits {
                costUsage = CostUsage(
                    totalCost: Decimal(used) / 100,
                    budget: extra.monthlyLimit.map { Decimal($0) / 100 },
                    apiDuration: 0,
                    providerId: "claude",
                    capturedAt: Date(),
                    resetsAt: nil,
                    resetText: nil
                )
            }
        }

        // Determine account tier from subscription type
        let accountTier = parseAccountTier(subscriptionType)

        AppLog.probes.info("Claude API: Parsed \(quotas.count) quotas, tier=\(accountTier?.badgeText ?? "unknown")")

        return UsageSnapshot(
            providerId: "claude",
            quotas: quotas,
            capturedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            accountTier: accountTier,
            costUsage: costUsage
        )
    }

    /// Parses an HTTP `Retry-After` header value into a duration.
    /// Per RFC 7231 the value is either a non-negative integer of seconds, or
    /// an HTTP-date. Returns nil for missing, malformed, or past-dated values
    /// so the caller can apply its own fallback.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        // Reject 0 — the /api/oauth/usage endpoint has been observed returning
        // `Retry-After: 0` while continuing to 429, so treating 0 as "retry
        // immediately" lands us right back in a hammering loop. See
        // anthropics/claude-code#30930.
        if let seconds = TimeInterval(value), seconds > 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }

    private func parseISODate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private func formatResetText(_ date: Date?) -> String? {
        guard let date else { return nil }

        let now = Date()
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }

        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "Resets in \(minutes)m"
        } else {
            return "Resets soon"
        }
    }

    private func parseAccountTier(_ subscriptionType: String?) -> AccountTier? {
        guard let subscriptionType else { return nil }

        switch subscriptionType.lowercased() {
        case "claude_max", "max":
            return .claudeMax
        case "claude_pro", "pro":
            return .claudePro
        case "api", "claude_api":
            return .claudeApi
        default:
            return .custom(subscriptionType)
        }
    }
}

// MARK: - Response Models

private struct UsageResponse: Decodable {
    let fiveHour: UsageQuotaData?
    let sevenDay: UsageQuotaData?
    let sevenDaySonnet: UsageQuotaData?
    let sevenDayOpus: UsageQuotaData?
    let extraUsage: ExtraUsageData?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

private struct UsageQuotaData: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct ExtraUsageData: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }
}
