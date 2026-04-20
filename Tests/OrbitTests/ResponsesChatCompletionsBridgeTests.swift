import Foundation
import XCTest
@testable import Orbit

final class ResponsesChatCompletionsBridgeTests: XCTestCase {
    func testCopilotACPStreamEventParserEmitsDeltasForCumulativeUpdates() throws {
        var parser = CopilotACPStreamEventParser()

        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先")),
            [.reasoningDelta("先")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先检查")),
            [.reasoningDelta("检查")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先检查")),
            []
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "message", content: "完成")),
            [.messageDelta("完成")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "message", content: "完成。")),
            [.messageDelta("。")]
        )

        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_1",
                    "title": "Shell",
                    "rawInput": ["command": "pwd"],
                ])
            ),
            [
                .toolCall(
                    CopilotACPToolCall(
                        callID: "call_1",
                        name: "Shell",
                        arguments: #"{"command":"pwd"}"#,
                        outputText: nil
                    )
                ),
            ]
        )
        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call_1",
                    "rawOutput": "/tmp",
                ])
            ),
            [.toolCallOutput(callID: "call_1", output: "/tmp")]
        )
        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call_1",
                    "rawOutput": "/tmp/project",
                ])
            ),
            [.toolCallOutput(callID: "call_1", output: "/project")]
        )
    }

    func testCopilotResponsesStreamEncoderEmitsLiveEvents() throws {
        var encoder = CopilotResponsesStreamEncoder(responseID: "resp_test", model: "gpt-4.1")
        var data = Data()

        data.append(encoder.startData())
        data.append(encoder.encode(event: .reasoningDelta("先检查。")))
        data.append(
            encoder.encode(
                event: .toolCall(
                    CopilotACPToolCall(
                        callID: "call_1",
                        name: "Shell",
                        arguments: #"{"command":"pwd"}"#,
                        outputText: nil
                    )
                )
            )
        )
        data.append(encoder.encode(event: .toolCallOutput(callID: "call_1", output: "/tmp/project")))
        data.append(encoder.encode(event: .messageDelta("完成。")))
        data.append(encoder.completeData())

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("event: response.created"))
        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""type":"function_call_output""#))
        XCTAssertTrue(text.contains("event: response.output_text.delta"))
        XCTAssertTrue(text.contains("event: response.completed"))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testMakeResponseStreamDataIncludesFunctionCallOutputItems() throws {
        let response: [String: Any] = [
            "id": "resp_copilot",
            "object": "response",
            "model": "gpt-5.3-codex",
            "output": [
                [
                    "id": "rs_1",
                    "type": "reasoning",
                    "summary": [[
                        "type": "summary_text",
                        "text": "先检查工作目录。",
                    ]],
                ],
                [
                    "id": "fc_1",
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "Print working directory",
                    "arguments": #"{"command":"pwd"}"#,
                ],
                [
                    "id": "fco_1",
                    "type": "function_call_output",
                    "call_id": "call_1",
                    "output": "/tmp/project",
                ],
                [
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "content": [[
                        "type": "output_text",
                        "text": "目录是 /tmp/project。",
                    ]],
                ],
            ],
            "usage": [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0,
            ],
        ]

        let data = ResponsesChatCompletionsBridge.makeResponseStreamData(from: response)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.done"))
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""type":"function_call_output""#))
        XCTAssertTrue(text.contains(#""call_id":"call_1""#))
        XCTAssertTrue(text.contains(#""output":"\/tmp\/project""#))
        XCTAssertTrue(text.contains("event: response.completed"))
    }

    private func acpUpdate(sessionUpdate: String, content: String) throws -> Data {
        try acpUpdate([
            "sessionUpdate": sessionUpdate,
            "content": content,
        ])
    }

    private func acpUpdate(_ update: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "update": update,
                ],
            ],
            options: []
        )
    }
}
