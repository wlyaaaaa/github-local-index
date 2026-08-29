# git.milestone-record

## 产品目标
只在真实 Git 事实里程碑时写公开安全记录，避免普通 push 触发控制面连锁提交。

## 触发条件
triggers: `milestone|push_record`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
外层 closeout 提供已确认的仓库、分支、提交标识和公开安全理由。

## 核心机制
`tools/Add-PushRecord.ps1` write helper is pure-file and idempotent，以稳定键去重并拒绝 secret-shaped reason。

## 输出合同
helper 只更新目标记录文件并返回 changed 结果；它 is not zero-write and performs no Git transaction。

`tools/Get-GitOwnerStatus.ps1 -Json` 的既有 owner provider 只读输出嵌套字段
`milestone_records`，其 schema 为 `github-local-index.milestone-records.v1`；最多返回
记录文件中现存的 50 条公开安全记录。空表是合法 current 结果，不制造事件。

## 失败与降级
输入不安全、文件锁或写入失败时保持原文件不变；stage、commit、pull、rebase、push 由外层处理。

## 验证证据
`tests/Test-PushRecord.ps1` 验证 pure-file、idempotent、并发去重、拒绝不安全理由和 no Git transaction；
`tests/Test-GitOwnerStatus.ps1` 验证只读解析、稳定语义摘要、空表、50 条上界及公开安全失败关闭。

## 上下文策略
普通任务不加载历史表；只有明确里程碑时调用 helper 并检查单次结果。知识库等消费者需要
长期结果增量时，调用既有 owner provider 并只读取有界 `milestone_records`，不遍历 Git 历史。

## 已知限制
`bootstrap_gap=true` 与 `retained_window_only=true` 是永久诚实边界：provider 只提供当前保留窗口，
Git 历史中的更早记录不属于运行时来源，也不会被伪装为完整历史。

## 扩展入口
只有记录格式或幂等键出现长期需求变化时，才在 owner 测试保护下演进 helper。
