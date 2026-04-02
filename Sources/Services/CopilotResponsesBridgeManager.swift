import Foundation
import Network

enum CopilotResponsesBridgeManagerError: LocalizedError, Equatable {
    case bridgeStartFailed
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .bridgeStartFailed:
            return L10n.tr("GitHub Copilot Responses 本地桥接启动失败。")
        case .invalidRequest:
            return L10n.tr("GitHub Copilot Responses 请求格式无效。")
        }
    }
}

actor CopilotResponsesBridgeManager {
    private let provider: any CopilotProviderServing
    private var servers: [String: CopilotResponsesBridgeServer] = [:]

    init(provider: any CopilotProviderServing) {
        self.provider = provider
    }

    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL
    ) async throws -> PreparedCopilotResponsesBridge {
        let key = "\(accountID.uuidString)|\(workingDirectoryURL.standardizedFileURL.path)"
        let server = servers[key] ?? CopilotResponsesBridgeServer(provider: provider)
        server.update(
            credential: credential,
            model: model,
            availableModels: availableModels,
            workingDirectoryURL: workingDirectoryURL
        )
        let baseURL = try await server.startIfNeeded()
        servers[key] = server

        return PreparedCopilotResponsesBridge(
            baseURL: baseURL,
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "github-copilot-bridge"
        )
    }
}

extension CopilotResponsesBridgeManager: CopilotResponsesBridgeManaging {}

private final class CopilotResponsesBridgeServer: @unchecked Sendable {
    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private struct HTTPResponse {
        let statusCode: Int
        let contentType: String
        let body: Data
    }

    private struct State: Sendable {
        let credential: CopilotCredential
        let defaultModel: String
        let availableModels: [String]
        let workingDirectoryURL: URL
    }

    private let queue = DispatchQueue(label: "com.openai.Orbit.copilot-responses-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.Orbit.copilot-responses-bridge.state")
    private let provider: any CopilotProviderServing

    private var listener: NWListener?
    private var localBaseURL: String?
    private var credential = CopilotCredential(
        configDirectoryName: "",
        host: "https://github.com",
        login: "",
        defaultModel: nil
    )
    private var defaultModel = "gpt-4.1"
    private var availableModels = ["gpt-4.1"]
    private var workingDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    init(provider: any CopilotProviderServing) {
        self.provider = provider
    }

    func update(
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL
    ) {
        stateQueue.sync {
            self.credential = credential
            self.defaultModel = normalizedModelCandidate(model) ?? "gpt-4.1"
            self.availableModels = normalizedAvailableModels(availableModels, fallbackModel: self.defaultModel)
            self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
        }
    }

    func startIfNeeded() async throws -> String {
        if let localBaseURL = stateQueue.sync(execute: { self.localBaseURL }) {
            return localBaseURL
        }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                var didResume = false
            }

            let resumeState = ResumeState()
            let resumeQueue = DispatchQueue(label: "com.openai.Orbit.copilot-responses-bridge.resume")
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
                        resumeOnce(.failure(CopilotResponsesBridgeManagerError.bridgeStartFailed))
                        return
                    }
                    let baseURL = "http://127.0.0.1:\(port)"
                    self.stateQueue.sync {
                        self.localBaseURL = baseURL
                    }
                    resumeOnce(.success(baseURL))
                case .failed:
                    resumeOnce(.failure(CopilotResponsesBridgeManagerError.bridgeStartFailed))
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
                send(
                    response: jsonResponse(
                        statusCode: 400,
                        body: errorPayload(message: L10n.tr("GitHub Copilot bridge 请求格式无效。"))
                    ),
                    through: connection
                )
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
            path: String(requestParts[1]),
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func response(for request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/responses"), ("POST", "/v1/responses"):
            return await responsesResponse(for: request)
        case ("GET", "/models"), ("GET", "/v1/models"):
            return jsonResponse(statusCode: 200, body: jsonData(["data": modelObjects()]))
        default:
            return jsonResponse(statusCode: 404, body: errorPayload(message: L10n.tr("不支持的 GitHub Copilot bridge 路径。")))
        }
    }

    private func responsesResponse(for request: HTTPRequest) async -> HTTPResponse {
        do {
            let state = currentState()
            let requestObject = try requestJSONObject(from: request.body)
            let wantsStream = (requestObject["stream"] as? Bool) ?? false
            let requestedModel = trimmedString(requestObject["model"]) ?? state.defaultModel
            let upstreamRequest = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
                from: request.body,
                fallbackModel: requestedModel
            )
            let (statusCode, data) = try await provider.sendChatCompletions(
                using: state.credential,
                body: upstreamRequest
            )
            guard (200..<300).contains(statusCode) else {
                return jsonResponse(
                    statusCode: statusCode,
                    body: errorPayload(message: ResponsesChatCompletionsBridge.extractErrorMessage(from: data))
                )
            }

            let responseData = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
                from: data,
                fallbackModel: requestedModel
            )
            guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw ResponsesChatCompletionsBridge.TranslationError.invalidResponse(L10n.tr("本地桥接响应格式无效。"))
            }

            if wantsStream {
                return HTTPResponse(
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: ResponsesChatCompletionsBridge.makeResponseStreamData(from: responseObject)
                )
            }

            return jsonResponse(statusCode: 200, body: responseData)
        } catch {
            let message = error.localizedDescription
            return jsonResponse(statusCode: statusCode(for: message), body: errorPayload(message: message))
        }
    }

    private func requestJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotResponsesBridgeManagerError.invalidRequest
        }
        return object
    }

    private func currentState() -> State {
        stateQueue.sync {
            State(
                credential: credential,
                defaultModel: defaultModel,
                availableModels: availableModels,
                workingDirectoryURL: workingDirectoryURL
            )
        }
    }

    private func promptText(from requestObject: [String: Any]) throws -> String {
        let instructions = flattenText(from: requestObject["instructions"])
        let input = flattenText(from: requestObject["input"])

        var sections = [String]()
        if !instructions.isEmpty {
            sections.append("System instructions:\n\(instructions)")
        }
        if !input.isEmpty {
            sections.append("Conversation:\n\(input)")
        }

        let prompt = sections.joined(separator: "\n\n")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CopilotResponsesBridgeManagerError.invalidRequest
        }
        return prompt
    }

    private func flattenText(from value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let array = value as? [Any] {
            let parts = array.map { flattenText(from: $0) }.filter { !$0.isEmpty }
            return parts.joined(separator: "\n\n")
        }

        if let object = value as? [String: Any] {
            let type = trimmedString(object["type"])
            switch type {
            case "input_text", "output_text", "text":
                return trimmedString(object["text"]) ?? ""
            case "message":
                return messageText(from: object)
            case "function_call":
                let name = trimmedString(object["name"]) ?? "tool"
                let arguments = trimmedString(object["arguments"])
                    ?? jsonString(from: object["arguments"] ?? [:])
                    ?? "{}"
                return "Tool \(name) call:\n\(arguments)"
            case "function_call_output":
                let name = trimmedString(object["name"])
                    ?? trimmedString(object["call_id"])
                    ?? "tool"
                let output = flattenText(from: object["output"])
                return output.isEmpty ? "" : "Tool \(name) output:\n\(output)"
            default:
                if object["role"] != nil || object["content"] != nil {
                    return messageText(from: object)
                }
                if let output = object["output"] {
                    return flattenText(from: output)
                }
                return jsonString(from: object) ?? ""
            }
        }

        return ""
    }

    private func messageText(from object: [String: Any]) -> String {
        let role = normalizedRole(from: object["role"])
        let content = flattenText(from: object["content"])
        guard !content.isEmpty else { return "" }
        return "\(role.capitalized):\n\(content)"
    }

    private func responseObject(from result: CopilotACPPromptResult) -> [String: Any] {
        var output = [[String: Any]]()
        if let reasoningText = result.reasoningText, !reasoningText.isEmpty {
            output.append([
                "id": "rs_\(UUID().uuidString)",
                "type": "reasoning",
                "summary": [[
                    "type": "summary_text",
                    "text": reasoningText,
                ]],
            ])
        }
        for toolCall in result.toolCalls {
            output.append([
                "id": "fc_\(toolCall.callID)",
                "type": "function_call",
                "call_id": toolCall.callID,
                "name": toolCall.name,
                "arguments": toolCall.arguments,
            ])
            if let outputText = toolCall.outputText, !outputText.isEmpty {
                output.append([
                    "id": "fco_\(toolCall.callID)",
                    "type": "function_call_output",
                    "call_id": toolCall.callID,
                    "output": outputText,
                ])
            }
        }
        output.append([
            "id": "msg_\(UUID().uuidString)",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": result.outputText,
            ]],
        ])

        return [
            "id": UUID().uuidString,
            "object": "response",
            "model": result.model,
            "output": output,
            "usage": [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0,
            ],
        ]
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
        return models.map { model in
            [
                "id": model,
                "object": "model",
                "owned_by": "github-copilot",
            ]
        }
    }

    private func normalizedAvailableModels(_ availableModels: [String], fallbackModel: String) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in availableModels {
            guard let trimmed = normalizedModelCandidate(model), seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        if let trimmedFallback = normalizedModelCandidate(fallbackModel),
           seen.insert(trimmedFallback).inserted
        {
            normalized.append(trimmedFallback)
        }

        return normalized
    }

    private func normalizedModelCandidate(_ model: String?) -> String? {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedModel.isEmpty, trimmedModel != "gpt-5.3-codex" else {
            return nil
        }
        return trimmedModel
    }

    private func trimmedString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRole(from value: Any?) -> String {
        switch trimmedString(value) {
        case "assistant":
            return "assistant"
        case "system":
            return "system"
        default:
            return "user"
        }
    }

    private func jsonString(from value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private func statusCode(for message: String) -> Int {
        let normalized = message.lowercased()
        if normalized.contains("not authenticated")
            || normalized.contains("authenticate")
            || normalized.contains("login")
            || normalized.contains("config.json")
        {
            return 401
        }
        if normalized.contains("payment") || normalized.contains("quota exhausted") || normalized.contains("premium") {
            return 402
        }
        if normalized.contains("rate") || normalized.contains("429") || normalized.contains("too many") {
            return 429
        }
        return 502
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 402:
            return "Payment Required"
        case 404:
            return "Not Found"
        case 429:
            return "Too Many Requests"
        default:
            return "Bad Gateway"
        }
    }
}
