import Testing
import Foundation
@testable import Infrastructure

@Suite("Quota usage history rate")
struct QuotaUsageHistoryStoreTests {
    private typealias Sample = QuotaUsageHistoryStore.Sample

    @Test
    func `rate per hour from samples over a lookback`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let samples = [
            Sample(t: now.addingTimeInterval(-3600), pct: 20),
            Sample(t: now.addingTimeInterval(-1800), pct: 25),
            Sample(t: now, pct: 30),
        ]
        // lookback 1h → past = -3600 (20%), latest = 30%, 1h apart → 10%/hr.
        #expect(QuotaUsageHistoryStore.ratePerHour(samples: samples, now: now, lookback: 3600) == 10)
    }

    @Test
    func `returns nil when the quota reset within the window (usage dropped)`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let samples = [
            Sample(t: now.addingTimeInterval(-3600), pct: 80),
            Sample(t: now, pct: 10),
        ]
        #expect(QuotaUsageHistoryStore.ratePerHour(samples: samples, now: now, lookback: 3600) == nil)
    }

    @Test
    func `returns nil without an old-enough sample`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let samples = [
            Sample(t: now.addingTimeInterval(-300), pct: 28),
            Sample(t: now, pct: 30),
        ]
        // Only ~5 min of history but asking for a 1h lookback → not enough coverage.
        #expect(QuotaUsageHistoryStore.ratePerHour(samples: samples, now: now, lookback: 3600) == nil)
    }
}
