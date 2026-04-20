import Foundation

enum CopilotACPClientError: LocalizedError {
    case cliUnavailable
    case serverExited(String)
    case requestFailed(String)
    case invalidResponse(String)
    case missingSessionID
    case unsupportedReasoningEffort(model: String, effort: String)
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
        case let .unsupportedReasoningEffort(model, effort):
            return L10n.tr("GitHub Copilot ACP 当前模型 %@ 不支持推理强度 %@。", model, effort)
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

struct CopilotACPToolCall: Equatable, Sendable {
    let callID: String
    let name: String
    let arguments: String
    let outputText: String?
}

struct CopilotACPConnectionLaunchInfo: Equatable, Sendable {
    let commandLine: String
    let processID: Int32
}

enum CopilotACPClientDebugEvent: Equatable, Sendable {
    case processStarted(CopilotACPConnectionLaunchInfo)
    case request(method: String, payloadPreview: String)
    case response(method: String, payloadPreview: String)
    case notification(method: String, payloadPreview: String)
    case error(String)
}

typealias CopilotACPDebugEventHandler = @Sendable (CopilotACPClientDebugEvent) async -> Void

enum CopilotACPStreamEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case messageDelta(String)
    case toolCall(CopilotACPToolCall)
    case toolCallOutput(callID: String, output: String)
    case error(String)
    case completed
}

struct CopilotACPClient: Sendable {
    private let configDirectoryURL: URL
    private let requestTimeout: Duration
    private let promptRequestTimeout: Duration
    private let debugEventHandler: CopilotACPDebugEventHandler?

    init(
        configDirectoryURL: URL,
        requestTimeout: Duration = .seconds(90),
        promptRequestTimeout: Duration = .seconds(600),
        debugEventHandler: CopilotACPDebugEventHandler? = nil
    ) {
        self.configDirectoryURL = configDirectoryURL
        self.requestTimeout = requestTimeout
        self.promptRequestTimeout = promptRequestTimeout
        self.debugEventHandler = debugEventHandler
    }

    func fetchStatus(workingDirectoryURL: URL) async throws -> CopilotACPStatusResult {
        let connection = try CopilotACPConnection(
            configDirectoryURL: configDirectoryURL,
            requestTimeout: requestTimeout,
            debugEventHandler: debugEventHandler
        )
        if let debugEventHandler {
            await debugEventHandler(.processStarted(await connection.launchInfo()))
        }
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
        reasoningEffort: String,
        prompt: String
    ) async throws -> CopilotACPPromptResult {
        let connection = try CopilotACPConnection(
            configDirectoryURL: configDirectoryURL,
            requestTimeout: requestTimeout,
            debugEventHandler: debugEventHandler
        )
        if let debugEventHandler {
            await debugEventHandler(.processStarted(await connection.launchInfo()))
        }
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
        var currentOptions = session.configOptions
        if let resolvedModel, resolvedModel != session.currentModel {
            let setModelData = try await connection.request(
                method: "session/set_config_option",
                params: [
                    "sessionId": session.sessionID,
                    "configId": "model",
                    "value": resolvedModel,
                ]
            )
            currentOptions = try configOptions(from: setModelData)
        }

        let resolvedReasoningEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedReasoningEffort.isEmpty {
            let availableReasoningEfforts = values(for: "reasoning_effort", in: currentOptions)
            if !availableReasoningEfforts.isEmpty,
               !availableReasoningEfforts.contains(resolvedReasoningEffort)
            {
                throw CopilotACPClientError.unsupportedReasoningEffort(
                    model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "unknown",
                    effort: resolvedReasoningEffort
                )
            }

            let currentReasoningEffort = currentValue(for: "reasoning_effort", in: currentOptions)
            if currentReasoningEffort != resolvedReasoningEffort {
                let setReasoningData = try await connection.request(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": session.sessionID,
                        "configId": "reasoning_effort",
                        "value": resolvedReasoningEffort,
                    ]
                )
                currentOptions = try configOptions(from: setReasoningData)
                guard currentValue(for: "reasoning_effort", in: currentOptions) == resolvedReasoningEffort else {
                    throw CopilotACPClientError.unsupportedReasoningEffort(
                        model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "unknown",
                        effort: resolvedReasoningEffort
                    )
                }
            }
        }

        let collector = CopilotACPNotificationCollector()
        await connection.setNotificationHandler { data in
            _ = await collector.consume(data: data)
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
            ],
            timeout: promptRequestTimeout
        )
        await connection.setNotificationHandler(nil)

        return await collector.result(
            model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "gpt-5.3-codex",
            availableModels: session.availableModels
        )
    }

    func promptStream(
        workingDirectoryURL: URL,
        model: String,
        reasoningEffort: String,
        prompt: String,
        onEvent: @escaping @Sendable (CopilotACPStreamEvent) async -> Void
    ) async throws -> CopilotACPPromptResult {
        let connection = try CopilotACPConnection(
            configDirectoryURL: configDirectoryURL,
            requestTimeout: requestTimeout,
            debugEventHandler: debugEventHandler
        )
        if let debugEventHandler {
            await debugEventHandler(.processStarted(await connection.launchInfo()))
        }
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
        var currentOptions = session.configOptions
        if let resolvedModel, resolvedModel != session.currentModel {
            let setModelData = try await connection.request(
                method: "session/set_config_option",
                params: [
                    "sessionId": session.sessionID,
                    "configId": "model",
                    "value": resolvedModel,
                ]
            )
            currentOptions = try configOptions(from: setModelData)
        }

        let resolvedReasoningEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedReasoningEffort.isEmpty {
            let availableReasoningEfforts = values(for: "reasoning_effort", in: currentOptions)
            if !availableReasoningEfforts.isEmpty,
               !availableReasoningEfforts.contains(resolvedReasoningEffort)
            {
                throw CopilotACPClientError.unsupportedReasoningEffort(
                    model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "unknown",
                    effort: resolvedReasoningEffort
                )
            }

            let currentReasoningEffort = currentValue(for: "reasoning_effort", in: currentOptions)
            if currentReasoningEffort != resolvedReasoningEffort {
                let setReasoningData = try await connection.request(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": session.sessionID,
                        "configId": "reasoning_effort",
                        "value": resolvedReasoningEffort,
                    ]
                )
                currentOptions = try configOptions(from: setReasoningData)
                guard currentValue(for: "reasoning_effort", in: currentOptions) == resolvedReasoningEffort else {
                    throw CopilotACPClientError.unsupportedReasoningEffort(
                        model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "unknown",
                        effort: resolvedReasoningEffort
                    )
                }
            }
        }

        let collector = CopilotACPNotificationCollector()
        await connection.setNotificationHandler { data in
            let events = await collector.consume(data: data)
            for event in events {
                await onEvent(event)
            }
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
            ],
            timeout: promptRequestTimeout
        )
        await connection.setNotificationHandler(nil)

        return await collector.result(
            model: resolvedModel ?? session.currentModel ?? session.availableModels.first ?? "gpt-5.3-codex",
            availableModels: session.availableModels
        )
    }
}

private extension CopilotACPClient {
    struct ConfigOption {
        let id: String
        let currentValue: String?
        let values: [String]
    }

    struct SessionDescription {
        let sessionID: String
        let availableModels: [String]
        let currentModel: String?
        let configOptions: [ConfigOption]
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
        let configOptions = parseConfigOptions(result["configOptions"])
        return SessionDescription(
            sessionID: sessionID,
            availableModels: availableModels,
            currentModel: currentModel,
            configOptions: configOptions
        )
    }

    func configOptions(from data: Data) throws -> [ConfigOption] {
        let object = try jsonObject(from: data)
        guard let result = object["result"] as? [String: Any] else {
            throw CopilotACPClientError.invalidResponse(L10n.tr("GitHub Copilot ACP 返回了无效的配置更新响应。"))
        }
        return parseConfigOptions(result["configOptions"])
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

    func parseConfigOptions(_ value: Any?) -> [ConfigOption] {
        guard let options = value as? [Any] else {
            return []
        }
        return options.compactMap { optionValue in
            guard let option = optionValue as? [String: Any],
                  let id = stringValue(option["id"])
            else {
                return nil
            }

            let values = ((option["options"] as? [Any]) ?? []).compactMap { item -> String? in
                if let object = item as? [String: Any] {
                    return stringValue(object["value"]) ?? stringValue(object["id"])
                }
                return stringValue(item)
            }

            return ConfigOption(
                id: id,
                currentValue: stringValue(option["currentValue"]),
                values: values
            )
        }
    }

    func values(for configID: String, in options: [ConfigOption]) -> [String] {
        options.first(where: { $0.id == configID })?.values ?? []
    }

    func currentValue(for configID: String, in options: [ConfigOption]) -> String? {
        options.first(where: { $0.id == configID })?.currentValue
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

struct CopilotACPStreamEventParser: Sendable {
    private struct ToolCallState: Sendable {
        var name: String
        var arguments: String
        var outputText: String
        var emittedCall = false
    }

    private var messageText = ""
    private var reasoningText = ""
    private var toolCallOrder = [String]()
    private var toolCalls = [String: ToolCallState]()

    init() {}

    mutating func consume(data: Data) -> [CopilotACPStreamEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String,
            method == "session/update",
            let params = object["params"] as? [String: Any],
            let update = params["update"] as? [String: Any]
        else {
            return []
        }

        let updateType = (Self.stringValue(update["sessionUpdate"]) ?? "").lowercased()
        if updateType.contains("error") || update["error"] != nil {
            return [.error(Self.extractErrorText(from: update))]
        }
        if updateType.contains("complete") || updateType.contains("done") {
            return [.completed]
        }
        if updateType.contains("thought") || updateType.contains("reasoning") {
            guard let delta = textDelta(from: Self.extractText(from: update["content"]), accumulated: &reasoningText) else {
                return []
            }
            return [.reasoningDelta(delta)]
        }
        if updateType.contains("message") {
            guard let delta = textDelta(from: Self.extractText(from: update["content"]), accumulated: &messageText) else {
                return []
            }
            return [.messageDelta(delta)]
        }
        if updateType == "tool_call" {
            return consumeToolCall(update)
        }
        if updateType == "tool_call_update" {
            return consumeToolCallUpdate(update)
        }
        return []
    }

    func result(model: String, availableModels: [String]) -> CopilotACPPromptResult {
        CopilotACPPromptResult(
            model: model,
            availableModels: availableModels,
            toolCalls: orderedToolCalls(),
            outputText: messageText,
            reasoningText: reasoningText.isEmpty ? nil : reasoningText
        )
    }

    private mutating func consumeToolCall(_ update: [String: Any]) -> [CopilotACPStreamEvent] {
        let toolCallIDValue = update["toolCallId"]
        let rawInput = update["rawInput"]
        let titleValue = update["title"]
        let kindValue = update["kind"]
        guard let callID = Self.stringValue(toolCallIDValue) else { return [] }
        let name = Self.stringValue(titleValue) ?? Self.stringValue(kindValue) ?? "tool"
        let extractedArguments = Self.extractText(from: rawInput)
        let arguments = Self.jsonString(from: rawInput) ?? (extractedArguments.isEmpty ? "{}" : extractedArguments)
        if toolCalls[callID] == nil {
            toolCallOrder.append(callID)
        }
        var state = toolCalls[callID] ?? ToolCallState(name: name, arguments: arguments, outputText: "")
        state.name = state.name.isEmpty ? name : state.name
        state.arguments = state.arguments.isEmpty ? arguments : state.arguments
        guard !state.emittedCall else {
            toolCalls[callID] = state
            return []
        }
        state.emittedCall = true
        toolCalls[callID] = state
        return [
            .toolCall(
                CopilotACPToolCall(
                    callID: callID,
                    name: state.name.isEmpty ? "tool" : state.name,
                    arguments: state.arguments.isEmpty ? "{}" : state.arguments,
                    outputText: state.outputText.isEmpty ? nil : state.outputText
                )
            ),
        ]
    }

    private mutating func consumeToolCallUpdate(_ update: [String: Any]) -> [CopilotACPStreamEvent] {
        let toolCallIDValue = update["toolCallId"]
        let titleValue = update["title"]
        let rawOutputValue = update["rawOutput"]
        let contentValue = update["content"]
        guard let callID = Self.stringValue(toolCallIDValue) else { return [] }
        if toolCalls[callID] == nil {
            toolCallOrder.append(callID)
        }
        var state = toolCalls[callID] ?? ToolCallState(name: Self.stringValue(titleValue) ?? "tool", arguments: "{}", outputText: "")
        let rawOutputText = Self.extractText(from: rawOutputValue)
        let outputText = rawOutputText.isEmpty ? Self.extractText(from: contentValue) : rawOutputText
        guard let delta = textDelta(from: outputText, accumulated: &state.outputText) else {
            toolCalls[callID] = state
            return []
        }
        toolCalls[callID] = state
        return [.toolCallOutput(callID: callID, output: delta)]
    }

    private func orderedToolCalls() -> [CopilotACPToolCall] {
        toolCallOrder.compactMap { callID in
            guard let toolCall = toolCalls[callID] else { return nil }
            return CopilotACPToolCall(
                callID: callID,
                name: toolCall.name.isEmpty ? "tool" : toolCall.name,
                arguments: toolCall.arguments.isEmpty ? "{}" : toolCall.arguments,
                outputText: toolCall.outputText.isEmpty ? nil : toolCall.outputText
            )
        }
    }

    private func textDelta(from text: String, accumulated: inout String) -> String? {
        guard !text.isEmpty else { return nil }
        if text == accumulated {
            return nil
        }
        if text.hasPrefix(accumulated) {
            let delta = String(text.dropFirst(accumulated.count))
            accumulated = text
            return delta.isEmpty ? nil : delta
        }
        if accumulated.hasSuffix(text) {
            return nil
        }
        accumulated += text
        return text
    }

    private static func extractText(from value: Any?) -> String {
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

    private static func extractErrorText(from update: [String: Any]) -> String {
        let message = [
            stringValue(update["message"]),
            stringValue(update["error"]),
            extractText(from: update["error"]),
            extractText(from: update["content"]),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        return message.isEmpty ? L10n.tr("GitHub Copilot ACP 请求失败。") : message
    }

    private static func jsonString(from value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private actor CopilotACPNotificationCollector {
    private var parser = CopilotACPStreamEventParser()

    func consume(data: Data) -> [CopilotACPStreamEvent] {
        parser.consume(data: data)
    }

    func result(model: String, availableModels: [String]) -> CopilotACPPromptResult {
        parser.result(model: model, availableModels: availableModels)
    }
}

private enum CopilotCLIExecutableResolver {
    static func resolve() -> URL? {
        let fileManager = FileManager.default
        let processInfo = ProcessInfo.processInfo
        var seen = Set<String>()

        for candidateURL in candidateURLs(fileManager: fileManager, processInfo: processInfo) {
            let url = URL(fileURLWithPath: candidateURL.path, isDirectory: false).standardizedFileURL
            guard seen.insert(url.path).inserted,
                  isExecutableFile(at: url, fileManager: fileManager)
            else {
                continue
            }
            return url
        }

        return nil
    }

    static func launchEnvironment(for executableURL: URL?) -> [String: String]? {
        guard let executableURL else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        let executableDirectoryPath = executableURL.deletingLastPathComponent().path
        let currentPath = environment["PATH"] ?? ""
        let pathComponents = currentPath.split(separator: ":").map(String.init)
        guard !pathComponents.contains(executableDirectoryPath) else {
            return environment
        }

        environment["PATH"] = currentPath.isEmpty ? executableDirectoryPath : "\(executableDirectoryPath):\(currentPath)"
        return environment
    }

    private static func candidateURLs(fileManager: FileManager, processInfo: ProcessInfo) -> [URL] {
        let homeDirectoryURL = fileManager.homeDirectoryForCurrentUser
        var urls = pathCandidateURLs(processInfo.environment["PATH"])
        urls.append(contentsOf: fixedCandidateURLs(homeDirectoryURL: homeDirectoryURL))
        if let shellURL = shellCandidateURL(fileManager: fileManager, processInfo: processInfo) {
            urls.append(shellURL)
        }
        urls.append(contentsOf: nvmCandidateURLs(fileManager: fileManager, homeDirectoryURL: homeDirectoryURL))
        return urls
    }

    private static func pathCandidateURLs(_ path: String?) -> [URL] {
        (path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("copilot", isDirectory: false) }
    }

    private static func fixedCandidateURLs(homeDirectoryURL: URL) -> [URL] {
        [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            homeDirectoryURL.appendingPathComponent(".nvm/current/bin/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".volta/bin/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".asdf/shims/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".local/bin/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".bun/bin/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".yarn/bin/copilot", isDirectory: false).path,
            homeDirectoryURL.appendingPathComponent(".npm-global/bin/copilot", isDirectory: false).path,
        ].map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private static func nvmCandidateURLs(fileManager: FileManager, homeDirectoryURL: URL) -> [URL] {
        let nodeVersionsURL = homeDirectoryURL
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versionURLs = try? fileManager.contentsOfDirectory(
            at: nodeVersionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versionURLs
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .map {
                $0.appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("copilot", isDirectory: false)
            }
    }

    private static func shellCandidateURL(fileManager: FileManager, processInfo: ProcessInfo) -> URL? {
        let shellPath = processInfo.environment["SHELL"].flatMap {
            fileManager.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath, isDirectory: false)
        process.arguments = ["-lic", "command -v copilot"]
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let path = output
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("/") })
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func isExecutableFile(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }
}

private actor CopilotACPConnection {
    private let requestTimeout: Duration
    private let debugEventHandler: CopilotACPDebugEventHandler?
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
        requestTimeout: Duration,
        debugEventHandler: CopilotACPDebugEventHandler? = nil
    ) throws {
        self.requestTimeout = requestTimeout
        self.debugEventHandler = debugEventHandler
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        let copilotExecutableURL = CopilotCLIExecutableResolver.resolve()
        process.executableURL = copilotExecutableURL ?? URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
        var arguments = [
            "--acp",
            "--stdio",
            "--config-dir",
            configDirectoryURL.path,
            "--allow-all",
            "--no-ask-user",
        ]
        if copilotExecutableURL == nil {
            arguments.insert("copilot", at: 0)
        }
        process.arguments = arguments
        process.environment = CopilotCLIExecutableResolver.launchEnvironment(for: copilotExecutableURL)
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

    func launchInfo() -> CopilotACPConnectionLaunchInfo {
        CopilotACPConnectionLaunchInfo(
            commandLine: commandLine(),
            processID: process.processIdentifier
        )
    }

    func request(
        method: String,
        params: [String: Any],
        timeout: Duration? = nil
    ) async throws -> Data {
        if let processExitError {
            throw processExitError
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: []) + Data([0x0A])

        await debugEventHandler?(.request(method: method, payloadPreview: Self.payloadPreview(from: data)))
        do {
            let responseData = try await withCheckedThrowingContinuation { continuation in
                pendingResponses[requestID] = continuation
                timeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: timeout ?? self?.requestTimeout ?? .seconds(90))
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
            await debugEventHandler?(.response(method: method, payloadPreview: Self.payloadPreview(from: responseData)))
            return responseData
        } catch {
            await debugEventHandler?(.error("\(method): \(error.localizedDescription)"))
            throw error
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
            let method = object["method"] as? String ?? "notification"
            await debugEventHandler?(.notification(method: method, payloadPreview: Self.payloadPreview(from: data)))
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

    private func commandLine() -> String {
        let executablePath = process.executableURL?.path ?? ""
        let arguments = process.arguments ?? []
        return ([executablePath] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'"))) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func payloadPreview(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        if text.count <= CopilotACPDebugStore.payloadPreviewLimit {
            return text
        }
        return String(text.prefix(CopilotACPDebugStore.payloadPreviewLimit)) + "\n... truncated ..."
    }
}
