import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class PlatformFoundationTests: XCTestCase {
    func testLegacyDatabaseDecodesAccountsAsCodexAndBumpsVersion() throws {
        let accountID = UUID()
        let json = """
        {
          "version": 2,
          "accounts": [
            {
              "id": "\(accountID.uuidString)",
              "codexAccountID": "acct_legacy",
              "displayName": "Legacy User",
              "email": "legacy@example.com",
              "authMode": "chatgpt",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "switchLogs": [],
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))

        XCTAssertEqual(database.version, AppDatabase.currentVersion)
        XCTAssertEqual(database.accounts.count, 1)
        XCTAssertEqual(database.accounts.first?.platform, .codex)
    }

    func testAppPathsMigratesLegacySupportDirectoryWhenNewDirectoryMissing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let legacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let legacyDatabase = legacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL.lastPathComponent, "LLMAccountSwitcher")
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacySupport.path))
    }

    func testAppPathsPrefersNewSupportDirectoryWhenBothDirectoriesExist() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let legacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let newSupport = root.appendingPathComponent("LLMAccountSwitcher", isDirectory: true)
        let newDatabase = newSupport.appendingPathComponent("accounts.json")
        let legacyDatabase = legacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newSupport, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDatabase)
        try Data("new".utf8).write(to: newDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL, newSupport)
        XCTAssertEqual(try String(contentsOf: newDatabase), "new")
        XCTAssertEqual(try String(contentsOf: legacyDatabase), "legacy")
    }
}
