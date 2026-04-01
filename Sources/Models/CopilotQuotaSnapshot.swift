import Foundation

struct CopilotQuotaBucketSnapshot: Codable, Hashable, Sendable {
    var entitlementRequests: Double
    var usedRequests: Double
    var remainingPercentage: Double
    var overage: Double
    var overageAllowedWithExhaustedQuota: Bool
    var resetDate: Date?

    var remainingPercentageText: String {
        "\(Int(remainingPercentage.rounded()))%"
    }

    var usageSummary: String {
        "\(formatted(usedRequests)) / \(formatted(entitlementRequests))"
    }

    private func formatted(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}

struct CopilotQuotaSnapshot: Codable, Hashable, Sendable {
    var chat: CopilotQuotaBucketSnapshot?
    var completions: CopilotQuotaBucketSnapshot?
    var premiumInteractions: CopilotQuotaBucketSnapshot?
    var capturedAt: Date

    subscript(category: String) -> CopilotQuotaBucketSnapshot? {
        switch category {
        case "chat":
            return chat
        case "completions":
            return completions
        case "premium_interactions":
            return premiumInteractions
        default:
            return nil
        }
    }
}
