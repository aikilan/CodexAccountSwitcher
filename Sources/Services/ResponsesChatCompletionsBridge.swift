import Foundation

enum ResponsesChatCompletionsBridge {
    enum TranslationError: LocalizedError {
        case invalidRequest(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case let .invalidRequest(message):
                return message
            case let .invalidResponse(message):
                return message
            }
        }
    }

    static func makeChatCompletionsRequestData(
        from data: Data,
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool = false,
        usesMiniMaxReasoning: Bool = false
    ) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidRequest(L10n.tr("Responses 请求不是有效的 JSON。"))
        }

        let object = try makeChatCompletionsRequestObject(
            from: request,
            fallbackModel: fallbackModel,
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters,
            usesMiniMaxReasoning: usesMiniMaxReasoning
        )
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponsesResponseData(
        from data: Data,
        fallbackModel: String,
        usesMiniMaxReasoning: Bool = false
    ) throws -> Data {
        let object = try makeResponsesResponseObject(
            from: data,
            fallbackModel: fallbackModel,
            usesMiniMaxReasoning: usesMiniMaxReasoning
        )
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponseStreamData(from response: [String: Any]) -> Data {
        let responseID = trimmedString(response["id"]) ?? UUID().uuidString
        let model = trimmedString(response["model"]) ?? ""
        let usage = response["usage"] as? [String: Any] ?? [:]
        let outputItems = (response["output"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        var events = [String]()

        appendStreamEvent(
            named: "response.created",
            payload: [
                "type": "response.created",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "model": model,
                    "status": "in_progress",
                    "output": [],
                ],
            ],
            to: &events
        )

        for (outputIndex, item) in outputItems.enumerated() {
            let itemType = trimmedString(item["type"]) ?? "message"
            switch itemType {
            case "reasoning":
                let itemID = trimmedString(item["id"]) ?? "rs_\(UUID().uuidString)"
                let summaryItems = (item["summary"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "reasoning",
                            "status": "in_progress",
                            "summary": [],
                            "content": NSNull(),
                        ],
                    ],
                    to: &events
                )

                var completedSummary = [[String: Any]]()
                for (summaryIndex, summaryItem) in summaryItems.enumerated() {
                    let summaryType = trimmedString(summaryItem["type"]) ?? "summary_text"
                    guard summaryType == "summary_text" else { continue }
                    let text = summaryItem["text"] as? String ?? ""
                    let addedPart: [String: Any] = [
                        "type": "summary_text",
                        "text": "",
                    ]
                    let completedPart: [String: Any] = [
                        "type": "summary_text",
                        "text": text,
                    ]

                    appendStreamEvent(
                        named: "response.reasoning_summary_part.added",
                        payload: [
                            "type": "response.reasoning_summary_part.added",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "part": addedPart,
                        ],
                        to: &events
                    )
                    if !text.isEmpty {
                        appendStreamEvent(
                            named: "response.reasoning_summary_text.delta",
                            payload: [
                                "type": "response.reasoning_summary_text.delta",
                                "response_id": responseID,
                                "output_index": outputIndex,
                                "item_id": itemID,
                                "summary_index": summaryIndex,
                                "delta": text,
                            ],
                            to: &events
                        )
                    }
                    appendStreamEvent(
                        named: "response.reasoning_summary_text.done",
                        payload: [
                            "type": "response.reasoning_summary_text.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "text": text,
                        ],
                        to: &events
                    )
                    appendStreamEvent(
                        named: "response.reasoning_summary_part.done",
                        payload: [
                            "type": "response.reasoning_summary_part.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "part": completedPart,
                        ],
                        to: &events
                    )
                    completedSummary.append(completedPart)
                }

                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "reasoning",
                            "status": "completed",
                            "summary": completedSummary,
                            "content": NSNull(),
                        ],
                    ],
                    to: &events
                )
            case "message":
                let itemID = trimmedString(item["id"]) ?? "msg_\(UUID().uuidString)"
                let role = normalizedRole(from: item["role"])
                let contentItems = (item["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "message",
                            "status": "in_progress",
                            "role": role,
                            "content": [],
                        ],
                    ],
                    to: &events
                )

                var completedContent = [[String: Any]]()
                for (contentIndex, contentItem) in contentItems.enumerated() {
                    let contentType = trimmedString(contentItem["type"]) ?? "output_text"
                    guard contentType == "output_text" || contentType == "text" else { continue }
                    let text = contentItem["text"] as? String ?? ""
                    let addedPart: [String: Any] = [
                        "type": "output_text",
                        "text": "",
                    ]
                    let completedPart: [String: Any] = [
                        "type": "output_text",
                        "text": text,
                    ]

                    appendStreamEvent(
                        named: "response.content_part.added",
                        payload: [
                            "type": "response.content_part.added",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "part": addedPart,
                        ],
                        to: &events
                    )
                    if !text.isEmpty {
                        appendStreamEvent(
                            named: "response.output_text.delta",
                            payload: [
                                "type": "response.output_text.delta",
                                "response_id": responseID,
                                "output_index": outputIndex,
                                "item_id": itemID,
                                "content_index": contentIndex,
                                "delta": text,
                            ],
                            to: &events
                        )
                    }
                    appendStreamEvent(
                        named: "response.output_text.done",
                        payload: [
                            "type": "response.output_text.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "text": text,
                        ],
                        to: &events
                    )
                    appendStreamEvent(
                        named: "response.content_part.done",
                        payload: [
                            "type": "response.content_part.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "part": completedPart,
                        ],
                        to: &events
                    )
                    completedContent.append(completedPart)
                }

                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "message",
                            "status": "completed",
                            "role": role,
                            "content": completedContent,
                        ],
                    ],
                    to: &events
                )
            case "function_call":
                let itemID = trimmedString(item["id"]) ?? "fc_\(UUID().uuidString)"
                let callID = trimmedString(item["call_id"]) ?? itemID
                let name = trimmedString(item["name"]) ?? "tool"
                let arguments = trimmedString(item["arguments"]) ?? "{}"

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call",
                            "status": "in_progress",
                            "call_id": callID,
                            "name": name,
                            "arguments": "",
                        ],
                    ],
                    to: &events
                )
                if !arguments.isEmpty {
                    appendStreamEvent(
                        named: "response.function_call_arguments.delta",
                        payload: [
                            "type": "response.function_call_arguments.delta",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "delta": arguments,
                        ],
                        to: &events
                    )
                }
                appendStreamEvent(
                    named: "response.function_call_arguments.done",
                    payload: [
                        "type": "response.function_call_arguments.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item_id": itemID,
                        "arguments": arguments,
                    ],
                    to: &events
                )
                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call",
                            "status": "completed",
                            "call_id": callID,
                            "name": name,
                            "arguments": arguments,
                        ],
                    ],
                    to: &events
                )
            default:
                continue
            }
        }

        appendStreamEvent(
            named: "response.completed",
            payload: [
                "type": "response.completed",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "model": model,
                    "output": outputItems,
                    "usage": usage,
                ],
            ],
            to: &events
        )

        events.append("data: [DONE]\n\n")
        return Data(events.joined().utf8)
    }

    static func extractErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? L10n.tr("上游模型返回了未知错误。")
        }

        if let error = object["error"] as? [String: Any], let message = trimmedString(error["message"]) {
            return message
        }
        if let message = trimmedString(object["message"]) {
            return message
        }
        if let detail = trimmedString(object["detail"]) {
            return detail
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? L10n.tr("上游模型返回了未知错误。")
    }

    private static func makeChatCompletionsRequestObject(
        from request: [String: Any],
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool,
        usesMiniMaxReasoning: Bool
    ) throws -> [String: Any] {
        let model = trimmedString(request["model"]) ?? fallbackModel
        let instructions = trimmedString(request["instructions"])
        let messages = try translateMessages(
            from: request["input"],
            instructions: instructions,
            usesMiniMaxReasoning: usesMiniMaxReasoning
        )
        let tools = translateTools(
            from: request["tools"],
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters
        )
        let toolChoice = translateToolChoice(from: request["tool_choice"])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let toolChoice {
            body["tool_choice"] = toolChoice
        }
        if let maxTokens = intValue(request["max_output_tokens"] ?? request["max_tokens"]) {
            body["max_tokens"] = maxTokens
        }
        if let parallelToolCalls = request["parallel_tool_calls"] as? Bool {
            body["parallel_tool_calls"] = parallelToolCalls
        }
        if usesMiniMaxReasoning {
            body["reasoning_split"] = true
        }
        return body
    }

    private static func translateMessages(
        from input: Any?,
        instructions: String?,
        usesMiniMaxReasoning: Bool
    ) throws -> [[String: Any]] {
        var messages = [[String: Any]]()
        if let instructions, !instructions.isEmpty {
            messages.append([
                "role": "system",
                "content": instructions,
            ])
        }

        if let text = input as? String, !text.isEmpty {
            messages.append([
                "role": "user",
                "content": text,
            ])
            return messages
        }

        guard let items = input as? [Any] else {
            return messages
        }

        var lastAssistantIndex: Int?
        var pendingReasoningDetails = [[String: Any]]()

        for itemValue in items {
            guard let item = itemValue as? [String: Any], let type = trimmedString(item["type"]) else { continue }

            switch type {
            case "reasoning":
                guard usesMiniMaxReasoning else { continue }
                let reasoningDetails = reasoningDetails(from: item)
                guard !reasoningDetails.isEmpty else { continue }
                if let index = lastAssistantIndex {
                    var message = messages[index]
                    mergeReasoningDetails(reasoningDetails, into: &message)
                    messages[index] = message
                } else {
                    pendingReasoningDetails.append(contentsOf: reasoningDetails)
                }
            case "message":
                let role = normalizedRole(from: item["role"])
                var message: [String: Any] = ["role": role]
                if let content = translateMessageContent(from: item["content"], role: role) {
                    message["content"] = content
                } else if role == "assistant" {
                    message["content"] = NSNull()
                } else {
                    message["content"] = ""
                }
                if usesMiniMaxReasoning, role == "assistant", !pendingReasoningDetails.isEmpty {
                    mergeReasoningDetails(pendingReasoningDetails, into: &message)
                    pendingReasoningDetails.removeAll()
                }
                messages.append(message)
                lastAssistantIndex = role == "assistant" ? messages.index(before: messages.endIndex) : nil
            case "function_call", "custom_tool_call":
                let toolCall = makeToolCall(from: item, type: type)
                if let index = lastAssistantIndex {
                    var message = messages[index]
                    if usesMiniMaxReasoning, !pendingReasoningDetails.isEmpty {
                        mergeReasoningDetails(pendingReasoningDetails, into: &message)
                        pendingReasoningDetails.removeAll()
                    }
                    var toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
                    toolCalls.append(toolCall)
                    message["tool_calls"] = toolCalls
                    if message["content"] == nil {
                        message["content"] = NSNull()
                    }
                    messages[index] = message
                } else {
                    var message: [String: Any] = [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [toolCall],
                    ]
                    if usesMiniMaxReasoning, !pendingReasoningDetails.isEmpty {
                        mergeReasoningDetails(pendingReasoningDetails, into: &message)
                        pendingReasoningDetails.removeAll()
                    }
                    messages.append(message)
                    lastAssistantIndex = messages.index(before: messages.endIndex)
                }
            case "function_call_output":
                messages.append([
                    "role": "tool",
                    "tool_call_id": trimmedString(item["call_id"]) ?? UUID().uuidString,
                    "content": toolOutputText(from: item["output"]),
                ])
                lastAssistantIndex = nil
            default:
                continue
            }
        }

        return messages
    }

    private static func reasoningDetails(from item: [String: Any]) -> [[String: Any]] {
        var details = [[String: Any]]()

        let summaryItems = (item["summary"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for summaryItem in summaryItems {
            guard let text = trimmedString(summaryItem["text"]) else { continue }
            details.append(["text": text])
        }
        if !details.isEmpty {
            return details
        }

        let contentItems = (item["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for contentItem in contentItems {
            guard let text = trimmedString(contentItem["text"]) else { continue }
            details.append(["text": text])
        }
        if !details.isEmpty {
            return details
        }

        if let text = trimmedString(item["text"]) {
            details.append(["text": text])
        }
        return details
    }

    private static func mergeReasoningDetails(_ details: [[String: Any]], into message: inout [String: Any]) {
        guard !details.isEmpty else { return }
        let existingDetails = (message["reasoning_details"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        message["reasoning_details"] = existingDetails + details
    }

    private static func normalizedRole(from value: Any?) -> String {
        switch trimmedString(value) {
        case "assistant":
            return "assistant"
        case "system":
            return "system"
        default:
            return "user"
        }
    }

    private static func translateMessageContent(from value: Any?, role: String) -> Any? {
        if let string = value as? String {
            return string
        }

        guard let content = value as? [Any] else {
            return nil
        }

        var textParts = [String]()
        var richParts = [[String: Any]]()
        var hasImage = false

        for itemValue in content {
            guard let item = itemValue as? [String: Any], let type = trimmedString(item["type"]) else { continue }
            switch type {
            case "input_text", "output_text", "text":
                let text = item["text"] as? String ?? ""
                textParts.append(text)
                richParts.append([
                    "type": "text",
                    "text": text,
                ])
            case "input_image":
                guard let imageURL = trimmedString(item["image_url"]) else { continue }
                hasImage = true
                richParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": imageURL,
                    ],
                ])
            default:
                continue
            }
        }

        if hasImage {
            return richParts
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n\n")
        }
        return role == "assistant" ? NSNull() : ""
    }

    private static func makeToolCall(from item: [String: Any], type: String) -> [String: Any] {
        let arguments: String
        if type == "custom_tool_call" {
            arguments = trimmedString(item["input"]) ?? "{}"
        } else if let stringArguments = item["arguments"] as? String {
            arguments = stringArguments
        } else {
            arguments = jsonString(from: item["arguments"] ?? [:]) ?? "{}"
        }

        return [
            "id": trimmedString(item["call_id"]) ?? UUID().uuidString,
            "type": "function",
            "function": [
                "name": trimmedString(item["name"]) ?? "tool",
                "arguments": arguments,
            ],
        ]
    }

    private static func translateTools(
        from value: Any?,
        requiresNonEmptyToolParameters: Bool
    ) -> [[String: Any]] {
        guard let tools = value as? [Any] else {
            return []
        }

        return tools.compactMap { toolValue in
            guard
                let tool = toolValue as? [String: Any],
                let name = trimmedString(tool["name"])
            else {
                return nil
            }

            var function: [String: Any] = ["name": name]
            if let description = trimmedString(tool["description"]) {
                function["description"] = description
            }
            if let parameters = normalizedToolParameters(
                from: tool["parameters"] ?? tool["input_schema"],
                requiresNonEmptyToolParameters: requiresNonEmptyToolParameters
            ) {
                function["parameters"] = parameters
            }

            return [
                "type": "function",
                "function": function,
            ]
        }
    }

    private static func normalizedToolParameters(
        from value: Any?,
        requiresNonEmptyToolParameters: Bool
    ) -> [String: Any]? {
        guard var parameters = value as? [String: Any] else {
            return requiresNonEmptyToolParameters ? compatibilityPlaceholderParameters() : nil
        }

        guard requiresNonEmptyToolParameters else {
            return parameters
        }

        guard trimmedString(parameters["type"]) == "object" else {
            return parameters
        }

        let properties = parameters["properties"] as? [String: Any] ?? [:]
        guard properties.isEmpty else {
            return parameters
        }

        parameters["properties"] = compatibilityPlaceholderParameters()["properties"]
        return parameters
    }

    private static func compatibilityPlaceholderParameters() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "_compat": [
                    "type": "boolean",
                    "description": "Compatibility placeholder.",
                ],
            ],
        ]
    }

    private static func translateToolChoice(from value: Any?) -> Any? {
        guard let value else {
            return nil
        }

        if let string = trimmedString(value) {
            switch string {
            case "auto", "required", "none":
                return string
            default:
                return nil
            }
        }

        guard
            let object = value as? [String: Any],
            let type = trimmedString(object["type"])
        else {
            return nil
        }

        switch type {
        case "function", "tool":
            guard let name = trimmedString(object["name"]) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": name,
                ],
            ]
        case "auto", "required", "none":
            return type
        default:
            return nil
        }
    }

    private static func toolOutputText(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let items as [Any]:
            let texts = items.compactMap { itemValue -> String? in
                guard
                    let item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "input_text" || type == "text"
                else {
                    return nil
                }
                return item["text"] as? String
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n\n")
            }
            return jsonString(from: items) ?? ""
        case nil:
            return ""
        default:
            return jsonString(from: value) ?? ""
        }
    }

    private static func makeResponsesResponseObject(
        from data: Data,
        fallbackModel: String,
        usesMiniMaxReasoning: Bool
    ) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse(L10n.tr("上游 Chat Completions 返回了无效 JSON。"))
        }

        guard
            let choices = response["choices"] as? [Any],
            let choice = choices.first as? [String: Any],
            let message = choice["message"] as? [String: Any]
        else {
            throw TranslationError.invalidResponse(L10n.tr("上游 Chat Completions 缺少 choices。"))
        }

        var output = [[String: Any]]()
        let normalizedOutput = normalizedOutput(from: message, usesMiniMaxReasoning: usesMiniMaxReasoning)
        if let reasoningItem = normalizedOutput.reasoningItem {
            output.append(reasoningItem)
        }
        if !normalizedOutput.content.isEmpty {
            output.append([
                "id": "msg_\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": normalizedOutput.content,
            ])
        }

        let toolCalls = message["tool_calls"] as? [Any] ?? []
        for toolCallValue in toolCalls {
            guard
                let toolCall = toolCallValue as? [String: Any],
                let function = toolCall["function"] as? [String: Any]
            else {
                continue
            }

            output.append([
                "id": trimmedString(toolCall["id"]) ?? "fc_\(UUID().uuidString)",
                "type": "function_call",
                "status": "completed",
                "call_id": trimmedString(toolCall["id"]) ?? UUID().uuidString,
                "name": trimmedString(function["name"]) ?? "tool",
                "arguments": trimmedString(function["arguments"]) ?? "{}",
            ])
        }

        if output.isEmpty {
            output.append([
                "id": "msg_\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "",
                ]],
            ])
        }

        let usage = response["usage"] as? [String: Any]
        let inputTokens = intValue(usage?["prompt_tokens"]) ?? intValue(usage?["input_tokens"]) ?? 0
        let outputTokens = intValue(usage?["completion_tokens"]) ?? intValue(usage?["output_tokens"]) ?? 0
        let totalTokens = intValue(usage?["total_tokens"]) ?? (inputTokens + outputTokens)

        return [
            "id": trimmedString(response["id"]) ?? UUID().uuidString,
            "object": "response",
            "model": trimmedString(response["model"]) ?? fallbackModel,
            "output": output,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "total_tokens": totalTokens,
            ],
        ]
    }

    private static func normalizedOutput(
        from message: [String: Any],
        usesMiniMaxReasoning: Bool
    ) -> (reasoningItem: [String: Any]?, content: [[String: Any]]) {
        var reasoningTexts = usesMiniMaxReasoning ? reasoningTexts(from: message["reasoning_details"]) : []
        let extraction = outputTextContent(
            from: message["content"],
            stripMiniMaxThinking: usesMiniMaxReasoning,
            collectMiniMaxThinking: usesMiniMaxReasoning && reasoningTexts.isEmpty
        )
        if reasoningTexts.isEmpty {
            reasoningTexts = extraction.reasoningTexts
        }

        let reasoningItem: [String: Any]?
        if usesMiniMaxReasoning, !reasoningTexts.isEmpty {
            reasoningItem = [
                "id": "rs_\(UUID().uuidString)",
                "type": "reasoning",
                "summary": reasoningTexts.map { text in
                    [
                        "type": "summary_text",
                        "text": text,
                    ]
                },
                "content": NSNull(),
            ]
        } else {
            reasoningItem = nil
        }

        return (reasoningItem, extraction.content)
    }

    private static func reasoningTexts(from value: Any?) -> [String] {
        switch value {
        case let string as String:
            return trimmedString(string).map { [$0] } ?? []
        case let items as [Any]:
            return items.compactMap { itemValue in
                if let text = trimmedString(itemValue) {
                    return text
                }
                guard let item = itemValue as? [String: Any] else {
                    return nil
                }
                return trimmedString(item["text"])
            }
        default:
            return []
        }
    }

    private static func outputTextContent(
        from value: Any?,
        stripMiniMaxThinking: Bool = false,
        collectMiniMaxThinking: Bool = false
    ) -> (content: [[String: Any]], reasoningTexts: [String]) {
        switch value {
        case let string as String:
            let extracted = extractMiniMaxThinking(
                from: string,
                stripMiniMaxThinking: stripMiniMaxThinking,
                collectMiniMaxThinking: collectMiniMaxThinking
            )
            guard !extracted.content.isEmpty else {
                return ([], extracted.reasoningTexts)
            }
            return ([[
                "type": "output_text",
                "text": extracted.content,
            ]], extracted.reasoningTexts)
        case let items as [Any]:
            var reasoningTexts = [String]()
            let content = items.compactMap { itemValue -> [String: Any]? in
                guard
                    let item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "text" || type == "output_text",
                    let text = item["text"] as? String
                else {
                    return nil
                }
                let extracted = extractMiniMaxThinking(
                    from: text,
                    stripMiniMaxThinking: stripMiniMaxThinking,
                    collectMiniMaxThinking: collectMiniMaxThinking
                )
                reasoningTexts.append(contentsOf: extracted.reasoningTexts)
                guard !extracted.content.isEmpty else {
                    return nil
                }
                return [
                    "type": "output_text",
                    "text": extracted.content,
                ]
            }
            return (content, reasoningTexts)
        default:
            return ([], [])
        }
    }

    private static func extractMiniMaxThinking(
        from text: String,
        stripMiniMaxThinking: Bool,
        collectMiniMaxThinking: Bool
    ) -> (content: String, reasoningTexts: [String]) {
        guard stripMiniMaxThinking, !text.isEmpty else {
            return (text, [])
        }

        guard
            let regex = try? NSRegularExpression(
                pattern: "<think>(.*?)</think>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else {
            return (text, [])
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return (text, [])
        }

        let nsText = text as NSString
        let reasoningTexts = collectMiniMaxThinking ? matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            let thinkRange = match.range(at: 1)
            guard thinkRange.location != NSNotFound else { return nil }
            return trimmedString(nsText.substring(with: thinkRange))
        } : []

        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, reasoningTexts)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func jsonString(from value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func appendStreamEvent(named eventName: String, payload: [String: Any], to events: inout [String]) {
        let payloadString = jsonString(from: payload) ?? "{}"
        events.append("event: \(eventName)\ndata: \(payloadString)\n\n")
    }
}
