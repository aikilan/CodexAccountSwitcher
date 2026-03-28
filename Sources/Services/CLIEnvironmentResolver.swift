import Foundation

enum CLIEnvironmentResolverError: LocalizedError, Equatable {
    case mismatchedTarget
    case missingCodexPayload
    case invalidCustomProvider
    case missingClaudeCredential
    case invalidClaudeProvider
    case missingLinkedCodexEnvironment
    case missingInheritedCodexEnvironment
    case linkedEnvironmentMustBeCodex
    case invalidInheritedCodexProvider(String)

    var errorDescription: String? {
        switch self {
        case .mismatchedTarget:
            return L10n.tr("CLI 环境与目标启动器不匹配。")
        case .missingCodexPayload:
            return L10n.tr("当前 Codex 环境需要账号凭据，但没有可用的 auth payload。")
        case .invalidCustomProvider:
            return L10n.tr("Codex 自定义 Provider 配置不完整。")
        case .missingClaudeCredential:
            return L10n.tr("Claude 环境缺少可用凭据。")
        case .invalidClaudeProvider:
            return L10n.tr("Claude 环境的 Provider 配置不完整。")
        case .missingLinkedCodexEnvironment:
            return L10n.tr("Claude 环境指定的覆盖来源 Codex 环境不存在。")
        case .missingInheritedCodexEnvironment:
            return L10n.tr("当前账号不是 Codex；请先为 Claude 环境指定一个覆盖来源 Codex 环境。")
        case .linkedEnvironmentMustBeCodex:
            return L10n.tr("Claude 环境绑定的覆盖来源必须是 Codex 环境。")
        case let .invalidInheritedCodexProvider(environmentName):
            return L10n.tr(
                "来源 Codex 环境 %@ 未配置可继承的自定义 provider。请先为该环境填写模型、Base URL 和 API Key。",
                environmentName
            )
        }
    }
}

struct CLIEnvironmentResolver {
    private struct ClaudeResolvedProvider {
        let source: ClaudeProviderSource
        let model: String
        let modelProvider: String?
        let baseURL: String
        let apiKeyEnvName: String
        let apiKey: String
    }

    init(fileManager _: FileManager = .default) {}

    func resolveCodexContext(
        for account: ManagedAccount,
        environmentProfile: CLIEnvironmentProfile,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        authPayload: CodexAuthPayload?
    ) throws -> ResolvedCodexCLILaunchContext {
        guard environmentProfile.target == .codex else {
            throw CLIEnvironmentResolverError.mismatchedTarget
        }

        let configuration = environmentProfile.resolvedCodex
        let shouldUseAccountCredentials = account.platform == .codex && configuration.useAccountCredentials
        let needsIsolatedHome = !shouldUseAccountCredentials || configuration.requiresConfigFile || !account.isActive

        if shouldUseAccountCredentials && account.isActive && !needsIsolatedHome {
            return ResolvedCodexCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                mode: .globalCurrentAuth,
                codexHomeURL: nil,
                authPayload: nil,
                configFileContents: nil,
                environmentVariables: [:],
                arguments: []
            )
        }

        if shouldUseAccountCredentials && authPayload == nil {
            throw CLIEnvironmentResolverError.missingCodexPayload
        }

        let codexHomeURL = isolatedCodexHomeURL(
            for: account.id,
            environmentProfileID: environmentProfile.id,
            appSupportDirectoryURL: appPaths.appSupportDirectoryURL
        )

        return ResolvedCodexCLILaunchContext(
            accountID: account.id,
            workingDirectoryURL: workingDirectoryURL,
            mode: .isolated,
            codexHomeURL: codexHomeURL,
            authPayload: shouldUseAccountCredentials ? authPayload : nil,
            configFileContents: codexConfigContents(for: configuration),
            environmentVariables: try codexEnvironmentVariables(for: configuration),
            arguments: []
        )
    }

    func resolveClaudeContext(
        for account: ManagedAccount,
        environmentProfile: CLIEnvironmentProfile,
        allEnvironmentProfiles: [CLIEnvironmentProfile],
        preferredCodexEnvironmentID: String?,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        codexAuthPayload: CodexAuthPayload?,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging,
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging,
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging
    ) async throws -> ResolvedClaudeCLILaunchContext {
        guard environmentProfile.target == .claude else {
            throw CLIEnvironmentResolverError.mismatchedTarget
        }

        let configuration = effectiveClaudeConfiguration(
            for: account,
            configuration: environmentProfile.resolvedClaude
        )

        if configuration.usesAccountCredentials {
            let resolvedCredential = account.platform == .claude ? credential : nil
            let rootURL = try claudeAccountRootURL(
                for: account,
                credential: resolvedCredential,
                claudeProfileManager: claudeProfileManager
            )

            return ResolvedClaudeCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                rootURL: rootURL,
                configDirectoryURL: rootURL?.appendingPathComponent(".claude", isDirectory: true),
                patchedExecutableURL: nil,
                providerSnapshot: nil,
                environmentVariables: claudeCredentialEnvironmentVariables(
                    apiKeyEnvName: configuration.trimmedAPIKeyEnvName,
                    apiKey: resolvedCredential?.anthropicAPIKeyCredential?.apiKey
                ),
                arguments: []
            )
        }

        let provider = try await resolveClaudeProvider(
            from: configuration,
            allEnvironmentProfiles: allEnvironmentProfiles,
            account: account,
            preferredCodexEnvironmentID: preferredCodexEnvironmentID,
            appPaths: appPaths,
            codexAuthPayload: codexAuthPayload,
            codexOAuthClaudeBridgeManager: codexOAuthClaudeBridgeManager
        )
        let rootURL = managedClaudeRootURL(
            for: account.id,
            environmentProfileID: environmentProfile.id,
            appSupportDirectoryURL: appPaths.appSupportDirectoryURL
        )

        return ResolvedClaudeCLILaunchContext(
            accountID: account.id,
            workingDirectoryURL: workingDirectoryURL,
            rootURL: rootURL,
            configDirectoryURL: rootURL.appendingPathComponent(".claude", isDirectory: true),
            patchedExecutableURL: try claudePatchedRuntimeManager.preparePatchedRuntime(
                model: provider.model,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            ),
            providerSnapshot: ResolvedClaudeProviderSnapshot(
                source: provider.source,
                model: provider.model,
                modelProvider: provider.modelProvider,
                baseURL: provider.baseURL,
                apiKeyEnvName: provider.apiKeyEnvName
            ),
            environmentVariables: claudeProviderEnvironmentVariables(
                for: provider,
                contextLimit: configuration.contextLimit
            ),
            arguments: ["--model", provider.model]
        )
    }

    private func effectiveClaudeConfiguration(
        for account: ManagedAccount,
        configuration: ClaudeCLIEnvironmentConfiguration
    ) -> ClaudeCLIEnvironmentConfiguration {
        guard configuration.usesAccountCredentials, account.platform == .codex else {
            return configuration
        }

        return ClaudeCLIEnvironmentConfiguration(
            providerSource: .inheritCodexEnvironment,
            linkedCodexEnvironmentID: configuration.linkedCodexEnvironmentID,
            model: configuration.model,
            providerBaseURL: configuration.providerBaseURL,
            apiKeyEnvName: configuration.apiKeyEnvName,
            apiKey: configuration.apiKey,
            contextLimit: configuration.contextLimit
        )
    }

    private func codexEnvironmentVariables(
        for configuration: CodexCLIEnvironmentConfiguration
    ) throws -> [String: String] {
        guard let provider = configuration.normalizedCustomProvider else {
            return [:]
        }

        let identifier = provider.resolvedIdentifier
        let baseURL = provider.trimmedBaseURL
        if identifier.isEmpty || baseURL.isEmpty {
            throw CLIEnvironmentResolverError.invalidCustomProvider
        }

        if provider.trimmedEnvKey.isEmpty || provider.trimmedAPIKey.isEmpty {
            return [:]
        }

        return [provider.trimmedEnvKey: provider.trimmedAPIKey]
    }

    private func codexConfigContents(
        for configuration: CodexCLIEnvironmentConfiguration
    ) -> String? {
        var lines = [String]()

        if !configuration.trimmedModel.isEmpty {
            lines.append("model = \"\(tomlEscaped(configuration.trimmedModel))\"")
        }

        let resolvedProvider = configuration.resolvedModelProvider
        if !resolvedProvider.isEmpty {
            lines.append("model_provider = \"\(tomlEscaped(resolvedProvider))\"")
        }

        if let provider = configuration.normalizedCustomProvider {
            let identifier = provider.resolvedIdentifier
            let baseURL = provider.trimmedBaseURL
            if !identifier.isEmpty && !baseURL.isEmpty {
                lines.append("")
                lines.append("[model_providers.\(identifier)]")
                lines.append("name = \"\(tomlEscaped(provider.resolvedDisplayName))\"")
                lines.append("base_url = \"\(tomlEscaped(baseURL))\"")
                if !provider.trimmedEnvKey.isEmpty {
                    lines.append("env_key = \"\(tomlEscaped(provider.trimmedEnvKey))\"")
                }
                lines.append("wire_api = \"\(provider.wireAPI.rawValue)\"")
            }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
    }

    private func claudeAccountRootURL(
        for account: ManagedAccount,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging
    ) throws -> URL? {
        switch credential {
        case let .claudeProfile(snapshotRef):
            if account.isActive {
                return nil
            }
            return try claudeProfileManager.prepareIsolatedProfileRoot(for: account.id, snapshotRef: snapshotRef)
        case .anthropicAPIKey:
            return try claudeProfileManager.prepareIsolatedAPIKeyRoot(for: account.id)
        case .codex:
            throw CLIEnvironmentResolverError.missingClaudeCredential
        case .none:
            throw CLIEnvironmentResolverError.missingClaudeCredential
        }
    }

    private func resolveClaudeProvider(
        from configuration: ClaudeCLIEnvironmentConfiguration,
        allEnvironmentProfiles: [CLIEnvironmentProfile],
        account: ManagedAccount,
        preferredCodexEnvironmentID: String?,
        appPaths: AppPaths,
        codexAuthPayload: CodexAuthPayload?,
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging
    ) async throws -> ClaudeResolvedProvider {
        switch configuration.providerSource {
        case .accountCredentials:
            throw CLIEnvironmentResolverError.invalidClaudeProvider
        case .explicitProvider:
            guard
                !configuration.trimmedModel.isEmpty,
                !configuration.trimmedProviderBaseURL.isEmpty,
                !configuration.trimmedAPIKey.isEmpty
            else {
                throw CLIEnvironmentResolverError.invalidClaudeProvider
            }

            return ClaudeResolvedProvider(
                source: .explicitProvider,
                model: configuration.trimmedModel,
                modelProvider: nil,
                baseURL: configuration.trimmedProviderBaseURL,
                apiKeyEnvName: configuration.trimmedAPIKeyEnvName,
                apiKey: configuration.trimmedAPIKey
            )
        case .inheritCodexEnvironment:
            let linkedEnvironment = try resolveInheritedCodexEnvironment(
                from: configuration,
                allEnvironmentProfiles: allEnvironmentProfiles,
                account: account,
                preferredCodexEnvironmentID: preferredCodexEnvironmentID
            )
            guard linkedEnvironment.target == .codex else {
                throw CLIEnvironmentResolverError.linkedEnvironmentMustBeCodex
            }

            let codexConfiguration = linkedEnvironment.resolvedCodex
            if
                !codexConfiguration.trimmedModel.isEmpty,
                let provider = codexConfiguration.normalizedCustomProvider,
                !provider.trimmedBaseURL.isEmpty,
                !provider.trimmedAPIKey.isEmpty
            {
                let resolvedModelProvider = codexConfiguration.resolvedModelProvider.isEmpty
                    ? provider.resolvedIdentifier
                    : codexConfiguration.resolvedModelProvider

                return ClaudeResolvedProvider(
                    source: .inheritCodexEnvironment,
                    model: codexConfiguration.trimmedModel,
                    modelProvider: resolvedModelProvider.isEmpty ? nil : resolvedModelProvider,
                    baseURL: provider.trimmedBaseURL,
                    apiKeyEnvName: configuration.trimmedAPIKeyEnvName,
                    apiKey: provider.trimmedAPIKey
                )
            }

            guard codexConfiguration.useAccountCredentials else {
                throw CLIEnvironmentResolverError.invalidInheritedCodexProvider(linkedEnvironment.sanitizedDisplayName)
            }

            guard let codexAuthPayload else {
                throw CLIEnvironmentResolverError.missingCodexPayload
            }

            let bridgeModel = resolvedCodexBridgeModel(
                from: codexConfiguration,
                codexHomeURL: appPaths.codexHome
            )
            let bridge = try await codexOAuthClaudeBridgeManager.prepareBridge(
                accountID: account.id,
                payload: codexAuthPayload,
                model: bridgeModel
            )

            return ClaudeResolvedProvider(
                source: .inheritCodexEnvironment,
                model: bridgeModel,
                modelProvider: nil,
                baseURL: bridge.baseURL,
                apiKeyEnvName: bridge.apiKeyEnvName,
                apiKey: bridge.apiKey
            )
        }
    }

    private func resolvedCodexBridgeModel(
        from configuration: CodexCLIEnvironmentConfiguration,
        codexHomeURL: URL
    ) -> String {
        if !configuration.trimmedModel.isEmpty {
            return configuration.trimmedModel
        }

        let configURL = codexHomeURL.appendingPathComponent("config.toml", isDirectory: false)
        if
            let contents = try? String(contentsOf: configURL, encoding: .utf8),
            let regex = try? NSRegularExpression(pattern: #"(?m)^\s*model\s*=\s*"([^"]+)""#),
            let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
            let range = Range(match.range(at: 1), in: contents)
        {
            let model = contents[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                return model
            }
        }

        return "gpt-5.4"
    }

    private func resolveInheritedCodexEnvironment(
        from configuration: ClaudeCLIEnvironmentConfiguration,
        allEnvironmentProfiles: [CLIEnvironmentProfile],
        account: ManagedAccount,
        preferredCodexEnvironmentID: String?
    ) throws -> CLIEnvironmentProfile {
        if let linkedID = configuration.trimmedLinkedCodexEnvironmentID {
            guard let linkedEnvironment = allEnvironmentProfiles.first(where: { $0.id == linkedID }) else {
                throw CLIEnvironmentResolverError.missingLinkedCodexEnvironment
            }
            guard linkedEnvironment.target == .codex else {
                throw CLIEnvironmentResolverError.linkedEnvironmentMustBeCodex
            }
            return linkedEnvironment
        }

        guard account.platform == .codex else {
            throw CLIEnvironmentResolverError.missingInheritedCodexEnvironment
        }

        if let preferredCodexEnvironmentID,
           let preferredEnvironment = allEnvironmentProfiles.first(where: { $0.id == preferredCodexEnvironmentID && $0.target == .codex })
        {
            return preferredEnvironment
        }

        guard let builtInCodexEnvironment = allEnvironmentProfiles.first(where: { $0.id == CLIEnvironmentProfile.builtInCodexProfileID }) else {
            throw CLIEnvironmentResolverError.missingLinkedCodexEnvironment
        }
        return builtInCodexEnvironment
    }

    private func claudeCredentialEnvironmentVariables(
        apiKeyEnvName: String,
        apiKey: String?
    ) -> [String: String] {
        guard let apiKey, !apiKey.isEmpty else {
            return [:]
        }

        var variables = ["ANTHROPIC_API_KEY": apiKey]
        if apiKeyEnvName != "ANTHROPIC_API_KEY" {
            variables[apiKeyEnvName] = apiKey
        }
        return variables
    }

    private func claudeProviderEnvironmentVariables(
        for provider: ClaudeResolvedProvider,
        contextLimit: Int?
    ) -> [String: String] {
        var variables = claudeCredentialEnvironmentVariables(
            apiKeyEnvName: provider.apiKeyEnvName,
            apiKey: provider.apiKey
        )
        variables["ANTHROPIC_BASE_URL"] = provider.baseURL
        variables["ANTHROPIC_MODEL"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"] = provider.model
        variables["CLAUDE_CODE_SUBAGENT_MODEL"] = provider.model
        if let contextLimit {
            variables["CLAUDE_CODE_CONTEXT_LIMIT"] = String(contextLimit)
        }
        return variables
    }

    private func isolatedCodexHomeURL(
        for accountID: UUID,
        environmentProfileID: String,
        appSupportDirectoryURL: URL
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("cli-environments", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(safePathComponent(environmentProfileID), isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    private func managedClaudeRootURL(
        for accountID: UUID,
        environmentProfileID: String,
        appSupportDirectoryURL: URL
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("cli-environments", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(safePathComponent(environmentProfileID), isDirectory: true)
            .appendingPathComponent("root", isDirectory: true)
    }

    private func safePathComponent(_ value: String) -> String {
        let sanitized = value.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".":
                return Character(scalar)
            default:
                return "-"
            }
        }
        let result = String(sanitized)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? UUID().uuidString : result
    }

    private func tomlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension CLIEnvironmentResolver: CLIEnvironmentResolving {}
