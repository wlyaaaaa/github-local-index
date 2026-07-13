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
Fast 保留为既有调用方的 compatibility mode，避免 tracked Markdown rebuild 但可能写 private log；CheckOnly 使用 system temp 比较并清理；完整 refresh 才重建 tracked Markdown。

## 输出合同
Fast 返回 V1 admission 兼容结果，CheckOnly 返回 drift 诊断，完整刷新返回生成结果；三者都不自动 stage、commit 或 push。

## 失败与降级
刷新或比较失败时保留错误，不把 unknown 解释为一致，也不自动发布生成材料；可直接用当前 owner 证据继续只读诊断。

## 验证证据
`tests/Run-UnitTests.ps1` 验证 compatibility mode、system temp、仓库树写入边界与生成器行为。

## 上下文策略
仅在维护索引一致性时加载生成器和 drift 证据；日常项目任务不需要 Fast、CheckOnly 或完整 refresh。

## 已知限制
Fast 与 CheckOnly 都不是 `zero_write`：前者可能写 private log，后者创建并清理 system temp；Hook 或 refresh 也不是 publication 证明。

## 扩展入口
新增模式需声明 tracked、private、temporary 与 external 写入效果，并证明其信息价值不能由现有能力覆盖。
