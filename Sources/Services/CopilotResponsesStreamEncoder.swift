import Foundation

struct CopilotResponsesStreamEncoder {
    private let responseID: String
    private let model: String

    private var nextOutputIndex = 0
    private var outputItems = [[String: Any]]()
    private var reasoningState: TextItemState?
    private var messageState: TextItemState?
    private var completedToolCallIDs = Set<String>()

    init(
        responseID: String = UUID().uuidString,
        model: String
    ) {
        self.responseID = responseID
        self.model = model
    }

    mutating func startData() -> Data {
        ResponsesChatCompletionsBridge.makeStreamEventData(
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
            ]
        )
    }

    mutating func encode(event: CopilotACPStreamEvent) -> Data {
        switch event {
        case let .reasoningDelta(text):
            return encodeReasoningDelta(text)
        case let .messageDelta(text):
            return encodeMessageDelta(text)
        case let .toolCall(toolCall):
            return encodeToolCall(toolCall)
        case let .toolCallOutput(callID, output):
            return encodeToolCallOutput(callID: callID, output: output)
        case .error, .completed:
            return Data()
        }
    }

    mutating func completeData() -> Data {
        var data = Data()
        if let reasoningState {
            data.append(completeReasoning(state: reasoningState))
            outputItems.append([
                "id": reasoningState.itemID,
                "type": "reasoning",
                "status": "completed",
                "summary": [[
                    "type": "summary_text",
                    "text": reasoningState.text,
                ]],
                "content": NSNull(),
            ])
            self.reasoningState = nil
        }
        if let messageState {
            data.append(completeMessage(state: messageState))
            outputItems.append([
                "id": messageState.itemID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": messageState.text,
                ]],
            ])
            self.messageState = nil
        }

        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.completed",
                payload: [
                    "type": "response.completed",
                    "response": [
                        "id": responseID,
                        "object": "response",
                        "model": model,
                        "status": "completed",
                        "output": outputItems,
                        "usage": [
                            "input_tokens": 0,
                            "output_tokens": 0,
                            "total_tokens": 0,
                        ],
                    ],
                ]
            )
        )
        data.append(ResponsesChatCompletionsBridge.makeStreamDoneData())
        return data
    }

    mutating func failureData(message: String) -> Data {
        var data = Data()
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.failed",
                payload: [
                    "type": "response.failed",
                    "response": [
                        "id": responseID,
                        "object": "response",
                        "model": model,
                        "status": "failed",
                        "output": outputItems,
                        "error": [
                            "message": message,
                            "type": "api_error",
                        ],
                    ],
                ]
            )
        )
        data.append(ResponsesChatCompletionsBridge.makeStreamDoneData())
        return data
    }

    private mutating func encodeReasoningDelta(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        var data = Data()
        if reasoningState == nil {
            reasoningState = TextItemState(
                itemID: "rs_\(UUID().uuidString)",
                outputIndex: nextOutputIndex
            )
            nextOutputIndex += 1
            data.append(
                ResponsesChatCompletionsBridge.makeStreamEventData(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": reasoningState?.outputIndex ?? 0,
                        "item": [
                            "id": reasoningState?.itemID ?? "",
                            "type": "reasoning",
                            "status": "in_progress",
                            "summary": [],
                            "content": NSNull(),
                        ],
                    ]
                )
            )
            data.append(
                ResponsesChatCompletionsBridge.makeStreamEventData(
                    named: "response.reasoning_summary_part.added",
                    payload: [
                        "type": "response.reasoning_summary_part.added",
                        "response_id": responseID,
                        "output_index": reasoningState?.outputIndex ?? 0,
                        "item_id": reasoningState?.itemID ?? "",
                        "summary_index": 0,
                        "part": [
                            "type": "summary_text",
                            "text": "",
                        ],
                    ]
                )
            )
        }

        guard var state = reasoningState else { return data }
        state.text += text
        reasoningState = state
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.reasoning_summary_text.delta",
                payload: [
                    "type": "response.reasoning_summary_text.delta",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "summary_index": 0,
                    "delta": text,
                ]
            )
        )
        return data
    }

    private mutating func encodeMessageDelta(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        var data = Data()
        if messageState == nil {
            messageState = TextItemState(
                itemID: "msg_\(UUID().uuidString)",
                outputIndex: nextOutputIndex
            )
            nextOutputIndex += 1
            data.append(
                ResponsesChatCompletionsBridge.makeStreamEventData(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": messageState?.outputIndex ?? 0,
                        "item": [
                            "id": messageState?.itemID ?? "",
                            "type": "message",
                            "status": "in_progress",
                            "role": "assistant",
                            "content": [],
                        ],
                    ]
                )
            )
            data.append(
                ResponsesChatCompletionsBridge.makeStreamEventData(
                    named: "response.content_part.added",
                    payload: [
                        "type": "response.content_part.added",
                        "response_id": responseID,
                        "output_index": messageState?.outputIndex ?? 0,
                        "item_id": messageState?.itemID ?? "",
                        "content_index": 0,
                        "part": [
                            "type": "output_text",
                            "text": "",
                        ],
                    ]
                )
            )
        }

        guard var state = messageState else { return data }
        state.text += text
        messageState = state
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_text.delta",
                payload: [
                    "type": "response.output_text.delta",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "content_index": 0,
                    "delta": text,
                ]
            )
        )
        return data
    }

    private mutating func encodeToolCall(_ toolCall: CopilotACPToolCall) -> Data {
        guard completedToolCallIDs.insert(toolCall.callID).inserted else {
            return Data()
        }

        let itemID = "fc_\(toolCall.callID)"
        let outputIndex = nextOutputIndex
        nextOutputIndex += 1
        outputItems.append([
            "id": itemID,
            "type": "function_call",
            "status": "completed",
            "call_id": toolCall.callID,
            "name": toolCall.name,
            "arguments": toolCall.arguments,
        ])

        var data = Data()
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.added",
                payload: [
                    "type": "response.output_item.added",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "function_call",
                        "status": "in_progress",
                        "call_id": toolCall.callID,
                        "name": toolCall.name,
                        "arguments": "",
                    ],
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.function_call_arguments.delta",
                payload: [
                    "type": "response.function_call_arguments.delta",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item_id": itemID,
                    "delta": toolCall.arguments,
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.function_call_arguments.done",
                payload: [
                    "type": "response.function_call_arguments.done",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item_id": itemID,
                    "arguments": toolCall.arguments,
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.done",
                payload: [
                    "type": "response.output_item.done",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "function_call",
                        "status": "completed",
                        "call_id": toolCall.callID,
                        "name": toolCall.name,
                        "arguments": toolCall.arguments,
                    ],
                ]
            )
        )
        return data
    }

    private mutating func encodeToolCallOutput(callID: String, output: String) -> Data {
        guard !output.isEmpty else { return Data() }
        let itemID = "fco_\(UUID().uuidString)"
        let outputIndex = nextOutputIndex
        nextOutputIndex += 1
        outputItems.append([
            "id": itemID,
            "type": "function_call_output",
            "status": "completed",
            "call_id": callID,
            "output": output,
        ])

        var data = Data()
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.added",
                payload: [
                    "type": "response.output_item.added",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "function_call_output",
                        "status": "in_progress",
                        "call_id": callID,
                        "output": "",
                    ],
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.done",
                payload: [
                    "type": "response.output_item.done",
                    "response_id": responseID,
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "function_call_output",
                        "status": "completed",
                        "call_id": callID,
                        "output": output,
                    ],
                ]
            )
        )
        return data
    }

    private func completeReasoning(state: TextItemState) -> Data {
        var data = Data()
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.reasoning_summary_text.done",
                payload: [
                    "type": "response.reasoning_summary_text.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "summary_index": 0,
                    "text": state.text,
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.reasoning_summary_part.done",
                payload: [
                    "type": "response.reasoning_summary_part.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "summary_index": 0,
                    "part": [
                        "type": "summary_text",
                        "text": state.text,
                    ],
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.done",
                payload: [
                    "type": "response.output_item.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item": [
                        "id": state.itemID,
                        "type": "reasoning",
                        "status": "completed",
                        "summary": [[
                            "type": "summary_text",
                            "text": state.text,
                        ]],
                        "content": NSNull(),
                    ],
                ]
            )
        )
        return data
    }

    private func completeMessage(state: TextItemState) -> Data {
        var data = Data()
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_text.done",
                payload: [
                    "type": "response.output_text.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "content_index": 0,
                    "text": state.text,
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.content_part.done",
                payload: [
                    "type": "response.content_part.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "content_index": 0,
                    "part": [
                        "type": "output_text",
                        "text": state.text,
                    ],
                ]
            )
        )
        data.append(
            ResponsesChatCompletionsBridge.makeStreamEventData(
                named: "response.output_item.done",
                payload: [
                    "type": "response.output_item.done",
                    "response_id": responseID,
                    "output_index": state.outputIndex,
                    "item": [
                        "id": state.itemID,
                        "type": "message",
                        "status": "completed",
                        "role": "assistant",
                        "content": [[
                            "type": "output_text",
                            "text": state.text,
                        ]],
                    ],
                ]
            )
        )
        return data
    }

    private struct TextItemState {
        let itemID: String
        let outputIndex: Int
        var text = ""
    }
}
