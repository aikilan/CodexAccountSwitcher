import Foundation

enum CopilotManagedConfigManagerError: LocalizedError, Equatable {
    case bootstrapTimedOut

    var errorDescription: String? {
        switch self {
        case .bootstrapTimedOut:
            return L10n.tr("GitHub Copilot CLI 原生登录尚未完成，请在 Terminal 完成授权后重试。")
        }
    }
}

struct CopilotManagedConfigManager: @unchecked Sendable {
    private let paths: AppPaths
    private let terminalCommandLauncher: any TerminalCommandLaunching
    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let requestTimeout: Duration
    private let requestPollInterval: Duration
    private let probeStatus: @Sendable (URL, URL) async throws -> CopilotACPStatusResult
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        paths: AppPaths,
        terminalCommandLauncher: any TerminalCommandLaunching,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil,
        requestTimeout: Duration = .seconds(180),
        requestPollInterval: Duration = .seconds(2),
        probeStatus: (@Sendable (URL, URL) async throws -> CopilotACPStatusResult)? = nil,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.paths = paths
        self.terminalCommandLauncher = terminalCommandLauncher
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.requestTimeout = requestTimeout
        self.requestPollInterval = requestPollInterval
        self.probeStatus = probeStatus ?? { configDirectoryURL, workingDirectoryURL in
            try await CopilotACPClient(configDirectoryURL: configDirectoryURL).fetchStatus(
                workingDirectoryURL: workingDirectoryURL
            )
        }
        self.sleep = sleep ?? { duration in
            try await Task.sleep(for: duration)
        }
    }

    func bootstrap(
        accountID: UUID,
        credential: CopilotCredential,
        model: String?,
        reasoningEffort: String
    ) async throws -> ManagedCopilotConfigBootstrapResult {
        let configDirectoryName = resolvedConfigDirectoryName(accountID: accountID, credential: credential)
        let configDirectoryURL = paths.copilotManagedConfigDirectoryURL(named: configDirectoryName)
        let updatedCredential = try CopilotCredential(
            configDirectoryName: configDirectoryName,
            host: credential.host,
            login: credential.login,
            githubAccessToken: credential.githubAccessToken,
            accessToken: credential.accessToken,
            defaultModel: model ?? credential.defaultModel,
            source: credential.source
        ).validated()

        if try await !isProbeReady(configDirectoryURL: configDirectoryURL) {
            if globalConfigMatches(updatedCredential) {
                try cloneDefaultCLIState(into: configDirectoryURL)
            } else {
                try launchCopilotLogin(configDirectoryURL: configDirectoryURL, host: updatedCredential.host)
                try CopilotCLIConfiguration(
                    host: updatedCredential.host,
                    login: updatedCredential.login,
                    defaultModel: model ?? updatedCredential.defaultModel,
                    effortLevel: reasoningEffort
                ).write(to: configDirectoryURL)
                try await waitUntilReady(configDirectoryURL: configDirectoryURL)
            }
        }

        try CopilotCLIConfiguration(
            host: updatedCredential.host,
            login: updatedCredential.login,
            defaultModel: model ?? updatedCredential.defaultModel,
            effortLevel: reasoningEffort
        ).write(to: configDirectoryURL)
        _ = try await probeStatus(configDirectoryURL, homeDirectoryURL)

        return ManagedCopilotConfigBootstrapResult(
            credential: updatedCredential,
            configDirectoryURL: configDirectoryURL
        )
    }
}

extension CopilotManagedConfigManager: CopilotManagedConfigManaging {}

private extension CopilotManagedConfigManager {
    func resolvedConfigDirectoryName(accountID: UUID, credential: CopilotCredential) -> String {
        let trimmed = credential.configDirectoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? accountID.uuidString : trimmed
    }

    func isProbeReady(configDirectoryURL: URL) async throws -> Bool {
        do {
            _ = try await probeStatus(configDirectoryURL, homeDirectoryURL)
            return true
        } catch {
            return false
        }
    }

    func globalConfigMatches(_ credential: CopilotCredential) -> Bool {
        guard let current = try? CopilotCLIConfiguration.load(
            from: defaultConfigDirectoryURL()
        ) else {
            return false
        }
        return normalizedHost(current.host) == normalizedHost(credential.host)
            && normalizedLogin(current.login) == normalizedLogin(credential.login)
    }

    func cloneDefaultCLIState(into configDirectoryURL: URL) throws {
        let defaultConfigDirectoryURL = defaultConfigDirectoryURL()
        let rootURL = configDirectoryURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: defaultConfigDirectoryURL, to: configDirectoryURL)
    }

    func defaultConfigDirectoryURL() -> URL {
        homeDirectoryURL.appendingPathComponent(".copilot", isDirectory: true)
    }

    func launchCopilotLogin(configDirectoryURL: URL, host: String) throws {
        try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let command = [
            "copilot",
            "login",
            "--config-dir",
            shellEscaped(configDirectoryURL.path),
            "--host",
            shellEscaped(host),
        ].joined(separator: " ")
        try terminalCommandLauncher.launch(command: command)
    }

    func waitUntilReady(configDirectoryURL: URL) async throws {
        let deadline = Date().addingTimeInterval(requestTimeout.timeInterval)
        while Date() < deadline {
            if try await isProbeReady(configDirectoryURL: configDirectoryURL) {
                return
            }
            try await sleep(requestPollInterval)
        }
        throw CopilotManagedConfigManagerError.bootstrapTimedOut
    }

    func normalizedHost(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func normalizedLogin(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
