# Design

## 数据模型

- 新增 `PlatformKind`，固定为 `.codex` 与 `.claude`。
- `ManagedAccount` 增加 `platform` 字段，缺失时默认补 `.codex`。
- `AppDatabase` 版本提升到 `3`，读取旧数据时自动写回当前版本。

## 路径与目录

- `AppPaths` 新增 `PlatformPaths`，同时维护 Codex 与 Claude 的 home 路径。
- Codex 继续解析 `CODEX_HOME` 或 `~/.codex`。
- Claude 预留 `CLAUDE_CONFIG_DIR` 或 `~/.claude`。
- 应用支持目录从 `CodexAccountSwitcher` 迁移到 `LLMAccountSwitcher`。

## 运行时边界

- 新增 `PlatformRuntime` 与 `PlatformCapabilities`。
- `CodexPlatformRuntime` 暴露全部现有能力。
- `ClaudePlatformRuntime` 暴露禁用矩阵，所有真实动作必须被阻止。
- `AppViewModel` 保持原有 Codex 服务依赖，但以平台能力矩阵决定 UI 和入口行为。

## UI

- 主界面侧栏增加平台切换。
- 新增账号窗口增加平台切换。
- Claude 详情页与新增账号页只显示占位说明，按钮禁用。
- 菜单栏 tooltip、主窗口标题、README 使用统一产品名。

## 迁移与验证

- 迁移目录时只在“旧存在、新不存在”时执行 move。
- 若新旧目录同时存在，以新目录为准。
- 主要验证通过 `swift test` 完成，并补充平台与迁移测试。
