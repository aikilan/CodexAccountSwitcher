import Foundation

struct PlatformPaths: Sendable {
    let platform: PlatformKind
    let homeURL: URL
    let authFileURL: URL?
    let sessionsDirectoryURL: URL?
    let stateDatabaseURL: URL?
}

struct AppPaths: Sendable {
    private static let legacyAppSupportDirectoryName = "CodexAccountSwitcher"
    private static let appSupportDirectoryName = "LLMAccountSwitcher"

    let codex: PlatformPaths
    let claude: PlatformPaths
    let appSupportDirectoryURL: URL
    let databaseURL: URL
    let credentialCacheURL: URL

    init(
        fileManager: FileManager = .default,
        codexHomeOverride: URL? = nil,
        claudeHomeOverride: URL? = nil,
        appSupportOverride: URL? = nil,
        applicationSupportRootOverride: URL? = nil
    ) throws {
        let codexHome = codexHomeOverride ?? AppPaths.resolveCodexHome(fileManager: fileManager)
        let claudeHome = claudeHomeOverride ?? AppPaths.resolveClaudeHome(fileManager: fileManager)
        let appSupport = try appSupportOverride
            ?? AppPaths.resolveAppSupportDirectory(
                fileManager: fileManager,
                rootOverride: applicationSupportRootOverride
            )

        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        self.codex = PlatformPaths(
            platform: .codex,
            homeURL: codexHome,
            authFileURL: codexHome.appendingPathComponent("auth.json"),
            sessionsDirectoryURL: codexHome.appendingPathComponent("sessions", isDirectory: true),
            stateDatabaseURL: codexHome.appendingPathComponent("state_5.sqlite")
        )
        self.claude = PlatformPaths(
            platform: .claude,
            homeURL: claudeHome,
            authFileURL: nil,
            sessionsDirectoryURL: nil,
            stateDatabaseURL: nil
        )
        self.appSupportDirectoryURL = appSupport
        self.databaseURL = appSupport.appendingPathComponent("accounts.json")
        self.credentialCacheURL = appSupport.appendingPathComponent("credentials-cache.json")
    }

    var codexHome: URL {
        codex.homeURL
    }

    var authFileURL: URL {
        codex.authFileURL!
    }

    var sessionsDirectoryURL: URL {
        codex.sessionsDirectoryURL!
    }

    var stateDatabaseURL: URL {
        codex.stateDatabaseURL!
    }

    func paths(for platform: PlatformKind) -> PlatformPaths {
        switch platform {
        case .codex:
            return codex
        case .claude:
            return claude
        }
    }

    private static func resolveCodexHome(fileManager: FileManager) -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func resolveClaudeHome(fileManager: FileManager) -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    private static func resolveAppSupportDirectory(fileManager: FileManager, rootOverride: URL?) throws -> URL {
        let root = try rootOverride ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let newURL = root.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        let legacyURL = root.appendingPathComponent(legacyAppSupportDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: legacyURL.path), !fileManager.fileExists(atPath: newURL.path) {
            try fileManager.moveItem(at: legacyURL, to: newURL)
        }

        return newURL
    }
}
