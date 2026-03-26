import Foundation

enum ClaudeAPIClientError: LocalizedError, Equatable {
    case invalidResponse
    case invalidRateLimitHeaders
    case httpFailure(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.tr("Anthropic 接口返回的数据结构无效。")
        case .invalidRateLimitHeaders:
            return L10n.tr("Anthropic 接口没有返回可解析的限额头。")
        case let .httpFailure(code, body):
            return L10n.tr("Anthropic 接口返回 %d：%@", code, body)
        }
    }
}

struct ClaudeAPIClientConfiguration: Sendable {
    var baseURL = URL(string: "https://api.anthropic.com")!
    var version = "2023-06-01"
    var modelsPath = "/v1/models"
    var messagesPath = "/v1/messages"
    var fallbackModel = "claude-3-5-haiku-latest"
}

final class ClaudeAPIClient: @unchecked Sendable {
    private let configuration: ClaudeAPIClientConfiguration
    private let session: URLSession

    init(
        configuration: ClaudeAPIClientConfiguration = ClaudeAPIClientConfiguration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func probeStatus(using credential: AnthropicAPIKeyCredential) async throws -> ClaudeRateLimitSnapshot {
        let validatedCredential = try credential.validated()
        let modelsURL = configuration.baseURL.appending(path: configuration.modelsPath)
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.httpMethod = "GET"
        applyHeaders(to: &modelsRequest, apiKey: validatedCredential.apiKey)

        let (modelsData, modelsResponse) = try await session.data(for: modelsRequest)
        let modelsHTTPResponse = try validateHTTP(response: modelsResponse, data: modelsData)
        let modelIDs = parseModels(from: modelsData)
        let modelsSnapshot = snapshot(from: modelsHTTPResponse, capturedAt: Date())

        if modelsSnapshot.hasAnyValue {
            return modelsSnapshot
        }

        let selectedModel = preferredModel(from: modelIDs) ?? configuration.fallbackModel
        return try await probeMessages(apiKey: validatedCredential.apiKey, modelID: selectedModel)
    }

    private func probeMessages(apiKey: String, modelID: String) async throws -> ClaudeRateLimitSnapshot {
        let requestURL = configuration.baseURL.appending(path: configuration.messagesPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "max_tokens": 1,
            "messages": [
                [
                    "role": "user",
                    "content": "ping",
                ],
            ],
        ])

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validateHTTP(response: response, data: data)
        let snapshot = snapshot(from: httpResponse, capturedAt: Date())
        guard snapshot.hasAnyValue else {
            throw ClaudeAPIClientError.invalidRateLimitHeaders
        }
        return snapshot
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.version, forHTTPHeaderField: "anthropic-version")
    }

    private func validateHTTP(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeAPIClientError.httpFailure(httpResponse.statusCode, body)
        }
        return httpResponse
    }

    private func parseModels(from data: Data) -> [String] {
        guard let payload = try? JSONDecoder().decode(ClaudeModelListResponse.self, from: data) else {
            return []
        }
        return payload.data.map(\.id)
    }

    private func preferredModel(from modelIDs: [String]) -> String? {
        let preferredCandidates = [
            configuration.fallbackModel,
            "claude-3-5-haiku-20241022",
            "claude-3-haiku-20240307",
        ]

        for candidate in preferredCandidates where modelIDs.contains(candidate) {
            return candidate
        }

        return modelIDs.first
    }

    private func snapshot(from response: HTTPURLResponse, capturedAt: Date) -> ClaudeRateLimitSnapshot {
        let headers: [String: String] = Dictionary(
            uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key.lowercased(), String(describing: value))
            }
        )

        return ClaudeRateLimitSnapshot(
            requests: ClaudeRateLimitValueSnapshot(
                limit: parseInt(headers["anthropic-ratelimit-requests-limit"]),
                remaining: parseInt(headers["anthropic-ratelimit-requests-remaining"]),
                resetAt: parseDate(headers["anthropic-ratelimit-requests-reset"])
            ),
            inputTokens: ClaudeRateLimitValueSnapshot(
                limit: parseInt(headers["anthropic-ratelimit-input-tokens-limit"]),
                remaining: parseInt(headers["anthropic-ratelimit-input-tokens-remaining"]),
                resetAt: parseDate(headers["anthropic-ratelimit-input-tokens-reset"])
            ),
            outputTokens: ClaudeRateLimitValueSnapshot(
                limit: parseInt(headers["anthropic-ratelimit-output-tokens-limit"]),
                remaining: parseInt(headers["anthropic-ratelimit-output-tokens-remaining"]),
                resetAt: parseDate(headers["anthropic-ratelimit-output-tokens-reset"])
            ),
            capturedAt: capturedAt,
            source: .onlineUsageRefresh
        )
    }

    private func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension ClaudeAPIClient: ClaudeAPIClienting {}

private struct ClaudeModelListResponse: Decodable {
    let data: [ClaudeModel]

    struct ClaudeModel: Decodable {
        let id: String
    }
}

private extension ClaudeRateLimitSnapshot {
    var hasAnyValue: Bool {
        [requests, inputTokens, outputTokens].contains { snapshot in
            snapshot.limit != nil || snapshot.remaining != nil || snapshot.resetAt != nil
        }
    }
}
