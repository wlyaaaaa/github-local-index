# git.refresh-consistency

owner: E:\GitHub总索引

Git owner 的零写入事实、诊断与可重建快照入口。日常项目任务不需要这些入口，不作为普通 Git 开工或收尾流程。

triggers: `owner_status|refresh|consistency|index_drift`；事实、口径或公开快照可能漂移时触发，任务运行态不是输入。

## 输入与身份核验

入口为 `Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器和 consistency checker。status 只读 Git/GitHub metadata、声明 clone 的 `.git`、索引 identity/head、治理 registry 与私有 v3 baseline。Git/GitHub 是权威；PUBLIC Markdown 仅作兼容投影，不是 owner baseline。

先比较 `RepoRoot/.git` 的 origin identity、HEAD 与 expected `wlyaaaaa/github-local-index`（或测试/迁移绑定）。通过前不读 baseline、registry、`gh` 或 local root；缺失或 mismatch 返回 `completed/blocked`、`zero_write=true`、调用 0。通过后读取远端事实并核验 root `.git`。普通 status 不运行 `git status/fetch`，不建 temp/receipt，不写入。

## 刷新与原子快照

ignored 私有 `github-local-index.owner-baseline-store.v3` 分存 identity（repo、visibility、default branch）与可空 local root；原子保存 current/previous、root snapshot、规范 hash 和 receipt，读取时验证 schema、集合、hash 和 readback。

`-MigrateBaseline` 仅保留 explicit bootstrap/repair 兼容。已有有效 v3 baseline 时，默认 full refresh 在同一用户命令内先原子发布 generation、刷新 private clone navigation，再用 fresh owner inventory 原子 advance baseline/readback。previous→current transition 保留为 nonblocking history，不要求第二次相同 migration。

默认 full refresh 重建 Markdown，fetch 最多尝试三次；commit-pinned snapshot 只刷 metadata。Fast compatibility mode 写 private log；CheckOnly 用 system temp。仅 `-ZeroFetchAtomic` 传 `SkipFetch`，复用 atomic generation/manifest/projection readback/pointer CAS/rollback；禁止与 Fast/CheckOnly 合用，也不构成 refs freshness/publication 证据。byte-hashed pointer、generation 和 projections 由 `.gitattributes text eol=lf` 固定为 UTF-8/LF，避免 checkout 改写行尾破坏闭包。

持久事实为 Git/GitHub、JSON registry、generation manifest。generation 经同卷 `.incoming` 回读后原子改名，仅留 current+previous；projection id mismatch 即 stale。`refs/codex/turn-diffs/checkpoints`、unreachable objects 无 owner 证明不得 `gc`、`prune` 或清理。不引入数据库；cache 可删除、可重建，不能成为权威。

## 输出与失败

`github-local-index.owner-status.v1` 返回 `execution_status=completed|error`、`domain_status=current|review_needed|blocked|unknown`、`zero_write=true`、`fetch_performed=false`；其余限摘要、issue/attention、scope、registry、provenance、history、fingerprint，root delta 仅计数。fingerprint 排除时间、顺序、index HEAD、dirty、ahead/behind、任务状态和错误正文。

`completed` 退出 0；`gh` 不可启动、remote 非零或 JSON 无效为 `error/unknown`，退出 2。migration 仅返回计数/hash/bootstrap/history，不回显 identity 或路径。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`），不自动 stage/commit/push，也不授权发布。

v3 baseline 缺失、无效或首次 history gap → `completed/unknown`，不回退 PUBLIC Markdown；事实、registry 或 index identity 缺失/mismatch → `completed/blocked`。unknown 不等于一致；current 只表示完整 current/previous owner facts 与 live observation 一致。三次 fetch 失败保留 `fetch_failed`；刷新或比较失败写 `outcome=error`，均不证明 publication。

## 读取、验证与扩展

跨 owner 先读 compact status，仅为解释 delta/issue 或重建读取详情。provider 不扫未声明 root，不返回 branch/worktree/sync/task；新 root 由 refresh 发现。Fast/CheckOnly 不是 `zero_write`；Hook、refresh 或 current 不证明 publication。

`Test-GitOwnerStatus.ps1` 验证 identity gate、zero-write、expected repo、remote failure、fingerprint、status 与外部治理；`Run-UnitTests.ps1` 验证 generator、temp 和 receipt。

新增模式须声明 tracked/private/temporary/external 与 process exit 效果，保持 execution/domain 分离，并证明 compact status 不足。
