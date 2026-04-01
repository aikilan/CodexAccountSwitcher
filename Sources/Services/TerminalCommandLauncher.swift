import Foundation

enum TerminalCommandLauncherError: LocalizedError, Equatable {
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .appleScriptFailed(message):
            return L10n.tr("通过 Terminal 执行命令失败：%@", message)
        }
    }
}

struct TerminalCommandLauncher: @unchecked Sendable {
    private let runAppleScript: @Sendable ([String]) throws -> Void

    init(
        runAppleScript: @escaping @Sendable ([String]) throws -> Void = Self.runAppleScript
    ) {
        self.runAppleScript = runAppleScript
    }

    func launch(command: String) throws {
        try runAppleScript(
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"\(appleScriptEscaped(command))\"",
                "end tell",
            ]
        )
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ lines: [String]) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript", isDirectory: false)
        process.arguments = lines.flatMap { ["-e", $0] }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderr.isEmpty ? (stdout.isEmpty ? L10n.tr("未知错误") : stdout) : stderr
            throw TerminalCommandLauncherError.appleScriptFailed(message)
        }
    }
}

extension TerminalCommandLauncher: TerminalCommandLaunching {}
