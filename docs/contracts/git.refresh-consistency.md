# git.refresh-consistency

## 产品目标
为索引维护提供一致性诊断和快照重建能力，不把 refresh 变成普通 Git 开工或收尾步骤。

## 触发条件
triggers: `refresh|consistency|index_drift`；语义条件是索引 owner 事实、生成口径或公开快照确实可能漂移。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
refresh wrapper、索引生成器与 consistency checker 是维护入口；当前 Git/GitHub 事实高于生成 Markdown 的观察快照。

## 核心机制
Fast 保留为既有调用方的 compatibility mode，避免 tracked Markdown rebuild 但可能写 private log；CheckOnly 使用 system temp 比较并清理；完整 refresh 才重建 tracked Markdown。中央 discovery 持续发现新仓，但在枚举和 Git 命令前排除 PersonalOS 本地路径。

## 输出合同
Fast 返回 V1 admission 兼容结果，CheckOnly 返回 drift 诊断，完整刷新返回生成结果；三者都不自动 stage、commit 或 push。hidden CheckOnly 原子写入忽略目录中的 `github-local-index.consistency-receipt.v1`，含 `task_key=github_local_index_consistency`、`observed_at`、`outcome`、`exit_code` 与 drift files。

## 失败与降级
刷新或比较失败时写 `outcome=error` receipt，不把 unknown 解释为一致，也不自动发布生成材料；缺失或陈旧 receipt 可由 PCConfig runtime health 映射为 missing/stale。

## 验证证据
`tests/Run-UnitTests.ps1` 验证 compatibility mode、system temp、receipt 原子性、外部治理排除、仓库树写入边界与生成器行为。

## 上下文策略
仅在维护索引一致性时加载生成器和 drift 证据；日常项目任务不需要 Fast、CheckOnly 或完整 refresh。

## 已知限制
Fast 与 CheckOnly 都不是 `zero_write`：前者可能写 private log，后者创建并清理 system temp 且 hidden 模式更新 private receipt；Hook 或 refresh 也不是 publication 证明。

## 扩展入口
新增模式需声明 tracked、private、temporary 与 external 写入效果，并证明其信息价值不能由现有能力覆盖。
