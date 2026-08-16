# git.refresh-consistency

## 产品目标
为 Git owner 提供紧凑、零写入的稳定事实，并保留索引一致性诊断和快照重建；这些入口不是普通 Git 开工或收尾步骤。

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；仅在 owner 事实、生成口径或公开快照可能漂移时触发。任务运行态不是 owner 输入。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器和 consistency checker 是维护入口。owner status 读取 GitHub metadata、已声明 clone root 的 `.git` identity、索引仓库 identity/head 与治理 registry；当前 Git/GitHub 事实高于 Markdown 快照。

## 核心机制
owner provider 第一阶段只从 `RepoRoot/.git` 解析 origin identity 与 HEAD；读取索引、registry、调用 `gh` 或探测 local root 前，须与默认 expected repository `wlyaaaaa/github-local-index`（或显式测试/迁移绑定）比较。identity 缺失或 mismatch 即返回 `completed/blocked`、`zero_write=true` 和 bounded issue，四路 downstream 调用均为 0；不得先读未可信索引或猜测 current。通过后才读取远端 metadata 和已声明 owner facts，并直接核验对应 `.git`；不运行 `git status/fetch`，不创建 temp/receipt，不写 tracked/private/external 内容。外部治理仓库仅保留 repo metadata，local roots 为空。Fast 是兼容调用方的 compatibility mode，可能写 private log；CheckOnly 用 system temp 比较并清理；完整 refresh 才重建 tracked Markdown，普通 clone 的 fetch 最多尝试三次，commit-pinned snapshot 只刷新 metadata。discovery 在枚举和 Git 命令前排除外部治理路径。

## 输出合同
owner provider 输出 `github-local-index.owner-status.v1`，分离 `execution_status=completed|error` 与 `domain_status=current|review_needed|blocked|unknown`，声明 `zero_write=true`、`fetch_performed=false`，仅含稳定摘要、issue、blocking scope、registry validity、provenance 和 SHA-256 fingerprint。fingerprint 使用排序后的稳定 owner 事实，排除时间、输入顺序、index HEAD、dirty/ahead/behind、任务状态和错误正文。有效 evidence 的 `completed` 退出 0；`gh` 缺失、remote 非零、JSON 无效等 provider 错误统一 `error/unknown` 并退出 2。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；所有入口都不自动 stage、commit、push 或授权发布。

## 失败与降级
`gh` 无法启动、remote 非零或 JSON 无效返回 `error/unknown` 和非零；仅输入已验证但领域结论不足时允许 `completed/unknown`。事实、registry 或索引 identity 缺失/mismatch 返回 `completed/blocked`。unknown 不等于一致，current 只证明 stable owner facts。refresh 三次 fetch 失败保留 `fetch_failed`，刷新或比较失败写 `outcome=error`；均不证明 publication。

## 验证证据
`tests/Test-GitOwnerStatus.ps1` 验证 identity 失败时 index、registry、`gh`、local-path 四路零调用，并覆盖零写入边界、expected repository、remote failure、稳定 fingerprint、状态分离和外部治理隔离；`tests/Run-UnitTests.ps1` 继续覆盖 compatibility、temp、receipt 与生成器。

## 上下文策略
跨 owner 编排优先读取 compact owner status；只有 deltas/issues 需要解释或确需重建时才加载详细索引、生成器或 drift 证据。日常项目任务不需要这些入口。

## 已知限制
owner provider 不扫描未声明 clone root，也不返回普通 branch/worktree/sync/task 事实；新增本地 root 仍由显式 refresh 发现。Fast 与 CheckOnly 不是 `zero_write`；Hook、refresh 或 owner current 都不是 publication 证明。

## 扩展入口
新增模式需声明 tracked、private、temporary、external 和 process exit 效果，保持 execution/domain 分离，并证明其信息价值不能由 compact owner status 覆盖。
