import Foundation
import XCTest
@testable import Orbit

final class AppSupportPathRepairerTests: XCTestCase {
    func testRepairLegacyAbsolutePathsRewritesManagedFilesAndLeavesUnrelatedFilesUntouched() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let appSupportURL = rootURL.appendingPathComponent("Orbit", isDirectory: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let legacyLLMRoot = rootURL.appendingPathComponent("LLMAccountSwitcher", isDirectory: true).path
        let legacyCodexRoot = rootURL.appendingPathComponent("CodexAccountSwitcher", isDirectory: true).path

        let wrapperURL = appSupportURL
            .appendingPathComponent("claude-patched-runtimes", isDirectory: true)
            .appendingPathComponent("2.1.87", isDirectory: true)
            .appendingPathComponent("hash", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
        let configURL = appSupportURL
            .appendingPathComponent("account-cli", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        let marketplacesURL = appSupportURL
            .appendingPathComponent("account-cli", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("root", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("known_marketplaces.json", isDirectory: false)
        let skillsCacheURL = appSupportURL
            .appendingPathComponent("isolated-codex-instances", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
            .appendingPathComponent("vendor_imports", isDirectory: true)
            .appendingPathComponent("skills-curated-cache.json", isDirectory: false)
        let unrelatedURL = appSupportURL
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("unrelated.json", isDirectory: false)

        try fileManager.createDirectory(at: wrapperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: marketplacesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: skillsCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unrelatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try "#!/bin/sh\nexec node \"\(legacyLLMRoot)/claude-patched-runtimes/2.1.87/hash/package/cli.js\"\n"
            .write(to: wrapperURL, atomically: true, encoding: .utf8)
        try "model = \"gpt-5.4\"\nmodel_catalog_json = \"\(legacyLLMRoot)/account-cli/codex/legacy/model-catalog.json\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        try #"{"path":"\#(legacyLLMRoot)/account-cli/claude/legacy/.claude/plugins/marketplace.json"}"#
            .write(to: marketplacesURL, atomically: true, encoding: .utf8)
        try #"{"cache":"\#(legacyCodexRoot)/isolated-codex-instances/legacy/vendor_imports"}"#
            .write(to: skillsCacheURL, atomically: true, encoding: .utf8)
        try #"{"untouched":"\#(legacyLLMRoot)/logs/history.json"}"#
            .write(to: unrelatedURL, atomically: true, encoding: .utf8)

        let didRepair = try AppSupportPathRepairer(fileManager: fileManager).repairLegacyAbsolutePaths(in: appSupportURL)

        XCTAssertTrue(didRepair)
        XCTAssertEqual(try String(contentsOf: wrapperURL, encoding: .utf8).contains(legacyLLMRoot), false)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8).contains(legacyLLMRoot), false)
        XCTAssertEqual(try String(contentsOf: marketplacesURL, encoding: .utf8).contains(legacyLLMRoot), false)
        XCTAssertEqual(try String(contentsOf: skillsCacheURL, encoding: .utf8).contains(legacyCodexRoot), false)
        XCTAssertTrue(try String(contentsOf: wrapperURL, encoding: .utf8).contains(appSupportURL.path))
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains(appSupportURL.path))
        XCTAssertTrue(try String(contentsOf: marketplacesURL, encoding: .utf8).contains(appSupportURL.path))
        XCTAssertTrue(try String(contentsOf: skillsCacheURL, encoding: .utf8).contains(appSupportURL.path))
        XCTAssertTrue(try String(contentsOf: unrelatedURL, encoding: .utf8).contains(legacyLLMRoot))
    }

    func testRepairLegacyAbsolutePathsPreservesBinClaudePermissions() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let appSupportURL = rootURL.appendingPathComponent("Orbit", isDirectory: true)
        let legacyLLMRoot = rootURL.appendingPathComponent("LLMAccountSwitcher", isDirectory: true).path
        let wrapperURL = appSupportURL
            .appendingPathComponent("claude-patched-runtimes", isDirectory: true)
            .appendingPathComponent("2.1.87", isDirectory: true)
            .appendingPathComponent("hash", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)

        try fileManager.createDirectory(at: wrapperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexec node \"\(legacyLLMRoot)/claude-patched-runtimes/2.1.87/hash/package/cli.js\"\n"
            .write(to: wrapperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        _ = try AppSupportPathRepairer(fileManager: fileManager).repairLegacyAbsolutePaths(in: appSupportURL)

        let permissions = try XCTUnwrap(
            try fileManager.attributesOfItem(atPath: wrapperURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o755)
    }
}
