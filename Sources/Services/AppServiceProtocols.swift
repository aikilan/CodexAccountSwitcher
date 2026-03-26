import Foundation

protocol AuthFileManaging {
    func readCurrentAuth() throws -> CodexAuthPayload?
    func activate(_ payload: CodexAuthPayload) throws
    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws
    func clearAuthFile() throws
}

protocol AccountCredentialStore {
    func preload() throws
    func save(_ credential: StoredCredential, for accountID: UUID) throws
    func load(for accountID: UUID) throws -> StoredCredential
    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> StoredCredential
    func delete(for accountID: UUID) throws
}

protocol OAuthClienting: Sendable {
    func beginBrowserLogin(openURL: @escaping @Sendable (URL) -> Bool) async throws -> BrowserOAuthSession
    func completeBrowserLogin(session: BrowserOAuthSession) async throws -> AuthLoginResult
    func completeBrowserLogin(session: BrowserOAuthSession, pastedInput: String) async throws -> AuthLoginResult
    func startDeviceCodeLogin() async throws -> DeviceCodeChallenge
    func pollDeviceCodeLogin(challenge: DeviceCodeChallenge) async throws -> AuthLoginResult
    func refreshAuth(using payload: CodexAuthPayload) async throws -> AuthLoginResult
    func fetchUsageSnapshot(using payload: CodexAuthPayload) async throws -> UsageRefreshResult
}

protocol ClaudeProfileManaging: Sendable {
    func currentProfileExists() -> Bool
    func importCurrentProfile() throws -> ClaudeProfileSnapshotRef
    func activateProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws
    func deleteProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws
    func prepareIsolatedProfileRoot(for accountID: UUID, snapshotRef: ClaudeProfileSnapshotRef) throws -> URL
    func prepareIsolatedAPIKeyRoot(for accountID: UUID) throws -> URL
}

protocol ClaudeAPIClienting: Sendable {
    func probeStatus(using credential: AnthropicAPIKeyCredential) async throws -> ClaudeRateLimitSnapshot
}

protocol QuotaMonitoring: AnyObject {
    func bootstrapSnapshot() -> QuotaSnapshot?
    func start(
        onSnapshot: @escaping (UUID, QuotaSnapshot) -> Void,
        onSignal: @escaping (UUID, Date) -> Void
    )
    func setActiveAccountID(_ accountID: UUID?)
    func stop()
}

protocol UserNotifying: Sendable {
    func notifyLowQuotaRecommendation(
        identifier: String,
        title: String,
        body: String
    ) async
}

protocol CodexRuntimeInspecting: Sendable {
    func isCodexDesktopRunning() -> Bool
    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval) async -> SwitchVerificationResult
    func restartCodex() async throws
}

enum CodexCLILaunchMode: Equatable, Sendable {
    case globalCurrentAuth
    case isolatedAccount(payload: CodexAuthPayload)
}

struct IsolatedCodexLaunchPaths: Equatable, Sendable {
    let rootDirectoryURL: URL
    let codexHomeURL: URL
    let userDataURL: URL
}

protocol CodexInstanceLaunching {
    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL
    ) throws -> IsolatedCodexLaunchPaths
}

protocol CodexCLILaunching {
    func launchCLI(
        for account: ManagedAccount,
        mode: CodexCLILaunchMode,
        workingDirectoryURL: URL,
        appSupportDirectoryURL: URL
    ) throws
}

enum ClaudeCLILaunchMode: Equatable, Sendable {
    case globalProfile
    case isolatedProfile(rootURL: URL)
    case anthropicAPIKey(rootURL: URL, credential: AnthropicAPIKeyCredential)
}

protocol ClaudeCLILaunching {
    func launchCLI(
        for account: ManagedAccount,
        mode: ClaudeCLILaunchMode,
        workingDirectoryURL: URL
    ) throws
}
