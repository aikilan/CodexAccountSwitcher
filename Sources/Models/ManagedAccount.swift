import Foundation

struct SubscriptionDetails: Codable, Hashable, Sendable {
    var allowed: Bool? = nil
    var limitReached: Bool? = nil
}

extension SubscriptionDetails {
    var hasAnyValue: Bool {
        allowed != nil
            || limitReached != nil
    }

    func merged(over existing: SubscriptionDetails?) -> SubscriptionDetails {
        SubscriptionDetails(
            allowed: allowed ?? existing?.allowed,
            limitReached: limitReached ?? existing?.limitReached
        )
    }

    var usageStatusText: String {
        var parts = [String]()
        if allowed == false {
            parts.append("不可用")
        }
        if limitReached == true {
            parts.append("额度受限")
        }
        if parts.isEmpty, allowed == true {
            parts.append("可用")
        }
        return parts.isEmpty ? "未知" : parts.joined(separator: " / ")
    }

    var availabilityText: String {
        if let allowed {
            return allowed ? "可用" : "不可用"
        }
        return "未知"
    }

    var limitStatusText: String {
        switch limitReached {
        case .some(true):
            return "已触达"
        case .some(false):
            return "未触达"
        case .none:
            return "未知"
        }
    }
}

struct ManagedAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var codexAccountID: String
    var displayName: String
    var email: String?
    var authMode: CodexAuthMode
    var createdAt: Date
    var lastUsedAt: Date?
    var lastQuotaSnapshotAt: Date?
    var lastRefreshAt: Date?
    var planType: String?
    var subscriptionDetails: SubscriptionDetails? = nil
    var lastStatusCheckAt: Date?
    var lastStatusMessage: String?
    var lastStatusLevel: SwitchLogLevel?
    var isActive: Bool
}

enum SwitchLogLevel: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

struct SwitchLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: SwitchLogLevel
    var message: String
}

struct AppDatabase: Codable, Sendable {
    var version: Int
    var accounts: [ManagedAccount]
    var quotaSnapshots: [String: QuotaSnapshot]
    var switchLogs: [SwitchLogEntry]
    var activeAccountID: UUID?

    static let currentVersion = 1

    static let empty = AppDatabase(
        version: currentVersion,
        accounts: [],
        quotaSnapshots: [:],
        switchLogs: [],
        activeAccountID: nil
    )

    func account(id: UUID?) -> ManagedAccount? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    func snapshot(for accountID: UUID) -> QuotaSnapshot? {
        quotaSnapshots[accountID.uuidString]
    }

    mutating func setActiveAccount(_ id: UUID?) {
        activeAccountID = id
        for index in accounts.indices {
            accounts[index].isActive = accounts[index].id == id
            if accounts[index].isActive {
                accounts[index].lastUsedAt = Date()
            }
        }
    }

    mutating func upsert(account: ManagedAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id || $0.codexAccountID == account.codexAccountID }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    mutating func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        quotaSnapshots.removeValue(forKey: id.uuidString)
        if activeAccountID == id {
            activeAccountID = nil
        }
    }

    mutating func updateSnapshot(_ snapshot: QuotaSnapshot, for accountID: UUID) {
        quotaSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastQuotaSnapshotAt = snapshot.capturedAt
    }

    mutating func appendLog(level: SwitchLogLevel, message: String) {
        switchLogs.insert(
            SwitchLogEntry(id: UUID(), timestamp: Date(), level: level, message: message),
            at: 0
        )
        if switchLogs.count > 200 {
            switchLogs = Array(switchLogs.prefix(200))
        }
    }
}
