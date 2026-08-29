# git.refresh-consistency

## 产品目标
Git owner 的零写入事实/诊断/可重建快照；非普通 Git 开工/收尾。

## 触发条件
triggers: `owner_status|refresh|consistency|index_drift`；事实/口径/公开快照可能漂移时触发，任务运行态非输入。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
入口：`Get-GitOwnerStatus.ps1`、refresh wrapper、索引生成器、consistency checker。status 只读 Git/GitHub metadata、声明 clone 的 `.git`、索引 identity/head、治理 registry、私有 v3 baseline。Git/GitHub 是权威；PUBLIC Markdown 仅兼容，不是 owner baseline。

## 核心机制
先将 `RepoRoot/.git` 的 origin identity、HEAD 与 expected `wlyaaaaa/github-local-index`（或测试/迁移绑定）比较。通过前不读 baseline/registry/`gh`/local root；缺失/mismatch 返回 `completed/blocked`、`zero_write=true`、调用 0。通过后读远端事实并核验 root `.git`。普通 status 不运行 `git status/fetch`、不建 temp/receipt、不写入。

ignored 私有 `github-local-index.owner-baseline-store.v3` 分存 identity（repo、visibility、default branch）与可空 local root；原子保存 current/previous、root snapshot、规范 hash、receipt，读取验证 schema/集合/hash/readback。

唯一写入口 `-MigrateBaseline` 只查 live metadata、核验 v2 navigation `.git` origin；不 fetch/扫正文/重建公开索引。无 prior baseline 时写 `history_gap=true` bootstrap receipt 并保持 attention/unknown；禁止 live 自比、PUBLIC 子集、自动化记忆伪造历史，delta review 至下次稳定比较。Fast compatibility mode 可写 private log；CheckOnly 用 system temp；完整 refresh 重建 tracked Markdown，clone fetch 最多尝试三次，commit-pinned snapshot 只刷 metadata；discovery 排除外部治理路径。

## 输出合同
`github-local-index.owner-status.v1`：`execution_status=completed|error`、`domain_status=current|review_needed|blocked|unknown`、`zero_write=true`、`fetch_performed=false`；其余限摘要、issue/attention、scope、registry、provenance、history、fingerprint，root delta 仅计数。fingerprint 排除时间/顺序/index HEAD/dirty/ahead/behind/任务状态/错误正文。`completed` 退出 0；`gh` 不可启动、remote 非零、JSON 无效为 `error/unknown`、退出 2。migration 仅返计数/hash/bootstrap/history，不回显 identity/路径。hidden CheckOnly 原子写 private `github-local-index.consistency-receipt.v1`（`task_key=github_local_index_consistency`）；不自动 stage/commit/push 或授权发布。

## 失败与降级
v3 baseline 缺失/无效/首次 history gap → `completed/unknown`，不回退 PUBLIC Markdown；事实/registry/index identity 缺失或 mismatch → `completed/blocked`。unknown 非一致；current 仅表示完整 current/previous owner facts 与 live observation 一致。三次 fetch 失败保留 `fetch_failed`；刷新/比较失败写 `outcome=error`；均不证明 publication。

## 验证证据
`Test-GitOwnerStatus.ps1` 验 identity gate/zero-write/expected repo/remote failure/fingerprint/status/外部治理；`Run-UnitTests.ps1` 验 generator/temp/receipt。

## 上下文策略
跨 owner 先读 compact status；仅为解释 delta/issue 或重建读详情。日常项目任务不需要这些入口。

## 已知限制
provider 不扫未声明 root、不返 branch/worktree/sync/task；新 root 由 refresh 发现。Fast/CheckOnly 非 `zero_write`；Hook/refresh/current 不证明 publication。

持久事实：Git/GitHub、JSON registry、generation manifest。generation 经同卷 `.incoming` 回读后原子改名，仅留 current+previous；projection id mismatch 即 stale。`refs/codex/turn-diffs/checkpoints`、unreachable objects 无 owner 证明不得 `gc`/`prune`/清理。不引入数据库；cache 可删除/重建且非权威。

## 扩展入口
新增模式须声明 tracked/private/temporary/external 与 process exit 效果；须 execution/domain 分离且 compact status 不足。
