import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class CodexCLILauncherTests: XCTestCase {
    func testLaunchCLIGlobalModeRunsPlainCodexCommand() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let workingDirectoryURL = rootURL.appendingPathComponent("workspace", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedCodexCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                mode: .globalCurrentAuth,
                codexHomeURL: nil,
                authPayload: nil,
                configFileContents: nil,
                environmentVariables: [:],
                arguments: []
            )
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIIsolatedModeWritesAuthAndRunsWithIsolatedCodexHome() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let payload = makePayload(accountID: "acct_cli", refreshToken: "refresh_cli")
        let workingDirectoryURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedCodexCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: payload,
                configFileContents: "model = \"gpt-5.4\"\n",
                environmentVariables: ["OPENROUTER_API_KEY": "sk-or-test"],
                arguments: []
            )
        )

        let savedPayload = try XCTUnwrap(
            try AuthFileManager(authFileURL: codexHomeURL.appendingPathComponent("auth.json")).readCurrentAuth()
        )
        XCTAssertEqual(savedPayload, payload)
        XCTAssertEqual(
            try String(contentsOf: codexHomeURL.appendingPathComponent("config.toml")),
            "model = \"gpt-5.4\"\n"
        )
        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env CODEX_HOME=\\\"\(codexHomeURL.path)\\\" OPENROUTER_API_KEY=\\\"sk-or-test\\\" codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIPropagatesAppleScriptFailure() {
        let fileManager = FileManager.default
        let appSupport = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { _ in
                throw TestError.appleScriptFailed
            }
        )

        XCTAssertThrowsError(
            try launcher.launchCLI(
                context: ResolvedCodexCLILaunchContext(
                    accountID: UUID(),
                    workingDirectoryURL: appSupport,
                    mode: .globalCurrentAuth,
                    codexHomeURL: nil,
                    authPayload: nil,
                    configFileContents: nil,
                    environmentVariables: [:],
                    arguments: []
                )
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .appleScriptFailed)
        }
    }

    private func makePayload(accountID: String, refreshToken: String) -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id_\(accountID)",
                accessToken: "access_\(accountID)",
                refreshToken: refreshToken,
                accountID: accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }
}

private enum TestError: Error, Equatable {
    case appleScriptFailed
}
