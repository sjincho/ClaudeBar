import Foundation

/// Status of a single quota, mirrored from the domain `QuotaStatus` but kept
/// dependency-free so both the app and the widget extension can share it.
public enum WidgetQuotaStatus: String, Codable, Sendable {
    case healthy
    case warning
    case critical
    case depleted
}

/// A pace projection ("where you'll land at reset") for a quota.
public struct WidgetProjection: Codable, Sendable, Equatable {
    /// Projected percent in the active display mode's terms (may exceed 100, used mode).
    public let value: Double
    /// Severity of the projected value (so an over-budget projection reads red).
    public let status: WidgetQuotaStatus

    public init(value: Double, status: WidgetQuotaStatus) {
        self.value = value
        self.status = status
    }
}

/// One quota gauge (Session or Weekly) with current usage and up to two pace
/// projections (recent = shorter window, sustained = longer window).
public struct WidgetQuota: Codable, Sendable, Equatable {
    public let label: String
    /// Current value in the active display mode's terms (the bar fill + number).
    public let displayPercent: Double
    public let status: WidgetQuotaStatus
    public let recent: WidgetProjection?
    public let sustained: WidgetProjection?

    public init(
        label: String,
        displayPercent: Double,
        status: WidgetQuotaStatus,
        recent: WidgetProjection? = nil,
        sustained: WidgetProjection? = nil
    ) {
        self.label = label
        self.displayPercent = displayPercent
        self.status = status
        self.recent = recent
        self.sustained = sustained
    }
}

/// A single account's Session + Weekly usage.
public struct WidgetAccountUsage: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let subtitle: String?
    public let isActive: Bool
    public let session: WidgetQuota?
    public let weekly: WidgetQuota?

    public init(id: String, label: String, subtitle: String?, isActive: Bool, session: WidgetQuota?, weekly: WidgetQuota?) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.isActive = isActive
        self.session = session
        self.weekly = weekly
    }
}

/// The full payload the app serves over loopback and the widget fetches.
public struct WidgetUsagePayload: Codable, Sendable {
    /// Budget-weighted aggregate across all accounts.
    public let combinedSession: WidgetQuota?
    public let combinedWeekly: WidgetQuota?
    /// The active account (the one bare `claude` uses), shown in detail.
    public let activeAccount: WidgetAccountUsage?
    /// Remaining accounts, pre-sorted by least used (Session first, then Weekly).
    public let otherAccounts: [WidgetAccountUsage]
    public let updatedAt: Date
    /// "Remaining" or "Used" — mirrors the app's usage display mode.
    public let displayModeLabel: String

    public init(
        combinedSession: WidgetQuota?,
        combinedWeekly: WidgetQuota?,
        activeAccount: WidgetAccountUsage?,
        otherAccounts: [WidgetAccountUsage],
        updatedAt: Date,
        displayModeLabel: String = "Remaining"
    ) {
        self.combinedSession = combinedSession
        self.combinedWeekly = combinedWeekly
        self.activeAccount = activeAccount
        self.otherAccounts = otherAccounts
        self.updatedAt = updatedAt
        self.displayModeLabel = displayModeLabel
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data) -> WidgetUsagePayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetUsagePayload.self, from: data)
    }
}
