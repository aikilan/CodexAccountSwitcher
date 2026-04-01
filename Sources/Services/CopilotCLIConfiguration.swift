import Foundation

enum CopilotCLIConfigurationError: LocalizedError, Equatable {
    case missingConfiguration
    case noLoggedInUser
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return L10n.tr("未找到 GitHub Copilot 的 config.json。")
        case .noLoggedInUser:
            return L10n.tr("当前 Copilot 配置目录里没有已登录账号。")
        case .invalidConfiguration:
            return L10n.tr("GitHub Copilot 的配置格式无效。")
        }
    }
}

struct CopilotCLIConfiguration: Equatable, Sendable {
    let host: String
    let login: String
    let defaultModel: String?

    static func defaultConfigDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".copilot", isDirectory: true)
    }

    func makeCredential(configDirectoryName: String) throws -> CopilotCredential {
        try CopilotCredential(
            configDirectoryName: configDirectoryName,
            host: host,
            login: login,
            defaultModel: defaultModel
        ).validated()
    }

    func write(to configDirectoryURL: URL) throws {
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            ConfigurationFile(
                loggedInUsers: [ConfigurationAccount(host: host, login: login)],
                lastLoggedInUser: ConfigurationAccount(host: host, login: login),
                model: defaultModel
            )
        )
        try data.write(
            to: configDirectoryURL.appendingPathComponent("config.json", isDirectory: false),
            options: .atomic
        )
    }

    static func load(from configDirectoryURL: URL) throws -> CopilotCLIConfiguration {
        let configURL = configDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CopilotCLIConfigurationError.missingConfiguration
        }

        let data = try Data(contentsOf: configURL)
        let file = try JSONDecoder().decode(ConfigurationFile.self, from: data)
        guard let account = file.lastLoggedInUser ?? file.loggedInUsers.first else {
            throw CopilotCLIConfigurationError.noLoggedInUser
        }

        let host = account.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = account.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !login.isEmpty else {
            throw CopilotCLIConfigurationError.invalidConfiguration
        }

        let defaultModel = file.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CopilotCLIConfiguration(
            host: host,
            login: login,
            defaultModel: defaultModel?.isEmpty == false ? defaultModel : nil
        )
    }
}

private extension CopilotCLIConfiguration {
    struct ConfigurationAccount: Codable, Equatable {
        let host: String
        let login: String
    }

    struct ConfigurationFile: Codable, Equatable {
        let loggedInUsers: [ConfigurationAccount]
        let lastLoggedInUser: ConfigurationAccount?
        let model: String?

        private enum CodingKeys: String, CodingKey {
            case loggedInUsers = "logged_in_users"
            case lastLoggedInUser = "last_logged_in_user"
            case model
        }
    }
}
