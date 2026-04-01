import Foundation
import XCTest
@testable import Orbit

final class CodexOAuthClaudeBridgeManagerTests: XCTestCase {
    override func tearDown() {
        MiniMaxProviderMockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MiniMaxProviderMockURLProtocol.self)
        super.tearDown()
    }

    func testResponsesChatCompletionsBridgeConvertsResponsesRequestToChatCompletions() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "instructions": "You are Codex.",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "列出当前目录",
                        ],
                    ],
                ],
                [
                    "type": "function_call",
                    "call_id": "call_ls",
                    "name": "exec",
                    "arguments": "{\"cmd\":\"ls\"}",
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_ls",
                    "output": "README.md",
                ],
            ],
            "tools": [
                [
                    "type": "function",
                    "name": "exec",
                    "description": "run shell command",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "cmd": ["type": "string"],
                        ],
                    ],
                ],
            ],
            "tool_choice": [
                "type": "function",
                "name": "exec",
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "deepseek-chat"
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let toolChoice = try XCTUnwrap(object["tool_choice"] as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "列出当前目录")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual((messages[2]["tool_calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["content"] as? String, "README.md")
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "exec")
        XCTAssertEqual(toolChoice["type"] as? String, "function")
    }

    func testResponsesChatCompletionsBridgeConvertsChatCompletionsResponseToResponses() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_test",
            "model": "deepseek-chat",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "done",
                        "tool_calls": [
                            [
                                "id": "call_ls",
                                "type": "function",
                                "function": [
                                    "name": "exec",
                                    "arguments": "{\"cmd\":\"ls\"}",
                                ],
                            ],
                        ],
                    ],
                    "finish_reason": "tool_calls",
                ],
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15,
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: response,
            fallbackModel: "deepseek-chat"
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])

        XCTAssertEqual(object["id"] as? String, "chatcmpl_test")
        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(output.first?["type"] as? String, "message")
        XCTAssertEqual((output.first?["content"] as? [[String: Any]])?.first?["text"] as? String, "done")
        XCTAssertEqual(output.last?["type"] as? String, "function_call")
        XCTAssertEqual(output.last?["name"] as? String, "exec")
        XCTAssertEqual((object["usage"] as? [String: Any])?["total_tokens"] as? Int, 15)
    }

    func testResponsesChatCompletionsBridgeFillsEmptyToolParametersForMiniMaxCompatibility() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "input": "关闭页面",
            "tools": [
                [
                    "type": "function",
                    "name": "browser_close",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "MiniMax-M2.7",
            requiresNonEmptyToolParameters: true,
            usesMiniMaxReasoning: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertEqual(Array(properties.keys), ["_compat"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(object["reasoning_split"] as? Bool, true)
    }

    func testResponsesChatCompletionsBridgePreservesMiniMaxReasoningDetailsInHistory() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "parallel_tool_calls": true,
            "input": [
                [
                    "type": "reasoning",
                    "summary": [
                        [
                            "type": "summary_text",
                            "text": "先分析目录结构。",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "我先看看项目结构。",
                        ],
                    ],
                ],
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "MiniMax-M2.7",
            usesMiniMaxReasoning: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let reasoningDetails = try XCTUnwrap(messages.first?["reasoning_details"] as? [[String: Any]])

        XCTAssertEqual(reasoningDetails.first?["text"] as? String, "先分析目录结构。")
        XCTAssertEqual(messages.first?["content"] as? String, "我先看看项目结构。")
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
    }

    func testResponsesChatCompletionsBridgeSerializesMiniMaxToolOutputsAsAdjacentPairs() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_a",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"pwd\"}",
                ],
                [
                    "type": "function_call",
                    "call_id": "call_b",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"ls\"}",
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_a",
                    "output": "/tmp/project",
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_b",
                    "output": "README.md",
                ],
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "MiniMax-M2.7",
            usesMiniMaxReasoning: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let firstToolCalls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        let secondToolCalls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertEqual(firstToolCalls.first?["id"] as? String, "call_a")
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_a")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(secondToolCalls.first?["id"] as? String, "call_b")
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_b")
    }

    func testResponsesChatCompletionsBridgeConvertsMiniMaxReasoningDetailsToReasoningOutput() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_minimax_reasoning",
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_details": [
                            [
                                "text": "先确认依赖关系，再给结论。",
                            ],
                        ],
                        "content": "这是最终答案。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 12,
                "completion_tokens": 8,
                "total_tokens": 20,
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: response,
            fallbackModel: "MiniMax-M2.7",
            usesMiniMaxReasoning: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let summary = try XCTUnwrap(output.first?["summary"] as? [[String: Any]])
        let content = try XCTUnwrap(output.dropFirst().first?["content"] as? [[String: Any]])

        XCTAssertEqual(output.first?["type"] as? String, "reasoning")
        XCTAssertEqual(summary.first?["text"] as? String, "先确认依赖关系，再给结论。")
        XCTAssertEqual(output.dropFirst().first?["type"] as? String, "message")
        XCTAssertEqual(content.first?["text"] as? String, "这是最终答案。")
    }

    func testResponsesChatCompletionsBridgeSplitsMiniMaxThinkTagsFromVisibleOutput() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_minimax_think",
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "<think>先看模块，再输出总结。</think>\n最终答案",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 12,
                "completion_tokens": 8,
                "total_tokens": 20,
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: response,
            fallbackModel: "MiniMax-M2.7",
            usesMiniMaxReasoning: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let summary = try XCTUnwrap(output.first?["summary"] as? [[String: Any]])
        let content = try XCTUnwrap(output.dropFirst().first?["content"] as? [[String: Any]])

        XCTAssertEqual(output.first?["type"] as? String, "reasoning")
        XCTAssertEqual(summary.first?["text"] as? String, "先看模块，再输出总结。")
        XCTAssertEqual(content.first?["text"] as? String, "最终答案")
    }

    func testResponsesBridgeRequestUsesStreamingAndListInput() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "max_tokens": 256,
            "system": "You are Claude Code.",
            "messages": [
                [
                    "role": "user",
                    "content": "分析一下这个项目",
                ],
            ],
        ])

        let bridged = try makeCodexResponsesBridgeRequestData(from: request, fallbackModel: "gpt-5.4")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])

        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        XCTAssertEqual(object["instructions"] as? String, "You are Claude Code.")
        XCTAssertEqual((object["input"] as? [Any])?.isEmpty, false)
        XCTAssertNil(object["max_output_tokens"])
    }

    func testExtractCompletedResponsesBridgeDataReturnsFinalResponseObject() throws {
        let sseBody = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_test","status":"in_progress"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-5.4","output":[{"id":"msg_test","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"hello from codex"}]}],"usage":{"input_tokens":12,"output_tokens":7}}}

        """

        let extracted = try extractCodexResponsesBridgeCompletedData(from: Data(sseBody.utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: extracted) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "resp_test")
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let content = try XCTUnwrap(output.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello from codex")
    }

    func testBridgeReturnsAnthropicSSEForStreamingClaudeRequests() async throws {
        let upstreamSSE = """
        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-5.4","output":[{"id":"msg_test","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"hello from codex"}]}],"usage":{"input_tokens":12,"output_tokens":7}}}

        """

        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data(upstreamSSE.utf8)
                )
            }
        )
        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .codexAuthPayload(CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: "sk-test")),
            model: "gpt-5.4",
            availableModels: ["gpt-5.4"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("codex-oauth-bridge", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "stream": true,
            "messages": [
                [
                    "role": "user",
                    "content": "分析一下这个项目",
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertTrue(text.contains("event: message_start"))
        XCTAssertTrue(text.contains("event: content_block_start"))
        XCTAssertTrue(text.contains("event: message_stop"))
    }

    func testMiniMaxProviderBridgeDisablesParallelToolCallsAndStripsThinkingFromVisibleText() async throws {
        let recordedRequestBody = RecordedRequestBodyBox()
        MiniMaxProviderMockURLProtocol.requestHandler = { request in
            recordedRequestBody.data = requestBody(from: request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl_minimax_bridge",
                "model": "MiniMax-M2.7",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": "<think>先检查模块关系。</think>最终结论。",
                        ],
                        "finish_reason": "stop",
                    ],
                ],
                "usage": [
                    "prompt_tokens": 12,
                    "completion_tokens": 8,
                    "total_tokens": 20,
                ],
            ])
            return (response, body)
        }
        URLProtocol.registerClass(MiniMaxProviderMockURLProtocol.self)

        let manager = CodexOAuthClaudeBridgeManager()

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .provider(
                baseURL: "https://api.minimax.io/v1",
                apiKeyEnvName: "MINIMAX_API_KEY",
                apiKey: "sk-minimax-test",
                supportsResponsesAPI: false
            ),
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("codex-oauth-bridge", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "stream": false,
            "messages": [
                [
                    "role": "user",
                    "content": "分析一下这个项目",
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        let upstreamRequestBody = try XCTUnwrap(recordedRequestBody.data)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamRequestBody) as? [String: Any])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(upstreamRequestObject["reasoning_split"] as? Bool, true)
        XCTAssertEqual(upstreamRequestObject["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "最终结论。")
    }

    func testModelsEndpointReturnsAvailableModelsForProviderBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .provider(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnvName: "OPENAI_API_KEY",
                apiKey: "sk-openai-test",
                supportsResponsesAPI: true
            ),
            model: "gpt-5.4",
            availableModels: ["gpt-4.1", "gpt-4o"]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-4.1", "gpt-4o", "gpt-5.4"])
    }

    func testModelsEndpointFallsBackToSingleDefaultModelForProviderBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .provider(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnvName: "OPENAI_API_KEY",
                apiKey: "sk-openai-test",
                supportsResponsesAPI: true
            ),
            model: "gpt-5.4",
            availableModels: []
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-5.4"])
    }

    func testModelsEndpointReturnsAvailableModelsForCodexOAuthBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .codexAuthPayload(CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: "sk-test")),
            model: "gpt-5.4",
            availableModels: [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
            ]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-5.3-codex", "gpt-5.4", "gpt-5.2-codex"])
    }
}

private final class MiniMaxProviderMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == "api.minimax.io"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MiniMaxProviderMockURLProtocol.requestHandler 未设置")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RecordedRequestBodyBox: @unchecked Sendable {
    var data: Data?
}

private func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }

    return data.isEmpty ? nil : data
}
