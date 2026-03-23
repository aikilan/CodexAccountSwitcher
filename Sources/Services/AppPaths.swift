import Foundation

struct AppPaths: Sendable {
    let codexHome: URL
    let authFileURL: URL
    let sessionsDirectoryURL: URL
    let stateDatabaseURL: URL
    let appSupportDirectoryURL: URL
    let databaseURL: URL
    let credentialCacheURL: URL

    init(
        fileManager: FileManager = .default,
        codexHomeOverride: URL? = nil,
        appSupportOverride: URL? = nil
    ) throws {
        let codexHome = codexHomeOverride ?? AppPaths.resolveCodexHome(fileManager: fileManager)
        let appSupport = try appSupportOverride ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("CodexAccountSwitcher", isDirectory: true)

        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        self.codexHome = codexHome
        self.authFileURL = codexHome.appendingPathComponent("auth.json")
        self.sessionsDirectoryURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.stateDatabaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        self.appSupportDirectoryURL = appSupport
        self.databaseURL = appSupport.appendingPathComponent("accounts.json")
        self.credentialCacheURL = appSupport.appendingPathComponent("credentials-cache.json")
    }

    private static func resolveCodexHome(fileManager: FileManager) -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
}
