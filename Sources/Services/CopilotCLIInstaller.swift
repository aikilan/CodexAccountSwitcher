import Foundation

enum CopilotCLIInstallerError: LocalizedError, Equatable {
    case npmUnavailable
    case cliUnavailableAfterInstall
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .npmUnavailable:
            return L10n.tr("未找到 npm。请先安装 Node.js/npm 后再重试。")
        case .cliUnavailableAfterInstall:
            return L10n.tr("GitHub Copilot CLI 已安装，但当前 shell 仍无法找到 `copilot` 命令。")
        case let .installFailed(message):
            return message
        }
    }
}

struct CopilotCLIInstaller: CopilotCLIInstalling, @unchecked Sendable {
    func installCLI() async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.runInstall()
        }.value
    }

    private static func runInstall() throws {
        let fileManager = FileManager.default
        let processInfo = ProcessInfo.processInfo
        let shellPath = processInfo.environment["SHELL"].flatMap {
            fileManager.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath, isDirectory: false)
        process.arguments = [
            "-lic",
            """
            set -e
            if ! command -v npm >/dev/null 2>&1; then
              exit 127
            fi
            npm install -g @github/copilot@latest
            command -v copilot >/dev/null 2>&1 || exit 126
            """,
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderr.isEmpty ? stdout : stderr

            switch process.terminationStatus {
            case 127:
                throw CopilotCLIInstallerError.npmUnavailable
            case 126:
                throw CopilotCLIInstallerError.cliUnavailableAfterInstall
            default:
                throw CopilotCLIInstallerError.installFailed(
                    message.isEmpty ? L10n.tr("GitHub Copilot CLI 安装失败。") : message
                )
            }
        }
    }
}
