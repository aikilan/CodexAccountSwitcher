# add-llm-platform-foundation

## 目标

- 将应用从 Codex 单平台扩展为 Codex / Claude 双平台框架。
- 本轮只落 Claude 占位入口，不实现真实 Claude 能力。
- 按 OpenSpec 流程完成计划、实施、归档。

## 里程碑

1. 落盘规范文档与开发计划。
2. 完成产品改名与应用支持目录迁移。
3. 完成数据模型平台化与运行时占位层。
4. 完成主界面与新增账号窗口的双平台入口。
5. 完成测试并归档变更。

## 工作包

- 工作包 A：OpenSpec 文档与 `tasks/` 文档。
- 工作包 B：产品命名与打包脚本更新。
- 工作包 C：`PlatformKind`、`ManagedAccount.platform`、目录迁移。
- 工作包 D：Claude 占位 runtime 与 UI。
- 工作包 E：迁移与占位行为测试。

## 依赖关系

- 工作包 A 先于其它工作包。
- 工作包 B、C、D 可以并行实施，但测试依赖它们全部完成。
- 工作包 E 完成后才能执行归档。

## 完成定义

- `swift test` 通过。
- `openspec/specs/platform-account-management/spec.md` 已更新。
- 归档目录存在且 `tasks/add-llm-platform-foundation/archive.md` 已填写。
