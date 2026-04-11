import SwiftUI

struct IsolatedCodexModelSelectionSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: OrbitSpacing.section) {
                    formSection

                    if let error = model.isolatedCodexModelSelectionError {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .orbitSurface(.danger)
                    }
                }
                .padding(OrbitSpacing.section)
                .frame(maxWidth: 720, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            footer
        }
        .background(OrbitPalette.background)
        .tint(OrbitPalette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: AppIconArtwork.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Orbit"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.tr("选择启动模型"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(L10n.tr("关闭")) {
                model.cancelIsolatedCodexModelSelection()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, OrbitSpacing.section)
        .padding(.top, OrbitSpacing.section)
        .padding(.bottom, OrbitSpacing.regular)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("独立实例启动模型"))
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("模型"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(
                    L10n.tr("模型"),
                    selection: Binding(
                        get: { model.isolatedCodexModelSelection?.selectedModel ?? "" },
                        set: { model.updateIsolatedCodexModelSelection($0) }
                    )
                ) {
                    ForEach(model.isolatedCodexModelSelection?.availableModels ?? [], id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("强度"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(
                    L10n.tr("强度"),
                    selection: Binding(
                        get: { model.isolatedCodexModelSelection?.selectedReasoningEffort ?? "medium" },
                        set: { model.updateIsolatedCodexModelSelectionReasoningEffort($0) }
                    )
                ) {
                    ForEach(model.isolatedCodexModelSelection?.availableReasoningEfforts ?? [], id: \.self) { reasoningEffort in
                        Text(reasoningEffortTitle(reasoningEffort)).tag(reasoningEffort)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(L10n.tr("本次确认后会先把模型写回当前账号的默认模型，再启动独立 Codex 实例。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("取消")) {
                model.cancelIsolatedCodexModelSelection()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(confirmButtonTitle) {
                Task {
                    await model.confirmIsolatedCodexModelSelection()
                    if model.isolatedCodexModelSelection == nil {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConfirmDisabled)
        }
        .padding(OrbitSpacing.section)
    }

    private var statusText: String {
        guard let selection = model.isolatedCodexModelSelection else {
            return L10n.tr("为独立实例确认一个启动模型。")
        }
        return L10n.tr("账号 %@ 会先使用你在这里确认的模型启动独立 Codex。", selection.accountDisplayName)
    }

    private var confirmButtonTitle: String {
        guard let accountID = model.isolatedCodexModelSelection?.accountID else {
            return L10n.tr("启动独立实例")
        }
        if model.isLaunchingIsolatedInstance(for: accountID) {
            return L10n.tr("正在启动...")
        }
        return L10n.tr("启动独立实例")
    }

    private var isConfirmDisabled: Bool {
        guard let selection = model.isolatedCodexModelSelection else { return true }
        return selection.selectedModel.isEmpty
            || selection.selectedReasoningEffort.isEmpty
            || model.isLaunchingIsolatedInstance(for: selection.accountID)
    }

    private func reasoningEffortTitle(_ reasoningEffort: String) -> String {
        switch reasoningEffort {
        case "low":
            return L10n.tr("低")
        case "medium":
            return L10n.tr("中")
        case "high":
            return L10n.tr("高")
        case "xhigh":
            return L10n.tr("极高")
        default:
            return reasoningEffort
        }
    }
}
