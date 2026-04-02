import Foundation
import CommonCrypto
import Security
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CopilotProviderError: LocalizedError, Equatable {
    case importUnavailable
    case reauthorizationRequired
    case invalidToken
    case invalidConfiguration
    case deviceAuthorizationPending
    case deviceAuthorizationSlowDown(Int)
    case deviceAuthorizationExpired
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .importUnavailable:
            return L10n.tr("未找到可导入的 GitHub Copilot 登录态。")
        case .reauthorizationRequired:
            return L10n.tr("当前 GitHub Copilot 账号缺少可用授权，请重新导入或重新登录。")
        case .invalidToken:
            return L10n.tr("当前 GitHub Copilot 授权无效，请重新登录。")
        case .invalidConfiguration:
            return L10n.tr("GitHub Copilot 配置不完整。")
        case .deviceAuthorizationPending:
            return L10n.tr("GitHub 授权尚未完成。")
        case let .deviceAuthorizationSlowDown(interval):
            return L10n.tr("GitHub 要求放慢轮询速度，新的轮询间隔为 %d 秒。", interval)
        case .deviceAuthorizationExpired:
            return L10n.tr("GitHub 授权码已过期，请重新开始登录。")
        case let .upstream(message):
            return message
        }
    }
}

actor CopilotNativeProvider {
    private static let keychainService = "copilot-cli"
    private static let vscodeSafeStorageService = "Code Safe Storage"
    private static let vscodeGlobalStorageRelativePath = "Library/Application Support/Code/User/globalStorage"
    private static let vscodeGitHubAuthKey = #"secret://{"extensionId":"vscode.github-authentication","key":"github.auth"}"#
    private static let vscodeEncryptionPrefix = Data("v10".utf8)
    private static let electronSafeStorageSalt = Data("saltysalt".utf8)
    private static let electronSafeStorageIterations: UInt32 = 1_003
    private static let copilotTokenExchangeAPIVersion = "2025-04-01"
    private static let githubAlignedScopes = Set(["read:user", "user:email", "repo", "workflow"])
    private static let githubMinimalScopes = Set(["user:email"])
    private static let githubFallbackScopes = Set(["read:user"])
    private static let defaultHost = "https://github.com"
    private static let defaultIntegrationID = "copilot-developer-cli"
    private static let githubAPIVersion = "2025-05-01"
    private static let oauthClientID = "Ov23ctDVkRmgkPke0Mmm"
    private static let oauthScope = "read:user,read:org,repo,gist"
    private static let requestTimeout: TimeInterval = 30

    private let fileManager: FileManager
    private let session: URLSession
    private let processInfo: ProcessInfo
    private let homeDirectoryURL: URL
    private let vscodeSafeStoragePassphrase: String?

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        processInfo: ProcessInfo = .processInfo,
        homeDirectoryURL: URL? = nil,
        vscodeSafeStoragePassphrase: String? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        self.processInfo = processInfo
        self.homeDirectoryURL = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.vscodeSafeStoragePassphrase = vscodeSafeStoragePassphrase
    }

    func importCredential(
        host: String,
        defaultModel: String?
    ) async throws -> CopilotCredential {
        let normalizedHost = normalizedHost(host)
        let localConfigSnapshot = try loadLocalConfigSnapshot()
        let preferredModel = trimmedOrNil(defaultModel) ?? localConfigSnapshot?.defaultModel

        if let credential = try await envCredential(host: normalizedHost, defaultModel: preferredModel) {
            return try credential.validated()
        }

        if let snapshot = localConfigSnapshot,
           let account = preferredAccount(from: snapshot, preferredHost: normalizedHost)
        {
            if let credential = try await vscodeCredential(
                host: account.host,
                defaultModel: preferredModel,
                preferredLogin: account.login
            ) {
                return try credential.validated()
            }
        }

        if let credential = try await vscodeCredential(
            host: normalizedHost,
            defaultModel: preferredModel
        ) {
            return try credential.validated()
        }

        throw CopilotProviderError.importUnavailable
    }

    func resolveCredential(_ credential: CopilotCredential) async throws -> CopilotCredential {
        let normalizedHost = normalizedHost(credential.host)
        let trimmedLogin = credential.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLogin.isEmpty else {
            throw CopilotProviderError.invalidConfiguration
        }
        let localConfigSnapshot = try loadLocalConfigSnapshot()
        let preferredModel = credential.defaultModel ?? localConfigSnapshot?.defaultModel

        if let githubAccessToken = trimmedOrNil(credential.githubAccessToken) {
            return try await validatedCredential(
                host: normalizedHost,
                login: trimmedLogin,
                githubAccessToken: githubAccessToken,
                defaultModel: preferredModel,
                source: credential.source ?? .localImport,
                configDirectoryName: credential.configDirectoryName
            )
        }

        if let envCredential = try await envCredential(host: normalizedHost, defaultModel: preferredModel),
           loginMatches(envCredential.login, trimmedLogin)
        {
            return mergedCredential(
                stored: credential,
                resolved: envCredential,
                defaultModel: preferredModel
            )
        }

        if let snapshot = localConfigSnapshot,
           let account = preferredAccount(from: snapshot, preferredHost: normalizedHost),
           loginMatches(account.login, trimmedLogin),
           let vscodeCredential = try await vscodeCredential(
               host: account.host,
               defaultModel: preferredModel,
               preferredLogin: account.login
           ),
           loginMatches(vscodeCredential.login, trimmedLogin)
        {
            return mergedCredential(
                stored: credential,
                resolved: vscodeCredential,
                defaultModel: preferredModel
            )
        }

        if let vscodeCredential = try await vscodeCredential(
            host: normalizedHost,
            defaultModel: preferredModel,
            preferredLogin: trimmedLogin
        ),
           loginMatches(vscodeCredential.login, trimmedLogin)
        {
            return mergedCredential(
                stored: credential,
                resolved: vscodeCredential,
                defaultModel: preferredModel
            )
        }

        throw CopilotProviderError.reauthorizationRequired
    }

    func startDeviceLogin(
        host: String,
        defaultModel: String?
    ) async throws -> CopilotDeviceLoginChallenge {
        let normalizedHost = normalizedHost(host)
        let requestURL = try url(path: "/login/device/code", baseURLString: loginAuthorityHost(for: normalizedHost))
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = URLComponents.formEncodedData([
            "client_id": Self.oauthClientID,
            "scope": Self.oauthScope,
        ])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(statusCode) else {
            throw mappedUpstreamError(data: data, statusCode: statusCode, fallback: L10n.tr("GitHub 设备授权启动失败。"))
        }

        let payload = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        guard let verificationURL = URL(string: payload.verificationURI) else {
            throw CopilotProviderError.invalidConfiguration
        }

        return CopilotDeviceLoginChallenge(
            host: normalizedHost,
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verificationURL,
            expiresInSeconds: payload.expiresIn,
            intervalSeconds: max(1, payload.interval),
            defaultModel: trimmedOrNil(defaultModel)
        )
    }

    func completeDeviceLogin(_ challenge: CopilotDeviceLoginChallenge) async throws -> CopilotCredential {
        let startedAt = Date()
        var interval = max(1, challenge.intervalSeconds)

        while Date().timeIntervalSince(startedAt) < TimeInterval(challenge.expiresInSeconds) {
            try Task.checkCancellation()

            switch try await pollDeviceAuthorization(
                host: loginAuthorityHost(for: challenge.host),
                deviceCode: challenge.deviceCode
            ) {
            case let .token(githubAccessToken):
                return try await validatedCredential(
                    host: challenge.host,
                    login: "",
                    githubAccessToken: githubAccessToken,
                    defaultModel: challenge.defaultModel,
                    source: .orbitOAuth,
                    configDirectoryName: nil
                )
            case .authorizationPending:
                try await Task.sleep(for: .seconds(interval))
            case let .slowDown(updatedInterval):
                interval = max(interval + 1, updatedInterval)
                try await Task.sleep(for: .seconds(interval))
            case .expired:
                throw CopilotProviderError.deviceAuthorizationExpired
            }
        }

        throw CopilotProviderError.deviceAuthorizationExpired
    }

    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus {
        let resolvedCredential = try await resolveCredential(credential)
        guard let githubAccessToken = trimmedOrNil(resolvedCredential.githubAccessToken),
              let accessToken = resolvedCredential.accessToken
        else {
            throw CopilotProviderError.reauthorizationRequired
        }

        let user = try await copilotUser(host: resolvedCredential.host, githubAccessToken: githubAccessToken)
        let availableModels = try await fetchModelIDs(user: user, host: resolvedCredential.host, accessToken: accessToken)
        let localConfigSnapshot = try loadLocalConfigSnapshot()
        let fallbackModel = resolvedCredential.defaultModel
            ?? localConfigSnapshot?.defaultModel
        let currentModel = trimmedOrNil(fallbackModel) ?? availableModels.first

        return CopilotAccountStatus(
            availableModels: mergedModels(availableModels, defaultModel: currentModel),
            currentModel: currentModel,
            quotaSnapshot: quotaSnapshot(from: user)
        )
    }

    func sendChatCompletions(
        using credential: CopilotCredential,
        body: Data
    ) async throws -> (statusCode: Int, data: Data) {
        let resolvedCredential = try await resolveCredential(credential)
        guard let githubAccessToken = trimmedOrNil(resolvedCredential.githubAccessToken),
              let accessToken = resolvedCredential.accessToken
        else {
            throw CopilotProviderError.reauthorizationRequired
        }

        let user = try await copilotUser(host: resolvedCredential.host, githubAccessToken: githubAccessToken)
        let baseURL = try apiBaseURL(from: user, host: resolvedCredential.host)
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions", isDirectory: false))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("conversation-agent", forHTTPHeaderField: "Openai-Intent")
        request.setValue("user", forHTTPHeaderField: "X-Initiator")
        request.setValue(Self.githubAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            processInfo.environment["GITHUB_COPILOT_INTEGRATION_ID"] ?? Self.defaultIntegrationID,
            forHTTPHeaderField: "Copilot-Integration-Id"
        )
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Interaction-Id")
        request.setValue("Orbit/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return (statusCode, data)
    }
}

extension CopilotNativeProvider: CopilotProviderServing {}

private extension CopilotNativeProvider {
    struct LocalConfigSnapshot {
        struct Account {
            let host: String
            let login: String
        }

        let accounts: [Account]
        let defaultModel: String?
        let plaintextTokens: [String: String]
    }

    struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int

        private enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    enum DeviceAuthorizationResult {
        case token(String)
        case authorizationPending
        case slowDown(Int)
        case expired
    }

    struct DeviceTokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?
        let interval: Int?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    struct CopilotUserResponse: Decodable {
        struct Endpoints: Decodable {
            let api: String?
        }

        struct QuotaSnapshots: Decodable {
            let chat: QuotaBucketResponse?
            let completions: QuotaBucketResponse?
            let premiumInteractions: QuotaBucketResponse?

            private enum CodingKeys: String, CodingKey {
                case chat
                case completions
                case premiumInteractions = "premium_interactions"
            }
        }

        let login: String?
        let endpoints: Endpoints?
        let quotaSnapshots: QuotaSnapshots?

        private enum CodingKeys: String, CodingKey {
            case login
            case endpoints
            case quotaSnapshots = "quota_snapshots"
        }
    }

    struct QuotaBucketResponse: Decodable {
        let percentRemaining: Double?
        let quotaRemaining: Double?
        let remaining: Double?
        let overageCount: Double?
        let overagePermitted: Bool?
        let unlimited: Bool?
        let quotaResetDateUTC: String?
        let timestampUTC: String?

        private enum CodingKeys: String, CodingKey {
            case percentRemaining = "percent_remaining"
            case quotaRemaining = "quota_remaining"
            case remaining
            case overageCount = "overage_count"
            case overagePermitted = "overage_permitted"
            case unlimited
            case quotaResetDateUTC = "quota_reset_date_utc"
            case timestampUTC = "timestamp_utc"
        }
    }

    struct VSCodeGitHubSession: Decodable {
        struct Account: Decodable {
            let label: String
        }

        let accessToken: String
        let scopes: [String]
        let account: Account
    }

    struct VSCodeBufferEnvelope: Decodable {
        let type: String
        let data: [UInt8]
    }

    struct CopilotTokenEnvelope: Decodable {
        let token: String
    }

    func normalizedHost(_ host: String) -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedHost.isEmpty ? Self.defaultHost : trimmedHost
        guard let url = URL(string: candidate.hasPrefix("http://") || candidate.hasPrefix("https://") ? candidate : "https://\(candidate)") else {
            return Self.defaultHost
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? Self.defaultHost
    }

    func trimmedOrNil(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    func envCredential(host: String, defaultModel: String?) async throws -> CopilotCredential? {
        let env = processInfo.environment
        let candidates = [
            env["COPILOT_GITHUB_TOKEN"],
            env["GH_TOKEN"],
            env["GITHUB_TOKEN"],
        ]

        for token in candidates {
            guard let githubAccessToken = trimmedOrNil(token) else { continue }
            if githubAccessToken.hasPrefix("ghp_") {
                continue
            }

            do {
                return try await validatedCredential(
                    host: host,
                    login: "",
                    githubAccessToken: githubAccessToken,
                    defaultModel: defaultModel,
                    source: .localImport,
                    configDirectoryName: nil
                )
            } catch {
                continue
            }
        }

        return nil
    }

    func vscodeCredential(
        host: String,
        defaultModel: String?,
        preferredLogin: String? = nil
    ) async throws -> CopilotCredential? {
        let sessions = try loadVSCodeGitHubSessions()
        guard !sessions.isEmpty else {
            return nil
        }

        for session in sessions.sorted(by: {
            vscodeSessionPriority(for: $0, preferredLogin: preferredLogin)
                < vscodeSessionPriority(for: $1, preferredLogin: preferredLogin)
        }) {
            do {
                return try await validatedCredential(
                    host: host,
                    login: session.account.label,
                    githubAccessToken: session.accessToken,
                    defaultModel: defaultModel,
                    source: .localImport,
                    configDirectoryName: nil
                )
            } catch {
                continue
            }
        }

        return nil
    }

    func loadVSCodeGitHubSessions() throws -> [VSCodeGitHubSession] {
        let encryptedData = try vscodeEncryptedGitHubAuthSessionsData()
        guard let encryptedData, !encryptedData.isEmpty else {
            return []
        }

        let passphrase = trimmedOrNil(vscodeSafeStoragePassphrase)
            ?? (try? anyKeychainPassword(service: Self.vscodeSafeStorageService))
        guard let passphrase else {
            return []
        }

        let decryptedData = try decryptElectronSafeStorageData(encryptedData, passphrase: passphrase)
        let sessions = try JSONDecoder().decode([VSCodeGitHubSession].self, from: decryptedData)
        return sessions.filter { session in
            trimmedOrNil(session.accessToken) != nil && trimmedOrNil(session.account.label) != nil
        }
    }

    func vscodeEncryptedGitHubAuthSessionsData() throws -> Data? {
        let databaseURL = homeDirectoryURL
            .appendingPathComponent(Self.vscodeGlobalStorageRelativePath, isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        return try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CopilotProviderError.invalidConfiguration
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, Self.vscodeGitHubAuthKey, -1, SQLITE_TRANSIENT)
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else {
                if stepResult == SQLITE_DONE {
                    return nil
                }
                throw CopilotProviderError.invalidConfiguration
            }

            switch sqlite3_column_type(statement, 0) {
            case SQLITE_BLOB:
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    return nil
                }
                return Data(bytes: bytes, count: length)
            case SQLITE_TEXT:
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard length > 0, let bytes = sqlite3_column_text(statement, 0) else {
                    return nil
                }
                let textData = Data(bytes: bytes, count: length)
                return try vscodeBufferData(from: textData)
            default:
                return nil
            }
        }
    }

    func vscodeBufferData(from textData: Data) throws -> Data {
        let envelope = try JSONDecoder().decode(VSCodeBufferEnvelope.self, from: textData)
        guard envelope.type == "Buffer", !envelope.data.isEmpty else {
            throw CopilotProviderError.invalidConfiguration
        }
        return Data(envelope.data)
    }

    func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            throw CopilotProviderError.invalidConfiguration
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    func decryptElectronSafeStorageData(_ encryptedData: Data, passphrase: String) throws -> Data {
        let payload: Data
        if encryptedData.starts(with: Self.vscodeEncryptionPrefix) {
            payload = encryptedData.dropFirst(Self.vscodeEncryptionPrefix.count)
        } else {
            payload = encryptedData
        }

        guard !payload.isEmpty else {
            throw CopilotProviderError.invalidConfiguration
        }

        let key = try electronSafeStorageKey(passphrase: passphrase)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var decryptedData = Data(count: payload.count + kCCBlockSizeAES128)
        var decryptedLength = 0
        let outputLength = decryptedData.count

        let status = decryptedData.withUnsafeMutableBytes { decryptedBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            decryptedBytes.baseAddress,
                            outputLength,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CopilotProviderError.invalidConfiguration
        }

        decryptedData.removeSubrange(decryptedLength..<decryptedData.count)
        return decryptedData
    }

    func electronSafeStorageKey(passphrase: String) throws -> Data {
        let password = Data(passphrase.utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                Self.electronSafeStorageSalt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        Self.electronSafeStorageSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        Self.electronSafeStorageIterations,
                        derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw CopilotProviderError.invalidConfiguration
        }

        return derivedKey
    }

    func exchangeCopilotToken(host: String, githubAccessToken: String) async throws -> String {
        let requestURL = try url(path: "/copilot_internal/v2/token", baseURLString: dotcomAPIRoot(for: host))
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("token \(githubAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.copilotTokenExchangeAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Orbit/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(statusCode) else {
            throw mappedUpstreamError(
                data: data,
                statusCode: statusCode,
                fallback: L10n.tr("VS Code GitHub 登录态无法换取 Copilot 授权。")
            )
        }

        let payload = try JSONDecoder().decode(CopilotTokenEnvelope.self, from: data)
        guard let token = trimmedOrNil(payload.token) else {
            throw CopilotProviderError.invalidConfiguration
        }

        return token
    }

    func vscodeSessionPriority(
        for session: VSCodeGitHubSession,
        preferredLogin: String?
    ) -> Int {
        let loginPenalty = loginMatches(session.account.label, preferredLogin) ? 0 : 10
        let scopeSet = Set(session.scopes)
        if Self.githubAlignedScopes.isSubset(of: scopeSet) {
            return loginPenalty
        }
        if !scopeSet.isDisjoint(with: Self.githubMinimalScopes) {
            return loginPenalty + 1
        }
        if !scopeSet.isDisjoint(with: Self.githubFallbackScopes) {
            return loginPenalty + 2
        }
        return loginPenalty + 3
    }

    func loadLocalConfigSnapshot() throws -> LocalConfigSnapshot? {
        let configURL = homeDirectoryURL
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        guard fileManager.fileExists(atPath: configURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotProviderError.invalidConfiguration
        }

        var accounts = [LocalConfigSnapshot.Account]()
        if let last = configAccount(from: object["last_logged_in_user"]) {
            accounts.append(last)
        }
        if let rawAccounts = object["logged_in_users"] as? [Any] {
            for rawAccount in rawAccounts {
                guard let account = configAccount(from: rawAccount),
                      !accounts.contains(where: { $0.host == account.host && $0.login == account.login })
                else {
                    continue
                }
                accounts.append(account)
            }
        }

        return LocalConfigSnapshot(
            accounts: accounts,
            defaultModel: trimmedOrNil(object["model"] as? String),
            plaintextTokens: (object["copilot_tokens"] as? [String: String]) ?? [:]
        )
    }

    func configAccount(from rawValue: Any?) -> LocalConfigSnapshot.Account? {
        guard let object = rawValue as? [String: Any],
              let host = trimmedOrNil(object["host"] as? String),
              let login = trimmedOrNil(object["login"] as? String)
        else {
            return nil
        }

        return LocalConfigSnapshot.Account(host: normalizedHost(host), login: login)
    }

    func preferredAccount(
        from snapshot: LocalConfigSnapshot,
        preferredHost: String
    ) -> LocalConfigSnapshot.Account? {
        snapshot.accounts.first(where: { $0.host == preferredHost }) ?? snapshot.accounts.first
    }

    func storedToken(
        for host: String,
        login: String,
        config: LocalConfigSnapshot
    ) throws -> String? {
        let account = "\(host):\(login)"
        if let keychainToken = try keychainPassword(service: Self.keychainService, account: account) {
            return keychainToken
        }
        return trimmedOrNil(config.plaintextTokens[account])
    }

    func anyStoredToken(config: LocalConfigSnapshot) throws -> String? {
        if let token = try anyKeychainPassword(service: Self.keychainService) {
            return token
        }
        return config.plaintextTokens.values.compactMap(trimmedOrNil).first
    }

    func keychainPassword(service: String, account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"]
            )
        }
    }

    func anyKeychainPassword(service: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"]
            )
        }
    }

    func pollDeviceAuthorization(host: String, deviceCode: String) async throws -> DeviceAuthorizationResult {
        let requestURL = try url(path: "/login/oauth/access_token", baseURLString: host)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = URLComponents.formEncodedData([
            "client_id": Self.oauthClientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(statusCode) else {
            throw mappedUpstreamError(data: data, statusCode: statusCode, fallback: L10n.tr("GitHub 设备授权失败。"))
        }

        let payload = try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
        if let accessToken = trimmedOrNil(payload.accessToken) {
            return .token(accessToken)
        }

        switch payload.error {
        case "authorization_pending":
            return .authorizationPending
        case "slow_down":
            return .slowDown(payload.interval ?? 5)
        case "expired_token":
            return .expired
        default:
            throw CopilotProviderError.upstream(
                payload.errorDescription
                    ?? payload.error
                    ?? L10n.tr("GitHub 设备授权失败。")
            )
        }
    }

    func mergedCredential(
        stored: CopilotCredential,
        resolved: CopilotCredential,
        defaultModel: String?
    ) -> CopilotCredential {
        CopilotCredential(
            configDirectoryName: stored.configDirectoryName,
            host: resolved.host,
            login: resolved.login,
            githubAccessToken: resolved.githubAccessToken,
            accessToken: resolved.accessToken,
            defaultModel: defaultModel ?? resolved.defaultModel,
            source: stored.source ?? resolved.source
        )
    }

    func loginMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = trimmedOrNil(lhs), let rhs = trimmedOrNil(rhs) else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    func validatedCredential(
        host: String,
        login: String,
        githubAccessToken: String,
        defaultModel: String?,
        source: CopilotCredentialSource,
        configDirectoryName: String?
    ) async throws -> CopilotCredential {
        async let user = copilotUser(host: host, githubAccessToken: githubAccessToken)
        async let accessToken = exchangeCopilotToken(host: host, githubAccessToken: githubAccessToken)
        let resolvedUser = try await user
        let resolvedAccessToken = try await accessToken
        let resolvedLogin = trimmedOrNil(resolvedUser.login) ?? trimmedOrNil(login)
        guard let resolvedLogin else {
            throw CopilotProviderError.invalidToken
        }

        return CopilotCredential(
            configDirectoryName: configDirectoryName,
            host: normalizedHost(host),
            login: resolvedLogin,
            githubAccessToken: githubAccessToken,
            accessToken: resolvedAccessToken,
            defaultModel: defaultModel,
            source: source
        )
    }

    func copilotUser(host: String, githubAccessToken: String) async throws -> CopilotUserResponse {
        let requestURL = try url(path: "/copilot_internal/user", baseURLString: dotcomAPIRoot(for: host))
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("token \(githubAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.copilotTokenExchangeAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Orbit/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                throw CopilotProviderError.invalidToken
            }
            throw mappedUpstreamError(data: data, statusCode: statusCode, fallback: L10n.tr("GitHub Copilot 用户信息读取失败。"))
        }

        do {
            return try JSONDecoder().decode(CopilotUserResponse.self, from: data)
        } catch {
            throw CopilotProviderError.invalidConfiguration
        }
    }

    func apiBaseURL(from user: CopilotUserResponse, host: String) throws -> URL {
        if let baseURL = trimmedOrNil(user.endpoints?.api), let url = URL(string: baseURL) {
            return url
        }
        guard let url = URL(string: capiRoot(for: host)) else {
            throw CopilotProviderError.invalidConfiguration
        }
        return url
    }

    func fetchModelIDs(
        user: CopilotUserResponse,
        host: String,
        accessToken: String
    ) async throws -> [String] {
        let modelsURL = try apiBaseURL(from: user, host: host).appendingPathComponent("models", isDirectory: false)
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("conversation-agent", forHTTPHeaderField: "Openai-Intent")
        request.setValue("user", forHTTPHeaderField: "X-Initiator")
        request.setValue(Self.githubAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            processInfo.environment["GITHUB_COPILOT_INTEGRATION_ID"] ?? Self.defaultIntegrationID,
            forHTTPHeaderField: "Copilot-Integration-Id"
        )
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Interaction-Id")
        request.setValue("Orbit/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(statusCode) else {
            throw mappedUpstreamError(data: data, statusCode: statusCode, fallback: L10n.tr("GitHub Copilot 模型列表读取失败。"))
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = object["data"] as? [[String: Any]]
        else {
            return []
        }

        var modelIDs = [String]()
        var seen = Set<String>()

        for rawModel in rawModels {
            let modelPickerEnabled = rawModel["model_picker_enabled"] as? Bool
            let policy = rawModel["policy"] as? [String: Any]
            let policyState = trimmedOrNil(policy?["state"] as? String)
            if modelPickerEnabled == false, policyState != "enabled" {
                continue
            }

            guard let modelID = trimmedOrNil(rawModel["id"] as? String),
                  seen.insert(modelID).inserted
            else {
                continue
            }

            modelIDs.append(modelID)
        }

        return modelIDs
    }

    func quotaSnapshot(from user: CopilotUserResponse) -> CopilotQuotaSnapshot? {
        let snapshots = user.quotaSnapshots
        let chat = quotaBucket(from: snapshots?.chat)
        let completions = quotaBucket(from: snapshots?.completions)
        let premium = quotaBucket(from: snapshots?.premiumInteractions)

        guard chat != nil || completions != nil || premium != nil else {
            return nil
        }

        return CopilotQuotaSnapshot(
            chat: chat,
            completions: completions,
            premiumInteractions: premium,
            capturedAt: Date()
        )
    }

    func quotaBucket(from bucket: QuotaBucketResponse?) -> CopilotQuotaBucketSnapshot? {
        guard let bucket else { return nil }

        if bucket.unlimited == true {
            return CopilotQuotaBucketSnapshot(
                entitlementRequests: 0,
                usedRequests: 0,
                remainingPercentage: 100,
                overage: bucket.overageCount ?? 0,
                overageAllowedWithExhaustedQuota: bucket.overagePermitted ?? false,
                resetDate: parsedDate(bucket.quotaResetDateUTC) ?? parsedDate(bucket.timestampUTC)
            )
        }

        let remaining = bucket.quotaRemaining ?? bucket.remaining ?? 0
        let remainingPercentage = max(0, min(100, bucket.percentRemaining ?? 0))
        let entitlement: Double
        if remaining > 0, remainingPercentage > 0 {
            entitlement = remaining / (remainingPercentage / 100)
        } else {
            entitlement = remaining + max(0, bucket.overageCount ?? 0)
        }

        return CopilotQuotaBucketSnapshot(
            entitlementRequests: entitlement,
            usedRequests: max(0, entitlement - remaining),
            remainingPercentage: remainingPercentage,
            overage: bucket.overageCount ?? 0,
            overageAllowedWithExhaustedQuota: bucket.overagePermitted ?? false,
            resetDate: parsedDate(bucket.quotaResetDateUTC) ?? parsedDate(bucket.timestampUTC)
        )
    }

    func parsedDate(_ value: String?) -> Date? {
        guard let value = trimmedOrNil(value) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    func mergedModels(_ modelIDs: [String], defaultModel: String?) -> [String] {
        var merged = [String]()
        var seen = Set<String>()

        for modelID in modelIDs {
            guard seen.insert(modelID).inserted else { continue }
            merged.append(modelID)
        }

        if let defaultModel = trimmedOrNil(defaultModel), seen.insert(defaultModel).inserted {
            merged.append(defaultModel)
        }

        return merged
    }

    func mappedUpstreamError(data: Data, statusCode: Int, fallback: String) -> CopilotProviderError {
        let message = ResponsesChatCompletionsBridge.extractErrorMessage(from: data)
        let resolvedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : message
        if statusCode == 401 || statusCode == 403 {
            return .invalidToken
        }
        return .upstream(resolvedMessage)
    }

    func dotcomAPIRoot(for host: String) -> String {
        let normalized = normalizedHost(host)
        if normalized == Self.defaultHost {
            return "https://api.github.com"
        }
        guard let url = URL(string: normalized), let hostname = url.host else {
            return "https://api.github.com"
        }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = "api.\(hostname)"
        components.port = url.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "https://api.github.com"
    }

    func capiRoot(for host: String) -> String {
        if host == Self.defaultHost {
            return "https://api.githubcopilot.com"
        }

        if let hostname = URL(string: host)?.host,
           let match = hostname.range(of: #"^(.+)\.ghe\.com$"#, options: .regularExpression)
        {
            let prefix = String(hostname[match]).replacingOccurrences(of: ".ghe.com", with: "")
            return "https://copilot-api.\(prefix).ghe.com"
        }

        return "https://api.githubcopilot.com"
    }

    func loginAuthorityHost(for host: String) -> String {
        let normalized = normalizedHost(host)
        if normalized == Self.defaultHost {
            return normalized
        }
        return Self.defaultHost
    }

    func url(path: String, baseURLString: String) throws -> URL {
        guard let baseURL = URL(string: baseURLString) else {
            throw CopilotProviderError.invalidConfiguration
        }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CopilotProviderError.invalidConfiguration
        }
        return url
    }
}

private extension URLComponents {
    static func formEncodedData(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}
