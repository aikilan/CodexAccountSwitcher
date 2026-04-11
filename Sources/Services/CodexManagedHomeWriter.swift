import Foundation

struct CodexManagedHomeWriter {
    private static let managedModelCatalogFileName = "model-catalog.json"
    private static let mainManagedModelCatalogFileName = "orbit-main-model-catalog.json"
    private static let mainManagedStartMarker = "# orbit-managed:start main-codex"
    private static let mainManagedEndMarker = "# orbit-managed:end main-codex"
    private static let managedBaseInstructions = """
    You are Codex, a coding agent. You share the user's workspace and collaborate to achieve the user's goals.

    Be pragmatic, direct, and concise. Prefer making the requested change over describing it at length. State assumptions and blockers clearly when they matter.

    Read the relevant code before editing. Prefer fast search tools such as rg or rg --files when available. Keep changes tightly scoped to the user's request.

    Do not revert unrelated user changes. Avoid destructive commands unless the user explicitly asks for them. Prefer non-interactive git commands.

    When the user clearly wants code or file changes, make them instead of only outlining a plan. If something blocks the requested change, explain the blocker precisely.

    Share short commentary updates while working and provide a concise final answer when finished. Mention important verification you completed and any notable remaining risk.

    Use Markdown when it improves readability, but keep responses compact and easy to scan.
    """
    private static let managedReasoningLevels: [[String: String]] = [
        [
            "effort": "low",
            "description": "Fast responses with lighter reasoning",
        ],
        [
            "effort": "medium",
            "description": "Balances speed and reasoning depth for everyday tasks",
        ],
        [
            "effort": "high",
            "description": "Greater reasoning depth for complex problems",
        ],
        [
            "effort": "xhigh",
            "description": "Extra high reasoning depth for complex problems",
        ],
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareManagedHome(
        codexHomeURL: URL,
        authPayload: CodexAuthPayload?,
        configFileContents: String?,
        modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    ) throws {
        try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)

        if let authPayload {
            let authFileURL = codexHomeURL.appendingPathComponent("auth.json")
            try AuthFileManager(authFileURL: authFileURL, fileManager: fileManager).activate(authPayload)
        }

        guard let managedConfigContents = try managedConfigContents(
            codexHomeURL: codexHomeURL,
            configFileContents: configFileContents,
            modelCatalogSnapshot: modelCatalogSnapshot
        ) else {
            return
        }

        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        try managedConfigContents.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func syncMainHome(
        codexHomeURL: URL,
        authPayload: CodexAuthPayload?,
        clearAuthFile: Bool,
        configFileContents: String?,
        modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    ) throws {
        try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)

        let authFileURL = codexHomeURL.appendingPathComponent("auth.json")
        let authFileManager = AuthFileManager(authFileURL: authFileURL, fileManager: fileManager)
        if let authPayload {
            try authFileManager.activate(authPayload)
        } else if clearAuthFile {
            try authFileManager.clearAuthFile()
        }

        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        let existingConfigContents: String
        if fileManager.fileExists(atPath: configURL.path) {
            existingConfigContents = try String(contentsOf: configURL, encoding: .utf8)
        } else {
            existingConfigContents = ""
        }

        let cleanedConfigContents = removingMainManagedBlock(
            from: removingMainManagedModelCatalogEntries(from: existingConfigContents)
        )
        let nextConfigContents = try mergedMainConfigContents(
            codexHomeURL: codexHomeURL,
            existingConfigContents: cleanedConfigContents,
            managedConfigFileContents: configFileContents,
            modelCatalogSnapshot: modelCatalogSnapshot
        )

        if let nextConfigContents {
            try nextConfigContents.write(to: configURL, atomically: true, encoding: .utf8)
        } else if fileManager.fileExists(atPath: configURL.path) {
            try fileManager.removeItem(at: configURL)
        }
    }

    private func managedConfigContents(
        codexHomeURL: URL,
        configFileContents: String?,
        modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    ) throws -> String? {
        var configContents = removingManagedModelCatalogEntries(from: configFileContents ?? "")

        if let modelCatalogSnapshot {
            let modelCatalogURL = codexHomeURL.appendingPathComponent(Self.managedModelCatalogFileName)
            let catalogContents = try modelCatalogContents(from: modelCatalogSnapshot)
            try catalogContents.write(to: modelCatalogURL, atomically: true, encoding: .utf8)
            configContents = insertingRootConfigEntry(
                "model_catalog_json = \"\(tomlEscaped(modelCatalogURL.path))\"",
                into: configContents
            )
        }

        return configContents.isEmpty ? nil : configContents
    }

    private func mergedMainConfigContents(
        codexHomeURL: URL,
        existingConfigContents: String,
        managedConfigFileContents: String?,
        modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    ) throws -> String? {
        let managedBlock = try managedMainBlock(
            codexHomeURL: codexHomeURL,
            configFileContents: managedConfigFileContents,
            modelCatalogSnapshot: modelCatalogSnapshot
        )
        let trimmedExistingConfigContents = existingConfigContents.trimmingCharacters(in: .newlines)

        guard let managedBlock else {
            return trimmedExistingConfigContents.isEmpty ? nil : trimmedExistingConfigContents + "\n"
        }

        let merged = insertingRootConfigBlock(managedBlock, into: trimmedExistingConfigContents)
        let trimmedMerged = merged.trimmingCharacters(in: .newlines)
        return trimmedMerged.isEmpty ? nil : trimmedMerged + "\n"
    }

    private func managedMainBlock(
        codexHomeURL: URL,
        configFileContents: String?,
        modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    ) throws -> String? {
        var configContents = removingMainManagedModelCatalogEntries(from: configFileContents ?? "")

        let modelCatalogURL = codexHomeURL.appendingPathComponent(Self.mainManagedModelCatalogFileName)
        if let modelCatalogSnapshot {
            let catalogContents = try modelCatalogContents(from: modelCatalogSnapshot)
            try catalogContents.write(to: modelCatalogURL, atomically: true, encoding: .utf8)
            configContents = insertingRootConfigEntry(
                "model_catalog_json = \"\(tomlEscaped(modelCatalogURL.path))\"",
                into: configContents
            )
        } else if fileManager.fileExists(atPath: modelCatalogURL.path) {
            try fileManager.removeItem(at: modelCatalogURL)
        }

        let trimmedConfigContents = configContents.trimmingCharacters(in: .newlines)
        guard !trimmedConfigContents.isEmpty else {
            return nil
        }

        return [
            Self.mainManagedStartMarker,
            trimmedConfigContents,
            Self.mainManagedEndMarker,
        ].joined(separator: "\n")
    }

    private func removingManagedModelCatalogEntries(from configContents: String) -> String {
        configContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("model_catalog_json = ") == false
            }
            .joined(separator: "\n")
    }

    private func removingMainManagedModelCatalogEntries(from configContents: String) -> String {
        configContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard trimmedLine.hasPrefix("model_catalog_json = ") else {
                    return true
                }
                return trimmedLine.contains(Self.mainManagedModelCatalogFileName) == false
            }
            .joined(separator: "\n")
    }

    private func removingMainManagedBlock(from configContents: String) -> String {
        var remainingLines: [Substring] = []
        remainingLines.reserveCapacity(configContents.count)

        var isSkippingManagedBlock = false
        for line in configContents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == Self.mainManagedStartMarker {
                isSkippingManagedBlock = true
                continue
            }
            if isSkippingManagedBlock {
                if trimmedLine == Self.mainManagedEndMarker {
                    isSkippingManagedBlock = false
                }
                continue
            }
            remainingLines.append(line)
        }

        return remainingLines.joined(separator: "\n")
    }

    private func insertingRootConfigEntry(_ entry: String, into configContents: String) -> String {
        guard !configContents.isEmpty else {
            return entry + "\n"
        }

        if let firstTableRange = configContents.range(of: #"(?m)^\["#, options: .regularExpression) {
            let prefix = String(configContents[..<firstTableRange.lowerBound])
                .trimmingCharacters(in: .newlines)
            let suffix = String(configContents[firstTableRange.lowerBound...])
            if prefix.isEmpty {
                return entry + "\n\n" + suffix
            }
            return prefix + "\n" + entry + "\n\n" + suffix
        }

        let trimmedConfigContents = configContents.trimmingCharacters(in: .newlines)
        if trimmedConfigContents.isEmpty {
            return entry + "\n"
        }
        return trimmedConfigContents + "\n" + entry + "\n"
    }

    private func insertingRootConfigBlock(_ block: String, into configContents: String) -> String {
        guard !configContents.isEmpty else {
            return block + "\n"
        }

        if let firstTableRange = configContents.range(of: #"(?m)^\["#, options: .regularExpression) {
            let prefix = String(configContents[..<firstTableRange.lowerBound])
                .trimmingCharacters(in: .newlines)
            let suffix = String(configContents[firstTableRange.lowerBound...])
            if prefix.isEmpty {
                return block + "\n\n" + suffix
            }
            return prefix + "\n\n" + block + "\n\n" + suffix
        }

        let trimmedConfigContents = configContents.trimmingCharacters(in: .newlines)
        if trimmedConfigContents.isEmpty {
            return block + "\n"
        }
        return trimmedConfigContents + "\n\n" + block + "\n"
    }

    private func modelCatalogContents(from snapshot: ResolvedCodexModelCatalogSnapshot) throws -> String {
        let models = normalizedAvailableModels(snapshot.availableModels)
        let catalog = [
            "models": models.enumerated().map { index, model in
                modelCatalogEntry(
                    for: model,
                    priority: index,
                    supportsParallelToolCalls: snapshot.supportsParallelToolCalls
                )
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func modelCatalogEntry(
        for model: String,
        priority: Int,
        supportsParallelToolCalls: Bool
    ) -> [String: Any] {
        [
            "apply_patch_tool_type": "freeform",
            "availability_nux": NSNull(),
            "base_instructions": Self.managedBaseInstructions,
            "context_window": 272000,
            "default_reasoning_level": "medium",
            "default_reasoning_summary": "none",
            "default_verbosity": "low",
            "description": model,
            "display_name": model,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "priority": priority,
            "shell_type": "shell_command",
            "slug": model,
            "support_verbosity": true,
            "supported_in_api": true,
            "supported_reasoning_levels": Self.managedReasoningLevels,
            "supports_image_detail_original": true,
            "supports_parallel_tool_calls": supportsParallelToolCalls,
            "supports_reasoning_summaries": true,
            "truncation_policy": [
                "limit": 10000,
                "mode": "tokens",
            ],
            "upgrade": NSNull(),
            "visibility": "list",
        ]
    }

    private func normalizedAvailableModels(_ availableModels: [String]) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in availableModels {
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty, seen.insert(trimmedModel).inserted else { continue }
            normalized.append(trimmedModel)
        }

        return normalized
    }

    private func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
