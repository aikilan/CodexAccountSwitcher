import Foundation
import XCTest
@testable import Orbit

final class ClaudeProviderCodexBridgeManagerTests: XCTestCase {
    func testMakeClaudeProviderUpstreamRequestUsesXAPIKeyForStandardAnthropicProvider() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-test",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMakeClaudeProviderUpstreamRequestUsesAuthorizationForMiniMaxAnthropicProvider() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.minimax.io/anthropic",
            apiKey: "sk-minimax-test",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.minimax.io/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-minimax-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMakeClaudeProviderUpstreamRequestNormalizesMiniMaxAnthropicV1BaseURL() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.minimaxi.com/anthropic/v1",
            apiKey: "sk-minimax-cn",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.minimaxi.com/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-minimax-cn")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testBridgeInjectsConfiguredModelParametersIntoClaudeRequest() async throws {
        actor Recorder {
            var lastRequestBody: Data?

            func store(_ data: Data) {
                lastRequestBody = data
            }

            func body() -> Data? {
                lastRequestBody
            }
        }

        let recorder = Recorder()
        let upstreamResponse = try JSONSerialization.data(withJSONObject: [
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
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, body in
                await recorder.store(body)
                return (200, upstreamResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: ["claude-sonnet-4.5"],
            modelSettings: [ProviderModelSettings(model: "claude-sonnet-4.5", temperature: 0.45, topP: 0.88)]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4.5",
            "stream": false,
            "input": "说一句话",
        ])

        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(upstreamObject["temperature"] as? Double, 0.45)
        XCTAssertEqual(upstreamObject["top_p"] as? Double, 0.88)
    }

    func testBridgeNormalizesPersistent529To429AfterRetrying() async throws {
        actor AttemptCounter {
            private var count = 0

            func next() -> Int {
                count += 1
                return count
            }

            func value() -> Int {
                count
            }
        }

        let attempts = AttemptCounter()
        let overloadResponse = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "The server cluster is currently under high load. Please retry after a short wait.",
                "type": "api_error",
            ],
        ])
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                _ = await attempts.next()
                return (529, overloadResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.minimax.io/anthropic/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "stream": false,
            "input": "说一句话",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let responseObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(responseObject["error"] as? [String: Any])
        let totalAttempts = await attempts.value()

        XCTAssertEqual(httpResponse.statusCode, 429)
        XCTAssertEqual(totalAttempts, 3)
        XCTAssertEqual(error["message"] as? String, "The server cluster is currently under high load. Please retry after a short wait.")
    }

    func testModelsEndpointReturnsAvailableModelsAndAppendsDefaultModel() async throws {
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: ["claude-opus-4.1", "claude-sonnet-4"]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["claude-opus-4.1", "claude-sonnet-4", "claude-sonnet-4.5"])
    }

    func testModelsEndpointFallsBackToSingleDefaultModel() async throws {
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: []
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/models")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["claude-sonnet-4.5"])
    }
}
