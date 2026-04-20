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
    let effortLevel: String?

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
        let configURL = configDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = existing
        }

        object.removeValue(forKey: "logged_in_users")
        object.removeValue(forKey: "last_logged_in_user")
        object["loggedInUsers"] = [[
            "host": host,
            "login": login,
        ]]
        object["lastLoggedInUser"] = [
            "host": host,
            "login": login,
        ]
        object["banner"] = "never"
        if let defaultModel {
            object["model"] = defaultModel
        } else {
            object.removeValue(forKey: "model")
        }
        if let effortLevel {
            object["effortLevel"] = effortLevel
        } else {
            object.removeValue(forKey: "effortLevel")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: configURL,
            options: .atomic
        )
    }

    static func load(from configDirectoryURL: URL) throws -> CopilotCLIConfiguration {
        let configURL = configDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CopilotCLIConfigurationError.missingConfiguration
        }

        let data = try Data(contentsOf: configURL)
        guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotCLIConfigurationError.invalidConfiguration
        }
        let loggedInUsers = (file["loggedInUsers"] as? [Any]) ?? (file["logged_in_users"] as? [Any]) ?? []
        let lastLoggedInUser = file["lastLoggedInUser"] ?? file["last_logged_in_user"]
        guard
            let accountValue = account(from: lastLoggedInUser) ?? loggedInUsers.compactMap(account(from:)).first
        else {
            throw CopilotCLIConfigurationError.noLoggedInUser
        }

        let host = accountValue.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = accountValue.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !login.isEmpty else {
            throw CopilotCLIConfigurationError.invalidConfiguration
        }

        let defaultModel = (file["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortLevel = (file["effortLevel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CopilotCLIConfiguration(
            host: host,
            login: login,
            defaultModel: defaultModel?.isEmpty == false ? defaultModel : nil,
            effortLevel: effortLevel?.isEmpty == false ? effortLevel : nil
        )
    }
}

private extension CopilotCLIConfiguration {
    struct ConfigurationAccount: Equatable {
        let host: String
        let login: String
    }

    static func account(from value: Any?) -> ConfigurationAccount? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        let host = (object["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let login = (object["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty, !login.isEmpty else {
            return nil
        }
        return ConfigurationAccount(host: host, login: login)
    }
}
