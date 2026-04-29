import Foundation
import XCTest
@testable import Orbit

final class CLIEnvironmentResolverTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ResolverMockURLProtocol.requestHandler = nil
    }

    func testResolveClaudeContextPrefetchesPresetOpenAIModelsForBridge() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"gpt-4.1"},{"id":"gpt-4o"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverCodexOAuthClaudeBridgeManager()
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .codex,
            rule: .openAICompatible,
            presetID: "openai",
            baseURL: "https://api.openai.com/v1",
            envName: "OPENAI_API_KEY",
            model: "gpt-5.4"
        )

        let context = try await resolver.resolveClaudeContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            codexAuthPayload: nil,
            credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "sk-openai-test").validated()),
            claudeProfileManager: ResolverClaudeProfileManager(),
            claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        let requests = recorder.values()
        let snapshot = await bridgeManager.snapshot()
        XCTAssertNil(context.executableOverrideURL)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/models")
        XCTAssertEqual(snapshot, ["gpt-4.1", "gpt-4o", "gpt-5.4"])
    }

    func testResolveCodexContextPrefetchesPresetClaudeModelsForBridge() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"claude-opus-4.1"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverClaudeProviderBridgeManager()
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .claude,
            rule: .claudeCompatible,
            presetID: "anthropic",
            baseURL: "https://api.anthropic.com/v1",
            envName: "ANTHROPIC_API_KEY",
            model: "claude-sonnet-4.5"
        )

        _ = try await resolver.resolveCodexContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-ant-test").validated(),
            copilotCredential: nil,
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: bridgeManager
        )

        let requests = recorder.values()
        let snapshot = await bridgeManager.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/models")
        XCTAssertEqual(snapshot, ["claude-opus-4.1", "claude-sonnet-4.5"])
    }

    func testResolveClaudeContextFallsBackToDefaultModelWhenPrefetchFails() async throws {
        ResolverMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"failed"}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverCodexOAuthClaudeBridgeManager()
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .codex,
            rule: .openAICompatible,
            presetID: "openai",
            baseURL: "https://api.openai.com/v1",
            envName: "OPENAI_API_KEY",
            model: "gpt-5.4"
        )

        _ = try await resolver.resolveClaudeContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            codexAuthPayload: nil,
            credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "sk-openai-test").validated()),
            claudeProfileManager: ResolverClaudeProfileManager(),
            claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        let snapshot = await bridgeManager.snapshot()
        XCTAssertEqual(snapshot, ["gpt-5.4"])
    }

    func testResolveClaudeContextPrefetchesModelsForAllBuiltInClaudePresets() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"prefetched-model"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let presets = ProviderCatalog.presets(for: .claudeCompatible).filter { !$0.isCustom }

        for preset in presets {
            let account = makeProviderAccount(
                platform: .claude,
                rule: .claudeCompatible,
                presetID: preset.id,
                baseURL: preset.baseURL,
                envName: preset.apiKeyEnvName,
                model: preset.defaultModel
            )

            let context = try await resolver.resolveClaudeContext(
                for: account,
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                appPaths: paths,
                codexAuthPayload: nil,
                credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "key-\(preset.id)").validated()),
                claudeProfileManager: ResolverClaudeProfileManager(),
                claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
                copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
                codexOAuthClaudeBridgeManager: RecordingResolverCodexOAuthClaudeBridgeManager()
            )

            XCTAssertEqual(context.providerSnapshot?.availableModels, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
        }

        let requests = recorder.values()
        XCTAssertEqual(requests.count, presets.count)

        for (request, preset) in zip(requests, presets) {
            XCTAssertEqual(request.httpMethod, "GET", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "preset=\(preset.id)")

            if let normalizedBaseURL = normalizedMiniMaxAnthropicBaseURL(preset.baseURL, includeVersion: true) {
                XCTAssertEqual(request.url?.absoluteString, "\(normalizedBaseURL)/models", "preset=\(preset.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-\(preset.id)", "preset=\(preset.id)")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"), "preset=\(preset.id)")
            } else {
                XCTAssertEqual(request.url?.absoluteString, "\(preset.baseURL)/models", "preset=\(preset.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key-\(preset.id)", "preset=\(preset.id)")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "preset=\(preset.id)")
            }
        }
    }

    func testResolveClaudeContextUsesCodexModelCatalogForChatGPTOAuthBridge() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverCodexOAuthClaudeBridgeManager()
        let paths = try makePaths()
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: UUID().uuidString,
            displayName: "ChatGPT",
            email: "user@example.com",
            authKind: .chatgpt,
            providerRule: .chatgptOAuth,
            providerPresetID: nil,
            providerDisplayName: nil,
            providerBaseURL: nil,
            providerAPIKeyEnvName: nil,
            defaultModel: "gpt-5.4",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: true
        )

        let context = try await resolver.resolveClaudeContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            codexAuthPayload: CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: "sk-chatgpt-test"),
            credential: nil,
            claudeProfileManager: ResolverClaudeProfileManager(),
            claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        let snapshot = await bridgeManager.snapshot()
        XCTAssertNil(context.executableOverrideURL)
        XCTAssertEqual(
            snapshot,
            [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.2",
                "gpt-5.1-codex-mini",
            ]
        )
    }

    func testResolveCodexContextUsesCopilotCompatibleFallbackModel() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverCopilotResponsesBridgeManager()
        let paths = try makePaths()
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: "copilot_github.com_aikilan",
            displayName: "GitHub Copilot • aikilan",
            email: "https://github.com/aikilan",
            authKind: .githubCopilot,
            providerRule: .githubCopilot,
            providerPresetID: nil,
            providerDisplayName: "GitHub Copilot",
            providerBaseURL: nil,
            providerAPIKeyEnvName: nil,
            defaultModel: "gpt-5.3-codex",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
        let credential = try CopilotCredential(
            configDirectoryName: "acct-bridge",
            host: "https://github.com",
            login: "aikilan",
            defaultModel: "gpt-5.3-codex"
        ).validated()

        let context = try await resolver.resolveCodexContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: nil,
            copilotCredential: credential,
            copilotResponsesBridgeManager: bridgeManager,
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
        )

        let snapshot = await bridgeManager.snapshot()
        XCTAssertEqual(snapshot.lastModel, "gpt-4.1")
        XCTAssertEqual(snapshot.lastAvailableModels, ["gpt-4.1"])
        XCTAssertEqual(snapshot.lastConfigDirectoryURL, paths.copilotManagedConfigDirectoryURL(named: "acct-bridge"))
        XCTAssertEqual(snapshot.lastReasoningEffort, "medium")
        XCTAssertEqual(context.modelCatalogSnapshot?.availableModels, ["gpt-4.1"])
        XCTAssertTrue(context.configFileContents?.contains("model = \"gpt-4.1\"") == true)
    }

    func testResolveCodexContextUsesLiveCopilotModelsWhenStatusProvided() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverCopilotResponsesBridgeManager()
        let paths = try makePaths()
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: "copilot_github.com_aikilan",
            displayName: "GitHub Copilot • aikilan",
            email: "https://github.com/aikilan",
            authKind: .githubCopilot,
            providerRule: .githubCopilot,
            providerPresetID: nil,
            providerDisplayName: "GitHub Copilot",
            providerBaseURL: nil,
            providerAPIKeyEnvName: nil,
            defaultModel: "gpt-5.3-codex",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
        let credential = try CopilotCredential(
            configDirectoryName: "acct-live-models",
            host: "https://github.com",
            login: "aikilan",
            defaultModel: "gpt-5.3-codex"
        ).validated()
        let status = CopilotAccountStatus(
            availableModels: ["gpt-4.1", "gpt-4o"],
            currentModel: "gpt-4.1",
            quotaSnapshot: nil
        )

        let context = try await resolver.resolveCodexContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: nil,
            copilotCredential: credential,
            copilotStatus: status,
            copilotResponsesBridgeManager: bridgeManager,
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
        )

        let snapshot = await bridgeManager.snapshot()
        XCTAssertEqual(snapshot.lastModel, "gpt-4.1")
        XCTAssertEqual(snapshot.lastAvailableModels, ["gpt-4.1", "gpt-4o"])
        XCTAssertEqual(snapshot.lastConfigDirectoryURL, paths.copilotManagedConfigDirectoryURL(named: "acct-live-models"))
        XCTAssertEqual(snapshot.lastReasoningEffort, "medium")
        XCTAssertEqual(context.modelCatalogSnapshot?.availableModels, ["gpt-4.1", "gpt-4o"])
        XCTAssertTrue(context.configFileContents?.contains("model = \"gpt-4.1\"") == true)
    }

    func testResolveCodexContextSkipsPrefetchForCustomProvider() async throws {
        ResolverMockURLProtocol.requestHandler = { _ in
            XCTFail("custom provider 不应该触发模型预查询")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let bridgeManager = RecordingResolverClaudeProviderBridgeManager()
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .claude,
            rule: .claudeCompatible,
            presetID: ProviderCatalog.customPresetID,
            baseURL: "https://api.minimax.io/anthropic/v1",
            envName: "MINIMAX_API_KEY",
            model: "MiniMax-M2.7"
        )

        _ = try await resolver.resolveCodexContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-minimax-test").validated(),
            copilotCredential: nil,
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: bridgeManager
        )

        let snapshot = await bridgeManager.snapshot()
        XCTAssertEqual(snapshot, ["MiniMax-M2.7"])
    }

    func testResolveCodexContextManagesModelCatalogForCustomProviderNamedOpenAI() async throws {
        ResolverMockURLProtocol.requestHandler = { _ in
            XCTFail("custom provider 不应该触发模型预查询")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: UUID().uuidString,
            displayName: "Provider",
            email: "sk-***",
            authKind: .providerAPIKey,
            providerRule: .openAICompatible,
            providerPresetID: ProviderCatalog.customPresetID,
            providerDisplayName: "OpenAI",
            providerBaseURL: "https://example.com/v1",
            providerAPIKeyEnvName: "OPENAI_API_KEY",
            defaultModel: "custom-model",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )

        let context = try await resolver.resolveCodexContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-custom-openai").validated(),
            copilotCredential: nil,
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
        )

        XCTAssertEqual(context.modelCatalogSnapshot?.availableModels, ["custom-model"])
    }

    func testResolveClaudeContextSkipsPrefetchForCustomClaudeProvider() async throws {
        ResolverMockURLProtocol.requestHandler = { _ in
            XCTFail("custom provider 不应该触发模型预查询")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .claude,
            rule: .claudeCompatible,
            presetID: ProviderCatalog.customPresetID,
            baseURL: "https://api.minimax.io/anthropic/v1",
            envName: "MINIMAX_API_KEY",
            model: "MiniMax-M2.7"
        )

        let context = try await resolver.resolveClaudeContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            codexAuthPayload: nil,
            credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "sk-minimax-test").validated()),
            claudeProfileManager: ResolverClaudeProfileManager(),
            claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            codexOAuthClaudeBridgeManager: RecordingResolverCodexOAuthClaudeBridgeManager()
        )

        XCTAssertNil(context.executableOverrideURL)
        XCTAssertEqual(context.providerSnapshot?.availableModels, ["MiniMax-M2.7"])
    }

    func testResolveClaudeContextUsesExecutableOverrideWhenRuntimeManagerReturnsOne() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let account = makeProviderAccount(
            platform: .claude,
            rule: .claudeCompatible,
            presetID: ProviderCatalog.customPresetID,
            baseURL: "https://proxy.example/v1",
            envName: "ANTHROPIC_API_KEY",
            model: "claude-sonnet-4.5"
        )
        let overrideURL = paths.appSupportDirectoryURL
            .appendingPathComponent("patched-runtime", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)

        let context = try await resolver.resolveClaudeContext(
            for: account,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            appPaths: paths,
            codexAuthPayload: nil,
            credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "sk-ant-test").validated()),
            claudeProfileManager: ResolverClaudeProfileManager(),
            claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(executableOverrideURL: overrideURL),
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            codexOAuthClaudeBridgeManager: RecordingResolverCodexOAuthClaudeBridgeManager()
        )

        XCTAssertEqual(context.executableOverrideURL, overrideURL)
    }

    func testResolveClaudeContextPrefetchesModelsForAllBuiltInOpenAIPresets() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"prefetched-model"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let presets = ProviderCatalog.presets(for: .openAICompatible).filter { !$0.isCustom }

        for preset in presets {
            let bridgeManager = RecordingResolverCodexOAuthClaudeBridgeManager()
            let account = makeProviderAccount(
                platform: .codex,
                rule: .openAICompatible,
                presetID: preset.id,
                baseURL: preset.baseURL,
                envName: preset.apiKeyEnvName,
                model: preset.defaultModel
            )

            _ = try await resolver.resolveClaudeContext(
                for: account,
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                appPaths: paths,
                codexAuthPayload: nil,
                credential: .providerAPIKey(try ProviderAPIKeyCredential(apiKey: "key-\(preset.id)").validated()),
                claudeProfileManager: ResolverClaudeProfileManager(),
                claudePatchedRuntimeManager: ResolverPatchedRuntimeManager(),
                copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
                codexOAuthClaudeBridgeManager: bridgeManager
            )

            let snapshot = await bridgeManager.snapshot()
            XCTAssertEqual(snapshot, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
        }

        let requests = recorder.values()
        XCTAssertEqual(requests.count, presets.count)

        for (request, preset) in zip(requests, presets) {
            XCTAssertEqual(request.httpMethod, "GET", "preset=\(preset.id)")
            XCTAssertEqual(request.url?.absoluteString, "\(preset.baseURL)/models", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-\(preset.id)", "preset=\(preset.id)")
        }
    }

    func testResolveCodexContextPrefetchesModelsForAllBuiltInOpenAIBridgePresets() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"prefetched-model"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let presets = ProviderCatalog.presets(for: .openAICompatible).filter { !$0.isCustom && !$0.supportsResponsesAPI }

        for preset in presets {
            let bridgeManager = RecordingResolverOpenAICompatibleProviderBridgeManager()
            let account = makeProviderAccount(
                platform: .codex,
                rule: .openAICompatible,
                presetID: preset.id,
                baseURL: preset.baseURL,
                envName: preset.apiKeyEnvName,
                model: preset.defaultModel
            )

            _ = try await resolver.resolveCodexContext(
                for: account,
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                appPaths: paths,
                authPayload: nil,
                providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "key-\(preset.id)").validated(),
                copilotCredential: nil,
                copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
                openAICompatibleProviderCodexBridgeManager: bridgeManager,
                claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
            )

            let snapshot = await bridgeManager.snapshot()
            XCTAssertEqual(snapshot, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
        }

        let requests = recorder.values()
        XCTAssertEqual(requests.count, presets.count)

        for (request, preset) in zip(requests, presets) {
            XCTAssertEqual(request.httpMethod, "GET", "preset=\(preset.id)")
            XCTAssertEqual(request.url?.absoluteString, "\(preset.baseURL)/models", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-\(preset.id)", "preset=\(preset.id)")
        }
    }

    func testResolveCodexDesktopContextPrefetchesModelsForAllBuiltInOpenAIBridgePresets() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"prefetched-model"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let presets = ProviderCatalog.presets(for: .openAICompatible).filter { !$0.isCustom && !$0.supportsResponsesAPI }

        for preset in presets {
            let bridgeManager = RecordingResolverOpenAICompatibleProviderBridgeManager()
            let account = makeProviderAccount(
                platform: .codex,
                rule: .openAICompatible,
                presetID: preset.id,
                baseURL: preset.baseURL,
                envName: preset.apiKeyEnvName,
                model: preset.defaultModel
            )

            let context = try await resolver.resolveCodexDesktopContext(
                for: account,
                appPaths: paths,
                authPayload: nil,
                providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "key-\(preset.id)").validated(),
                copilotCredential: nil,
                copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
                openAICompatibleProviderCodexBridgeManager: bridgeManager,
                claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
            )

            let snapshot = await bridgeManager.snapshot()
            XCTAssertEqual(snapshot, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
            XCTAssertEqual(context.modelCatalogSnapshot?.availableModels, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
            XCTAssertEqual(context.environmentVariables["OPENAI_API_KEY"], "openai-compatible-provider-bridge", "preset=\(preset.id)")
            XCTAssertTrue(context.codexHomeURL.path.contains("/isolated-codex-instances/"), "preset=\(preset.id)")
            XCTAssertTrue(context.configFileContents?.contains("model_provider = \"\(preset.id)\"") == true, "preset=\(preset.id)")
        }

        let requests = recorder.values()
        XCTAssertEqual(requests.count, presets.count)

        for (request, preset) in zip(requests, presets) {
            XCTAssertEqual(request.httpMethod, "GET", "preset=\(preset.id)")
            XCTAssertEqual(request.url?.absoluteString, "\(preset.baseURL)/models", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-\(preset.id)", "preset=\(preset.id)")
        }
    }

    func testResolveCodexContextPrefetchesModelsForAllBuiltInClaudePresets() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ResolverMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"prefetched-model"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let presets = ProviderCatalog.presets(for: .claudeCompatible).filter { !$0.isCustom }

        for preset in presets {
            let bridgeManager = RecordingResolverClaudeProviderBridgeManager()
            let account = makeProviderAccount(
                platform: .claude,
                rule: .claudeCompatible,
                presetID: preset.id,
                baseURL: preset.baseURL,
                envName: preset.apiKeyEnvName,
                model: preset.defaultModel
            )

            _ = try await resolver.resolveCodexContext(
                for: account,
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                appPaths: paths,
                authPayload: nil,
                providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "key-\(preset.id)").validated(),
                copilotCredential: nil,
                copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
                openAICompatibleProviderCodexBridgeManager: RecordingResolverOpenAICompatibleProviderBridgeManager(),
                claudeProviderCodexBridgeManager: bridgeManager
            )

            let snapshot = await bridgeManager.snapshot()
            XCTAssertEqual(snapshot, ["prefetched-model", preset.defaultModel], "preset=\(preset.id)")
        }

        let requests = recorder.values()
        XCTAssertEqual(requests.count, presets.count)

        for (request, preset) in zip(requests, presets) {
            XCTAssertEqual(request.httpMethod, "GET", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "preset=\(preset.id)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "preset=\(preset.id)")

            if let normalizedBaseURL = normalizedMiniMaxAnthropicBaseURL(preset.baseURL, includeVersion: true) {
                XCTAssertEqual(request.url?.absoluteString, "\(normalizedBaseURL)/models", "preset=\(preset.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-\(preset.id)", "preset=\(preset.id)")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"), "preset=\(preset.id)")
            } else {
                XCTAssertEqual(request.url?.absoluteString, "\(preset.baseURL)/models", "preset=\(preset.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key-\(preset.id)", "preset=\(preset.id)")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "preset=\(preset.id)")
            }
        }
    }

    func testResolveCodexDesktopModelSelectionPrefetchesPresetProviderModels() async throws {
        ResolverMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"gpt-4.1"},{"id":"gpt-4o"}]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let account = makeProviderAccount(
            platform: .codex,
            rule: .openAICompatible,
            presetID: "openai",
            baseURL: "https://api.openai.com/v1",
            envName: "OPENAI_API_KEY",
            model: "gpt-5.4"
        )

        let selection = try await resolver.resolveCodexDesktopModelSelection(
            for: account,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-openai-test").validated(),
            copilotCredential: nil,
            copilotStatus: nil
        )

        XCTAssertEqual(selection.selectedModel, "gpt-5.4")
        XCTAssertEqual(selection.availableModels, ["gpt-4.1", "gpt-4o", "gpt-5.4"])
    }

    func testResolveCodexDesktopModelSelectionFallsBackToDefaultModelForCustomProvider() async throws {
        ResolverMockURLProtocol.requestHandler = { _ in
            XCTFail("custom provider 不应该触发模型预查询")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        let resolver = CLIEnvironmentResolver(session: makeSession())
        let account = makeProviderAccount(
            platform: .codex,
            rule: .openAICompatible,
            presetID: ProviderCatalog.customPresetID,
            baseURL: "https://example.com/v1",
            envName: "CUSTOM_API_KEY",
            model: "deepseek-chat"
        )

        let selection = try await resolver.resolveCodexDesktopModelSelection(
            for: account,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-custom-openai").validated(),
            copilotCredential: nil,
            copilotStatus: nil
        )

        XCTAssertEqual(selection.selectedModel, "deepseek-chat")
        XCTAssertEqual(selection.availableModels, ["deepseek-chat"])
    }

    func testResolveCodexDesktopModelSelectionUsesCopilotLiveStatus() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: UUID().uuidString,
            displayName: "GitHub Copilot",
            email: "user@example.com",
            authKind: .githubCopilot,
            providerRule: .githubCopilot,
            providerPresetID: nil,
            providerDisplayName: "GitHub Copilot",
            providerBaseURL: nil,
            providerAPIKeyEnvName: nil,
            defaultModel: "gpt-4.1",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
        let credential = try CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            defaultModel: "gpt-4o"
        ).validated()
        let status = CopilotAccountStatus(
            availableModels: ["gpt-4.1", "claude-opus-4.1"],
            currentModel: "claude-opus-4.1",
            quotaSnapshot: nil
        )

        let selection = try await resolver.resolveCodexDesktopModelSelection(
            for: account,
            providerAPIKeyCredential: nil,
            copilotCredential: credential,
            copilotStatus: status
        )

        XCTAssertEqual(selection.selectedModel, "gpt-4.1")
        XCTAssertEqual(selection.availableModels, ["gpt-4.1", "claude-opus-4.1"])
    }

    func testResolveCodexDesktopContextWritesConfiguredReasoningEffort() async throws {
        let resolver = CLIEnvironmentResolver(session: makeSession())
        let paths = try makePaths()
        let account = ManagedAccount(
            id: UUID(),
            platform: .codex,
            accountIdentifier: UUID().uuidString,
            displayName: "OpenAI",
            email: "sk-***",
            authKind: .providerAPIKey,
            providerRule: .openAICompatible,
            providerPresetID: "openai",
            providerDisplayName: "OpenAI",
            providerBaseURL: "https://api.openai.com/v1",
            providerAPIKeyEnvName: "OPENAI_API_KEY",
            defaultModel: "gpt-5.4",
            defaultModelReasoningEffort: "high",
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )

        let context = try await resolver.resolveCodexDesktopContext(
            for: account,
            appPaths: paths,
            authPayload: nil,
            providerAPIKeyCredential: try ProviderAPIKeyCredential(apiKey: "sk-openai-test").validated(),
            copilotCredential: nil,
            copilotResponsesBridgeManager: ResolverCopilotResponsesBridgeManager(),
            openAICompatibleProviderCodexBridgeManager: ResolverOpenAICompatibleProviderBridgeManager(),
            claudeProviderCodexBridgeManager: RecordingResolverClaudeProviderBridgeManager()
        )

        XCTAssertTrue(context.configFileContents?.contains("model_reasoning_effort = \"high\"") == true)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makePaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try AppPaths(
            fileManager: .default,
            codexHomeOverride: root.appendingPathComponent("codex-home", isDirectory: true),
            claudeHomeOverride: root.appendingPathComponent("claude-home", isDirectory: true),
            appSupportOverride: root.appendingPathComponent("app-support", isDirectory: true)
        )
    }

    private func makeProviderAccount(
        platform: PlatformKind,
        rule: ProviderRule,
        presetID: String,
        baseURL: String,
        envName: String,
        model: String,
        reasoningEffort: String? = nil
    ) -> ManagedAccount {
        ManagedAccount(
            id: UUID(),
            platform: platform,
            accountIdentifier: UUID().uuidString,
            displayName: "Provider",
            email: "sk-***",
            authKind: .providerAPIKey,
            providerRule: rule,
            providerPresetID: presetID,
            providerDisplayName: ProviderCatalog.preset(id: presetID)?.displayName ?? "Custom",
            providerBaseURL: baseURL,
            providerAPIKeyEnvName: envName,
            defaultModel: model,
            defaultModelReasoningEffort: reasoningEffort,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
    }
}

private final class ResolverMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("ResolverMockURLProtocol.requestHandler 未设置")
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

private final class RequestRecorder<Value: Sendable>: @unchecked Sendable {
    private var storedValues = [Value]()
    private let lock = NSLock()

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}

private struct ResolverClaudeProfileManager: ClaudeProfileManaging {
    func currentProfileExists() -> Bool { false }
    func importCurrentProfile() throws -> ClaudeProfileSnapshotRef { throw NSError(domain: "test", code: 1) }
    func activateProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {}
    func deleteProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {}
    func prepareIsolatedProfileRoot(for accountID: UUID, snapshotRef: ClaudeProfileSnapshotRef) throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func prepareIsolatedAPIKeyRoot(for accountID: UUID) throws -> URL {
        FileManager.default.temporaryDirectory
    }
}

private struct ResolverPatchedRuntimeManager: ClaudePatchedRuntimeManaging {
    var executableOverrideURL: URL? = nil

    func resolveExecutableOverride(model: String, appSupportDirectoryURL: URL) throws -> URL? {
        executableOverrideURL
    }
}

private struct ResolverOpenAICompatibleProviderBridgeManager: OpenAICompatibleProviderCodexBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        PreparedOpenAICompatibleProviderCodexBridge(
            baseURL: "http://127.0.0.1:18082",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "openai-compatible-provider-bridge"
        )
    }
}

private struct ResolverCopilotResponsesBridgeManager: CopilotResponsesBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL,
        configDirectoryURL: URL,
        reasoningEffort: String
    ) async throws -> PreparedCopilotResponsesBridge {
        PreparedCopilotResponsesBridge(
            baseURL: "http://127.0.0.1:18083",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "github-copilot-bridge"
        )
    }
}

private actor RecordingResolverOpenAICompatibleProviderBridgeManager: OpenAICompatibleProviderCodexBridgeManaging {
    private var lastAvailableModels = [String]()

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        lastAvailableModels = availableModels
        return PreparedOpenAICompatibleProviderCodexBridge(
            baseURL: "http://127.0.0.1:18082",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "openai-compatible-provider-bridge"
        )
    }

    func snapshot() -> [String] {
        lastAvailableModels
    }
}

private actor RecordingResolverClaudeProviderBridgeManager: ClaudeProviderCodexBridgeManaging {
    private var lastAvailableModels = [String]()

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) async throws -> PreparedClaudeProviderCodexBridge {
        lastAvailableModels = availableModels
        return PreparedClaudeProviderCodexBridge(
            baseURL: "http://127.0.0.1:18081",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "claude-provider-bridge"
        )
    }

    func snapshot() -> [String] {
        lastAvailableModels
    }
}

private actor RecordingResolverCodexOAuthClaudeBridgeManager: CodexOAuthClaudeBridgeManaging {
    private var lastAvailableModels = [String]()

    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) async throws -> PreparedCodexOAuthClaudeBridge {
        lastAvailableModels = availableModels
        return PreparedCodexOAuthClaudeBridge(
            baseURL: "http://127.0.0.1:18080",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "codex-oauth-bridge"
        )
    }

    func snapshot() -> [String] {
        lastAvailableModels
    }
}

private actor RecordingResolverCopilotResponsesBridgeManager: CopilotResponsesBridgeManaging {
    struct Snapshot: Equatable {
        let lastModel: String?
        let lastAvailableModels: [String]
        let lastConfigDirectoryURL: URL?
        let lastReasoningEffort: String?
    }

    private var lastModel: String?
    private var lastAvailableModels = [String]()
    private var lastConfigDirectoryURL: URL?
    private var lastReasoningEffort: String?

    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL,
        configDirectoryURL: URL,
        reasoningEffort: String
    ) async throws -> PreparedCopilotResponsesBridge {
        lastModel = model
        lastAvailableModels = availableModels
        lastConfigDirectoryURL = configDirectoryURL
        lastReasoningEffort = reasoningEffort
        return PreparedCopilotResponsesBridge(
            baseURL: "http://127.0.0.1:18083",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "github-copilot-bridge"
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            lastModel: lastModel,
            lastAvailableModels: lastAvailableModels,
            lastConfigDirectoryURL: lastConfigDirectoryURL,
            lastReasoningEffort: lastReasoningEffort
        )
    }
}
