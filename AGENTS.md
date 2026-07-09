# AGENTS.md - GitHub 总索引规则

本仓库是 `E:\GitHub总索引` 的公开索引仓库，远端为 `wlyaaaaa/github-local-index`。默认用简体中文协作。

## 核心边界

- 本仓库是公开仓库，只提交可公开的索引、诊断摘要、推送决策和脱敏后的审计报告。
- 不要把私钥值、token 值、完整 `.env`、OAuth JSON、`auth-profiles.json`、数据库、原始日志、截图或未脱敏机器快照提交到本仓库。
- `99_private/` 是本机私有原始材料目录，必须保持在 `.gitignore` 中；可以本地使用，不进公开 Git。
- 公开文档可以写“某私有仓库含密钥备份/某配置存在私钥字段”，但不得复制具体密钥内容。

## 职责与真相源

- 本仓库只拥有 Git/GitHub 项目事实入口、公开索引、远端可见性、分支/同步状态、推送决策和可公开的健康摘要；Agent 控制入口仍是 `E:\.agents`。
- 本仓库可以记录项目入口路径，但路径含义仅用于定位 Git 项目；涉及跨盘迁移、计划任务 Action、启动脚本、快捷方式、端口、模型、本机数据源、备份/恢复时，机器事实以 `E:\PCConfig` 为准。
- 计划任务在本仓库只作为公开健康看板和项目联动摘要；实际运行状态归 Windows Task Scheduler，机器配置和恢复门禁归 `E:\PCConfig`，任务业务语义和注册脚本归具体项目。
- AI 全局行为、skills/plugins、能力路由和跨项目协作规则归 `E:\.agents`；本仓库不得把这些内容复制成第二套规则源。
- 健康、职业、关系、财富等个人领域判断归对应领域项目；本仓库只能记录仓库状态，不保存个人原始数据或决策内容。
- 如果同一事实必须被多处引用，本仓库只写摘要和指向，避免复制可变配置；冲突时按“`.agents` 管 AI 行为，`PCConfig` 管机器事实，具体项目管业务语义，本仓库管 Git 门禁”裁决。

## 私有仓库规则

用户已明确说明：GitHub 私有仓库就是密钥、配置和恢复材料的云备份位置。只要目标 GitHub 仓库可见性是 `PRIVATE`，且仓库用途是备份、恢复、个人知识库或私有配置快照，不要因为存在密钥、token、私钥、OAuth 配置或账号配置而默认脱敏或否决推送。

执行规则：

- 推送前先用 `gh repo view <owner>/<repo> --json visibility` 确认可见性。
- `PRIVATE` 仓库：按用户备份需求优先推送；不要为了“安全感”破坏可恢复性。
- `PUBLIC` 仓库：必须做公开暴露面判断；发现真实密钥值、私钥内容、token、完整本机日志、未脱敏截图或可滥用运维细节时，否决原样提交。
- 不在聊天回复中复述密钥值，即使它们已进入私有仓库。
- 如果私有仓库变为公开仓库，必须重新审计并阻止继续推送敏感内容。

### `wlyaaaaa/Key` 特例

- `wlyaaaaa/Key` 严格禁止克隆到本机，哪怕它是 PRIVATE。
- 总索引只记录它的远端私有备份状态和“本机无 clone”结论。
- 不为 `Key` 创建计划任务，不展开内容，不做本地恢复建议，不把“clone 到私有目录”作为下一步。

## 推送决策

- 私有备份仓库：工作区干净且 ahead 时，可直接推送。
- 公开索引仓库：只推文档、规则、摘要和脱敏结论。
- 公开业务仓库：按仓库自己的 `AGENTS.md` 和本轮用户目标判断；含截图、临时帧、原始日志、绝对路径、进程列表或未整理产物时，优先否决原样提交。
- 多仓库批处理时，分别记录“已推送 / 否决 / 需人工确认”的原因。
- 目标项目的提交/推送由目标项目 closeout 决定。本索引不因每个小任务或普通 push 自动写日志或制造 commit；仓库身份、路径、可见性、公开门禁、worktree 口径发生变化，或用户明确要求记录里程碑时，才更新本索引。`tools/Add-PushRecord.ps1` 只做纯文件幂等写入，Git stage/commit/pull/rebase/push 必须由外层流程显式执行。

## 项目入口门禁

- 用户要求修改、审计、运行、提交、推送或恢复任意 Git 项目时，Agent 控制先走 `E:\.agents\skills\project-entry-gate`，再把本仓库作为 Git 项目事实入口和公开发布门禁查询。先在本仓库确认项目本地路径、远端、可见性、分支/同步状态、脏状态和推送策略，再进入具体项目。
- 本仓库只负责 Git 项目事实、公开索引和 Git/推送门禁；不替代 `E:\.agents` 的能力路由，也不替代具体项目的 `AGENTS.md`、README、脚本、测试命令或业务规则。
- 进入具体项目后，必须读取当前项目目录链上的 `AGENTS.md` / `AGENTS.override.md`，再按项目规则执行。
- 如果改动涉及绝对路径、计划任务、本机数据源、跨盘迁移、备份/恢复、本地工具链、启动脚本、快捷方式或共享目录，必须同时查询 `E:\PCConfig` 的路径依赖、迁移记录和恢复规则。
- `E:\PCConfig` 不是项目入口；它是机器配置事实来源。不要把项目列表、远端状态和推送决策搬进 PCConfig。
- 不要在本仓库直接决定计划任务的创建/删除/改 Action；先确认任务所属具体项目和 `E:\PCConfig` 中的机器门禁，再由拥有项目或 PCConfig 迁移流程执行。
- 如果具体项目发现新的机器级路径依赖，应把可公开摘要写回本仓库，机器事实和恢复细节写入 `E:\PCConfig`，敏感值仍留在私有位置。

## 维护习惯

- 不用 `git add .` 盲目提交混合工作区；优先显式 stage 文件。
- 只有明确里程碑需要记录时，才调用 `tools/Add-PushRecord.ps1 -Repo <owner/name> -Branch <branch> -Commit <hash> -Reason <summary>`；以 `repo|branch|commit` 幂等，禁止 LLM 手工改大日志，也禁止该 helper 自行执行任何 Git 事务。
- **原地语义重构与行数限制契约**：禁止盲目在文件末尾追加补丁。更新规则时必须定位最相关条目进行“原地语义合并与重写”，保持高内聚。本仓库及具体项目 `AGENTS.md` 长度强控在 **400 行** 内。
- 本地必须通过运行 `tools/Install-GitHook.ps1` 部署 Git pre-commit 拦截 Hook。Hook 采用无 BOM 的 UTF-8 编码和纯英文注释以兼容 Git Bash。
- 当 Hook 或扫描函数检测到 staged 或 untracked 列表中包含 `99_private/`, `secrets/`, `private_key` 等敏感字，或者内容包含 `-----BEGIN PRIVATE KEY-----` 和 `ghp_` 等敏感私钥 Token 时，无条件强行拦截提交（返回 Exit 1）。
- 项目入口优先使用 `tools/Get-ProjectAdmission.ps1 -Repo <owner/name> -Json`；项目收尾可用 `tools/Refresh-GitHubLocalIndex.ps1 -Fast -Repo <owner/name> -Json` 做同 schema 快查。只有索引事实或明确里程碑变化时才重建 `00_总览/`、`01_仓库索引/`、`02_同步诊断/` 或写 `03_推送决策/`。
- 检查本仓库是否与当前本机/GitHub 状态一致时，优先运行 `tools/Test-GitHubLocalIndexConsistency.ps1 -SkipFetch` 或 `tools/Refresh-GitHubLocalIndex.ps1 -CheckOnly`；默认只把 GitHub/同步诊断类稳定文档漂移视为失败，计划任务文档因时间戳和运行态高频变化只作为易变漂移提示。不要为了“强一致性”自动提交或推送公开摘要。
- 计划任务只记录公开安全的运行状态和异常，不在本仓库保存完整 Action、触发器、恢复事实或敏感 XML。`Register-GitHubLocalIndexRefreshTask.ps1 -CheckOnly` 必须保持纯 dry-run；live `-Apply`、legacy task pre-image、禁用和回滚均由 root/PCConfig 流程处理。
