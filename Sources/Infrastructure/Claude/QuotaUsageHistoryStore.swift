import Foundation
import Domain

/// Persists a short rolling history of per-account, per-quota utilization-%
/// samples so the widget can project "where you'll land at reset" from the
/// recent pace (rate of % climb), without any token data.
///
/// Samples are taken on each refresh; rates are read over lookback windows that
/// stay inside the quota's own period (so they never straddle a reset).
public final class QuotaUsageHistoryStore: @unchecked Sendable {
    struct Sample: Codable, Equatable {
        let t: Date
        let pct: Double   // percentUsed at time t
    }

    private let fileURL: URL
    private let maxAge: TimeInterval
    private let queue = DispatchQueue(label: "com.tddworks.claudebar.quotahistory")
    private var byKey: [String: [Sample]] = [:]
    private var loaded = false

    public init(fileURL: URL? = nil, maxAge: TimeInterval = 25 * 3600) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("ClaudeBar", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("quota-history.json")
        }
        self.maxAge = maxAge
    }

    private static func key(_ accountId: String, _ quotaKey: String) -> String { "\(accountId)|\(quotaKey)" }

    /// Runs on `queue`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        byKey = (try? decoder.decode([String: [Sample]].self, from: data)) ?? [:]
    }

    /// Runs on `queue`.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(byKey) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Records a sample and prunes anything older than `maxAge`, then persists.
    public func record(accountId: String, quotaKey: String, percentUsed: Double, at now: Date) {
        queue.sync {
            loadIfNeeded()
            let key = Self.key(accountId, quotaKey)
            var samples = byKey[key] ?? []
            samples.append(Sample(t: now, pct: percentUsed))
            let cutoff = now.addingTimeInterval(-maxAge)
            samples.removeAll { $0.t < cutoff }
            byKey[key] = samples
            persist()
        }
    }

    /// The % climb per hour over the last `lookback` for a quota, or nil when
    /// there isn't an old-enough sample or the quota reset within the window
    /// (usage dropped).
    public func ratePerHour(accountId: String, quotaKey: String, lookback: TimeInterval, now: Date) -> Double? {
        queue.sync {
            loadIfNeeded()
            return Self.ratePerHour(samples: byKey[Self.key(accountId, quotaKey)] ?? [], now: now, lookback: lookback)
        }
    }

    /// Pure rate computation: rate = (latest% − past%) ÷ hours-between, where
    /// `past` is the newest sample at/just before `now − lookback`. Returns nil
    /// if coverage is too thin or the usage dropped (a reset).
    static func ratePerHour(samples: [Sample], now: Date, lookback: TimeInterval) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let latest = sorted.last else { return nil }
        let target = now.addingTimeInterval(-lookback)
        // Newest sample at or before the lookback target.
        guard let past = sorted.last(where: { $0.t <= target }) else { return nil }
        let hours = latest.t.timeIntervalSince(past.t) / 3600
        guard hours > 0 else { return nil }
        // Require at least half the window covered, to avoid wild extrapolation.
        guard latest.t.timeIntervalSince(past.t) >= lookback * 0.5 else { return nil }
        let delta = latest.pct - past.pct
        guard delta >= 0 else { return nil }   // usage dropped → quota reset; skip
        return delta / hours
    }
}
