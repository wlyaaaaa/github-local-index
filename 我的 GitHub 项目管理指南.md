# 我的 GitHub 项目管理指南

> 面向用户｜非执行规则、非动态事实权威、非 AI 默认上下文｜更新：2026-08-22（中国时间 UTC+8）
>
> AI 仅在用户明确要求解释、入门、维护本文档，或具名验收确实需要时按需读取。执行时以 `AGENTS.md`、owner-local 合同、当前 Git/GitHub 证据和实际候选差异为准。

GitHub 总索引把本机分散的 Git 仓库整理成一个公开安全的查询入口：项目在哪里、远端和可见性是什么、分支/worktree 是否同步，以及准备发布时有哪些真实风险。它提供能力和证据，不是每个项目任务必须逐站通过的流水线。

## 1. 三个控制面和具体项目

| 负责方 | 负责内容 |
|---|---|
| `E:\.agents` | Agent 行为、skills/plugins 和能力路由 |
| `E:\GitHub总索引` | 仓库身份、远端、可见性、同步诊断和公开发布边界 |
| `E:\PCConfig` | 路径迁移、计划任务、端口、运行时、本机数据和恢复 |
| 具体项目 | 业务语义、源码、项目规则、测试和部署 |

它们按问题组合，不是线性审批链。例如，日志里出现 `E:\Projects\...` 不代表一定要读取 PCConfig；只有当前决定依赖路径是否迁移、任务 Action、端口占用或恢复方式时，机器事实才相关。

### 新仓库放在哪里

- 现有三个控制面和旧仓库保持原位，不为目录统一批量迁移。
- 新建或新 clone 的个人仓库默认放在 `V:\Personal\Projects\...`。
- 个人临时 worktree 默认放在 `V:\Personal\Worktrees\...`，任务完成并确认没有独有内容后及时退役。
- 新的工作项目使用 `V:\Work\...`，同时服从具体项目、设备和合规边界。
- `V:\Dev` 只保留已经存在的 worktree，不手工搬动，也不继续创建新仓库。
- `Z:` 是可丢缓存层，不放 Git 仓库、worktree 或唯一副本。

总索引只登记实际存在的仓库，不为空目录或假想未来项目预建记录。

## 2. 总索引解决什么问题

项目多以后，容易出现这些错误：

- 把旧路径或旧 remote 当成现状；
- 混淆同名仓库或不同 worktree；
- 把 PRIVATE 误判成 PUBLIC，或反过来；
- 只看当前分支，漏掉其它 worktree 和独有提交；
- 把“Git 可以 push”误解为“内容可以公开”。

总索引提供三类帮助：

1. 公开索引和同步看板，方便人发现值得关注的仓库；
2. 结构化 admission provider，在需要时取得单仓库新鲜事实；
3. 公开发布规则，检查候选内容能否进入公开目标。

它不拥有项目代码，不替代项目测试，也不要求普通 commit 生成控制面记录。

## 3. 什么时候使用 Admission

以下情况通常值得查询：

- 本地目录、remote 或 GitHub identity 可能混淆；
- 要根据当前 branch、worktree、ahead/behind 选择安全操作；
- visibility 或 push 目标不明确；
- 旧索引与当前 `.git` 证据冲突；
- 删除 branch/worktree 前需要确认是否有独有内容。

```powershell
pwsh -NoProfile -File E:\GitHub总索引\tools\Get-ProjectAdmission.ps1 `
  -Repo wlyaaaaa/github-local-index -LiveMetadata -Json
```

已有新鲜、可靠的 `.git`、remote、visibility 和候选差异证据时，可以直接使用，不为流程完整重复调用 provider。

结果要这样理解：

- `decision=block`：当前证据不足以支持依赖这些事实的写入或 transport；只读调查仍可继续。
- `push_decision` / `push_strategy`：只描述 Git transport readiness。
- admission 不提供 publication 授权，也不判断实际候选内容是否适合公开。
- `unknown` 是删除前的临时保护，不应长期保留为“以后再看”。

## 4. Push 与公开发布是两件事

remote 可达、工作区干净、分支 ahead，只能证明 Git transport 条件。向 `PUBLIC` 目标发布前还要确认：

- visibility 是当前现场值，不是旧记忆；
- 实际候选 commits、paths 和 content 已审查；
- 没有凭据、隐私、原始日志、数据库、聊天、健康资料、私密截图、机器快照、完整任务 XML 或可直接滥用的运维细节；
- 项目规则和本次用户授权允许发布。

确认仍为 `PRIVATE` 的备份、恢复或配置仓库可以保留任务需要的精确内容。PRIVATE 目标可信，不代表自动获得外部写入授权，也不代表可以把秘密复制到公开索引或聊天。

`wlyaaaaa/Key` 是受管私有密文仓库：checkout 只保留密文和公开安全说明；解密明文、口令和 keyfile 不得写入仓库。

完整矩阵只维护在 [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)，避免多份文档复制后漂移。

## 5. 目录和入口

| 路径 | 作用 |
|---|---|
| `00_总览/` | 人类总览和同步看板 |
| `01_仓库索引/` | PUBLIC 仓库摘要；不替代当前 Git 事实 |
| `02_同步诊断/` | branch、remote、worktree 和同步候选问题 |
| `03_推送决策/` | 有长期价值的公开里程碑，不是每次 push 的日志 |
| `04_计划任务/` | 只提供 PCConfig owner 路由，不复制任务运行态 |
| `05_规则与模板/` | 发布和脱敏规则 |
| `docs/contracts/` | owner-local 稳定机制卡，按需读取 |
| `99_private/` | ignored 本机导航 cache，禁止进入公开 Git |

生成 Markdown 适合人类浏览；结构化 provider 和当前 Git 命令适合机器判断。完整 refresh 使用原子 generation，只保留 current+previous；具体实现由合同和测试负责，不需要用户日常维护。

## 6. 什么时候刷新或维护

需要更新总索引的典型变化：

- 仓库新增、删除、改名，remote 或 visibility 改变；
- clone 路径迁移、默认分支或长期同步策略改变；
- worktree/admission 的稳定语义改变；
- 公开门禁升级或需要记录重要里程碑；
- 用户明确要求重建公开快照。

主要工具：

```powershell
# 预览，不写入
pwsh -NoProfile -File E:\GitHub总索引\tools\Update-GitHubIndex.ps1 -SkipFetch -NoWrite

# 确有需要时重建公开快照
pwsh -NoProfile -File E:\GitHub总索引\tools\Update-GitHubIndex.ps1

# 检查投影漂移
pwsh -NoProfile -File E:\GitHub总索引\tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch
```

通常不需要更新：普通功能、bugfix、文档 commit、只有项目业务内容改变，或已有新鲜证据却只想重复跑工具。Hook 和 Fast refresh 是防护或兼容入口，不是每次任务的固定收尾步骤。

## 7. 常见问题

### 有 provider 就要每次调用吗？

不需要。只有当前不确定性会改变决策时，它才有价值。

### Admission block 后什么都不能做吗？

不是。它阻止依赖不充分 Git 证据的写入和 transport；只读调查正是定位 block 原因的方法。

### Transport proceed 就能公开吗？

不能。公开发布还要审查当前 visibility、实际候选内容和授权。

### PRIVATE 仓库出现秘密就必须脱敏吗？

不一定。确认目标仍为 PRIVATE 且任务确实是备份或恢复时，精确保真可能是产品要求；但不得把内容复制到公开索引或聊天。

### 每次 push 都要写总索引记录吗？

不需要。只有 owner 事实变化或明确里程碑才值得记录。

## 8. 保持简单

总索引最有价值的不是更长的流程，而是少量可靠能力：需要时迅速取得 Git 事实，公开前守住真实内容边界，其余判断由项目和当前证据完成。

新规则、文档、快照或兼容层必须有当前 consumer 和可验证收益。完成的计划、复盘和旧流水由 Git 留史，不在活动树重复归档。
