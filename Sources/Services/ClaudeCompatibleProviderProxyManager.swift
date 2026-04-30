import Foundation
import Network

enum ClaudeCompatibleProviderProxyManagerError: LocalizedError, Equatable {
    case proxyStartFailed
    case invalidProvider

    var errorDescription: String? {
        switch self {
        case .proxyStartFailed:
            return L10n.tr("Claude Provider 本地代理启动失败。")
        case .invalidProvider:
            return L10n.tr("Claude Provider 配置不完整。")
        }
    }
}

actor ClaudeCompatibleProviderProxyManager {
    private let sendUpstreamRequest: @Sendable (String, String, String, [String: String], Data) async throws -> (Int, Data)
    private var servers: [String: ClaudeCompatibleProviderProxyServer] = [:]

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, String, [String: String], Data) async throws -> (Int, Data) = ClaudeCompatibleProviderProxyManager.sendUpstreamRequest
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func prepareProxy(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) async throws -> PreparedClaudeCompatibleProviderProxy {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedAPIKey.isEmpty, !trimmedModel.isEmpty else {
            throw ClaudeCompatibleProviderProxyManagerError.invalidProvider
        }

        let server = servers[accountID.uuidString]
            ?? ClaudeCompatibleProviderProxyServer(sendUpstreamRequest: sendUpstreamRequest)
        server.update(
            baseURL: trimmedBaseURL,
            apiKeyEnvName: apiKeyEnvName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            model: trimmedModel,
            availableModels: availableModels,
            modelSettings: modelSettings
        )
        let localBaseURL = try await server.startIfNeeded()
        servers[accountID.uuidString] = server

        return PreparedClaudeCompatibleProviderProxy(
            baseURL: localBaseURL,
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "claude-compatible-provider-proxy"
        )
    }

    private static func sendUpstreamRequest(
        baseURL: String,
        apiKey: String,
        endpoint: String,
        headers: [String: String],
        body: Data
    ) async throws -> (Int, Data) {
        let requestURL = try upstreamURL(baseURL: baseURL, endpoint: endpoint)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var hasAnthropicVersion = false
        for (name, value) in headers where name.hasPrefix("anthropic-") && !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
            if name == "anthropic-version" {
                hasAnthropicVersion = true
            }
        }
        if !hasAnthropicVersion {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        if normalizedMiniMaxAnthropicBaseURL(baseURL, includeVersion: false) != nil {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 500, data)
    }

    private static func upstreamURL(baseURL: String, endpoint: String) throws -> URL {
        if let minimaxBaseURL = normalizedMiniMaxAnthropicBaseURL(baseURL, includeVersion: true) {
            return try validURL("\(minimaxBaseURL)/\(endpoint)")
        }
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try validURL("\(normalizedBaseURL)/\(endpoint)")
    }

    private static func validURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ClaudeCompatibleProviderProxyManagerError.invalidProvider
        }
        return url
    }
}

extension ClaudeCompatibleProviderProxyManager: ClaudeCompatibleProviderProxyManaging {}

private final class ClaudeCompatibleProviderProxyServer: @unchecked Sendable {
    private final class ResumeState: @unchecked Sendable {
        var didResume = false
    }

    private struct HTTPRequest {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data

        var path: String {
            String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
    }

    private struct HTTPResponse {
        let statusCode: Int
        let contentType: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "com.openai.Orbit.claude-compatible-provider-proxy")
    private let stateQueue = DispatchQueue(label: "com.openai.Orbit.claude-compatible-provider-proxy.state")
    private let sendUpstreamRequest: @Sendable (String, String, String, [String: String], Data) async throws -> (Int, Data)

    private var listener: NWListener?
    private var localBaseURL: String?
    private var upstreamBaseURL = ""
    private var apiKeyEnvName = "ANTHROPIC_API_KEY"
    private var apiKey = ""
    private var defaultModel = "claude-sonnet-4.5"
    private var availableModels = ["claude-sonnet-4.5"]
    private var modelSettings = [ProviderModelSettings(model: "claude-sonnet-4.5")]

    init(sendUpstreamRequest: @escaping @Sendable (String, String, String, [String: String], Data) async throws -> (Int, Data)) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func update(
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) {
        stateQueue.sync {
            self.upstreamBaseURL = baseURL
            self.apiKeyEnvName = apiKeyEnvName.isEmpty ? "ANTHROPIC_API_KEY" : apiKeyEnvName
            self.apiKey = apiKey
            self.defaultModel = model
            self.availableModels = normalizedAvailableModels(availableModels, fallbackModel: model)
            self.modelSettings = ProviderModelSettings.normalized(modelSettings, fallbackModel: model)
        }
    }

    func startIfNeeded() async throws -> String {
        if let localBaseURL = stateQueue.sync(execute: { self.localBaseURL }) {
            return localBaseURL
        }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeState()
            let resumeQueue = DispatchQueue(label: "com.openai.Orbit.claude-compatible-provider-proxy.resume")

            let resumeOnce: @Sendable (Result<String, Error>) -> Void = { result in
                resumeQueue.sync {
                    guard !resumeState.didResume else { return }
                    resumeState.didResume = true
                    switch result {
                    case let .success(baseURL):
                        continuation.resume(returning: baseURL)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        resumeOnce(.failure(ClaudeCompatibleProviderProxyManagerError.proxyStartFailed))
                        return
                    }
                    let localBaseURL = "http://127.0.0.1:\(port)"
                    self.stateQueue.sync {
                        self.localBaseURL = localBaseURL
                    }
                    resumeOnce(.success(localBaseURL))
                case .failed:
                    resumeOnce(.failure(ClaudeCompatibleProviderProxyManagerError.proxyStartFailed))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = parseRequest(from: nextBuffer) {
                Task { [weak self] in
                    guard let self else { return }
                    let response = await self.response(for: request)
                    self.send(response: response, through: connection)
                }
                return
            }

            if isComplete {
                send(response: jsonResponse(statusCode: 400, body: errorPayload(message: L10n.tr("Claude 请求格式无效。"))), through: connection)
                return
            }

            receive(connection: connection, buffer: nextBuffer)
        }
    }

    private func parseRequest(from buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            return nil
        }

        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers = [String: String]()
        for line in headerLines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else {
            return nil
        }

        return HTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func response(for request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/messages"), ("POST", "/v1/messages"):
            return await upstreamResponse(for: request, endpoint: "messages", injectModelParameters: true)
        case ("POST", "/messages/count_tokens"), ("POST", "/v1/messages/count_tokens"):
            return await upstreamResponse(for: request, endpoint: "messages/count_tokens", injectModelParameters: false)
        case ("GET", "/models"), ("GET", "/v1/models"):
            return jsonResponse(statusCode: 200, body: jsonData(["data": modelObjects()]))
        default:
            return jsonResponse(statusCode: 404, body: errorPayload(message: L10n.tr("不支持的 Claude Provider 代理路径。")))
        }
    }

    private func upstreamResponse(
        for request: HTTPRequest,
        endpoint: String,
        injectModelParameters: Bool
    ) async -> HTTPResponse {
        do {
            let state = currentState()
            let mediaAdjustedBody = claudeCompatibleProviderSupportsMediaBlocks(baseURL: state.baseURL)
                ? request.body
                : try Self.bodyByStrippingUnsupportedMediaBlocks(from: request.body)
            let body: Data
            if injectModelParameters {
                // Claude Code 直连 provider 时，请求体在代理边界统一补齐当前模型采样参数。
                body = try ProviderModelSettings.applyParameters(
                    toJSONData: mediaAdjustedBody,
                    requestedModel: requestModel(from: mediaAdjustedBody),
                    settings: state.modelSettings,
                    fallbackModel: state.defaultModel
                )
            } else {
                body = mediaAdjustedBody
            }
            let (statusCode, data) = try await sendUpstreamRequest(
                state.baseURL,
                state.apiKey,
                endpoint,
                request.headers,
                body
            )
            let contentType = (200..<300).contains(statusCode) && requestWantsStreaming(request.body)
                ? "text/event-stream"
                : "application/json"
            return HTTPResponse(statusCode: statusCode, contentType: contentType, body: data)
        } catch {
            return jsonResponse(statusCode: 502, body: errorPayload(message: error.localizedDescription))
        }
    }

    private static func bodyByStrippingUnsupportedMediaBlocks(from data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        guard let messages = object["messages"] as? [Any] else {
            return data
        }

        // MiniMax 的 Anthropic 兼容接口只接受文本、工具与 thinking 块，图片和文档必须在代理边界剥离。
        object["messages"] = messages.map { messageValue -> Any in
            guard var message = messageValue as? [String: Any] else {
                return messageValue
            }
            message["content"] = strippedUnsupportedMediaBlocks(from: message["content"])
            return message
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func strippedUnsupportedMediaBlocks(from content: Any?) -> Any {
        guard let blocks = content as? [Any] else {
            return content ?? ""
        }

        let stripped = blocks.filter { blockValue in
            guard let block = blockValue as? [String: Any] else {
                return true
            }
            let type = block["type"] as? String
            return type != "image" && type != "document"
        }
        let fallback: [[String: Any]] = [["type": "text", "text": ""]]
        return stripped.isEmpty ? fallback : stripped
    }

    private func requestModel(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["model"] as? String
    }

    private func requestWantsStreaming(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["stream"] as? Bool) ?? false
    }

    private func currentState() -> (
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        defaultModel: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) {
        stateQueue.sync {
            (upstreamBaseURL, apiKeyEnvName, apiKey, defaultModel, availableModels, modelSettings)
        }
    }

    private func send(response: HTTPResponse, through connection: NWConnection) {
        let header = [
            "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func jsonResponse(statusCode: Int, body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "application/json", body: body)
    }

    private func errorPayload(message: String) -> Data {
        jsonData([
            "error": [
                "message": message,
                "type": "api_error",
            ],
        ])
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }

    private func modelObjects() -> [[String: Any]] {
        let state = currentState()
        let models = state.availableModels.isEmpty ? [state.defaultModel] : state.availableModels
        return models.map {
            [
                "id": $0,
                "object": "model",
                "owned_by": "claude-compatible-provider",
            ]
        }
    }

    private func normalizedAvailableModels(_ availableModels: [String], fallbackModel: String) -> [String] {
        ProviderModelSettings.modelNames(
            from: availableModels.map { ProviderModelSettings(model: $0) },
            fallbackModel: fallbackModel
        )
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        case 429:
            return "Too Many Requests"
        default:
            return "Error"
        }
    }
}
