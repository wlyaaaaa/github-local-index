# git.worktree-sync

## 产品目标
让同步判断覆盖共享 common-dir 下的全部 worktree，而不是只观察当前目录。

## 触发条件
triggers: `worktree|dirty|sync|ahead_behind`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
权威输入是 admission provider 对 Git worktree、status 和 upstream 关系的当前检查。

## 核心机制
all worktrees contribute to dirty、sync and ahead/behind judgment；结果按稳定路径排序并汇总。

## 输出合同
每个 worktree 暴露 dirty summary、sync state、upstream 限制以及 locked/prunable 可见标记。

## 失败与降级
任一可达 worktree inspection failure fails closed；locked/prunable limits remain visible，不被折叠成正常。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 以 primary、linked、detached、locked/prunable 和检查失败场景验证行为。

## 上下文策略
卡片只描述聚合口径；动态路径、计数和同步值在任务当下从 provider 读取。

## 已知限制
无法检查的 worktree 不推断为 clean；没有 upstream 的分支不能获得直接 transport 放行。

## 扩展入口
新增 Git worktree 状态时先扩展 owner 测试，再评估是否需要兼容 schema 演进。
