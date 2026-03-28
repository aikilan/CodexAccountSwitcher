import Foundation
import XCTest
@testable import CodexAccountSwitcher

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
}
