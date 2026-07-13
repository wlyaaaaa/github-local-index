# GitHub 总索引

这是本机 GitHub 仓库的公开索引、同步诊断和发布边界仓库，远端为 `wlyaaaaa/github-local-index`。它提供可查询事实和维护工具，但不要求每个 Git 任务执行固定命令链。

完整的人类说明见 [我的 GitHub 项目管理指南](./我的%20GitHub%20项目管理指南.md)。

## Owner 定位

| Owner | 负责内容 | 何时关注 |
|---|---|---|
| `E:\.agents` | Agent 行为、skills/plugins、能力路由 | 工作方式或能力选择相关 |
| `E:\GitHub总索引` | 仓库身份、远端、可见性、同步诊断、公开发布边界 | Git 事实或发布风险相关 |
| `E:\PCConfig` | 路径迁移、任务、端口、运行时、本机数据、恢复 | 当前决策依赖机器事实 |
| 具体项目 | 业务语义、源码、项目规则、测试和部署 | 项目实现相关 |

模型根据目标、不确定性、风险与信息成本选择相关 owner。一个 Windows 路径只是上下文时，不需要因此加载 PCConfig；普通项目改动也不需要为了形式同步三个控制面。

## 核心能力

- `01_仓库索引/`：公开安全的 GitHub 仓库与本地 clone 索引。
- `02_同步诊断/`：分支、远端、ahead/behind、worktree 和脏状态快照。
- `03_推送决策/`：真正有长期价值的公开里程碑记录，不是每次 push 的流水账。
- `04_计划任务/`：可公开的自动化健康摘要，不拥有完整任务配置。
- `05_规则与模板/`：公开发布与脱敏规则。
- `tools/Get-ProjectAdmission.ps1 -Repo <owner/name> -Json`：按需取得当前仓库身份、worktree、同步与 transport 的结构化证据，schema 保持 `github-local-index.project-admission.v1`。

admission provider 在身份、同步、worktree、visibility 或推送条件不清楚时很有价值；已有新鲜可靠证据时可以跳过。其 transport 结论不是写入授权，更不是公开发布授权；`decision=block` 仍允许只读调查原因。

## 公开与私有边界

本仓库自身是 `PUBLIC`，只能保存公开安全的索引、规则、摘要和脱敏结论。真实密钥、私钥、token、完整配置、原始日志/数据库/聊天/健康资料、私密截图和机器快照不得进入本仓库。

确认仍为 `PRIVATE` 的备份、恢复或个人知识库目标可按任务需要保留精确凭据内容；`wlyaaaaa/Key` 是例外，只记录远端状态，禁止本机 clone 或展开。

Git transport readiness 与内容 publication 是两个不同判断。完整且唯一的发布矩阵见 [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)。

## 目录入口

- [GitHub 总览](00_总览/GitHub总览.md)
- [当前同步看板](00_总览/当前同步看板.md)
- [GitHub 仓库索引](01_仓库索引/GitHub仓库索引.md)
- [分支与远端诊断](02_同步诊断/分支与远端诊断.md)
- [未推送队列](02_同步诊断/未推送队列.md)
- [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)
- [owner-local Git 合同](docs/contracts/)

## 维护工具

- `tools/Get-ProjectAdmission.ps1`：单仓库结构化事实；`-Fetch` 请求 live 远端证据。
- `tools/Update-GitHubIndex.ps1 -SkipFetch -NoWrite`：只读预览索引生成结果。
- `tools/Update-GitHubIndex.ps1`：在确需更新公开快照时重建相关 Markdown。
- `tools/Test-GitHubLocalIndexConsistency.ps1 -SkipFetch`：诊断生成快照与当前索引的漂移。
- `tools/Install-GitHook.ps1`：首次安装或修复本仓库的防泄漏 Hook，不是每任务步骤。
- `tools/Add-PushRecord.ps1`：幂等写入明确里程碑；不执行 Git transaction。
- `tests/Run-UnitTests.ps1`、`tests/Test-ProjectAdmission.ps1`、`tests/Test-ControlPlaneContracts.ps1`：验证工具行为与稳定合同。

兼容工具可以继续被已有自动化调用，但兼容存在不等于推荐日常调用。只有仓库身份、路径、可见性、生成口径、公开门禁或明确里程碑等 owner 事实变化时才更新本索引；普通业务提交留在目标项目。
