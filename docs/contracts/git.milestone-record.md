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

## 失败与降级
输入不安全、文件锁或写入失败时保持原文件不变；stage、commit、pull、rebase、push 由外层处理。

## 验证证据
`tests/Test-PushRecord.ps1` 验证 pure-file、idempotent、并发去重、拒绝不安全理由和 no Git transaction。

## 上下文策略
普通任务不加载历史表；只有明确里程碑时调用 helper 并检查单次结果。

## 已知限制
no runtime provider/schema is a deliberate design result；该合同描述写入机制，不提供当前记录快照。

## 扩展入口
只有记录格式或幂等键出现长期需求变化时，才在 owner 测试保护下演进 helper。
