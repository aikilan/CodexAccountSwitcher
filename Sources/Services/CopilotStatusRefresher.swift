import Foundation

struct CopilotStatusRefresher {
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus {
        let configDirectoryURL = paths.copilotManagedConfigDirectoryURL(named: credential.configDirectoryName)
        try CopilotCLIConfiguration(
            host: credential.host,
            login: credential.login,
            defaultModel: credential.defaultModel
        ).write(to: configDirectoryURL)
        let status = try await CopilotACPClient(configDirectoryURL: configDirectoryURL).fetchStatus(
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        return CopilotAccountStatus(
            availableModels: status.availableModels,
            currentModel: status.currentModel,
            quotaSnapshot: nil
        )
    }
}

extension CopilotStatusRefresher: CopilotStatusRefreshing {}
