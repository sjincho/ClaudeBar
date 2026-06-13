import Foundation
import Mockable

/// Resolves account identity from external sources (e.g., config files).
@Mockable
public protocol AccountInfoResolving: Sendable {
    func resolve() -> AccountInfo?
}

/// A no-op resolver that always returns `nil`. Useful as a default in tests.
public struct NoOpAccountInfoResolver: AccountInfoResolving {
    public init() {}
    public func resolve() -> AccountInfo? { nil }
}

/// Value object representing account identity information for an AI provider.
/// Encapsulates email, organization, and login method with derived display logic.
public struct AccountInfo: Sendable, Equatable {
    public let email: String?
    public let organization: String?
    public let loginMethod: String?
    /// Relative budget weight from the account's rate-limit tier (e.g. Max 20x → 20,
    /// Team seat 5x → 5). Used to weight cross-account aggregates so a big-budget
    /// account isn't averaged as if it were the same size as a small one. nil if unknown.
    public let budgetWeight: Double?

    public init(
        email: String? = nil,
        organization: String? = nil,
        loginMethod: String? = nil,
        budgetWeight: Double? = nil
    ) {
        self.email = email
        self.organization = organization
        self.loginMethod = loginMethod
        self.budgetWeight = budgetWeight
    }

    /// The best available name for display: email first, then organization.
    public var displayName: String? {
        email ?? organization
    }

    /// Whether this account info has no useful data.
    public var isEmpty: Bool {
        email == nil && organization == nil
    }

    /// The uppercased first character of the display name, for avatar circles.
    public var initialLetter: String? {
        displayName?.first.map { String($0).uppercased() }
    }
}
