import SwiftUI

@MainActor
struct CLIEnvironmentManagerSheet: View {
    @ObservedObject var model: AppViewModel
    let account: ManagedAccount

    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfileID: String?
    @State private var draftProfile: CLIEnvironmentProfile
    @State private var draftContextLimit = ""

    init(model: AppViewModel, account: ManagedAccount) {
        self.model = model
        self.account = account

        let initialProfile = model.defaultCLIEnvironment(for: account)
        _selectedProfileID = State(initialValue: initialProfile.id)
        _draftProfile = State(initialValue: initialProfile)
        _draftContextLimit = State(initialValue: initialProfile.resolvedClaude.contextLimit.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                profileList
                Divider()
                profileEditor
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 620)
        .onChange(of: selectedProfileID) { _, newValue in
            guard let newValue, let profile = model.cliEnvironmentProfiles.first(where: { $0.id == newValue }) else {
                return
            }
            loadDraft(from: profile)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("CLI 环境管理"))
                    .font(.title2.bold())
                Text(L10n.tr("为账号 %@ 选择默认启动环境，或新建 Codex / Claude CLI 配置。", account.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("新建 Codex 环境")) {
                startNewEnvironment(target: .codex)
            }
            .buttonStyle(.bordered)

            Button(L10n.tr("新建 Claude 环境")) {
                startNewEnvironment(target: .claude)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var profileList: some View {
        List(model.cliEnvironmentProfiles, selection: $selectedProfileID) { profile in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(profile.sanitizedDisplayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(profile.target.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    if profile.isBuiltIn {
                        Text(L10n.tr("系统"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text(profile.launchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 300, maxWidth: 320)
        .listStyle(.sidebar)
    }

    private var profileEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(editorTitle)
                        .font(.title3.bold())
                    Spacer()
                    if isEditingBuiltIn {
                        Text(L10n.tr("系统默认环境不可直接编辑"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Group {
                    LabeledContent(L10n.tr("显示名")) {
                        TextField(L10n.tr("例如：OpenRouter / Claude 镜像"), text: displayNameBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent(L10n.tr("CLI 目标")) {
                        Picker(L10n.tr("CLI 目标"), selection: targetBinding) {
                            ForEach(CLIEnvironmentTarget.allCases) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .disabled(isEditingBuiltIn)

                if draftProfile.target == .codex {
                    codexEditor
                } else {
                    claudeEditor
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var codexEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.tr("Codex 配置"))

            Toggle(L10n.tr("使用当前账号凭据"), isOn: codexUseAccountCredentialsBinding)
                .disabled(isEditingBuiltIn)

            LabeledContent(L10n.tr("模型")) {
                TextField(L10n.tr("例如：gpt-5.4"), text: codexModelBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            LabeledContent(L10n.tr("模型 Provider")) {
                TextField(L10n.tr("例如：openai / openrouter"), text: codexModelProviderBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            Divider()

            sectionTitle(L10n.tr("自定义 Provider"))

            LabeledContent(L10n.tr("Provider ID")) {
                TextField(L10n.tr("例如：openrouter"), text: codexCustomProviderIdentifierBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            LabeledContent(L10n.tr("显示名")) {
                TextField(L10n.tr("例如：OpenRouter"), text: codexCustomProviderDisplayNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            LabeledContent(L10n.tr("Base URL")) {
                TextField(L10n.tr("例如：https://openrouter.ai/api/v1"), text: codexCustomProviderBaseURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            LabeledContent(L10n.tr("API Key 环境变量")) {
                TextField(L10n.tr("例如：OPENROUTER_API_KEY"), text: codexCustomProviderEnvKeyBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }

            LabeledContent(L10n.tr("API Key")) {
                SecureField(L10n.tr("仅写入隔离启动环境"), text: codexCustomProviderAPIKeyBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingBuiltIn)
            }
        }
    }

    private var claudeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.tr("Claude 配置"))

            Picker(L10n.tr("Provider 来源"), selection: claudeProviderSourceBinding) {
                ForEach(ClaudeProviderSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isEditingBuiltIn)

            switch draftProfile.resolvedClaude.providerSource {
            case .accountCredentials:
                if account.platform == .codex {
                    Text(L10n.tr("当此环境用于 Codex 账号时，应用会自动继承当前账号的 Codex 环境启动 Claude Code，并直接复用当前 Codex OAuth 或 API Key；切到 Claude 账号时，才会沿用 Claude 账号凭据或 Anthropic API Key。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("此模式会沿用当前 Claude 账号凭据或 Anthropic API Key，可按原生 Claude Code 方式启动。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .explicitProvider:
                Text(L10n.tr("此模式不会要求 Claude 登录；缺少 provider 配置时会直接报错，不会回退登录。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.tr("模型")) {
                    TextField(L10n.tr("例如：claude-sonnet-4.5"), text: claudeModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }

                LabeledContent(L10n.tr("Provider Base URL")) {
                    TextField(L10n.tr("例如：https://proxy.example/v1"), text: claudeProviderBaseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }

                LabeledContent(L10n.tr("API Key 环境变量")) {
                    TextField(L10n.tr("例如：ANTHROPIC_API_KEY"), text: claudeAPIKeyEnvNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }

                LabeledContent(L10n.tr("API Key")) {
                    SecureField(L10n.tr("仅写入隔离启动环境"), text: claudeAPIKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }

                LabeledContent(L10n.tr("上下文上限")) {
                    TextField(L10n.tr("例如：200000"), text: $draftContextLimit)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }

            case .inheritCodexEnvironment:
                Text(L10n.tr("此模式不会要求 Claude 登录；当前账号是 Codex 时，会默认自动继承该账号的 Codex 环境。若来源环境本身使用当前账号凭据，会直接复用当前 Codex OAuth 或 API Key；你也可以手动指定一个覆盖来源环境。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.tr("覆盖来源 Codex 环境")) {
                    Picker(L10n.tr("覆盖来源 Codex 环境"), selection: claudeLinkedCodexEnvironmentIDBinding) {
                        Text(L10n.tr("自动继承当前 Codex 账号环境"))
                            .tag("")
                        ForEach(codexEnvironmentProfiles) { profile in
                            Text(profile.sanitizedDisplayName)
                                .tag(profile.id)
                        }
                    }
                    .disabled(isEditingBuiltIn)
                }

                LabeledContent(L10n.tr("上下文上限")) {
                    TextField(L10n.tr("例如：200000"), text: $draftContextLimit)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditingBuiltIn)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let selectedProfile, !selectedProfile.isBuiltIn {
                Button(L10n.tr("删除环境"), role: .destructive) {
                    deleteSelectedEnvironment()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button(L10n.tr("关闭")) {
                dismiss()
            }
            .buttonStyle(.bordered)

            Button(L10n.tr("保存环境")) {
                persistDraft()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isEditingBuiltIn)
        }
        .padding(20)
    }

    private var selectedProfile: CLIEnvironmentProfile? {
        guard let selectedProfileID else { return nil }
        return model.cliEnvironmentProfiles.first(where: { $0.id == selectedProfileID })
    }

    private var isEditingBuiltIn: Bool {
        selectedProfile?.isBuiltIn == true
    }

    private var editorTitle: String {
        if let selectedProfile {
            return selectedProfile.sanitizedDisplayName
        }
        return L10n.tr("新建环境")
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { draftProfile.displayName },
            set: { draftProfile.displayName = $0 }
        )
    }

    private var targetBinding: Binding<CLIEnvironmentTarget> {
        Binding(
            get: { draftProfile.target },
            set: { newValue in
                draftProfile.target = newValue
                switch newValue {
                case .codex:
                    draftProfile.codex = draftProfile.codex ?? CodexCLIEnvironmentConfiguration()
                    draftProfile.claude = nil
                case .claude:
                    draftProfile.claude = draftProfile.claude ?? ClaudeCLIEnvironmentConfiguration()
                    draftProfile.codex = nil
                }
            }
        )
    }

    private var codexUseAccountCredentialsBinding: Binding<Bool> {
        Binding(
            get: { draftProfile.resolvedCodex.useAccountCredentials },
            set: { newValue in
                var configuration = draftProfile.resolvedCodex
                configuration.useAccountCredentials = newValue
                draftProfile.codex = configuration
            }
        )
    }

    private var codexModelBinding: Binding<String> {
        codexBinding(\.model)
    }

    private var codexModelProviderBinding: Binding<String> {
        codexBinding(\.modelProvider)
    }

    private var codexCustomProviderIdentifierBinding: Binding<String> {
        codexCustomProviderBinding(\.identifier)
    }

    private var codexCustomProviderDisplayNameBinding: Binding<String> {
        codexCustomProviderBinding(\.displayName)
    }

    private var codexCustomProviderBaseURLBinding: Binding<String> {
        codexCustomProviderBinding(\.baseURL)
    }

    private var codexCustomProviderEnvKeyBinding: Binding<String> {
        codexCustomProviderBinding(\.envKey)
    }

    private var codexCustomProviderAPIKeyBinding: Binding<String> {
        codexCustomProviderBinding(\.apiKey)
    }

    private var codexEnvironmentProfiles: [CLIEnvironmentProfile] {
        model.cliEnvironmentProfiles.filter { $0.target == .codex }
    }

    private var claudeProviderSourceBinding: Binding<ClaudeProviderSource> {
        Binding(
            get: { draftProfile.resolvedClaude.providerSource },
            set: { newValue in
                var configuration = draftProfile.resolvedClaude
                configuration.providerSource = newValue
                draftProfile.claude = configuration
            }
        )
    }

    private var claudeLinkedCodexEnvironmentIDBinding: Binding<String> {
        Binding(
            get: { draftProfile.resolvedClaude.linkedCodexEnvironmentID ?? "" },
            set: { newValue in
                var configuration = draftProfile.resolvedClaude
                let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.linkedCodexEnvironmentID = trimmedValue.isEmpty ? nil : trimmedValue
                draftProfile.claude = configuration
            }
        )
    }

    private var claudeModelBinding: Binding<String> {
        claudeBinding(\.model)
    }

    private var claudeProviderBaseURLBinding: Binding<String> {
        claudeBinding(\.providerBaseURL)
    }

    private var claudeAPIKeyEnvNameBinding: Binding<String> {
        claudeBinding(\.apiKeyEnvName)
    }

    private var claudeAPIKeyBinding: Binding<String> {
        claudeBinding(\.apiKey)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func startNewEnvironment(target: CLIEnvironmentTarget) {
        let profile = CLIEnvironmentProfile(
            displayName: "",
            target: target,
            isBuiltIn: false,
            codex: target == .codex ? CodexCLIEnvironmentConfiguration() : nil,
            claude: target == .claude ? ClaudeCLIEnvironmentConfiguration() : nil
        )
        selectedProfileID = nil
        loadDraft(from: profile)
    }

    private func loadDraft(from profile: CLIEnvironmentProfile) {
        draftProfile = profile
        draftContextLimit = profile.resolvedClaude.contextLimit.map(String.init) ?? ""
    }

    private func persistDraft() {
        var profile = draftProfile
        if profile.target == .codex {
            profile.claude = nil
            profile.codex = profile.resolvedCodex
        } else {
            profile.codex = nil
            var configuration = profile.resolvedClaude
            let trimmed = draftContextLimit.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.contextLimit = trimmed.isEmpty ? nil : Int(trimmed)
            profile.claude = configuration
        }

        model.saveCLIEnvironmentProfile(profile)
        selectedProfileID = profile.id
        loadDraft(from: profile)
    }

    private func deleteSelectedEnvironment() {
        guard let selectedProfile else { return }
        model.deleteCLIEnvironmentProfile(id: selectedProfile.id)
        let fallbackProfile = model.defaultCLIEnvironment(for: account)
        selectedProfileID = fallbackProfile.id
        loadDraft(from: fallbackProfile)
    }

    private func codexBinding(_ keyPath: WritableKeyPath<CodexCLIEnvironmentConfiguration, String>) -> Binding<String> {
        Binding(
            get: { draftProfile.resolvedCodex[keyPath: keyPath] },
            set: { newValue in
                var configuration = draftProfile.resolvedCodex
                configuration[keyPath: keyPath] = newValue
                draftProfile.codex = configuration
            }
        )
    }

    private func codexCustomProviderBinding(_ keyPath: WritableKeyPath<CodexCustomProviderConfig, String>) -> Binding<String> {
        Binding(
            get: { draftProfile.resolvedCodex.customProvider?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var configuration = draftProfile.resolvedCodex
                var provider = configuration.customProvider ?? CodexCustomProviderConfig()
                provider[keyPath: keyPath] = newValue
                configuration.customProvider = provider
                draftProfile.codex = configuration
            }
        )
    }

    private func claudeBinding(_ keyPath: WritableKeyPath<ClaudeCLIEnvironmentConfiguration, String>) -> Binding<String> {
        Binding(
            get: { draftProfile.resolvedClaude[keyPath: keyPath] },
            set: { newValue in
                var configuration = draftProfile.resolvedClaude
                configuration[keyPath: keyPath] = newValue
                draftProfile.claude = configuration
            }
        )
    }
}
