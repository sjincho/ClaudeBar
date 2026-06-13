import Foundation

/// Status of a single quota, mirrored from the domain `QuotaStatus` but kept
/// dependency-free so both the app and the widget extension can share it.
public enum WidgetQuotaStatus: String, Codable, Sendable {
    case healthy
    case warning
    case critical
    case depleted
}

/// One quota gauge for an account (e.g. Session, Weekly, Sonnet).
public struct WidgetQuota: Codable, Sendable, Hashable {
    public let label: String
    public let percentRemaining: Double
    public let status: WidgetQuotaStatus

    public init(label: String, percentRemaining: Double, status: WidgetQuotaStatus) {
        self.label = label
        self.percentRemaining = percentRemaining
        self.status = status
    }
}

/// A single account's usage as shown in the widget.
public struct WidgetAccountUsage: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let label: String
    public let subtitle: String?
    public let isActive: Bool
    public let quotas: [WidgetQuota]

    public init(
        id: String,
        label: String,
        subtitle: String?,
        isActive: Bool,
        quotas: [WidgetQuota]
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.isActive = isActive
        self.quotas = quotas
    }

    /// The lowest remaining quota — the binding constraint for a compact view.
    public var lowestQuota: WidgetQuota? {
        quotas.min { $0.percentRemaining < $1.percentRemaining }
    }
}

/// The full payload the app serves over loopback HTTP and the widget fetches on
/// its timeline.
public struct WidgetUsagePayload: Codable, Sendable {
    public let accounts: [WidgetAccountUsage]
    public let updatedAt: Date

    public init(accounts: [WidgetAccountUsage], updatedAt: Date) {
        self.accounts = accounts
        self.updatedAt = updatedAt
    }

    /// Encodes for transport (ISO-8601 dates). App and widget share this so the
    /// formats can't drift.
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
