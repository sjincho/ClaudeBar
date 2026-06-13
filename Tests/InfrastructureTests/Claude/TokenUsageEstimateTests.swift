import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("Token usage estimate")
struct TokenUsageEstimateTests {
    private func record(minutesAgo: Double, now: Date, input: Int, output: Int) -> TokenUsageRecord {
        TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude",
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            timestamp: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    @Test
    func `projects day from last hour and week from last day`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            record(minutesAgo: 30, now: now, input: 100, output: 50),       // in last hour & day
            record(minutesAgo: 120, now: now, input: 200, output: 100),     // in last day only
            record(minutesAgo: 60 * 30, now: now, input: 9999, output: 1),  // 30h ago — excluded
        ]

        let estimate = ClaudeDailyUsageAnalyzer.tokenEstimate(from: records, now: now)

        #expect(estimate.lastHourTokens == 150)            // 100 + 50
        #expect(estimate.lastDayTokens == 450)             // 150 + (200 + 100)
        #expect(estimate.projectedDailyTokens == 150 * 24) // last hour × 24
        #expect(estimate.projectedWeeklyTokens == 450 * 7) // last day × 7
    }

    @Test
    func `excludes future-dated records`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            record(minutesAgo: -10, now: now, input: 500, output: 500), // future — excluded
            record(minutesAgo: 10, now: now, input: 10, output: 5),
        ]

        let estimate = ClaudeDailyUsageAnalyzer.tokenEstimate(from: records, now: now)

        #expect(estimate.lastHourTokens == 15)
        #expect(estimate.lastDayTokens == 15)
    }
}
