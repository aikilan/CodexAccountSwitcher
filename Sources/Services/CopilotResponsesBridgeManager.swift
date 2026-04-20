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
    private var servers: [String: CopilotResponsesBridgeServer] = [:]
    private let debugStore: CopilotACPDebugStore?

    init(debugStore: CopilotACPDebugStore? = nil) {
        self.debugStore = debugStore
    }

    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL,
        configDirectoryURL: URL,
        reasoningEffort: String
    ) async throws -> PreparedCopilotResponsesBridge {
        let key = "\(accountID.uuidString)|\(workingDirectoryURL.standardizedFileURL.path)"
        let server = servers[key] ?? CopilotResponsesBridgeServer(debugStore: debugStore)
        server.update(
            model: model,
            availableModels: availableModels,
            workingDirectoryURL: workingDirectoryURL,
            configDirectoryURL: configDirectoryURL,
            reasoningEffort: reasoningEffort
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
        let defaultModel: String
        let availableModels: [String]
        let workingDirectoryURL: URL
        let configDirectoryURL: URL
        let defaultReasoningEffort: String
        let bridgeBaseURL: String
    }

    private let queue = DispatchQueue(label: "com.openai.Orbit.copilot-responses-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.Orbit.copilot-responses-bridge.state")

    private var listener: NWListener?
    private var localBaseURL: String?
    private var defaultModel = "gpt-4.1"
    private var availableModels = ["gpt-4.1"]
    private var workingDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    private var configDirectoryURL = CopilotCLIConfiguration.defaultConfigDirectoryURL()
    private var defaultReasoningEffort = "medium"
    private let debugStore: CopilotACPDebugStore?

    init(debugStore: CopilotACPDebugStore? = nil) {
        self.debugStore = debugStore
    }

    func update(
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL,
        configDirectoryURL: URL,
        reasoningEffort: String
    ) {
        stateQueue.sync {
            self.defaultModel = normalizedModelCandidate(model) ?? "gpt-4.1"
            self.availableModels = normalizedAvailableModels(availableModels, fallbackModel: self.defaultModel)
            self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
            self.configDirectoryURL = configDirectoryURL.standardizedFileURL
            self.defaultReasoningEffort = trimmedString(reasoningEffort) ?? "medium"
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
                    await self.handle(request: request, through: connection)
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

    private func handle(request: HTTPRequest, through connection: NWConnection) async {
        switch (request.method, request.path) {
        case ("POST", "/responses"), ("POST", "/v1/responses"):
            await sendResponsesResponse(for: request, through: connection)
        case ("GET", "/models"), ("GET", "/v1/models"):
            send(response: jsonResponse(statusCode: 200, body: jsonData(["data": modelObjects()])), through: connection)
        default:
            send(
                response: jsonResponse(statusCode: 404, body: errorPayload(message: L10n.tr("不支持的 GitHub Copilot bridge 路径。"))),
                through: connection
            )
        }
    }

    private func sendResponsesResponse(for request: HTTPRequest, through connection: NWConnection) async {
        let requestID = UUID()
        var didStartDebugRequest = false
        do {
            let state = currentState()
            let requestObject = try requestJSONObject(from: request.body)
            let wantsStream = (requestObject["stream"] as? Bool) ?? false
            let requestedModel = trimmedString(requestObject["model"]) ?? state.defaultModel
            let requestedReasoningEffort = trimmedString(requestObject["reasoning_effort"])
                ?? state.defaultReasoningEffort
            let prompt = try promptText(from: requestObject)
            await recordRequestStarted(
                id: requestID,
                state: state,
                path: request.path,
                model: requestedModel,
                reasoningEffort: requestedReasoningEffort,
                payloadPreview: Self.payloadPreview(from: request.body)
            )
            didStartDebugRequest = true

            let client = CopilotACPClient(
                configDirectoryURL: state.configDirectoryURL,
                debugEventHandler: debugEventHandler(for: requestID)
            )

            if wantsStream {
                await streamResponsesResponse(
                    requestID: requestID,
                    client: client,
                    connection: connection,
                    state: state,
                    model: requestedModel,
                    reasoningEffort: requestedReasoningEffort,
                    prompt: prompt
                )
                return
            }

            let result = try await client.prompt(
                workingDirectoryURL: state.workingDirectoryURL,
                model: requestedModel,
                reasoningEffort: requestedReasoningEffort,
                prompt: prompt
            )
            let responseData = jsonData(responseObject(from: result))
            guard (try JSONSerialization.jsonObject(with: responseData) as? [String: Any]) != nil else {
                throw CopilotResponsesBridgeManagerError.invalidRequest
            }

            await recordRequestFinished(id: requestID, status: .completed, httpStatus: 200, errorMessage: nil)
            send(response: jsonResponse(statusCode: 200, body: responseData), through: connection)
        } catch {
            let message = error.localizedDescription
            let statusCode = statusCode(for: message)
            if didStartDebugRequest {
                await recordRequestFinished(id: requestID, status: .failed, httpStatus: statusCode, errorMessage: message)
            }
            send(response: jsonResponse(statusCode: statusCode, body: errorPayload(message: message)), through: connection)
        }
    }

    private func streamResponsesResponse(
        requestID: UUID,
        client: CopilotACPClient,
        connection: NWConnection,
        state: State,
        model: String,
        reasoningEffort: String,
        prompt: String
    ) async {
        let stream = CopilotResponsesStreamResponse(connection: connection, model: model)
        await stream.start()
        do {
            _ = try await client.promptStream(
                workingDirectoryURL: state.workingDirectoryURL,
                model: model,
                reasoningEffort: reasoningEffort,
                prompt: prompt
            ) { event in
                await stream.send(event: event)
            }
            await stream.complete()
            await recordRequestFinished(id: requestID, status: .completed, httpStatus: 200, errorMessage: nil)
        } catch {
            let message = error.localizedDescription
            await stream.fail(message: message)
            await recordRequestFinished(id: requestID, status: .failed, httpStatus: 200, errorMessage: message)
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
                defaultModel: defaultModel,
                availableModels: availableModels,
                workingDirectoryURL: workingDirectoryURL,
                configDirectoryURL: configDirectoryURL,
                defaultReasoningEffort: defaultReasoningEffort,
                bridgeBaseURL: localBaseURL ?? ""
            )
        }
    }

    @MainActor
    private func recordRequestStarted(
        id: UUID,
        state: State,
        path: String,
        model: String,
        reasoningEffort: String,
        payloadPreview: String?
    ) {
        debugStore?.recordRequestStarted(
            id: id,
            bridgeBaseURL: state.bridgeBaseURL,
            path: path,
            model: model,
            reasoningEffort: reasoningEffort,
            workingDirectoryPath: state.workingDirectoryURL.path,
            configDirectoryPath: state.configDirectoryURL.path,
            payloadPreview: payloadPreview
        )
    }

    @MainActor
    private func recordRequestFinished(
        id: UUID,
        status: CopilotACPDebugRequestStatus,
        httpStatus: Int?,
        errorMessage: String?
    ) {
        debugStore?.recordRequestFinished(
            id: id,
            status: status,
            httpStatus: httpStatus,
            errorMessage: errorMessage
        )
    }

    private func debugEventHandler(for requestID: UUID) -> CopilotACPDebugEventHandler? {
        guard let debugStore else { return nil }
        return { event in
            await MainActor.run {
                switch event {
                case let .processStarted(info):
                    debugStore.recordACPCommand(
                        requestID: requestID,
                        commandLine: info.commandLine,
                        processID: info.processID
                    )
                case let .request(method, payloadPreview):
                    debugStore.appendEvent(
                        requestID: requestID,
                        title: L10n.tr("ACP 请求"),
                        detail: method,
                        payloadPreview: payloadPreview
                    )
                case let .response(method, payloadPreview):
                    debugStore.appendEvent(
                        requestID: requestID,
                        title: L10n.tr("ACP 响应"),
                        detail: method,
                        payloadPreview: payloadPreview
                    )
                case let .notification(method, payloadPreview):
                    debugStore.appendEvent(
                        requestID: requestID,
                        title: L10n.tr("ACP 通知"),
                        detail: method,
                        payloadPreview: payloadPreview
                    )
                case let .error(message):
                    debugStore.appendEvent(
                        requestID: requestID,
                        title: L10n.tr("ACP 错误"),
                        detail: message,
                        payloadPreview: nil
                    )
                }
            }
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

    private static func payloadPreview(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        if text.count <= CopilotACPDebugStore.payloadPreviewLimit {
            return text
        }
        return String(text.prefix(CopilotACPDebugStore.payloadPreviewLimit)) + "\n... truncated ..."
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

private actor CopilotResponsesStreamResponse {
    private let connection: NWConnection
    private var encoder: CopilotResponsesStreamEncoder
    private var isClosed = false

    init(connection: NWConnection, model: String) {
        self.connection = connection
        self.encoder = CopilotResponsesStreamEncoder(model: model)
    }

    func start() async {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        await send(Data(header.utf8))
        await send(encoder.startData())
    }

    func send(event: CopilotACPStreamEvent) async {
        if case let .error(message) = event {
            await fail(message: message)
            return
        }
        if case .completed = event {
            return
        }
        await send(encoder.encode(event: event))
    }

    func complete() async {
        await send(encoder.completeData())
        close()
    }

    func fail(message: String) async {
        await send(encoder.failureData(message: message))
        close()
    }

    private func send(_ data: Data) async {
        guard !data.isEmpty, !isClosed else { return }
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }
}
