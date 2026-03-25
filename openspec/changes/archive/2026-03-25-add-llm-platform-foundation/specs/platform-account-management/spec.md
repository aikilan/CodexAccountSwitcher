## ADDED Requirements

### Requirement: Platform Selection
应用必须提供 `Codex` 与 `Claude` 两个平台入口，并允许用户在主界面与新增账号流程中看到平台概念。

#### Scenario: Claude appears as a placeholder
- Given 用户切换到 `Claude`
- When 界面完成刷新
- Then Claude 详情区必须显示占位说明
- And 不可用操作必须处于禁用态

### Requirement: Legacy Data Migration
旧版账号数据必须在升级后保留可用。

#### Scenario: Missing platform defaults to Codex
- Given 旧账号记录没有 `platform`
- When 应用读取数据库
- Then 记录必须按 `Codex` 处理

### Requirement: Product Naming
用户可见产品名称必须统一为 `LLM Account Switcher`。

#### Scenario: Main window and packaging show new name
- Given 用户查看主窗口、状态栏或打包产物
- When 这些入口被展示
- Then 应显示 `LLM Account Switcher`
