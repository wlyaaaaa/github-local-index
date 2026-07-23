# GitHub 总索引规则

本仓库是公开的 `wlyaaaaa/github-local-index`，拥有 Git/GitHub 仓库身份、远端、可见性、同步诊断和公开发布边界。默认用简体中文；动态事实以任务当下证据为准。

## 硬边界

- 本仓库只能提交公开安全的索引、规则、摘要和脱敏结论；不得提交密钥值、token、私钥、完整 `.env`、OAuth JSON、原始日志/数据库/聊天/健康资料、私密截图、完整任务 XML 或未缩减机器快照。
- `99_private/` 是被 `.gitignore` 排除的本机原始材料区；其中内容不得进入本公开仓库。
- 公开目标在提交或推送前必须结合新鲜 visibility、候选 commits、paths 与 content 判断暴露面；Git transport 可用不等于内容可公开。
- 仓库身份、remote、目标分支、visibility 或候选内容存在实质冲突时，停止写入或发布并取得更可靠证据；只读调查仍可继续。
- 对已确认 `PRIVATE` 的备份、恢复、个人知识库或配置快照目标，按任务需要保留精确内容，不因包含凭据就自动遮盖或破坏可恢复性；外部写入仍服从活动授权。
- `wlyaaaaa/Key` 允许 clone 到受管私有路径，仅维护密文和公开安全说明；禁止把解密明文、口令或密钥文件写入 clone，仍不创建计划任务。

完整放行与否决矩阵只维护在 [`05_规则与模板/推送放行与否决规则.md`](./05_规则与模板/推送放行与否决规则.md)，其他文档只摘要和引用。

## Owner 分工与按需取证

- `E:\.agents` 拥有 Agent 行为、skills/plugins 与能力路由；本仓库不复制第二套行为规则。
- `E:\PCConfig` 只在当前决策确实依赖路径迁移、计划任务、端口、运行时、本机数据、备份或恢复事实时参与；出现一个绝对路径字面量本身不构成触发。
- 具体项目拥有业务语义、源码、项目规则、测试和部署方式；本仓库不替代项目内证据。
- 现有仓库路径继续作为事实保留。以后新建或新 clone 的个人 Git 仓库默认根是 `V:\Personal\Projects`，个人临时 worktree 默认根是 `V:\Personal\Worktrees`；未来工作仓库使用 `V:\Work\...`。`V:\Dev` 是已有 worktree 的兼容位置，不再新增。只有仓库实际创建、clone 或迁移后才写入索引，不预登记空目录；具体项目兼容性和公司合规要求可覆盖默认位置。
- `tools/Get-ProjectAdmission.ps1 -Json` 是可选的结构化证据能力。仓库身份、worktree、同步、visibility 或直接 transport 状态不清楚，或调用的信息价值高于成本时使用；事实已由新鲜可靠证据明确时不为流程打卡重复调用。
- admission V1 的 `decision`、`push_decision` 与 `push_strategy` 只描述 provider 观察到的进入/transport 条件，不授予写入或公开发布权限。`decision=block` 应阻止基于不充分证据的写入和直接 transport，但不得阻止继续只读诊断。
- owner-local 合同位于 [`docs/contracts/`](./docs/contracts/)；仅在机制、兼容性、故障或控制面演进需要时读取。

## 维护原则

- 模型按目标、风险、证据新鲜度和成本选择 provider、Git 命令、索引快照或项目证据；工具存在不构成固定调用链。
- `tools/Install-GitHook.ps1` 仅用于首次 bootstrap、缺失或损坏后的 repair。Hook 是 defense in depth，不能替代候选内容复审，也不在每个任务重复安装。
- Fast refresh 保留为兼容维护入口，不作为普通任务收尾；完整 refresh 仅在索引事实、生成口径或用户明确要求更新快照时使用。
- `tools/Add-PushRecord.ps1` 仅在用户要求或确有公开里程碑价值时使用；普通 commit/push 不生成索引流水账。
- 只显式 stage 本次目标文件，保护用户已有改动；不使用 `git add .` 吞入混合产物。
- 计划任务在这里只保留公开安全摘要；实时状态归 Task Scheduler，机器配置与恢复归 PCConfig，业务语义归所属项目。
- 规则在最相关位置原地重写并去重；本文件保持短小，专项机制放对应合同或工具文档。
