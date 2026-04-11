import Foundation
import XCTest
@testable import Orbit

final class CodexManagedHomeWriterTests: XCTestCase {
    func testSyncMainHomePreservesUserConfigAndReplacesManagedBlock() throws {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let configURL = homeURL.appendingPathComponent("config.toml")
        let managedCatalogURL = homeURL.appendingPathComponent("orbit-main-model-catalog.json")
        try """
        theme = "dark"

        # orbit-managed:start main-codex
        model = "old-model"
        model_catalog_json = "\(managedCatalogURL.path)"
        # orbit-managed:end main-codex

        [profiles.default]
        editor = "vim"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let writer = CodexManagedHomeWriter()
        try writer.syncMainHome(
            codexHomeURL: homeURL,
            authPayload: nil,
            clearAuthFile: false,
            configFileContents: """
            model = "gpt-4.1"
            model_reasoning_effort = "high"
            model_provider = "github-copilot"
            """,
            modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-4.1", "claude-opus-4.1"])
        )

        let configContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(configContents.contains("theme = \"dark\""))
        XCTAssertTrue(configContents.contains("[profiles.default]"))
        XCTAssertEqual(occurrenceCount(of: "# orbit-managed:start main-codex", in: configContents), 1)
        XCTAssertTrue(configContents.contains("model_provider = \"github-copilot\""))
        XCTAssertEqual(occurrenceCount(of: "orbit-main-model-catalog.json", in: configContents), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedCatalogURL.path))
    }

    func testSyncMainHomeRemovesManagedBlockWithoutTouchingUserModelCatalogReference() throws {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let configURL = homeURL.appendingPathComponent("config.toml")
        let managedCatalogURL = homeURL.appendingPathComponent("orbit-main-model-catalog.json")
        try "{}".write(to: managedCatalogURL, atomically: true, encoding: .utf8)
        try """
        theme = "dark"
        model_catalog_json = "/tmp/custom-model-catalog.json"

        # orbit-managed:start main-codex
        model = "old-model"
        model_catalog_json = "\(managedCatalogURL.path)"
        # orbit-managed:end main-codex
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let writer = CodexManagedHomeWriter()
        try writer.syncMainHome(
            codexHomeURL: homeURL,
            authPayload: nil,
            clearAuthFile: false,
            configFileContents: nil,
            modelCatalogSnapshot: nil
        )

        let configContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(configContents.contains("theme = \"dark\""))
        XCTAssertTrue(configContents.contains("model_catalog_json = \"/tmp/custom-model-catalog.json\""))
        XCTAssertFalse(configContents.contains("# orbit-managed:start main-codex"))
        XCTAssertFalse(configContents.contains("orbit-main-model-catalog.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedCatalogURL.path))
    }

    func testSyncMainHomeClearsAuthFileForNonChatGPTAccounts() throws {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let authFileURL = homeURL.appendingPathComponent("auth.json")
        try "legacy-auth".write(to: authFileURL, atomically: true, encoding: .utf8)

        let writer = CodexManagedHomeWriter()
        try writer.syncMainHome(
            codexHomeURL: homeURL,
            authPayload: nil,
            clearAuthFile: true,
            configFileContents: nil,
            modelCatalogSnapshot: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: authFileURL.path))
    }

    private func occurrenceCount(of substring: String, in text: String) -> Int {
        text.components(separatedBy: substring).count - 1
    }
}
