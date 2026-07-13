# git.project-admission

## 产品目标
在有信息价值时提供稳定、结构化的 Git 项目身份、worktree、同步与 transport 证据，不把 provider 变成所有 Git 任务的前置仪式。

## 触发条件
triggers: `git_project|repo_identity|project_entry`；语义条件是当前决定存在 identity、visibility、worktree 或 sync 不确定性，或结构化取证收益高于调用成本。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
运行时结构化入口是 `tools/Get-ProjectAdmission.ps1 -Json`，schema 保持 `github-local-index.project-admission.v1`；当前 `.git` 与远端证据比旧 Markdown 快照更有权威。

## 核心机制
provider 是 optional structured evidence。`decision` 表示项目进入证据是否充分；`warn` 暴露限制，cached 证据降低新鲜度。`decision=block` 阻止基于不充分证据的写入和直接 transport，但不阻止 read-only diagnosis。

## 输出合同
输出仓库 identity、定位、visibility、worktrees、sync 及 transport 结论；`push_decision` / `push_strategy` 不构成写入或 publication 授权。

## 失败与降级
provider、schema 或 identity 不明确时保留错误并收窄为只读调查；模型可用等价的新鲜 Git/GitHub 证据定位原因，不把工具失败扩大成禁止读取。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 V1 schema、CLI 退出语义、worktree 与稳定字段；工具行为首轮保持兼容。

## 上下文策略
按信息价值查询单个项目；证据已新鲜明确时可跳过 provider。合同卡不复制动态记录或历史快照。

## 已知限制
Markdown is not machine authority；V1 不输出 publication decision，也不能替代目标项目规则或用户授权。

## 扩展入口
只有稳定语义无法由 V1 或等价证据表达时才设计兼容版本，不为固定流程增加字段。
