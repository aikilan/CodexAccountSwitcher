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
