# git.worktree-sync

## 产品目标
让同步判断覆盖共享 common-dir 下的全部 worktree 和本地 branch ref，并保证已完成工作能够从仓库实际默认分支到达。

## 触发条件
triggers: `worktree|dirty|sync|ahead_behind`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
权威输入是 admission provider 对 Git worktree、status、upstream 和 default branch reachability 的当前检查。

## 核心机制
默认兼容模式下 all worktrees contribute to dirty、sync and ahead/behind judgment；指定 target worktree/ref 时，全部 worktree 仍作为 evidence 返回，只有精确目标参与顶层 transport 判断。provider 另比较每个非默认分支 HEAD 与实际远端默认分支，区分 `default|merged_ancestry|patch_equivalent|unmerged|unknown`，并枚举没有 worktree 的本地与 `origin/*` remote-tracking branch ref。已推送到自身 upstream 但默认分支缺提交仍是行动项；clean、已由默认分支吸收且非 locked 的临时分支/worktree只成为 retirement candidate，不自动删除。`config/git-artifact-governance.json` 有两类 exact-match：专门 owner ref 仍返回证据，但不把 PersonalOS artifact 或 PCConfig 合同明确的孤立加密备份流误判为默认分支待整合功能；精确 target 命中时 fail closed。必要保留 worktree 必须同时匹配 repo、绝对路径、40 位 HEAD，并带 owner、用途和退出条件。必要保留只有在路径存在、检查成功、clean 且非 prunable 时才抑制预期的 detached/no-upstream/retirement 行动，任何 HEAD、内容或健康漂移都会重新进入行动队列。若 clean 的历史 audit/reaudit/snapshot/review 路径以当前 HEAD 前缀结尾，且 either `有 upstream + 原始 ahead=0` or `detached + 无 upstream`，则认定为 commit-pinned snapshot：结构化保留数量与远端距离证据，但不把 pinned behind/no-upstream 汇入行动队列。dirty、非零 ahead、普通无 upstream 分支、路径/HEAD 不匹配、upstream 距离缺失或 detached 携带矛盾的非零距离时绝不抑制；文档只把它归入“无行动项”，不声称“已同步”。

## 输出合同
每个 worktree 暴露 dirty summary、sync state、默认分支整合状态、独有/缺失提交数、upstream 限制、locked/prunable 标记，以及命中时的必要保留 owner、用途和退出条件；顶层同时回显规范化 target 和本地 branch inventory。

## 失败与降级
任一可达 worktree inspection failure fails closed；locked/prunable limits remain visible，不被折叠成正常。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 以 primary、linked、detached、已推送但未进默认分支、remote-only branch、单 branch inventory、patch-equivalent、exact retention、locked/prunable 和检查失败场景验证行为；`tests/Run-UnitTests.ps1` 验证 retirement candidate、active dirty、unknown、commit-pinned snapshot 与必要保留的优先级。

## 上下文策略
卡片只描述聚合口径；动态路径、计数和同步值在任务当下从 provider 读取。

## 已知限制
目标 worktree 或默认分支可达性无法检查时不推断为 clean；没有 upstream 的目标分支不能获得直接 transport 放行。`unknown` 只是删除前的瞬时保护，不是个人仓库的稳定终态：closeout 必须继续解析 owner、独有内容、默认分支可达性和 PR/release/交接依赖，收敛为整合、删除或具有明确用途与退出条件的必要保留；无法查清则 BLOCK。retirement candidate 仍需任务 owner 证明无活跃依赖后才能清理。

## 扩展入口
新增 Git worktree 状态时先扩展 owner 测试，再评估是否需要兼容 schema 演进。
