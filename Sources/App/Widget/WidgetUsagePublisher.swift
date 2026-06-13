import Foundation
import WidgetKit
import Domain
import Infrastructure
import WidgetShared

/// Builds the widget payload after each refresh: records per-account quota
/// %-history, projects each quota's recent/sustained pace, weights the combined
/// aggregate by each account's budget, sorts the rest by least used, and serves
/// it over loopback. Runs on background refreshes too, so no app-open is needed.
@MainActor
enum WidgetUsagePublisher {
    private static let history = QuotaUsageHistoryStore()

    private enum Kind {
        case session, weekly
        var quotaType: QuotaType { self == .session ? .session : .weekly }
        /// Lookback windows for the recent / sustained pace, kept inside the
        /// quota's own period so they never straddle a reset.
        var windows: (recent: TimeInterval, sustained: TimeInterval) {
            self == .session ? (900, 3600) : (3600, 86400)  // session 15m/1h, weekly 1h/1d
        }
    }

    static func publish(from monitor: QuotaMonitor, now: Date = Date()) {
        guard let provider = monitor.provider(for: "claude") as? (any MultiAccountProvider) else { return }
        let mode = AppSettings.shared.usageDisplayMode
        let modeLabel = mode == .used ? "Used" : "Remaining"
        let activeId = provider.activeAccount.accountId

        // Record a history sample for each account/quota this cycle.
        for account in provider.accounts {
            guard let snapshot = provider.accountSnapshots[account.accountId] else { continue }
            for kind in [Kind.session, .weekly] {
                if let quota = snapshot.quota(for: kind.quotaType) {
                    history.record(
                        accountId: account.accountId,
                        quotaKey: kind.quotaType.quotaKey,
                        percentUsed: quota.percentUsed,
                        at: now
                    )
                }
            }
        }

        func usage(_ account: ProviderAccount) -> WidgetAccountUsage {
            let snapshot = provider.accountSnapshots[account.accountId]
            return WidgetAccountUsage(
                id: account.accountId,
                label: account.label,
                subtitle: account.email ?? account.organization,
                isActive: account.accountId == activeId,
                session: snapshot.flatMap { widgetQuota($0, .session, accountId: account.accountId, mode: mode, now: now) },
                weekly: snapshot.flatMap { widgetQuota($0, .weekly, accountId: account.accountId, mode: mode, now: now) }
            )
        }

        let active = provider.accounts.first { $0.accountId == activeId }.map(usage)
        let others = provider.accounts
            .filter { $0.accountId != activeId }
            .sorted { lhs, rhs in
                let ls = usedPercent(provider, lhs.accountId, .session)
                let rs = usedPercent(provider, rhs.accountId, .session)
                if ls != rs { return ls < rs }
                return usedPercent(provider, lhs.accountId, .weekly) < usedPercent(provider, rhs.accountId, .weekly)
            }
            .map(usage)

        let payload = WidgetUsagePayload(
            combinedSession: combined(provider, .session, mode: mode, now: now),
            combinedWeekly: combined(provider, .weekly, mode: mode, now: now),
            activeAccount: active,
            otherAccounts: others,
            updatedAt: now,
            displayModeLabel: modeLabel
        )
        if let data = payload.encoded() {
            WidgetUsageServer.shared.update(data)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Per-quota

    private static func widgetQuota(_ snapshot: UsageSnapshot, _ kind: Kind, accountId: String, mode: UsageDisplayMode, now: Date) -> WidgetQuota? {
        guard let quota = snapshot.quota(for: kind.quotaType) else { return nil }
        return WidgetQuota(
            label: kind.quotaType.displayName,
            displayPercent: quota.displayPercent(mode: mode),
            status: widgetStatus(quota.status),
            recent: projection(quota, accountId: accountId, kind: kind, lookback: kind.windows.recent, mode: mode, now: now),
            sustained: projection(quota, accountId: accountId, kind: kind, lookback: kind.windows.sustained, mode: mode, now: now)
        )
    }

    private static func projection(_ quota: UsageQuota, accountId: String, kind: Kind, lookback: TimeInterval, mode: UsageDisplayMode, now: Date) -> WidgetProjection? {
        guard let projectedUsed = projectedUsedPercent(quota, accountId: accountId, kind: kind, lookback: lookback, now: now) else { return nil }
        return WidgetProjection(value: displayValue(projectedUsed, mode: mode), status: statusForUsed(projectedUsed))
    }

    /// Projected `percentUsed` at reset: current used + recent %-rate × hours left.
    private static func projectedUsedPercent(_ quota: UsageQuota, accountId: String, kind: Kind, lookback: TimeInterval, now: Date) -> Double? {
        guard let timeUntilReset = quota.timeUntilReset,
              let ratePerHour = history.ratePerHour(accountId: accountId, quotaKey: kind.quotaType.quotaKey, lookback: lookback, now: now)
        else { return nil }
        return quota.percentUsed + ratePerHour * (timeUntilReset / 3600)
    }

    // MARK: - Combined (budget-weighted)

    private static func combined(_ provider: any MultiAccountProvider, _ kind: Kind, mode: UsageDisplayMode, now: Date) -> WidgetQuota? {
        var current: [(value: Double, weight: Double)] = []
        var recent: [(value: Double, weight: Double)] = []
        var sustained: [(value: Double, weight: Double)] = []
        for account in provider.accounts {
            guard let snapshot = provider.accountSnapshots[account.accountId],
                  let quota = snapshot.quota(for: kind.quotaType) else { continue }
            let weight = snapshot.budgetWeight ?? 1
            current.append((quota.percentUsed, weight))
            // An account with a snapshot but no computable rate (idle, or too
            // little history yet) is treated as flat — it lands at its current
            // usage. Excluding it instead would bias the weighted combined toward
            // whichever account happens to be moving (e.g. a busy Personal makes
            // the combined recent equal Personal's, ignoring the idle orgs).
            let r = projectedUsedPercent(quota, accountId: account.accountId, kind: kind, lookback: kind.windows.recent, now: now)
            recent.append((r ?? quota.percentUsed, weight))
            let s = projectedUsedPercent(quota, accountId: account.accountId, kind: kind, lookback: kind.windows.sustained, now: now)
            sustained.append((s ?? quota.percentUsed, weight))
        }
        guard let currentUsed = weightedAverage(current) else { return nil }
        func proj(_ pairs: [(value: Double, weight: Double)]) -> WidgetProjection? {
            guard let used = weightedAverage(pairs) else { return nil }
            return WidgetProjection(value: displayValue(used, mode: mode), status: statusForUsed(used))
        }
        return WidgetQuota(
            label: kind.quotaType.displayName,
            displayPercent: displayValue(currentUsed, mode: mode),
            status: statusForUsed(currentUsed),
            recent: proj(recent),
            sustained: proj(sustained)
        )
    }

    // MARK: - Helpers

    private static func usedPercent(_ provider: any MultiAccountProvider, _ accountId: String, _ kind: Kind) -> Double {
        guard let snapshot = provider.accountSnapshots[accountId],
              let quota = snapshot.quota(for: kind.quotaType) else { return 999 }
        return quota.percentUsed
    }

    private static func weightedAverage(_ pairs: [(value: Double, weight: Double)]) -> Double? {
        let totalWeight = pairs.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        return pairs.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
    }

    private static func displayValue(_ used: Double, mode: UsageDisplayMode) -> Double {
        mode == .used ? used : 100 - used
    }

    private static func statusForUsed(_ used: Double) -> WidgetQuotaStatus {
        let remaining = 100 - used
        if remaining <= 0 { return .depleted }
        if remaining < 20 { return .critical }
        if remaining < 50 { return .warning }
        return .healthy
    }

    private static func widgetStatus(_ status: QuotaStatus) -> WidgetQuotaStatus {
        switch status {
        case .healthy: return .healthy
        case .warning: return .warning
        case .critical: return .critical
        case .depleted: return .depleted
        }
    }
}
