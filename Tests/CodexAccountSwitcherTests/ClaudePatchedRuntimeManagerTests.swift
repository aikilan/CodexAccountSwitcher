import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class ClaudePatchedRuntimeManagerTests: XCTestCase {
    func testPreparePatchedRuntimeCopiesPackageAndAppliesPatches() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let sourceCLIURL = try makeSourceRuntime(
            rootURL: rootURL,
            version: "2.1.85"
        )
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let manager = ClaudePatchedRuntimeManager(
            fileManager: fileManager,
            resolveClaudeExecutableURL: { sourceCLIURL }
        )

        let runtimeURL = try manager.preparePatchedRuntime(
            model: "openrouter/anthropic/claude-sonnet-4.5",
            appSupportDirectoryURL: appSupportURL
        )

        let wrapperContents = try String(contentsOf: runtimeURL, encoding: .utf8)
        let patchedCLIURL = runtimeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package", isDirectory: true)
            .appendingPathComponent("cli.js", isDirectory: false)
        let patchedCLIContents = try String(contentsOf: patchedCLIURL, encoding: .utf8)

        XCTAssertTrue(fileManager.isExecutableFile(atPath: runtimeURL.path))
        XCTAssertTrue(wrapperContents.contains("package/cli.js"))
        XCTAssertTrue(wrapperContents.contains("/node"))
        XCTAssertTrue(patchedCLIContents.contains("ANTHROPIC_CUSTOM_MODEL_OPTION"))
        XCTAssertTrue(patchedCLIContents.contains(".string().optional()"))
        XCTAssertTrue(patchedCLIContents.contains("typeof K===\"string\""))
        XCTAssertTrue(patchedCLIContents.contains("CLAUDE_CODE_CONTEXT_LIMIT"))
    }

    func testPreparePatchedRuntimeCachesByVersionAndModel() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let sourceV1CLIURL = try makeSourceRuntime(rootURL: rootURL, version: "2.1.85")
        let sourceV2CLIURL = try makeSourceRuntime(rootURL: rootURL, version: "2.1.86")
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let managerV1 = ClaudePatchedRuntimeManager(
            fileManager: fileManager,
            resolveClaudeExecutableURL: { sourceV1CLIURL }
        )
        let managerV2 = ClaudePatchedRuntimeManager(
            fileManager: fileManager,
            resolveClaudeExecutableURL: { sourceV2CLIURL }
        )

        let runtimeV1 = try managerV1.preparePatchedRuntime(
            model: "openrouter/anthropic/claude-sonnet-4.5",
            appSupportDirectoryURL: appSupportURL
        )
        let runtimeV1Repeat = try managerV1.preparePatchedRuntime(
            model: "openrouter/anthropic/claude-sonnet-4.5",
            appSupportDirectoryURL: appSupportURL
        )
        let runtimeV2 = try managerV2.preparePatchedRuntime(
            model: "openrouter/anthropic/claude-sonnet-4.5",
            appSupportDirectoryURL: appSupportURL
        )

        XCTAssertEqual(runtimeV1, runtimeV1Repeat)
        XCTAssertNotEqual(runtimeV1, runtimeV2)
    }

    func testPreparePatchedRuntimeSupportsInlineAgentModelEnumShape() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appendingPathComponent("2.1.85-inline", isDirectory: true)
            .appendingPathComponent("claude-code", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let cliURL = packageURL.appendingPathComponent("cli.js", isDirectory: false)
        let nodeURL = packageURL.appendingPathComponent("node", isDirectory: false)
        let packageJSONURL = packageURL.appendingPathComponent("package.json", isDirectory: false)
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        try """
        #!/usr/bin/env node
        function O7(){return{}}
        function mj8(q){return q}
        function P66(q){let K=O7()||{availableModels:[]};return!0}
        function sample(){return h.object({subagent_type:h.string().optional(),model:h.enum(["sonnet","opus","haiku"]).optional().describe("Optional model override for this agent. Takes precedence over the agent definition's model frontmatter. If omitted, uses the agent definition's model, or inherits from the parent."),run_in_background:h.boolean().optional()})}
        var af1=200000,sF4=20000;
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: nodeURL, atomically: true, encoding: .utf8)
        try """
        {
          "name": "@anthropic-ai/claude-code",
          "version": "2.1.85"
        }
        """.write(to: packageJSONURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodeURL.path)

        let manager = ClaudePatchedRuntimeManager(
            fileManager: fileManager,
            resolveClaudeExecutableURL: { cliURL }
        )

        let runtimeURL = try manager.preparePatchedRuntime(
            model: "gpt-5.4",
            appSupportDirectoryURL: appSupportURL
        )
        let patchedCLIURL = runtimeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package", isDirectory: true)
            .appendingPathComponent("cli.js", isDirectory: false)
        let patchedCLIContents = try String(contentsOf: patchedCLIURL, encoding: .utf8)

        XCTAssertTrue(patchedCLIContents.contains("model:h.string().optional().describe(\"Optional model override for this agent."))
        XCTAssertTrue(patchedCLIContents.contains("ANTHROPIC_CUSTOM_MODEL_OPTION"))
        XCTAssertTrue(patchedCLIContents.contains("CLAUDE_CODE_CONTEXT_LIMIT"))
    }

    private func makeSourceRuntime(rootURL: URL, version: String) throws -> URL {
        let fileManager = FileManager.default
        let packageURL = rootURL
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("claude-code", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let cliURL = packageURL.appendingPathComponent("cli.js", isDirectory: false)
        let nodeURL = packageURL.appendingPathComponent("node", isDirectory: false)
        let packageJSONURL = packageURL.appendingPathComponent("package.json", isDirectory: false)

        try """
        #!/usr/bin/env node
        function O7(){return{}}
        function mj8(q){return q}
        function P66(q){let K=O7()||{availableModels:[]};return!0}
        function sample(){return {schema:{foo:1,model:u.enum(oEH).optional()}}}
        );let J=K&&typeof K==="string"&&oEH.includes(K)
        var af1=200000,sF4=20000;
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: nodeURL, atomically: true, encoding: .utf8)
        try """
        {
          "name": "@anthropic-ai/claude-code",
          "version": "\(version)"
        }
        """.write(to: packageJSONURL, atomically: true, encoding: .utf8)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodeURL.path)

        return cliURL
    }
}
