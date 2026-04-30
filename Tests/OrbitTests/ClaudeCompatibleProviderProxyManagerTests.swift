import Foundation
import XCTest
@testable import Orbit

final class ClaudeCompatibleProviderProxyManagerTests: XCTestCase {
    func testMessagesEndpointInjectsConfiguredModelParameters() async throws {
        actor Recorder {
            var lastBaseURL: String?
            var lastAPIKey: String?
            var lastEndpoint: String?
            var lastHeaders: [String: String]?
            var lastBody: Data?

            func store(baseURL: String, apiKey: String, endpoint: String, headers: [String: String], body: Data) {
                lastBaseURL = baseURL
                lastAPIKey = apiKey
                lastEndpoint = endpoint
                lastHeaders = headers
                lastBody = body
            }

            func snapshot() -> (String?, String?, String?, [String: String]?, Data?) {
                (lastBaseURL, lastAPIKey, lastEndpoint, lastHeaders, lastBody)
            }
        }

        let recorder = Recorder()
        let manager = ClaudeCompatibleProviderProxyManager(
            sendUpstreamRequest: { baseURL, apiKey, endpoint, headers, body in
                await recorder.store(baseURL: baseURL, apiKey: apiKey, endpoint: endpoint, headers: headers, body: body)
                let response = try JSONSerialization.data(withJSONObject: [
                    "id": "msg_test",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-sonnet-4.5",
                    "content": [
                        ["type": "text", "text": "ok"],
                    ],
                    "stop_reason": "end_turn",
                    "usage": [
                        "input_tokens": 1,
                        "output_tokens": 1,
                    ],
                ])
                return (200, response)
            }
        )

        let proxy = try await manager.prepareProxy(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: ["claude-sonnet-4.5"],
            modelSettings: [ProviderModelSettings(model: "claude-sonnet-4.5", temperature: 0.42, topP: 0.86)]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(proxy.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token-efficient-tools-2025-02-19", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4.5",
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let snapshot = await recorder.snapshot()
        let upstreamBody = try XCTUnwrap(snapshot.4)
        let upstreamObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(snapshot.0, "https://api.anthropic.com/v1")
        XCTAssertEqual(snapshot.1, "sk-ant-test")
        XCTAssertEqual(snapshot.2, "messages")
        XCTAssertEqual(snapshot.3?["anthropic-beta"], "token-efficient-tools-2025-02-19")
        XCTAssertEqual(upstreamObject["temperature"] as? Double, 0.42)
        XCTAssertEqual(upstreamObject["top_p"] as? Double, 0.86)
    }

    func testMiniMaxMessagesEndpointStripsUnsupportedMediaBlocks() async throws {
        actor Recorder {
            var lastBody: Data?

            func store(_ body: Data) {
                lastBody = body
            }

            func body() -> Data? {
                lastBody
            }
        }

        let recorder = Recorder()
        let manager = ClaudeCompatibleProviderProxyManager(
            sendUpstreamRequest: { _, _, _, _, body in
                await recorder.store(body)
                let response = try JSONSerialization.data(withJSONObject: [
                    "id": "msg_minimax",
                    "type": "message",
                    "role": "assistant",
                    "model": "MiniMax-M2.7",
                    "content": [
                        ["type": "text", "text": "ok"],
                    ],
                    "stop_reason": "end_turn",
                    "usage": [
                        "input_tokens": 1,
                        "output_tokens": 1,
                    ],
                ])
                return (200, response)
            }
        )

        let proxy = try await manager.prepareProxy(
            accountID: UUID(),
            baseURL: "https://api.minimax.io/anthropic",
            apiKeyEnvName: "ANTHROPIC_AUTH_TOKEN",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"],
            modelSettings: [ProviderModelSettings(model: "MiniMax-M2.7")]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(proxy.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "看附件",
                        ],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": "aaa",
                            ],
                        ],
                        [
                            "type": "document",
                            "source": [
                                "type": "base64",
                                "media_type": "application/pdf",
                                "data": "bbb",
                            ],
                        ],
                    ],
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let messages = try XCTUnwrap(upstreamObject["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let bodyText = try XCTUnwrap(String(data: upstreamBody, encoding: .utf8))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "看附件")
        XCTAssertFalse(bodyText.contains("image/png"))
        XCTAssertFalse(bodyText.contains("application/pdf"))
    }

    func testStreamingUpstreamErrorReturnsJSONContentType() async throws {
        let manager = ClaudeCompatibleProviderProxyManager(
            sendUpstreamRequest: { _, _, _, _, _ in
                let response = try JSONSerialization.data(withJSONObject: [
                    "error": [
                        "message": "invalid model",
                        "type": "invalid_request_error",
                    ],
                ])
                return (400, response)
            }
        )

        let proxy = try await manager.prepareProxy(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: ["claude-sonnet-4.5"],
            modelSettings: [ProviderModelSettings(model: "claude-sonnet-4.5")]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(proxy.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "bad-model",
            "max_tokens": 1024,
            "stream": true,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 400)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}
