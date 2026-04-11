import AppKit
import Foundation

enum SwitchVerificationIssue: Equatable, Sendable {
    case refreshTokenReused
    case generic(String)
}

enum SwitchVerificationResult: Equatable, Sendable {
    case noRunningClient
    case verified
    case restartRecommended
    case authError(SwitchVerificationIssue)
}

enum CodexRuntimeInspectorError: LocalizedError, Equatable {
    case applicationNotFound
    case gracefulShutdownTimedOut
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return L10n.tr("没有找到本机安装的 Codex.app。")
        case .gracefulShutdownTimedOut:
            return L10n.tr("Codex 没有在预期时间内退出。")
        case let .relaunchFailed(message):
            return L10n.tr("Codex 重新拉起失败：%@", message)
        }
    }
}

struct RunningCodexApplication: Sendable {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let terminate: @Sendable () -> Bool
}

final class CodexRuntimeInspector: @unchecked Sendable {
    private static let bundleIdentifier = "com.openai.codex"
    private static let isolatedInstancesDirectoryName = "isolated-codex-instances"

    private let logReader: SQLiteLogReader
    private let runningApplications: @Sendable () async -> [RunningCodexApplication]
    private let resolveApplicationURL: @Sendable () async -> URL?
    private let isIsolatedApplication: @Sendable (pid_t) async -> Bool
    private let openApplication: @Sendable (URL, [String: String]) async throws -> Void

    init(logReader: SQLiteLogReader) {
        self.logReader = logReader
        self.runningApplications = {
            await Self.liveRunningApplications()
        }
        self.resolveApplicationURL = {
            await Self.mainApplicationURL()
        }
        self.isIsolatedApplication = Self.isolatedApplication
        self.openApplication = { appURL, launchEnvironment in
            try await Self.openMainApplication(at: appURL, launchEnvironment: launchEnvironment)
        }
    }

    init(
        logReader: SQLiteLogReader,
        runningApplications: @escaping @Sendable () async -> [RunningCodexApplication],
        resolveApplicationURL: @escaping @Sendable () async -> URL?,
        isIsolatedApplication: @escaping @Sendable (pid_t) async -> Bool,
        openApplication: @escaping @Sendable (URL, [String: String]) async throws -> Void
    ) {
        self.logReader = logReader
        self.runningApplications = runningApplications
        self.resolveApplicationURL = resolveApplicationURL
        self.isIsolatedApplication = isIsolatedApplication
        self.openApplication = openApplication
    }

    convenience init(
        logReader: SQLiteLogReader,
        isRunningClient: @escaping @Sendable () -> Bool
    ) {
        self.init(
            logReader: logReader,
            runningApplications: {
                isRunningClient()
                    ? [RunningCodexApplication(processIdentifier: 0, bundleURL: nil, terminate: { true })]
                    : []
            },
            resolveApplicationURL: { nil },
            isIsolatedApplication: { _ in false },
            openApplication: { _, _ in }
        )
    }

    func hasRunningMainApplication() async -> Bool {
        !(await runningMainApplications()).isEmpty
    }

    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval = 6) async -> SwitchVerificationResult {
        guard await hasRunningMainApplication() else {
            return .noRunningClient
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let authError = logReader.latestAuthError(after: date) {
                switch authError.kind {
                case .authErrorRefreshTokenReused:
                    return .authError(.refreshTokenReused)
                case .authError:
                    return .authError(.generic(authError.message))
                default:
                    break
                }
            }

            if let signal = logReader.latestRelevantSignal(after: date) {
                switch signal.kind {
                case .rateLimitsUpdated, .authReloadCompleted:
                    return .verified
                case .authReloadStarted:
                    break
                default:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        return .restartRecommended
    }

    func restartCodex(launchEnvironment: [String: String]) async throws {
        let runningApps = await runningApplications()
        let mainApps = await runningMainApplications(from: runningApps)
        let fallbackApplicationURL = await resolveApplicationURL()
        guard
            let appURL = mainApps.first?.bundleURL
                ?? runningApps.first?.bundleURL
                ?? fallbackApplicationURL
        else {
            throw CodexRuntimeInspectorError.applicationNotFound
        }

        for app in mainApps {
            await MainActor.run {
                _ = app.terminate()
            }
        }

        if !mainApps.isEmpty {
            let deadline = Date().addingTimeInterval(5)
            while await hasRunningMainApplication(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard !(await hasRunningMainApplication()) else {
                throw CodexRuntimeInspectorError.gracefulShutdownTimedOut
            }
        }

        try await openApplication(appURL, launchEnvironment)
    }

    private func runningMainApplications() async -> [RunningCodexApplication] {
        let applications = await runningApplications()
        return await runningMainApplications(from: applications)
    }

    private func runningMainApplications(from applications: [RunningCodexApplication]) async -> [RunningCodexApplication] {
        var mainApplications: [RunningCodexApplication] = []
        mainApplications.reserveCapacity(applications.count)

        for application in applications {
            if !(await isIsolatedApplication(application.processIdentifier)) {
                mainApplications.append(application)
            }
        }

        return mainApplications
    }

    @MainActor
    private static func liveRunningApplications() -> [RunningCodexApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map { app in
            RunningCodexApplication(
                processIdentifier: app.processIdentifier,
                bundleURL: app.bundleURL,
                terminate: { app.terminate() }
            )
        }
    }

    @MainActor
    private static func mainApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private static func isolatedApplication(processIdentifier: pid_t) async -> Bool {
        guard let commandLine = await processCommandLine(for: processIdentifier) else {
            return false
        }

        return commandLine.contains("--user-data-dir=")
            && commandLine.contains("/\(isolatedInstancesDirectoryName)/")
    }

    private static func processCommandLine(for processIdentifier: pid_t) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-ww", "-o", "command=", "-p", String(processIdentifier)]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return nil
            }

            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let output, !output.isEmpty else {
                return nil
            }

            return output
        }.value
    }

    private static func openMainApplication(at appURL: URL, launchEnvironment: [String: String]) async throws {
        if launchEnvironment.isEmpty {
            try await openMainApplicationViaWorkspace(at: appURL)
        } else {
            try await launchMainApplicationProcess(at: appURL, launchEnvironment: launchEnvironment)
        }
    }

    @MainActor
    private static func openMainApplicationViaWorkspace(at appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completionHandler = openMainApplicationCompletionHandler(continuation: continuation)
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration,
                completionHandler: completionHandler
            )
        }
    }

    private static func launchMainApplicationProcess(at appURL: URL, launchEnvironment: [String: String]) async throws {
        let executableURL = executableURL(for: appURL)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launchEnvironment {
            environment[key] = value
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexRuntimeInspectorError.relaunchFailed(error.localizedDescription)
        }
    }

    private static func executableURL(for appURL: URL) -> URL {
        if let executableURL = Bundle(url: appURL)?.executableURL {
            return URL(fileURLWithPath: executableURL.path)
        }

        let executableName = appURL.deletingPathExtension().lastPathComponent
        return appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    static func openMainApplicationCompletionHandler(
        continuation: CheckedContinuation<Void, Error>
    ) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { _, error in
            if let error {
                continuation.resume(throwing: CodexRuntimeInspectorError.relaunchFailed(error.localizedDescription))
            } else {
                continuation.resume(returning: ())
            }
        }
    }
}

extension CodexRuntimeInspector: CodexRuntimeInspecting {}
