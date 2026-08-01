# git.refresh-consistency

## 产品目标
为 Git owner 提供紧凑、零写入的稳定事实状态，同时保留索引一致性诊断和快照重建能力；这些入口都不是普通 Git 开工或收尾步骤。

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；仅当 owner 事实、生成口径或公开快照可能漂移时触发。周期编排可以消费 owner status，但任务运行态不是 owner 输入。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器和 consistency checker 是维护入口。owner status 读取 GitHub metadata、公开索引中的已声明 clone root、对应 `.git` identity、索引仓库 identity/head 与 `git-artifact-governance` registry；当前 Git/GitHub 事实高于 Markdown 快照。

## 核心机制
owner provider 的入口第一阶段只能从 `RepoRoot/.git` 解析 origin repository identity 与 HEAD；在读取 `01_仓库索引`、governance registry、调用 `gh` 或进入任何 local-root merge/probe 前，必须先与默认 expected repository `wlyaaaaa/github-local-index`（或显式 `ExpectedRepository` 测试/迁移绑定）比较。identity 缺失或 mismatch 立即返回 `completed/blocked`、`zero_write=true` 与 bounded issue，并保证上述四路 downstream 调用计数全为 0；绝不能先读取未可信 index 再判断，也不能回退猜测为 current。identity 通过后才以 `gh repo list` 取得远端 metadata、读取已声明 owner facts，并直接读取对应 `.git` 文件验证已声明 root；它不运行 `git status/fetch`，不创建 temp/receipt，不写 tracked/private/external 内容。外部治理仓库只保留 repo metadata，local roots 固定为空，绝不解析、探测或回显其本地路径。Fast 保留为既有调用方的 compatibility mode 且可能写 private log；CheckOnly 使用 system temp 比较并清理；完整 refresh 才重建 tracked Markdown，对普通 clone 的 fetch 最多尝试三次，commit-pinned snapshot 只刷新 metadata。完整 refresh 的 discovery 仍在任何枚举和 Git 命令前排除外部治理路径。

## 输出合同
owner provider 输出 `github-local-index.owner-status.v1`：`execution_status=completed|error` 与 `domain_status=current|review_needed|blocked|unknown` 分离，声明 `zero_write=true`、`fetch_performed=false`，仅含摘要、稳定 owner deltas、bounded issue codes、blocking scopes、registry validity、provenance 和 SHA-256 fingerprint。fingerprint 对排序后的 repo/visibility/default branch/canonical roots、索引 repo/default branch 与 registry semantic identity 计算，排除时间、输入顺序、index HEAD、dirty/ahead/behind、任务状态和错误正文；HEAD 只作 provenance。所有已取得有效 provider evidence 的 `completed`（含 review、blocked、unknown）退出 0；`gh` CLI 缺失、remote transport 非零、remote JSON 无效及其他 provider 执行错误统一 `error/unknown` 并退出 2。hidden CheckOnly 仍原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；所有入口都不自动 stage、commit、push 或授权发布。

## 失败与降级
无法启动 `gh`、remote 命令非零或 JSON 解析失败属于 provider execution failure，返回 `error/unknown` 和非零；只有在 provider 已成功取得并验证输入后仍无法形成领域结论，才允许 `completed/unknown`。事实、registry 或索引 repository identity 缺失/mismatch 返回 `completed/blocked`。unknown 不解释为一致，current 也只证明 stable owner facts。既有 refresh 三次 fetch 失败保留 `fetch_failed`，刷新或比较失败的 receipt 写 `outcome=error`；这些结果都不证明 publication。

## 验证证据
`tests/Test-GitOwnerStatus.ps1` 用 mock/sentinel 验证 identity mismatch/unresolved 时 index、registry、`gh`、local-path 四路零调用及 valid path 各一次调用，并验证零写入源边界、精确 expected repository identity、三类 remote provider failure、稳定 fingerprint、registry、领域/执行分离、动态事实排除和外部治理路径隔离；`tests/Run-UnitTests.ps1` 纳入该测试并继续覆盖 compatibility、temp、receipt 与生成器行为。

## 上下文策略
跨 owner 编排优先读取 compact owner status；只有 deltas/issues 需要解释或确需重建时才加载详细索引、生成器或 drift 证据。日常项目任务不需要这些入口。

## 已知限制
owner provider 不扫描未声明 clone root，也不返回普通 branch/worktree/sync/task 事实；新增本地 root 仍由显式 refresh 发现。Fast 与 CheckOnly 不是 `zero_write`；Hook、refresh 或 owner current 都不是 publication 证明。

## 扩展入口
新增模式需声明 tracked、private、temporary、external 和 process exit 效果，保持 execution/domain 分离，并证明其信息价值不能由 compact owner status 覆盖。
