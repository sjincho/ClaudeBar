import Foundation

/// A short-window projection of token consumption, used to estimate how much a
/// day / week will total at the current pace.
///
/// - `projectedDailyTokens`  = last hour's tokens × 24
/// - `projectedWeeklyTokens` = last day's tokens × 7
public struct TokenUsageEstimate: Sendable, Equatable {
    /// Tokens consumed in the last hour.
    public let lastHourTokens: Int
    /// Tokens consumed in the last 24 hours.
    public let lastDayTokens: Int

    public init(lastHourTokens: Int, lastDayTokens: Int) {
        self.lastHourTokens = max(0, lastHourTokens)
        self.lastDayTokens = max(0, lastDayTokens)
    }

    /// Projected tokens for a full day at the last hour's rate.
    public var projectedDailyTokens: Int { lastHourTokens * 24 }

    /// Projected tokens for a full week at the last day's rate.
    public var projectedWeeklyTokens: Int { lastDayTokens * 7 }
}
