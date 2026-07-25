# git.project-admission

## 产品目标
在有信息价值时提供稳定、结构化的 Git 项目身份、worktree、同步与 transport 证据，不把 provider 变成所有 Git 任务的前置仪式。

## 触发条件
triggers: `git_project|repo_identity|project_entry`；语义条件是当前决定存在 identity、visibility、worktree 或 sync 不确定性，或结构化取证收益高于调用成本。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
运行时结构化入口是 `tools/Get-ProjectAdmission.ps1 -Json`，schema 保持 `github-local-index.project-admission.v1`；当前 `.git` 与远端证据比旧 Markdown 快照更有权威。PersonalOS 仅保留 GitHub 目录事实，禁止本 provider 读取其本地路径或给出行动建议。

## 核心机制
provider 是 optional structured evidence。visibility 是 `PUBLIC|PRIVATE|INTERNAL` 闭集，非法值 fail closed。`-LiveMetadata` 只读查询 GitHub 且 never fetch；`-RefreshRefs` 才运行 `git fetch`；兼容 `-Fetch` 等价于两者。`-TargetWorktree` / `-TargetRef` 让顶层 decision 只使用精确目标，仍保留全部 worktree 作为证据。

## 输出合同
输出仓库 identity、定位、visibility、worktrees、sync、`metadata_mode`、`refs_mode`、目标作用域及 transport 结论；`push_decision` / `push_strategy` 不构成写入或 publication 授权。

## 失败与降级
provider、schema、identity 不明确或证据仍为 cached 时保留限制；`decision=block` 阻止依赖不足证据的写入和直接 transport，但保留 read-only diagnosis。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 V1 schema、visibility 闭集、只读 metadata、refs refresh、ref/worktree scope、外部治理排除与兼容 `-Fetch`。

## 上下文策略
按信息价值查询单个项目；证据已新鲜明确时可跳过 provider。合同卡不复制动态记录或历史快照。

## 已知限制
Markdown is not machine authority；V1 不输出 publication decision，也不能替代目标项目规则或用户授权。无 target 的调用保留全 worktree 聚合兼容语义。

## 扩展入口
字段级 source/timestamp 计划在 V2 用稳定 `field_evidence` 映射表达；V1 继续以顶层观察时间和 mode 字段兼容现有调用方。
