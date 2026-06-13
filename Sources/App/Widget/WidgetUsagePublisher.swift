import Foundation
import WidgetKit
import Domain
import WidgetShared

/// Mirrors the latest Claude account usage into the shared App Group container
/// and reloads the widget timeline. Called after each refresh so the desktop
/// widget tracks the same data the menu shows.
@MainActor
enum WidgetUsagePublisher {
    // The token estimate needs the daily JSONL scan, which only runs on
    // interactive refreshes (background ticks skip it to stay cheap). Cache the
    // last computed value so background refreshes don't blank it out — it
    // refreshes whenever the user opens the menu.
    private static var lastEstimatedDailyTokens: Int?
    private static var lastEstimatedWeeklyTokens: Int?

    static func publish(from monitor: QuotaMonitor, now: Date = Date()) {
        guard let provider = monitor.provider(for: "claude") as? (any MultiAccountProvider) else {
            return
        }
        let activeId = provider.activeAccount.accountId
        // Resolve each quota's percentage for the app's display mode (remaining
        // vs used) here, so the sandboxed widget — which can't read settings —
        // just renders the number it's given.
        let mode = AppSettings.shared.usageDisplayMode
        let accounts: [WidgetAccountUsage] = provider.accounts.map { account in
            let snapshot = provider.accountSnapshots[account.accountId]
            let quotas: [WidgetQuota] = (snapshot?.quotas ?? [])
                .filter { quota in
                    // Drop model-specific quotas (e.g. Sonnet) — the widget shows
                    // just Session + Weekly to stay uncluttered.
                    if case .modelSpecific = quota.quotaType { return false }
                    return true
                }
                .map { quota in
                WidgetQuota(
                    label: quota.quotaType.displayName,
                    percentRemaining: quota.percentRemaining,
                    displayPercent: quota.displayPercent(mode: mode),
                    status: widgetStatus(quota.status)
                )
            }
            return WidgetAccountUsage(
                id: account.accountId,
                label: account.displayName,
                subtitle: account.email ?? account.organization,
                isActive: account.accountId == activeId,
                quotas: quotas
            )
        }
        let modeLabel = mode == .used ? "Used" : "Remaining"
        // Token pace projection is machine-wide; it rides the active account's
        // daily-usage report (the only snapshot the report is attached to).
        if let estimate = provider.accountSnapshots[activeId]?.dailyUsageReport?.tokenEstimate {
            lastEstimatedDailyTokens = estimate.projectedDailyTokens
            lastEstimatedWeeklyTokens = estimate.projectedWeeklyTokens
        }
        let payload = WidgetUsagePayload(
            accounts: accounts,
            updatedAt: now,
            displayModeLabel: modeLabel,
            estimatedDailyTokens: lastEstimatedDailyTokens,
            estimatedWeeklyTokens: lastEstimatedWeeklyTokens
        )
        if let data = payload.encoded() {
            WidgetUsageServer.shared.update(data)
        }
        WidgetCenter.shared.reloadAllTimelines()
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
