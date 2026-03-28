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
    var cliEnvironmentProfiles: [CLIEnvironmentProfile] = CLIEnvironmentProfile.builtInProfiles
    var defaultCLIEnvironmentIDByAccountID: [String: String] = [:]
    var preferredCodexEnvironmentIDByAccountID: [String: String] = [:]
    var cliLaunchHistoryByAccountID: [String: [CLILaunchRecord]] = [:]
    var activeAccountID: UUID?

    static let currentVersion = 7

    static let empty = AppDatabase(
        version: currentVersion,
        accounts: [],
        quotaSnapshots: [:],
        claudeRateLimitSnapshots: [:],
        switchLogs: [],
        cliEnvironmentProfiles: CLIEnvironmentProfile.builtInProfiles,
        defaultCLIEnvironmentIDByAccountID: [:],
        preferredCodexEnvironmentIDByAccountID: [:],
        cliLaunchHistoryByAccountID: [:],
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
        cliLaunchHistory(for: accountID).map(\.path)
    }

    func cliLaunchHistory(for accountID: UUID) -> [CLILaunchRecord] {
        cliLaunchHistoryByAccountID[accountID.uuidString] ?? []
    }

    func defaultCLIEnvironmentID(for accountID: UUID) -> String? {
        defaultCLIEnvironmentIDByAccountID[accountID.uuidString]
    }

    func preferredCodexEnvironmentID(for accountID: UUID) -> String? {
        preferredCodexEnvironmentIDByAccountID[accountID.uuidString]
    }

    func cliEnvironmentProfile(id: String) -> CLIEnvironmentProfile? {
        cliEnvironmentProfiles.first(where: { $0.id == id })
    }

    func defaultCLIEnvironment(for account: ManagedAccount) -> CLIEnvironmentProfile {
        let defaultID = defaultCLIEnvironmentIDByAccountID[account.id.uuidString]
            ?? CLIEnvironmentProfile.defaultProfileID(for: account.platform)
        if let profile = cliEnvironmentProfile(id: defaultID) {
            return profile
        }
        return cliEnvironmentProfiles.first(where: { $0.id == CLIEnvironmentProfile.defaultProfileID(for: account.platform) })
            ?? CLIEnvironmentProfile.builtInProfiles.first(where: { $0.id == CLIEnvironmentProfile.defaultProfileID(for: account.platform) })
            ?? CLIEnvironmentProfile.builtInProfiles[0]
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
        normalizeCLIEnvironmentState()
    }

    mutating func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        quotaSnapshots.removeValue(forKey: id.uuidString)
        claudeRateLimitSnapshots.removeValue(forKey: id.uuidString)
        cliLaunchHistoryByAccountID.removeValue(forKey: id.uuidString)
        defaultCLIEnvironmentIDByAccountID.removeValue(forKey: id.uuidString)
        preferredCodexEnvironmentIDByAccountID.removeValue(forKey: id.uuidString)
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

    mutating func upsertCLIEnvironmentProfile(_ profile: CLIEnvironmentProfile) {
        if let index = cliEnvironmentProfiles.firstIndex(where: { $0.id == profile.id }) {
            cliEnvironmentProfiles[index] = profile
        } else {
            cliEnvironmentProfiles.append(profile)
        }
        cliEnvironmentProfiles = mergedCLIEnvironmentProfiles(cliEnvironmentProfiles)
        normalizeCLIEnvironmentState()
    }

    mutating func removeCLIEnvironmentProfile(id: String) {
        guard let profile = cliEnvironmentProfile(id: id), !profile.isBuiltIn else { return }
        cliEnvironmentProfiles.removeAll(where: { $0.id == id })

        for account in accounts {
            let key = account.id.uuidString
            if defaultCLIEnvironmentIDByAccountID[key] == id {
                defaultCLIEnvironmentIDByAccountID[key] = CLIEnvironmentProfile.defaultProfileID(for: account.platform)
            }
            if preferredCodexEnvironmentIDByAccountID[key] == id {
                preferredCodexEnvironmentIDByAccountID[key] = fallbackPreferredCodexEnvironmentID(for: account)
            }
        }
        normalizeCLIEnvironmentState()
    }

    mutating func setDefaultCLIEnvironmentID(_ environmentID: String, for accountID: UUID) {
        defaultCLIEnvironmentIDByAccountID[accountID.uuidString] = environmentID
        if let profile = cliEnvironmentProfile(id: environmentID), profile.target == .codex {
            preferredCodexEnvironmentIDByAccountID[accountID.uuidString] = environmentID
        }
    }

    mutating func rememberCLILaunch(
        _ directoryURL: URL,
        environmentProfile: CLIEnvironmentProfile,
        for accountID: UUID
    ) {
        let normalizedPath = directoryURL.standardizedFileURL.path
        let key = accountID.uuidString
        var history = cliLaunchHistoryByAccountID[key] ?? []
        history.removeAll(where: { $0.path == normalizedPath && $0.environmentID == environmentProfile.id })
        history.insert(
            CLILaunchRecord(
                path: normalizedPath,
                environmentID: environmentProfile.id,
                environmentDisplayName: environmentProfile.sanitizedDisplayName,
                environmentTarget: environmentProfile.target,
                environmentSummary: environmentProfile.launchSummary,
                environmentSnapshot: environmentProfile,
                lastUsedAt: Date()
            ),
            at: 0
        )
        if history.count > 8 {
            history = Array(history.prefix(8))
        }
        cliLaunchHistoryByAccountID[key] = history
    }

    mutating func normalizeCLIEnvironmentState() {
        cliEnvironmentProfiles = mergedCLIEnvironmentProfiles(cliEnvironmentProfiles)

        for account in accounts {
            let key = account.id.uuidString
            let defaultEnvironmentID = defaultCLIEnvironmentIDByAccountID[key]
                ?? CLIEnvironmentProfile.defaultProfileID(for: account.platform)
            if cliEnvironmentProfile(id: defaultEnvironmentID) == nil {
                defaultCLIEnvironmentIDByAccountID[key] = CLIEnvironmentProfile.defaultProfileID(for: account.platform)
            } else if defaultCLIEnvironmentIDByAccountID[key] == nil {
                defaultCLIEnvironmentIDByAccountID[key] = defaultEnvironmentID
            }

            if codexEnvironmentProfile(id: preferredCodexEnvironmentIDByAccountID[key]) == nil {
                preferredCodexEnvironmentIDByAccountID[key] = fallbackPreferredCodexEnvironmentID(for: account)
            }
        }
    }

    private func codexEnvironmentProfile(id: String?) -> CLIEnvironmentProfile? {
        guard let id, let profile = cliEnvironmentProfile(id: id), profile.target == .codex else {
            return nil
        }
        return profile
    }

    private func fallbackPreferredCodexEnvironmentID(for account: ManagedAccount) -> String {
        let key = account.id.uuidString
        if let defaultCodexEnvironment = codexEnvironmentProfile(id: defaultCLIEnvironmentIDByAccountID[key]) {
            return defaultCodexEnvironment.id
        }
        return CLIEnvironmentProfile.builtInCodexProfileID
    }

    private func mergedCLIEnvironmentProfiles(_ profiles: [CLIEnvironmentProfile]) -> [CLIEnvironmentProfile] {
        var merged = [String: CLIEnvironmentProfile]()
        for profile in CLIEnvironmentProfile.builtInProfiles {
            merged[profile.id] = profile
        }
        for profile in profiles {
            if profile.isBuiltIn {
                continue
            }
            merged[profile.id] = profile
        }

        return merged.values.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return lhs.isBuiltIn && !rhs.isBuiltIn
            }
            return lhs.sanitizedDisplayName.localizedCaseInsensitiveCompare(rhs.sanitizedDisplayName) == .orderedAscending
        }
    }
}

extension AppDatabase {
    private enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case quotaSnapshots
        case claudeRateLimitSnapshots
        case switchLogs
        case cliEnvironmentProfiles
        case defaultCLIEnvironmentIDByAccountID
        case preferredCodexEnvironmentIDByAccountID
        case cliLaunchHistoryByAccountID
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
        let cliEnvironmentProfiles = try container.decodeIfPresent([CLIEnvironmentProfile].self, forKey: .cliEnvironmentProfiles)
            ?? CLIEnvironmentProfile.builtInProfiles
        let defaultCLIEnvironmentIDByAccountID = try container.decodeIfPresent([String: String].self, forKey: .defaultCLIEnvironmentIDByAccountID) ?? [:]
        let preferredCodexEnvironmentIDByAccountID = try container.decodeIfPresent([String: String].self, forKey: .preferredCodexEnvironmentIDByAccountID) ?? [:]
        let cliLaunchHistoryByAccountID = try container.decodeIfPresent([String: [CLILaunchRecord]].self, forKey: .cliLaunchHistoryByAccountID) ?? [:]
        let legacyCLIDirectories = try container.decodeIfPresent([String: [String]].self, forKey: .cliWorkingDirectoriesByAccountID) ?? [:]
        let activeAccountID = try container.decodeIfPresent(UUID.self, forKey: .activeAccountID)

        var database = AppDatabase(
            version: max(version, Self.currentVersion),
            accounts: accounts,
            quotaSnapshots: quotaSnapshots,
            claudeRateLimitSnapshots: claudeRateLimitSnapshots,
            switchLogs: switchLogs,
            cliEnvironmentProfiles: cliEnvironmentProfiles,
            defaultCLIEnvironmentIDByAccountID: defaultCLIEnvironmentIDByAccountID,
            preferredCodexEnvironmentIDByAccountID: preferredCodexEnvironmentIDByAccountID,
            cliLaunchHistoryByAccountID: cliLaunchHistoryByAccountID,
            activeAccountID: activeAccountID
        )

        if database.cliLaunchHistoryByAccountID.isEmpty, !legacyCLIDirectories.isEmpty {
            for account in database.accounts {
                let key = account.id.uuidString
                let defaultEnvironment = database.defaultCLIEnvironment(for: account)
                let legacyRecords = (legacyCLIDirectories[key] ?? []).map {
                    CLILaunchRecord(
                        path: $0,
                        environmentID: defaultEnvironment.id,
                        environmentDisplayName: defaultEnvironment.sanitizedDisplayName,
                        environmentTarget: defaultEnvironment.target,
                        environmentSummary: defaultEnvironment.launchSummary,
                        environmentSnapshot: defaultEnvironment
                    )
                }
                if !legacyRecords.isEmpty {
                    database.cliLaunchHistoryByAccountID[key] = legacyRecords
                }
            }
        }

        database.normalizeCLIEnvironmentState()
        self = database
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(quotaSnapshots, forKey: .quotaSnapshots)
        try container.encode(claudeRateLimitSnapshots, forKey: .claudeRateLimitSnapshots)
        try container.encode(switchLogs, forKey: .switchLogs)
        try container.encode(cliEnvironmentProfiles, forKey: .cliEnvironmentProfiles)
        try container.encode(defaultCLIEnvironmentIDByAccountID, forKey: .defaultCLIEnvironmentIDByAccountID)
        try container.encode(preferredCodexEnvironmentIDByAccountID, forKey: .preferredCodexEnvironmentIDByAccountID)
        try container.encode(cliLaunchHistoryByAccountID, forKey: .cliLaunchHistoryByAccountID)
        try container.encodeIfPresent(activeAccountID, forKey: .activeAccountID)
    }
}
