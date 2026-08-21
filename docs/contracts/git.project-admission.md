# git.project-admission

## 产品目标
在有信息价值时提供稳定、结构化的 Git 项目身份、worktree、同步与 transport 证据，不把 provider 变成所有 Git 任务的前置仪式。

## 触发条件
triggers: `git_project|repo_identity|project_entry`；语义条件是当前决定存在 identity、visibility、worktree 或 sync 不确定性，或结构化取证收益高于调用成本。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
运行时结构化入口是 `tools/Get-ProjectAdmission.ps1 -Json`，schema 保持 `github-local-index.project-admission.v1`；当前 `.git` 与远端证据比旧 Markdown 快照更有权威。provider 不按业务项目名称硬编码外部治理例外；跨 owner 边界只来自精确 artifact/retention registry 与项目规则。

## 核心机制
provider 是 optional structured evidence。visibility 是 `PUBLIC|PRIVATE|INTERNAL` 闭集，非法值 fail closed。`-LiveMetadata` 只读查询 GitHub 且 never fetch；`-RefreshRefs` 才运行 `git fetch`；兼容 `-Fetch` 等价于两者。`-ForPublication` 是发布决策的只读 live profile，同时要求 GitHub metadata 与 remote refs 新鲜，任一失败即保持阻断；普通本地/只读任务不默认使用。`-TargetWorktree` / `-TargetRef` 让顶层 decision 只使用精确目标，仍保留全部 worktree 与 branch inventory 作为证据，并比较 target 与实际 remote default branch reachability。exact artifact-owner registry 只排除明确跨 owner ref，不隐藏普通未来分支；exact necessary-retention registry 只为同时匹配 repo、路径和 HEAD 的已查明保留项附带 owner、用途与退出条件，不把名称猜测当作保留依据。

## 输出合同
输出仓库 identity、定位、visibility、worktrees、branches、artifact governance、necessary retention、default-branch integration、sync、目标作用域及 transport 结论。顶层必须显式返回 `evidence_source={local_git,github_metadata,remote_refs}`、`freshness=live|mixed|cached` 与 `live_checked`；调用方不得从字段缺失或旧 Markdown 猜新鲜度。`push_decision` / `push_strategy` 不构成写入或 publication 授权。

## 失败与降级
provider、schema、identity 不明确或证据仍为 cached 时保留限制；artifact registry 缺失、JSON/schema 无效、owner/ref/retention entry 不完整或重复时在模块加载阶段 fail closed，避免静默失去 owner 边界。`decision=block` 阻止依赖不足证据的写入和直接 transport，但保留 read-only diagnosis。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 V1 schema、显式证据来源/新鲜度、visibility 闭集、只读 metadata、refs refresh、publication live profile、ref/worktree scope 与兼容 `-Fetch`。

## 上下文策略
按信息价值查询单个项目；证据已新鲜明确时可跳过 provider。合同卡不复制动态记录或历史快照。

## 已知限制
Markdown is not machine authority；V1 不输出 publication decision，也不能替代目标项目规则或用户授权。无 target 的调用保留全 worktree 聚合兼容语义。

## 扩展入口
若未来需要每字段独立时效，再用版本化 `field_evidence` 扩展；V1 已用顶层观察时间、`evidence_source`、`freshness`、`live_checked` 与 mode 字段消除 cached/live 歧义。
