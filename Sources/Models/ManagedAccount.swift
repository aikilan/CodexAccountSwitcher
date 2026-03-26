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
            parts.append(L10n.tr("不可用"))
        }
        if limitReached == true {
            parts.append(L10n.tr("额度受限"))
        }
        if parts.isEmpty, allowed == true {
            parts.append(L10n.tr("可用"))
        }
        return parts.isEmpty ? L10n.tr("未知") : parts.joined(separator: " / ")
    }

    var availabilityText: String {
        if let allowed {
            return allowed ? L10n.tr("可用") : L10n.tr("不可用")
        }
        return L10n.tr("未知")
    }

    var limitStatusText: String {
        switch limitReached {
        case .some(true):
            return L10n.tr("已触达")
        case .some(false):
            return L10n.tr("未触达")
        case .none:
            return L10n.tr("未知")
        }
    }
}

struct ManagedAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var platform: PlatformKind
    var accountIdentifier: String
    var displayName: String
    var email: String?
    var authKind: ManagedAuthKind
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

    init(
        id: UUID,
        platform: PlatformKind = .codex,
        accountIdentifier: String,
        displayName: String,
        email: String?,
        authKind: ManagedAuthKind,
        createdAt: Date,
        lastUsedAt: Date?,
        lastQuotaSnapshotAt: Date?,
        lastRefreshAt: Date?,
        planType: String?,
        subscriptionDetails: SubscriptionDetails? = nil,
        lastStatusCheckAt: Date?,
        lastStatusMessage: String?,
        lastStatusLevel: SwitchLogLevel?,
        isActive: Bool
    ) {
        self.id = id
        self.platform = platform
        self.accountIdentifier = accountIdentifier
        self.displayName = displayName
        self.email = email
        self.authKind = authKind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastQuotaSnapshotAt = lastQuotaSnapshotAt
        self.lastRefreshAt = lastRefreshAt
        self.planType = planType
        self.subscriptionDetails = subscriptionDetails
        self.lastStatusCheckAt = lastStatusCheckAt
        self.lastStatusMessage = lastStatusMessage
        self.lastStatusLevel = lastStatusLevel
        self.isActive = isActive
    }
}

extension ManagedAccount {
    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case accountIdentifier
        case displayName
        case email
        case authKind
        case createdAt
        case lastUsedAt
        case lastQuotaSnapshotAt
        case lastRefreshAt
        case planType
        case subscriptionDetails
        case lastStatusCheckAt
        case lastStatusMessage
        case lastStatusLevel
        case isActive
        case codexAccountID
        case authMode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.platform = try container.decodeIfPresent(PlatformKind.self, forKey: .platform) ?? .codex
        self.accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
            ?? container.decode(String.self, forKey: .codexAccountID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.authKind = try container.decodeIfPresent(ManagedAuthKind.self, forKey: .authKind)
            ?? container.decode(ManagedAuthKind.self, forKey: .authMode)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.lastQuotaSnapshotAt = try container.decodeIfPresent(Date.self, forKey: .lastQuotaSnapshotAt)
        self.lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.subscriptionDetails = try container.decodeIfPresent(SubscriptionDetails.self, forKey: .subscriptionDetails)
        self.lastStatusCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastStatusCheckAt)
        self.lastStatusMessage = try container.decodeIfPresent(String.self, forKey: .lastStatusMessage)
        self.lastStatusLevel = try container.decodeIfPresent(SwitchLogLevel.self, forKey: .lastStatusLevel)
        self.isActive = try container.decode(Bool.self, forKey: .isActive)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(accountIdentifier, forKey: .accountIdentifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encode(authKind, forKey: .authKind)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(lastQuotaSnapshotAt, forKey: .lastQuotaSnapshotAt)
        try container.encodeIfPresent(lastRefreshAt, forKey: .lastRefreshAt)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(subscriptionDetails, forKey: .subscriptionDetails)
        try container.encodeIfPresent(lastStatusCheckAt, forKey: .lastStatusCheckAt)
        try container.encodeIfPresent(lastStatusMessage, forKey: .lastStatusMessage)
        try container.encodeIfPresent(lastStatusLevel, forKey: .lastStatusLevel)
        try container.encode(isActive, forKey: .isActive)
    }
}

struct ClaudeRateLimitValueSnapshot: Codable, Hashable, Sendable {
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?
}

struct ClaudeRateLimitSnapshot: Codable, Hashable, Sendable {
    var requests: ClaudeRateLimitValueSnapshot
    var inputTokens: ClaudeRateLimitValueSnapshot
    var outputTokens: ClaudeRateLimitValueSnapshot
    var capturedAt: Date
    var source: QuotaSnapshotSource
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
    var claudeRateLimitSnapshots: [String: ClaudeRateLimitSnapshot]
    var switchLogs: [SwitchLogEntry]
    var cliWorkingDirectoriesByAccountID: [String: [String]] = [:]
    var activeAccountID: UUID?

    static let currentVersion = 4

    static let empty = AppDatabase(
        version: currentVersion,
        accounts: [],
        quotaSnapshots: [:],
        claudeRateLimitSnapshots: [:],
        switchLogs: [],
        cliWorkingDirectoriesByAccountID: [:],
        activeAccountID: nil
    )

    func account(id: UUID?) -> ManagedAccount? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    func snapshot(for accountID: UUID) -> QuotaSnapshot? {
        quotaSnapshots[accountID.uuidString]
    }

    func claudeRateLimitSnapshot(for accountID: UUID) -> ClaudeRateLimitSnapshot? {
        claudeRateLimitSnapshots[accountID.uuidString]
    }

    func cliWorkingDirectories(for accountID: UUID) -> [String] {
        cliWorkingDirectoriesByAccountID[accountID.uuidString] ?? []
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
        if let index = accounts.firstIndex(where: {
            $0.id == account.id || ($0.platform == account.platform && $0.accountIdentifier == account.accountIdentifier)
        }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    mutating func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        quotaSnapshots.removeValue(forKey: id.uuidString)
        claudeRateLimitSnapshots.removeValue(forKey: id.uuidString)
        cliWorkingDirectoriesByAccountID.removeValue(forKey: id.uuidString)
        if activeAccountID == id {
            activeAccountID = nil
        }
    }

    mutating func updateSnapshot(_ snapshot: QuotaSnapshot, for accountID: UUID) {
        quotaSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastQuotaSnapshotAt = snapshot.capturedAt
    }

    mutating func updateClaudeRateLimitSnapshot(_ snapshot: ClaudeRateLimitSnapshot, for accountID: UUID) {
        claudeRateLimitSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastRefreshAt = snapshot.capturedAt
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

    mutating func rememberCLIWorkingDirectory(_ directoryURL: URL, for accountID: UUID) {
        let normalizedPath = directoryURL.standardizedFileURL.path
        let key = accountID.uuidString
        var directories = cliWorkingDirectoriesByAccountID[key] ?? []
        directories.removeAll(where: { $0 == normalizedPath })
        directories.insert(normalizedPath, at: 0)
        if directories.count > 8 {
            directories = Array(directories.prefix(8))
        }
        cliWorkingDirectoriesByAccountID[key] = directories
    }
}

extension AppDatabase {
    private enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case quotaSnapshots
        case claudeRateLimitSnapshots
        case switchLogs
        case cliWorkingDirectoriesByAccountID
        case activeAccountID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let accounts = try container.decodeIfPresent([ManagedAccount].self, forKey: .accounts) ?? []
        let quotaSnapshots = try container.decodeIfPresent([String: QuotaSnapshot].self, forKey: .quotaSnapshots) ?? [:]
        let claudeRateLimitSnapshots = try container.decodeIfPresent([String: ClaudeRateLimitSnapshot].self, forKey: .claudeRateLimitSnapshots) ?? [:]
        let switchLogs = try container.decodeIfPresent([SwitchLogEntry].self, forKey: .switchLogs) ?? []
        let cliWorkingDirectoriesByAccountID = try container.decodeIfPresent([String: [String]].self, forKey: .cliWorkingDirectoriesByAccountID) ?? [:]
        let activeAccountID = try container.decodeIfPresent(UUID.self, forKey: .activeAccountID)

        self.init(
            version: max(version, Self.currentVersion),
            accounts: accounts,
            quotaSnapshots: quotaSnapshots,
            claudeRateLimitSnapshots: claudeRateLimitSnapshots,
            switchLogs: switchLogs,
            cliWorkingDirectoriesByAccountID: cliWorkingDirectoriesByAccountID,
            activeAccountID: activeAccountID
        )
    }
}
