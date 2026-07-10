# GitHub 总索引

这是本机 GitHub 仓库的总索引、同步诊断和推送决策台账。它不是临时报告目录，而是长期维护的公开索引仓库。

公开远端：`wlyaaaaa/github-local-index`

完整的人类说明见 [我的 GitHub 项目管理指南](./我的%20GitHub%20项目管理指南.md)：它详细解释索引怎样工作、为什么这样分层、项目怎样进入和收尾，以及公开/私有仓库的安全边界。AI 做普通项目任务时按需使用，不必每次加载全文。

## 定位

- 记录 GitHub 仓库、本地 clone、分支、ahead/behind、脏工作区和计划任务健康状态。
- 保存可公开的审计摘要、推送决策、否决原因和后续处理队列。
- 不保存私钥值、token 值、完整 `.env`、OAuth JSON、原始密钥文件或未脱敏日志。
- 私有 GitHub 仓库按用户需求视为可信云备份位置，可用于备份密钥、配置快照和恢复材料；本公开索引只记录结论，不复制密钥内容。

## Git 项目事实入口

以后修改任意 Git 项目时，Agent 控制先走 `E:\.agents\skills\project-entry-gate`，再查询本仓库作为 Git 项目事实入口和公开发布门禁：

1. 优先运行 `tools\Get-ProjectAdmission.ps1 -Repo <owner/name> -Json`，获得带 schema、UTC 观察时间、`cached|live` 证据模式、所有 worktree 的 `dirty_summary` / `sync_state`、只读 `decision` 和直接推送 `push_decision` / `push_strategy` 的单仓库事实；Markdown 索引用于总览和人工阅读。
2. 如果改动涉及绝对路径、计划任务、本机数据源、跨盘迁移、备份/恢复、本地工具链、启动脚本、快捷方式或共享目录，同时查询 `E:\PCConfig`。
3. 进入具体项目后，再读取该项目自己的 `AGENTS.md`、README、脚本和测试命令。
4. 改完项目后，按默认联动提交/推送目标仓库；如果项目路径、机器依赖或恢复信息变化，再更新 `E:\PCConfig` 和本索引。

本仓库是 Git 项目事实入口和公开门禁；`E:\.agents` 是 Agent 控制入口；`E:\PCConfig` 是机器配置中心；具体项目保留自己的业务规则。

## 目录

| 路径 | 用途 |
|---|---|
| `00_总览/` | 当前全局看板和同步总览 |
| `01_仓库索引/` | GitHub 仓库、本地 clone、未发现 clone 的索引 |
| `02_同步诊断/` | 未推送、脏工作区、分支与远端诊断 |
| `03_推送决策/` | 已推送、否决推送、需人工确认的记录 |
| `04_计划任务/` | Windows 计划任务健康摘要和异常清单 |
| `05_规则与模板/` | 公开发布、推送放行/否决、审计报告模板 |
| `90_历史审计/` | 已完成的历史审计报告 |
| `99_private/` | 本地私有原始材料，已被 `.gitignore` 排除 |

## 当前入口

- [GitHub 总览](00_总览/GitHub总览.md)
- [当前同步看板](00_总览/当前同步看板.md)
- [GitHub 仓库索引](01_仓库索引/GitHub仓库索引.md)
- [分支与远端诊断](02_同步诊断/分支与远端诊断.md)
- [未推送队列](02_同步诊断/未推送队列.md)
- [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)
- [2026-07-05 历史审计](90_历史审计/2026/2026-07-05-GitHub仓库与计划任务审计.md)

## 自动刷新入口

- `.\tools\Get-ProjectAdmission.ps1 -Repo wlyaaaaa/github-local-index -Json`：使用 cached refs 的只读 admission；加 `-Fetch` 后只有 fetch 与 GitHub metadata 都成功才标记为 `live`。`decision` 保留项目进入语义，`push_decision` / `push_strategy` 表达直接推送门禁；behind/diverged 只阻止直接推送，不阻止只读进入。
- `.\tools\Update-GitHubIndex.ps1 -SkipFetch -NoWrite`：只读干跑，检查 GitHub 远端仓库、本地 clone、ahead/behind 和脏工作区映射。
- `.\tools\Update-GitHubIndex.ps1`：刷新 `00_总览/`、`01_仓库索引/`、`02_同步诊断/` 下的公开 Markdown 摘要。
- `.\tools\Update-ScheduledTaskHealth.ps1`：刷新 `04_计划任务/` 下的计划任务健康摘要和异常清单。
- `.\tools\Update-UserAutomationMap.ps1`：刷新 `04_计划任务/用户自动化任务地图.md` 和 `04_计划任务/仓库计划任务建议.md`，记录用户自动化任务用途推测和仓库计划任务缺口。
- `.\tools\Refresh-GitHubLocalIndex.ps1 -Fast -Repo wlyaaaaa/github-local-index -Json`：单仓库快路径，返回同一 admission schema；不重建公开 Markdown，不枚举计划任务。
- `.\tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch`：只读一致性检查，临时生成摘要后对比 tracked Markdown；默认只把 GitHub/同步诊断类稳定文档漂移视为失败，计划任务文档漂移作为易变警告。加 `-Strict` 可做全量强一致检查。
- `.\tools\Refresh-GitHubLocalIndex.ps1 -CheckOnly`：通过现有刷新包装器执行只读一致性检查，不写公开 Markdown。
- `.\tools\Register-GitHubLocalIndexRefreshTask.ps1 -CheckOnly -Json`：只输出 `GitHubLocalIndex Consistency Check` 的 read-only Action 定义，不注册或修改 live task。只有 root 在保存 legacy pre-image 并取得明确授权后才运行 `-Apply`。
- `.\tools\Add-PushRecord.ps1 -Repo <owner/name> -Branch <branch> -Commit <hash> -Reason <summary> -Json`：纯文件、幂等的里程碑记录；不会 stage、commit、pull、rebase 或 push。
- `pwsh .\tests\Run-UnitTests.ps1`、`pwsh .\tests\Test-ProjectAdmission.ps1`、`pwsh .\tests\Test-PushRecord.ps1`：运行行为、worktree/admission 和并发 push-record 测试。

## 收尾联动

项目收尾先读取 admission JSON，再由目标项目自己的流程决定提交和推送。本索引不因每次普通任务或普通 push 自动产生 commit：只有仓库身份/路径/可见性、公开门禁、worktree 状态口径或明确里程碑发生变化时，才运行生成器或 `Add-PushRecord.ps1`，Git 事务始终由外层 closeout 显式执行。用户要求“只本地”“不提交”或“不推送”时，本仓库同样保持本地且不触碰 remote。
