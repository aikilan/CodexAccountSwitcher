import Foundation

struct UnimplementedCopilotResponsesBridgeManager: CopilotResponsesBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL
    ) async throws -> PreparedCopilotResponsesBridge {
        throw CopilotResponsesBridgeManagerError.bridgeStartFailed
    }
}
