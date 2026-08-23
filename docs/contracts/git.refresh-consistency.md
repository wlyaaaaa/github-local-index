# git.refresh-consistency

## 产品目标
为 Git owner 提供紧凑、零写入的稳定事实、诊断和可重建快照；不是普通 Git 开工或收尾步骤。

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；仅在 owner 事实、生成口径或公开快照可能漂移时触发。任务运行态不是 owner 输入。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器和 consistency checker 是入口。status 只读 Git/GitHub metadata、声明 clone 的 `.git` identity、索引 identity/head、治理 registry 与 ignored 私有 v3 owner baseline；Git/GitHub 高于 Markdown 快照。PUBLIC Markdown 只是公开兼容投影，绝不作为全 owner identity baseline。

## 核心机制
第一阶段只从 `RepoRoot/.git` 解析 origin identity 与 HEAD；读取 baseline、registry、`gh` 或 local root 前，须与 expected `wlyaaaaa/github-local-index`（或显式测试/迁移绑定）比较。identity 缺失或 mismatch 即 `completed/blocked`、`zero_write=true`，四路调用为 0；不得读未可信 owner 数据或猜 current。通过后才读取远端 metadata/owner facts，并核验已声明 local root 的 `.git`；普通 status 不运行 `git status/fetch`，不创建 temp/receipt，不写 tracked/private/external 内容。

全 owner identity baseline 与 local root 分离保存于 ignored 私有 `github-local-index.owner-baseline-store.v3`：identity 只含 repo、visibility、default branch；每个 identity 的 local root 独立且可为 null。单个原子 store 同时保存 current、previous、对应 local-root snapshot、规范 hash 与 receipt；读取须完成 schema、集合、hash 与最终 readback 验证。显式 `-MigrateBaseline` 是唯一写入口：仅查询 live owner metadata、复用并逐项核验 v2 navigation 的 `.git` origin，不 fetch、不扫描仓库正文、不重建公开索引。首次没有真实 prior full-owner baseline 时写 `history_gap=true` 的 bootstrap receipt，status 保持 attention/unknown；不得用 live 自比较、PUBLIC 子集或自动化记忆伪造历史 current。后续 current/previous 的真实 delta 保留 review，直到下一次稳定比较。Fast compatibility mode 可写 private log；CheckOnly 用 system temp；完整 refresh 重建 tracked Markdown，普通 clone fetch 最多尝试三次，commit-pinned snapshot 只刷 metadata；discovery 排除外部治理路径。

## 输出合同
provider 输出 `github-local-index.owner-status.v1`，分离 `execution_status=completed|error` 与 `domain_status=current|review_needed|blocked|unknown`，声明 `zero_write=true`、`fetch_performed=false`，仅含摘要、issue/attention、scope、registry、provenance、history 和 fingerprint；local-root delta 只返回计数，不返回路径。fingerprint 排除时间、输入顺序、index HEAD、dirty/ahead/behind、任务状态和错误正文。有效 `completed` 退出 0；`gh` 缺失、remote 非零、JSON 无效统一 `error/unknown`、退出 2。显式 migration 只返回计数、hash、bootstrap/history 状态，不回显 identity 或路径。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；入口不自动 stage、commit、push 或授权发布。

## 失败与降级
`gh` 无法启动、remote 非零或 JSON 无效返回 `error/unknown`；v3 baseline 缺失、无效或首次 bootstrap history gap 返回明确 `completed/unknown`，不回退 PUBLIC Markdown。事实、registry 或 index identity 缺失/mismatch 返回 `completed/blocked`。unknown 不等于一致，current 只证明完整 current/previous owner facts 与本次 live observation 一致。refresh 三次 fetch 失败保留 `fetch_failed`，刷新或比较失败写 `outcome=error`；均不证明 publication。

## 验证证据
`tests/Test-GitOwnerStatus.ps1` 覆盖 identity 失败零调用、零写入、expected repository、remote failure、fingerprint、状态分离和外部治理隔离；`tests/Run-UnitTests.ps1` 覆盖生成器、temp、receipt。

## 上下文策略
跨 owner 编排优先读取 compact owner status；只有 deltas/issues 需要解释或确需重建时才加载详细索引、生成器或 drift 证据。日常项目任务不需要这些入口。

## 已知限制
provider 不扫描未声明 clone root，也不返回普通 branch/worktree/sync/task 事实；新增 root 由显式 refresh 发现。Fast 与 CheckOnly 不是 `zero_write`；Hook、refresh 或 owner current 都不是 publication 证明。

持久化边界：Git/GitHub、受管 JSON registry 和 current generation manifest 是事实与可审计 diff 的最小组合；generation 先写同卷 `.incoming`，完整回读后才原子改名，默认保留 current+previous，顶层 projection 仅兼容且 generation id 不匹配即 stale。`refs/codex/turn-diffs/checkpoints` 与 unreachable objects 是恢复材料，未取得 owner 的保留/恢复证明前不得 `gc`、`prune` 或清理。当前不引入数据库；未来查询加速只能是可删除、可重建的 derived cache，不能替代 Git、GitHub 或 registry。

## 扩展入口
新增模式需声明 tracked、private、temporary、external 和 process exit 效果，保持 execution/domain 分离，并证明其信息价值不能由 compact owner status 覆盖
