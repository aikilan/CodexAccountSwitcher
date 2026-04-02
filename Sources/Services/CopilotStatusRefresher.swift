import Foundation

struct CopilotStatusRefresher {
    private let provider: any CopilotProviderServing

    init(provider: any CopilotProviderServing) {
        self.provider = provider
    }

    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus {
        try await provider.fetchStatus(using: credential)
    }
}

extension CopilotStatusRefresher: CopilotStatusRefreshing {}
