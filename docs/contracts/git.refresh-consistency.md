# git.refresh-consistency

## 产品目标
Git owner 零写入诊断与可重建快照；非普通 Git 开工/收尾

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；事实/口径/公开快照漂移时读，不消费任务运行态

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
入口：`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器、consistency checker。status只读 Git/GitHub metadata、声明 clone/.git、索引 identity/head、治理 registry、私有 v3 baseline；Git/GitHub权威；PUBLIC Markdown仅兼容、非baseline

## 核心机制
先核验 `RepoRoot/.git` origin identity、HEAD 和 expected `wlyaaaaa/github-local-index`（或测试/迁移绑定）。通过前不读 baseline/registry/`gh`/local root；缺失/mismatch→`completed/blocked`、`zero_write=true`、调用0。通过后读远端/核验root `.git`；普通 status 不运行 `git status/fetch`、不建 temp/receipt、不写入

ignored 私有 `github-local-index.owner-baseline-store.v3` 分存 identity（repo、visibility、default branch）/可空 local root；原子保存 current/previous、root snapshot、规范 hash、receipt，校验 schema/集合/hash/readback。

`-MigrateBaseline` 是 explicit bootstrap/repair 兼容入口。有效 v3 baseline 的默认 full refresh 在同一用户命令内原子发布 generation、刷新 private clone navigation，以 fresh owner inventory 原子 advance baseline/readback；previous→current nonblocking history，不重复同次 migration。Fast compatibility mode 写 private log；CheckOnly 用 system temp。默认 full refresh 重建 Markdown，fetch 最多尝试三次；`commit-pinned snapshot` 只刷 metadata。仅 `-ZeroFetchAtomic` 传 `SkipFetch`，复用 atomic generation/manifest/projection readback、pointer CAS、rollback；禁与 Fast/CheckOnly 合用，非 refs freshness/publication 证据。byte-hashed pointer/generation/projections 用 `.gitattributes text eol=lf` 固定 UTF-8/LF，防 checkout 改行尾破坏闭包。

## 输出合同
`github-local-index.owner-status.v1`：`execution_status=completed|error`、`domain_status=current|review_needed|blocked|unknown`、`zero_write=true`、`fetch_performed=false`；其余为摘要/issue/attention/scope/registry/provenance/history/fingerprint/root delta计数。fingerprint 排除时间/顺序/index HEAD/dirty/ahead/behind/任务状态/错误正文；`completed` 退出0；`gh` 不可启动、remote非零、JSON无效→`error/unknown`，退出2。migration仅返计数/hash/bootstrap/history，不回显 identity/路径。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；不自动 stage/commit/push或授权发布

## 失败与降级
v3 baseline 缺失/无效/首次 history gap→`completed/unknown`，不回退 PUBLIC Markdown；事实/registry/index identity 缺失/mismatch→`completed/blocked`。unknown 非一致；current 仅表示完整 current/previous owner facts/live observation 一致。三次 fetch 失败保留 `fetch_failed`；刷新/比较失败写 `outcome=error`，均不证明 publication。

## 验证证据
`Test-GitOwnerStatus.ps1` / `Run-UnitTests.ps1`

## 上下文策略
跨 owner 先读 compact status，解释 delta/issue 或重建才读详情；日常项目任务不需要这些入口

## 已知限制
provider 不扫未声明 root、不返 branch/worktree/sync/task；新 root 由 refresh 发现。Fast/CheckOnly 非 `zero_write`；Hook/refresh/current 不证明 publication。

持久事实为 Git/GitHub、JSON registry、generation manifest；generation 同卷 `.incoming` 回读后原子改名，仅留 current+previous；projection id mismatch 即 stale。`refs/codex/turn-diffs/checkpoints`、unreachable objects 无 owner 证明，不得 `gc`/`prune`/清理。无数据库;cache可删/重建、非权威。

## 扩展入口
新增模式须声明 tracked/private/temporary/external 和 process exit 效果，分离 execution/domain，并证明 compact status 不足
