import Foundation

enum CopilotACPClientError: LocalizedError {
    case cliUnavailable
    case serverExited(String)
    case requestFailed(String)
    case invalidResponse(String)
    case missingSessionID
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return L10n.tr("当前机器未安装可用的 `copilot` CLI。")
        case let .serverExited(message):
            return message
        case let .requestFailed(message):
            return message
        case let .invalidResponse(message):
            return message
        case .missingSessionID:
            return L10n.tr("GitHub Copilot ACP 没有返回有效的 sessionId。")
        case .timedOut:
            return L10n.tr("GitHub Copilot ACP 请求超时。")
        }
    }
}

struct CopilotACPStatusResult: Sendable {
    let availableModels: [String]
    let currentModel: String?
}

struct CopilotACPPromptResult: Sendable {
    let model: String
    let availableModels: [String]
    let toolCalls: [CopilotACPToolCall]
    let outputText: String
    let reasoningText: String?
}

struct CopilotACPToolCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
    let outputText: String?
}

struct CopilotACPClient: Sendable {
    private let configDirectoryURL: URL
    private let requestTimeout: Duration

    init(
        configDirectoryURL: URL,
        requestTimeout: Duration = .seconds(90)
    ) {
        self.configDirectoryURL = configDirectoryURL
        self.requestTimeout = requestTimeout
    }

    func fetchStatus(workingDirectoryURL: URL) async throws -> CopilotACPStatusResult {
        let connection = try CopilotACPConnection(
            configDirectoryURL: configDirectoryURL,
            requestTimeout: requestTimeout
        )
        defer {
            Task {
                await connection.shutdown()
            }
        }

        _ = try await connection.request(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "Orbit",
                    "version": "1.0.0",
                ],
            ]
        )
        let sessionData = try await connection.request(
            method: "session/new",
            params: [
                "cwd": workingDirectoryURL.standardizedFileURL.path,
                "mcpServers": [],
            ]
        )
        let session = try parseSession(from: sessionData)
        return CopilotACPStatusResult(
            availableModels: session.availableModels,
            currentModel: session.currentModel
        )
    }

    func prompt(
        workingDirectoryURL: URL,
        model: String,
        prompt: String
    ) async throws -> CopilotACPPromptResult {
        let connection = try CopilotACPConnection(
            configDirectoryURL: configDirectoryURL,
            requestTimeout: requestTimeout
        )
        defer {
            Task {
                await connection.shutdown()
            }
        }

        _ = try await connection.request(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "Orbit",
                    "version": "1.0.0",
                ],
            ]
        )
        let sessionData = try await connection.request(
            method: "session/new",
            params: [
                "cwd": workingDirectoryURL.standardizedFileURL.path,
                "mcpServers": [],
            ]
        )
        let session = try parseSession(from: sessionData)
        let resolvedModel = resolvedModel(
            requestedModel: model,
            currentModel: session.currentModel,
            availableModels: session.availableModels
        )
        if let resolvedModel, resolvedModel != session.currentModel {
            _ = try await connection.request(
                method: "session/set_config_option",
                params: [
                    "sessionId": session.sessionID,
                    "configId": "model",
                    "value": resolvedModel,
                ]
            )
        }

        let collector = CopilotACPNotificationCollector()
        await connection.setNotificationHandler { data in
            await collector.consume(data: data)
        }
        _ = try await connection.request(
            method: "session/prompt",
            params: [
                "sessionId": session.sessionID,
                "prompt": [
                    [
                        "type": "text",
                        "text": prompt,
                    ],
                ],
            ]
        )
        await connection.setNotificationHandler(nil)

        return await collector.result(
            model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "gpt-5.3-codex",
            availableModels: session.availableModels
        )
    }
}

private extension CopilotACPClient {
    struct SessionDescription {
        let sessionID: String
        let availableModels: [String]
        let currentModel: String?
    }

    func parseSession(from data: Data) throws -> SessionDescription {
        let object = try jsonObject(from: data)
        guard let result = object["result"] as? [String: Any] else {
            throw CopilotACPClientError.invalidResponse(L10n.tr("GitHub Copilot ACP 返回了无效的 session/new 响应。"))
        }

        let sessionID = stringValue(result["sessionId"]) ?? ""
        guard !sessionID.isEmpty else {
            throw CopilotACPClientError.missingSessionID
        }

        let modelsObject = result["models"] as? [String: Any]
        let currentModel = stringValue(modelsObject?["currentModelId"])
            ?? currentModelFromConfigOptions(result["configOptions"])
        let rawModels = (modelsObject?["availableModels"] as? [Any]) ?? []
        let availableModels = normalizedModels(
            rawModels.compactMap { item in
                if let object = item as? [String: Any] {
                    if let modelID = stringValue(object["modelId"]) {
                        return modelID
                    }
                    return stringValue(object["id"])
                }
                return item as? String
            },
            fallbackModel: currentModel
        )
        return SessionDescription(
            sessionID: sessionID,
            availableModels: availableModels,
            currentModel: currentModel
        )
    }

    func currentModelFromConfigOptions(_ value: Any?) -> String? {
        guard let options = value as? [Any] else { return nil }
        for optionValue in options {
            guard let option = optionValue as? [String: Any] else { continue }
            if stringValue(option["id"]) == "model" {
                return stringValue(option["currentValue"])
            }
        }
        return nil
    }

    func resolvedModel(
        requestedModel: String,
        currentModel: String?,
        availableModels: [String]
    ) -> String? {
        let trimmedRequestedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRequestedModel.isEmpty {
            return trimmedRequestedModel
        }
        if let currentModel, !currentModel.isEmpty {
            return currentModel
        }
        return availableModels.first
    }

    func normalizedModels(_ models: [String?], fallbackModel: String?) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in models {
            let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        let trimmedFallback = fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFallback.isEmpty, seen.insert(trimmedFallback).inserted {
            normalized.append(trimmedFallback)
        }

        return normalized
    }

    func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotACPClientError.invalidResponse(L10n.tr("GitHub Copilot ACP 返回了无效 JSON。"))
        }
        return object
    }

    func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private actor CopilotACPNotificationCollector {
    private struct ToolCallState: Sendable {
        var name: String
        var arguments: String
        var outputText: String?
    }

    private var messageChunks = [String]()
    private var reasoningChunks = [String]()
    private var toolCallOrder = [String]()
    private var toolCalls = [String: ToolCallState]()

    func consume(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String,
            method == "session/update",
            let params = object["params"] as? [String: Any],
            let update = params["update"] as? [String: Any]
        else {
            return
        }

        let updateType = ((update["sessionUpdate"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if updateType.contains("thought") || updateType.contains("reasoning") {
            let text = Self.extractText(from: update["content"])
            appendDeduplicatedChunk(text, into: &reasoningChunks)
            return
        }
        if updateType.contains("message") {
            let text = Self.extractText(from: update["content"])
            guard !text.isEmpty else { return }
            messageChunks.append(text)
            return
        }
        if updateType == "tool_call" {
            consumeToolCall(update)
            return
        }
        if updateType == "tool_call_update" {
            consumeToolCallUpdate(update)
        }
    }

    func result(model: String, availableModels: [String]) -> CopilotACPPromptResult {
        let outputText = messageChunks.joined()
        let reasoningText = reasoningChunks.joined()
        return CopilotACPPromptResult(
            model: model,
            availableModels: availableModels,
            toolCalls: orderedToolCalls(),
            outputText: outputText,
            reasoningText: reasoningText.isEmpty ? nil : reasoningText
        )
    }

    private func consumeToolCall(_ update: [String: Any]) {
        let toolCallIDValue = update["toolCallId"]
        let rawInput = update["rawInput"]
        let titleValue = update["title"]
        let kindValue = update["kind"]
        guard let callID = Self.stringValue(toolCallIDValue) else { return }
        let name = Self.stringValue(titleValue) ?? Self.stringValue(kindValue) ?? "tool"
        let extractedArguments = Self.extractText(from: rawInput)
        let arguments = Self.jsonString(from: rawInput) ?? (extractedArguments.isEmpty ? "{}" : extractedArguments)
        if toolCalls[callID] == nil {
            toolCallOrder.append(callID)
        }
        var state = toolCalls[callID] ?? ToolCallState(name: name, arguments: arguments, outputText: nil)
        state.name = state.name.isEmpty ? name : state.name
        state.arguments = state.arguments.isEmpty ? arguments : state.arguments
        toolCalls[callID] = state
    }

    private func consumeToolCallUpdate(_ update: [String: Any]) {
        let toolCallIDValue = update["toolCallId"]
        let titleValue = update["title"]
        let rawOutputValue = update["rawOutput"]
        let contentValue = update["content"]
        guard let callID = Self.stringValue(toolCallIDValue) else { return }
        if toolCalls[callID] == nil {
            toolCallOrder.append(callID)
        }
        var state = toolCalls[callID] ?? ToolCallState(name: Self.stringValue(titleValue) ?? "tool", arguments: "{}", outputText: nil)
        let rawOutputText = Self.extractText(from: rawOutputValue)
        let outputText = rawOutputText.isEmpty ? Self.extractText(from: contentValue) : rawOutputText
        if !outputText.isEmpty {
            state.outputText = outputText
        }
        toolCalls[callID] = state
    }

    private func orderedToolCalls() -> [CopilotACPToolCall] {
        toolCallOrder.compactMap { callID in
            guard let toolCall = toolCalls[callID] else { return nil }
            return CopilotACPToolCall(
                callID: callID,
                name: toolCall.name.isEmpty ? "tool" : toolCall.name,
                arguments: toolCall.arguments.isEmpty ? "{}" : toolCall.arguments,
                outputText: toolCall.outputText
            )
        }
    }

    private func appendDeduplicatedChunk(_ chunk: String, into chunks: inout [String]) {
        guard !chunk.isEmpty else { return }
        if chunks.last == chunk {
            return
        }
        chunks.append(chunk)
    }

    nonisolated private static func extractText(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String {
                return text
            }
            if let content = object["content"] {
                return extractText(from: content)
            }
            return ""
        }
        if let array = value as? [Any] {
            return array.map { extractText(from: $0) }.joined()
        }
        return ""
    }

    nonisolated private static func jsonString(from value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private actor CopilotACPConnection {
    private let requestTimeout: Duration
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private var pendingResponses: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var processExitError: Error?
    private var notificationHandler: (@Sendable (Data) async -> Void)?

    init(
        configDirectoryURL: URL,
        requestTimeout: Duration
    ) throws {
        self.requestTimeout = requestTimeout
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
        process.arguments = [
            "copilot",
            "--acp",
            "--stdio",
            "--config-dir",
            configDirectoryURL.path,
            "--allow-all",
            "--no-ask-user",
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeStderr(data)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw CopilotACPClientError.cliUnavailable
        }
    }

    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) {
        notificationHandler = handler
    }

    func request(method: String, params: [String: Any]) async throws -> Data {
        if let processExitError {
            throw processExitError
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let data = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": requestID,
                "method": method,
                "params": params,
            ],
            options: []
        ) + Data([0x0A])

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            timeoutTasks[requestID] = Task { [weak self] in
                try? await Task.sleep(for: self?.requestTimeout ?? .seconds(90))
                await self?.timeoutRequest(id: requestID)
            }

            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                timeoutTasks.removeValue(forKey: requestID)?.cancel()
                pendingResponses.removeValue(forKey: requestID)
                continuation.resume(throwing: CopilotACPClientError.serverExited(error.localizedDescription))
            }
        }
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        if process.isRunning {
            process.terminate()
        }
        let error = CopilotACPClientError.serverExited(L10n.tr("GitHub Copilot ACP 连接已关闭。"))
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func timeoutRequest(id: Int) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: CopilotACPClientError.timedOut)
    }

    private func consumeStdout(_ data: Data) async {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0..<newlineRange.upperBound)
            guard !lineData.isEmpty else { continue }
            await handleMessage(lineData)
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
    }

    private func handleMessage(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let responseID = object["id"] as? Int {
            timeoutTasks.removeValue(forKey: responseID)?.cancel()
            guard let continuation = pendingResponses.removeValue(forKey: responseID) else { return }

            if let errorObject = object["error"] as? [String: Any] {
                let message = ((errorObject["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: CopilotACPClientError.requestFailed(message.isEmpty ? L10n.tr("GitHub Copilot ACP 请求失败。") : message))
                return
            }

            continuation.resume(returning: data)
            return
        }

        if let notificationHandler {
            await notificationHandler(data)
        }
    }

    private func handleTermination(status: Int32) {
        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message: String
        if status == 127 || stderrText.contains("No such file") || stderrText.contains("command not found") {
            message = CopilotACPClientError.cliUnavailable.localizedDescription
        } else if stderrText.isEmpty {
            message = L10n.tr("GitHub Copilot ACP 已退出（状态码 %d）。", status)
        } else {
            message = stderrText
        }

        let error = CopilotACPClientError.serverExited(message)
        processExitError = error

        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()

        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
