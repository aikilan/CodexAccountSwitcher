# Tasks

## 1. OpenSpec 基础落盘

- [x] 初始化 `openspec/config.yaml` 与 `openspec/project.md`
- [x] 创建 `add-llm-platform-foundation` 变更文档
- [x] 创建 `tasks/add-llm-platform-foundation/plan.md` 与 `archive.md`

## 2. 产品命名与本地目录迁移

- [x] 将用户可见产品名更新为 `LLM Account Switcher`
- [x] 将应用支持目录迁移到 `LLMAccountSwitcher`
- [x] 保持“新旧目录同时存在时以新目录为准”

## 3. 数据模型平台化

- [x] 新增 `PlatformKind`
- [x] 为 `ManagedAccount` 增加 `platform`
- [x] 将旧库记录默认迁移到 `.codex`

## 4. 运行时与路径抽象

- [x] 新增平台运行时接口与能力矩阵
- [x] 保留 Codex 真实能力
- [x] 新增 Claude 占位 runtime
- [x] 增加 `~/.claude` / `CLAUDE_CONFIG_DIR` 路径预留

## 5. UI 双平台入口

- [x] 主界面增加平台切换
- [x] 新增账号窗口增加平台切换
- [x] Claude 详情区展示占位说明
- [x] Claude 相关操作按钮禁用

## 6. 验证

- [x] 补充旧数据库迁移测试
- [x] 补充应用支持目录迁移测试
- [x] 补充 Claude 占位行为测试
- [x] 运行 `swift test`

## 7. 归档

- [x] 将最终能力沉淀到 `openspec/specs/platform-account-management/spec.md`
- [x] 将变更存放到 `openspec/changes/archive/2026-03-25-add-llm-platform-foundation/`
- [x] 填写 `tasks/add-llm-platform-foundation/archive.md`
