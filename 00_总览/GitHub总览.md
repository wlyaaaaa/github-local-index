# GitHub 总览

更新时间：2026-07-08

本机 GitHub 工作区当前按三类管理：

| 类型 | 策略 |
|---|---|
| 公开索引 | 本仓库，保存可公开的索引、诊断、规则和历史审计摘要 |
| 私有备份仓库 | 允许保存密钥、配置快照、恢复材料，优先满足云备份和新机恢复需求 |
| 公开业务仓库 | 只提交可公开代码、文档、清洗后的结果和不含敏感值的配置 |

## 当前关键结论

- 当前 `wlyaaaaa` 账号共有 27 个仓库：原审计 24 个，加上公开总索引仓库 `github-local-index`、新增公开仓库 `TURZX-SideScreen` 和新增私有仓库 `ai-coach`。
- `E:\GitHub总索引` 是长期总索引目录，不是临时报告目录。
- `wlyaaaaa/ai-coach` 本地位于 `G:\20_Projects\github\ai-coach`，`main` 与 `origin/main` 已同步；作为学习记录/复盘/审计仓库，不建议新增后台计划任务。
- `wlyaaaaa/codex-app-power-user-playbook` 本地位于 `E:\.agents-public-release`，`master` 与 `origin/master` 已同步，当前无需推送。
- `wlyaaaaa/TURZX-SideScreen` 本地位于 `E:\Projects\Tools\TURZX-SideScreen`，`main` 与 `origin/main` 已同步，当前无需推送。
- `wlyaaaaa/openclaw-backup` 为私有备份仓库，已按用户需求允许推送密钥/配置快照。
- `wlyaaaaa/ai-llm-job-prep` 为私有知识库仓库，参考资料和课程产物按私有备份策略处理。
- 公开仓库仍执行脱敏和暴露面审查。

## 当前审核队列

| 优先级 | 仓库 | 当前判断 |
|---|---|---|
| 完成 | `OpenClawGateway` | 完整运维交接已转入私有备份仓库，公开版脱敏后已推送 |
| 完成 | `rtx5090d-ollama-agent-bundle` | 已生成 public benchmark summary，原始 evidence 已忽略 |
| 完成 | `md-triple-tactics-talent-solver` | 已整理 3.0 canonical 产物并推送 |
| 完成 | `TimeAudit` | 已补运行态说明和 `tmp/` 忽略规则，配置文件本机标记 skip-worktree |
| 完成 | `codex-app-power-user-playbook` | 已确认本地 clone 干净，远端同步，无需推送 |
| 完成 | `TURZX-SideScreen` | 已确认新增远端仓库对应本地 clone，远端同步，无需推送 |
| 完成 | `ai-coach` | 已确认新增私有仓库对应本地 clone，远端同步，不建议新增计划任务 |

## 历史审计

- [2026-07-05 GitHub 仓库与计划任务审计](../90_历史审计/2026/2026-07-05-GitHub仓库与计划任务审计.md)
