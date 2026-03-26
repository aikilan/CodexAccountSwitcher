import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class ClaudeCLILauncherTests: XCTestCase {
    func testLaunchCLIAnthropicModeUsesFixedBinaryAndInjectsEnvironment() throws {
        let fileManager = LauncherTestFileManager()
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileManager.mockHomeDirectory = homeURL
        fileManager.executablePaths.insert(
            homeURL
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("claude")
                .path
        )

        var capturedLines: [String] = []
        let launcher = ClaudeCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )

        let rootURL = homeURL.appendingPathComponent("isolated-root", isDirectory: true)
        let workingDirectoryURL = homeURL.appendingPathComponent("workspace", isDirectory: true)

        try launcher.launchCLI(
            for: ManagedAccount(
                id: UUID(),
                platform: .claude,
                codexAccountID: "claude-test",
                displayName: "Claude Test",
                email: nil,
                authMode: .anthropicAPIKey,
                createdAt: Date(),
                lastUsedAt: nil,
                lastQuotaSnapshotAt: nil,
                lastRefreshAt: nil,
                planType: nil,
                lastStatusCheckAt: nil,
                lastStatusMessage: nil,
                lastStatusLevel: nil,
                isActive: false
            ),
            mode: .anthropicAPIKey(
                rootURL: rootURL,
                credential: try AnthropicAPIKeyCredential(apiKey: "sk-ant-test").validated()
            ),
            workingDirectoryURL: workingDirectoryURL
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env HOME=\\\"\(rootURL.path)\\\" CLAUDE_CONFIG_DIR=\\\"\(rootURL.appendingPathComponent(".claude").path)\\\" ANTHROPIC_API_KEY=\\\"sk-ant-test\\\" \\\"\(homeURL.appendingPathComponent(".local/bin/claude").path)\\\"\"",
                "end tell",
            ]
        )
    }
}

private final class LauncherTestFileManager: FileManager {
    var mockHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var executablePaths: Set<String> = []

    override var homeDirectoryForCurrentUser: URL {
        mockHomeDirectory
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
