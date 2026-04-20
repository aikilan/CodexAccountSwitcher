import XCTest
@testable import Orbit

final class CopilotManagedConfigManagerTests: XCTestCase {
    func testBootstrapClonesCurrentCLIStateWhenGlobalConfigMatches() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.cleanup() }

        let globalConfigDirectoryURL = fixture.homeDirectoryURL.appendingPathComponent(".copilot", isDirectory: true)
        try CopilotCLIConfiguration(
            host: "https://github.com",
            login: "aikilan",
            defaultModel: "gpt-4.1",
            effortLevel: "medium"
        ).write(to: globalConfigDirectoryURL)
        let sentinelURL = globalConfigDirectoryURL.appendingPathComponent("session-token", isDirectory: false)
        try Data("token".utf8).write(to: sentinelURL)

        let terminalLauncher = RecordingTerminalCommandLauncher()
        let manager = CopilotManagedConfigManager(
            paths: fixture.paths,
            terminalCommandLauncher: terminalLauncher,
            homeDirectoryURL: fixture.homeDirectoryURL,
            requestTimeout: .seconds(1),
            requestPollInterval: .milliseconds(10),
            probeStatus: { configDirectoryURL, _ in
                guard FileManager.default.fileExists(atPath: configDirectoryURL.appendingPathComponent("session-token").path) else {
                    throw CopilotACPClientError.requestFailed("not ready")
                }
                return CopilotACPStatusResult(availableModels: ["gpt-5.4"], currentModel: "gpt-5.4")
            }
        )

        let result = try await manager.bootstrap(
            accountID: fixture.accountID,
            credential: try CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                accessToken: "copilot_access_token",
                defaultModel: "gpt-4.1"
            ).validated(),
            model: "gpt-5.4",
            reasoningEffort: "xhigh"
        )

        XCTAssertEqual(result.credential.configDirectoryName, fixture.accountID.uuidString)
        XCTAssertTrue(terminalLauncher.commands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.configDirectoryURL.appendingPathComponent("session-token").path))

        let configuration = try CopilotCLIConfiguration.load(from: result.configDirectoryURL)
        XCTAssertEqual(configuration.host, "https://github.com")
        XCTAssertEqual(configuration.login, "aikilan")
        XCTAssertEqual(configuration.defaultModel, "gpt-5.4")
        XCTAssertEqual(configuration.effortLevel, "xhigh")
    }

    func testBootstrapRecognizesCurrentCopilotCLIConfigFormat() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.cleanup() }

        let globalConfigDirectoryURL = fixture.homeDirectoryURL.appendingPathComponent(".copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: globalConfigDirectoryURL, withIntermediateDirectories: true)
        try Data(
            """
            {
              "loggedInUsers": [
                {
                  "host": "https://github.com",
                  "login": "aikilan"
                }
              ],
              "lastLoggedInUser": {
                "host": "https://github.com",
                "login": "aikilan"
              },
              "model": "gpt-4.1",
              "effortLevel": "medium"
            }
            """.utf8
        ).write(to: globalConfigDirectoryURL.appendingPathComponent("config.json"))
        let sentinelURL = globalConfigDirectoryURL.appendingPathComponent("session-token", isDirectory: false)
        try Data("token".utf8).write(to: sentinelURL)

        let terminalLauncher = RecordingTerminalCommandLauncher()
        let manager = CopilotManagedConfigManager(
            paths: fixture.paths,
            terminalCommandLauncher: terminalLauncher,
            homeDirectoryURL: fixture.homeDirectoryURL,
            requestTimeout: .seconds(1),
            requestPollInterval: .milliseconds(10),
            probeStatus: { configDirectoryURL, _ in
                guard FileManager.default.fileExists(atPath: configDirectoryURL.appendingPathComponent("session-token").path) else {
                    throw CopilotACPClientError.requestFailed("not ready")
                }
                return CopilotACPStatusResult(availableModels: ["gpt-5.4"], currentModel: "gpt-5.4")
            }
        )

        let result = try await manager.bootstrap(
            accountID: fixture.accountID,
            credential: try CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                accessToken: "copilot_access_token",
                defaultModel: "gpt-4.1"
            ).validated(),
            model: "gpt-5.4",
            reasoningEffort: "xhigh"
        )

        XCTAssertTrue(terminalLauncher.commands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.configDirectoryURL.appendingPathComponent("session-token").path))

        let data = try Data(contentsOf: result.configDirectoryURL.appendingPathComponent("config.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["loggedInUsers"])
        XCTAssertNotNil(object["lastLoggedInUser"])
        XCTAssertNil(object["logged_in_users"])
        XCTAssertNil(object["last_logged_in_user"])
    }

    func testBootstrapLaunchesCLIWhenGlobalConfigDoesNotMatch() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.cleanup() }

        let globalConfigDirectoryURL = fixture.homeDirectoryURL.appendingPathComponent(".copilot", isDirectory: true)
        try CopilotCLIConfiguration(
            host: "https://github.com",
            login: "other-user",
            defaultModel: "gpt-4.1",
            effortLevel: "medium"
        ).write(to: globalConfigDirectoryURL)

        let readySignal = ManagedAtomicFlag()
        let terminalLauncher = RecordingTerminalCommandLauncher { _ in
            readySignal.setReady()
        }
        let manager = CopilotManagedConfigManager(
            paths: fixture.paths,
            terminalCommandLauncher: terminalLauncher,
            homeDirectoryURL: fixture.homeDirectoryURL,
            requestTimeout: .seconds(1),
            requestPollInterval: .milliseconds(10),
            probeStatus: { configDirectoryURL, _ in
                guard readySignal.isReady else {
                    throw CopilotACPClientError.requestFailed("not ready")
                }
                guard FileManager.default.fileExists(atPath: configDirectoryURL.appendingPathComponent("config.json").path) else {
                    throw CopilotACPClientError.requestFailed("missing config")
                }
                return CopilotACPStatusResult(availableModels: ["gpt-5.4"], currentModel: "gpt-5.4")
            }
        )

        let result = try await manager.bootstrap(
            accountID: fixture.accountID,
            credential: try CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                accessToken: "copilot_access_token"
            ).validated(),
            model: "gpt-5.4",
            reasoningEffort: "high"
        )

        XCTAssertEqual(terminalLauncher.commands.count, 1)
        XCTAssertTrue(terminalLauncher.commands[0].contains("copilot login"))
        XCTAssertTrue(terminalLauncher.commands[0].contains("--config-dir"))
        XCTAssertTrue(terminalLauncher.commands[0].contains("--host"))

        let configuration = try CopilotCLIConfiguration.load(from: result.configDirectoryURL)
        XCTAssertEqual(configuration.login, "aikilan")
        XCTAssertEqual(configuration.defaultModel, "gpt-5.4")
        XCTAssertEqual(configuration.effortLevel, "high")
    }

    func testCLIConfigurationRoundTripsEffortLevel() throws {
        let fixture = try makeFixture()
        defer { try? fixture.cleanup() }

        let configDirectoryURL = fixture.paths.copilotManagedConfigDirectoryURL(named: "roundtrip")
        try CopilotCLIConfiguration(
            host: "https://github.com",
            login: "aikilan",
            defaultModel: "gpt-5.4",
            effortLevel: "xhigh"
        ).write(to: configDirectoryURL)

        let configuration = try CopilotCLIConfiguration.load(from: configDirectoryURL)
        XCTAssertEqual(configuration.host, "https://github.com")
        XCTAssertEqual(configuration.login, "aikilan")
        XCTAssertEqual(configuration.defaultModel, "gpt-5.4")
        XCTAssertEqual(configuration.effortLevel, "xhigh")
    }
}

private extension CopilotManagedConfigManagerTests {
    struct Fixture {
        let rootURL: URL
        let homeDirectoryURL: URL
        let paths: AppPaths
        let accountID: UUID

        func cleanup() throws {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
        }
    }

    func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDirectoryURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)
        let appSupportURL = rootURL.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHomeURL,
            appSupportOverride: appSupportURL
        )
        return Fixture(
            rootURL: rootURL,
            homeDirectoryURL: homeDirectoryURL,
            paths: paths,
            accountID: UUID()
        )
    }
}

private final class RecordingTerminalCommandLauncher: @unchecked Sendable, TerminalCommandLaunching {
    private let onLaunch: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var storedCommands = [String]()

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    init(onLaunch: (@Sendable (String) -> Void)? = nil) {
        self.onLaunch = onLaunch
    }

    func launch(command: String) throws {
        lock.lock()
        storedCommands.append(command)
        lock.unlock()
        onLaunch?(command)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func setReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }
}
