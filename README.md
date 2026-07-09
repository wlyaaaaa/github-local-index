# GitHub 总索引

这是本机 GitHub 仓库的总索引、同步诊断和推送决策台账。它不是临时报告目录，而是长期维护的公开索引仓库。

公开远端：`wlyaaaaa/github-local-index`

## 定位

- 记录 GitHub 仓库、本地 clone、分支、ahead/behind、脏工作区和计划任务健康状态。
- 保存可公开的审计摘要、推送决策、否决原因和后续处理队列。
- 不保存私钥值、token 值、完整 `.env`、OAuth JSON、原始密钥文件或未脱敏日志。
- 私有 GitHub 仓库按用户需求视为可信云备份位置，可用于备份密钥、配置快照和恢复材料；本公开索引只记录结论，不复制密钥内容。

## 项目改动入口

以后修改任意 Git 项目时，先从本仓库进入：

1. 在 `01_仓库索引/` 和 `02_同步诊断/` 确认项目本地路径、远端、可见性、分支/同步状态、脏状态和推送策略。
2. 如果改动涉及绝对路径、计划任务、本机数据源、跨盘迁移、备份/恢复、本地工具链、启动脚本、快捷方式或共享目录，同时查询 `E:\PCConfig`。
3. 进入具体项目后，再读取该项目自己的 `AGENTS.md`、README、脚本和测试命令。
4. 改完项目后，按默认联动提交/推送目标仓库；如果项目路径、机器依赖或恢复信息变化，再更新 `E:\PCConfig` 和本索引。

本仓库是项目入口和公开门禁；`E:\PCConfig` 是机器配置中心；具体项目保留自己的业务规则。

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
- [本机配置状态](02_同步诊断/本机配置状态.md)
- [H 盘 U 盘收尾状态](02_同步诊断/H盘U盘收尾状态.md)
- [用户自动化任务治理建议](04_计划任务/用户自动化任务治理建议.md)
- [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)
- [2026-07-05 历史审计](90_历史审计/2026/2026-07-05-GitHub仓库与计划任务审计.md)

## 自动刷新入口

- `.\tools\Update-GitHubIndex.ps1 -SkipFetch -NoWrite`：只读干跑，检查 GitHub 远端仓库、本地 clone、ahead/behind 和脏工作区映射。
- `.\tools\Update-GitHubIndex.ps1`：刷新 `00_总览/`、`01_仓库索引/`、`02_同步诊断/` 下的公开 Markdown 摘要。
- `.\tools\Update-ScheduledTaskHealth.ps1`：刷新 `04_计划任务/` 下的计划任务健康摘要和异常清单。
- `.\tools\Update-UserAutomationMap.ps1`：刷新 `04_计划任务/用户自动化任务地图.md` 和 `04_计划任务/仓库计划任务建议.md`，记录用户自动化任务用途推测和仓库计划任务缺口。
- `.\tools\Refresh-GitHubLocalIndex.ps1 -Fast -Repo wlyaaaaa/github-local-index`：单仓库快路径，只解析现有 clone 索引并输出目标仓库分支、upstream、ahead/behind 和脏状态；用于项目收尾，不重建公开 Markdown，不枚举计划任务。
- `.\tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch`：只读一致性检查，临时生成摘要后对比 tracked Markdown；默认只把 GitHub/同步诊断类稳定文档漂移视为失败，计划任务文档漂移作为易变警告。加 `-Strict` 可做全量强一致检查。
- `.\tools\Refresh-GitHubLocalIndex.ps1 -CheckOnly`：通过现有刷新包装器执行只读一致性检查，不写公开 Markdown。
- `.\tools\Register-GitHubLocalIndexRefreshTask.ps1 -CheckOnly`：注册 `GitHubLocalIndex Consistency Check` 计划任务，只定期检查一致性，不自动提交或推送；计划任务入口使用 `wscript.exe` 调用 `tools\Refresh-GitHubLocalIndex-Hidden.vbs`，避免 PowerShell 窗口闪现并保留退出码。
- `pwsh .\tests\Run-UnitTests.ps1`：运行轻量 PowerShell 7 自测，覆盖刷新脚本 fast path 契约。

## Codex 默认联动

今后 Codex 只要实际修改了任意 Git 工作区，默认流程是：验证目标仓库、显式 stage、提交并推送目标仓库，然后回到本仓库记录本轮同步结论，再提交并推送 `wlyaaaaa/github-local-index`。用户明确说“只本地”“不提交”或“不推送”时，按用户本轮要求优先。
