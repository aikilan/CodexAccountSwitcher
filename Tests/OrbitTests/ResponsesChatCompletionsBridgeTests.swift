import Foundation
import XCTest
@testable import Orbit

final class ResponsesChatCompletionsBridgeTests: XCTestCase {
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
}
