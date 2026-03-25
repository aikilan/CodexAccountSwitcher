# add-llm-platform-foundation

## Why

当前应用是 Codex 单平台工具，数据模型、路径解析、运行时逻辑和 UI 都默认绑定 `~/.codex`。这会阻碍后续引入 Claude Code 平台，也会让产品命名与能力边界继续停留在 Codex 专用语义。

## What Changes

- 引入 `PlatformKind`，把 `Codex` 与 `Claude` 作为一等平台概念。
- 为 `ManagedAccount` 增加 `platform` 字段，并让旧数据默认迁移到 `Codex`。
- 增加平台运行时占位层，让 Codex 继续走真实实现，Claude 仅暴露占位能力。
- 主界面与新增账号窗口增加平台选择入口。
- 把产品展示名称统一为 `LLM Account Switcher`。
- 迁移应用支持目录到 `~/Library/Application Support/LLMAccountSwitcher`。

## Non-Goals

- 不实现真实 Claude 认证接入。
- 不实现 Claude 账号切换、CLI 启动、额度同步、Keychain 读写。
- 不扩展到第三个平台。
