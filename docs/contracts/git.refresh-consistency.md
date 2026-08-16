# git.refresh-consistency

## 产品目标
为 Git owner 提供紧凑、零写入的稳定事实、诊断和可重建快照；不是普通 Git 开工或收尾步骤。

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；仅在 owner 事实、生成口径或公开快照可能漂移时触发。任务运行态不是 owner 输入。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器和 consistency checker 是入口。status 只读 Git/GitHub metadata、声明 clone 的 `.git` identity、索引 identity/head 和治理 registry；Git/GitHub 高于 Markdown 快照。

## 核心机制
第一阶段只从 `RepoRoot/.git` 解析 origin identity 与 HEAD；读取索引、registry、`gh` 或 local root 前，须与 expected `wlyaaaaa/github-local-index`（或显式测试/迁移绑定）比较。identity 缺失或 mismatch 即 `completed/blocked`、`zero_write=true`，四路调用为 0；不得读未可信索引或猜 current。通过后才读取远端 metadata/owner facts，并核验 `.git`；不运行 `git status/fetch`，不创建 temp/receipt，不写 tracked/private/external 内容。外部治理仓库仅保留 repo metadata。Fast compatibility mode 可写 private log；CheckOnly 用 system temp；完整 refresh 重建 tracked Markdown，普通 clone fetch 最多尝试三次，commit-pinned snapshot 只刷 metadata；discovery 排除外部治理路径。

## 输出合同
provider 输出 `github-local-index.owner-status.v1`，分离 `execution_status=completed|error` 与 `domain_status=current|review_needed|blocked|unknown`，声明 `zero_write=true`、`fetch_performed=false`，仅含摘要、issue、scope、registry、provenance 和 fingerprint；fingerprint 排除时间、输入顺序、index HEAD、dirty/ahead/behind、任务状态和错误正文。有效 `completed` 退出 0；`gh` 缺失、remote 非零、JSON 无效统一 `error/unknown`、退出 2。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；入口不自动 stage、commit、push 或授权发布。

## 失败与降级
`gh` 无法启动、remote 非零或 JSON 无效返回 `error/unknown`；输入已验证但领域结论不足时可 `completed/unknown`。事实、registry 或 identity 缺失/mismatch 返回 `completed/blocked`。unknown 不等于一致，current 只证明 stable owner facts。refresh 三次 fetch 失败保留 `fetch_failed`，刷新或比较失败写 `outcome=error`；均不证明 publication。

## 验证证据
`tests/Test-GitOwnerStatus.ps1` 覆盖 identity 失败零调用、零写入、expected repository、remote failure、fingerprint、状态分离和外部治理隔离；`tests/Run-UnitTests.ps1` 覆盖生成器、temp、receipt。

## 上下文策略
跨 owner 编排优先读取 compact owner status；只有 deltas/issues 需要解释或确需重建时才加载详细索引、生成器或 drift 证据。日常项目任务不需要这些入口。

## 已知限制
provider 不扫描未声明 clone root，也不返回普通 branch/worktree/sync/task 事实；新增 root 由显式 refresh 发现。Fast 与 CheckOnly 不是 `zero_write`；Hook、refresh 或 owner current 都不是 publication 证明。

持久化边界：Git/GitHub、受管 JSON registry 和 current generation manifest 是事实与可审计 diff 的最小组合；generation 先写同卷 `.incoming`，完整回读后才原子改名，默认保留 current+previous，顶层 projection 仅兼容且 generation id 不匹配即 stale。`refs/codex/turn-diffs/checkpoints` 与 unreachable objects 是恢复材料，未取得 owner 的保留/恢复证明前不得 `gc`、`prune` 或清理。当前不引入数据库；未来查询加速只能是可删除、可重建的 derived cache，不能替代 Git、GitHub 或 registry。

## 扩展入口
新增模式需声明 tracked、private、temporary、external 和 process exit 效果，保持 execution/domain 分离，并证明其信息价值不能由 compact owner status 覆盖
