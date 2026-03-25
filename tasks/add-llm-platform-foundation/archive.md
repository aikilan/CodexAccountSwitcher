# add-llm-platform-foundation 归档

## 交付内容

- 新增 `PlatformKind`、`PlatformRuntime` 与 Claude 占位能力矩阵。
- `ManagedAccount` 增加 `platform`，旧库默认迁移到 `Codex`。
- 主界面与新增账号窗口增加平台切换，Claude 视图展示占位说明。
- 产品展示名称更新为 `LLM Account Switcher`。
- 应用支持目录迁移到 `~/Library/Application Support/LLMAccountSwitcher`。

## 验证结果

- 已执行 `swift test`
- 结果：通过

## 偏差说明

- 本轮没有实现真实 Claude 认证、切换、CLI 启动或额度同步。
- Swift 模块名与资源 bundle 名保持现状，以减少测试与资源加载改动面。

## 后续事项

- 单独立项实现真实 Claude 凭据接入。
- 评估是否需要把菜单栏面板也补成显式平台切换入口。

## 归档路径

- `openspec/changes/archive/2026-03-25-add-llm-platform-foundation/`
