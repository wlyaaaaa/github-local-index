# GitHub 总索引规则

本仓库是公开的 `wlyaaaaa/github-local-index`，只拥有 Git/GitHub 的 repo identity、remote、visibility、transport、candidate、secret-path 与同步诊断事实。施工项目 ID 为 `repo:wlyaaaaa:github-local-index`；动态事实以任务当下证据为准，默认简体中文。

## 硬边界

- 只能提交公开安全内容：可用密钥、token、私钥、真实 `.env`/OAuth 私密载荷等秘密明文不得提交；`99_private/` 是 `.gitignore` 排除的本机原始材料区，永不进入公开仓库。raw、日志、数据库、task XML、机器快照只是 review candidate，不能仅因形态/路径阻断实际 L1/L2；原始私人聊天、完整健康资料和私密截图按全局 L4 下限处理。
- 提交/推送前结合新鲜 visibility、candidate commits、paths 与 content 判断公开暴露；transport 可用不等于可公开。分级只消费 `E:\.agents` 的 `public_personal_data_classification` 结果，不拥有或改写：`below_l3_publication_default` 禁止本仓库、项目自写规则或路径命名上调 L1/L2；未获用户明确授权的 `project_publication_restriction_authority` 不是 Git 事实，不能阻断 L1/L2。secrets、raw chats、完整 health 资料至少 L4 或上位边界，不形成低级例外；分级不替代独立外部写入授权。
- repo identity、remote、target branch、visibility 或 candidate content 有实质冲突时停止写入/发布并取得更可靠证据，只读调查继续。已确认 PRIVATE 的备份、恢复、个人知识库或配置快照按任务需要保留精确内容，不因凭据自动遮盖或破坏恢复；外部写入仍服从活动授权。`wlyaaaaa/Key` 可 clone 到受管私有路径，只维护密文和公开安全说明，不写入解密明文、口令或密钥文件，也不创建计划任务。

完整放行与否决矩阵只在 [`05_规则与模板/推送放行与否决规则.md`](./05_规则与模板/推送放行与否决规则.md) 维护，其他文档只摘要引用。

## Owner 分工与按需取证

- `E:\.agents` 拥有 Agent 行为、skills/plugins、能力路由与公开分级，本仓库不复制第二套行为规则。Git consumer 只处理 Git 事实，不从项目限制、路径或仓库可见性反推更高敏感级别。`E:\PCConfig` 仅在路径迁移、计划任务、端口、运行时、本机数据、备份或恢复事实会改变当前决定时参与；绝对路径字面量不是触发。项目拥有业务语义、源码、规则、测试和部署，本仓库不替代项目证据。
- `wlyaaaaa/PersonalOS-Retired` 是普通 PRIVATE 冻结文档仓库，不是第四基座、默认个人上下文 Owner 或外部治理例外；维护其 Git/GitHub 身份与同步事实时不读业务正文。`PersonalKnowledge` 名称只给独立现行个人知识库项目。
- 现有路径保留为事实。未来新建/clone 的个人 Git 仓库默认 `V:\Personal\Projects`，临时 worktree 默认 `V:\Personal\Worktrees`，未来工作仓库 `V:\Work\...`；`V:\Dev` 只兼容已有 worktree，不新增。仅在实际创建、clone 或迁移后写入索引，不预登记空目录；项目兼容性或公司合规可覆盖默认位置。
- `tools/Get-ProjectAdmission.ps1 -Json` 是可选结构化证据：identity、worktree、sync、visibility 或 direct transport 不清，或信息价值高于成本时使用；新鲜可靠证据已明确时不打卡重调。admission V1 `decision`、`push_decision`、`push_strategy` 只描述进入/transport 条件，不授予写入或公开；`decision=block` 停止不充分证据下的写入/直接 transport，不停只读诊断。
- [`docs/contracts/`](./docs/contracts/) 的 owner-local 合同只在机制、兼容、故障或控制面演进时读。系统/受保护仓库由已登记最高权限智能体按真实目标审查；只有它决定人类因子，adapter 不得按 effect 自派生。因子仅 Passkey、TOTP、Recovery、Account，Google/Microsoft 只是 Account provider；稳定身份、动作分类、正常变化/恶意篡改和受保护 adapter 见 [`git.protected-major-actions`](./docs/contracts/git.protected-major-actions.md)。

## 维护原则

- 按目标、风险、证据新鲜度和成本选择 provider、Git 命令、索引快照或项目证据；工具存在不构成固定调用链。`tools/Install-GitHook.ps1` 只用于首次 bootstrap、缺失或损坏 repair；Hook 是 defense in depth，不能替代 candidate 内容复审，也不每任务重装。Fast refresh 仅兼容维护，不作普通收尾；完整 refresh 仅在索引事实、生成口径或用户要求更新快照时用。`tools/Add-PushRecord.ps1` 只在用户要求或确有公开里程碑价值时用，普通 commit/push 不记流水。
- 只显式 stage 本次目标文件，保护已有改动，不用 `git add .`。计划任务在这里只留短 owner 路由，不复制任务名、状态、Action、时间表或恢复事实；实时状态、机器配置/恢复和业务语义分别归 Task Scheduler、PCConfig、所属项目。
- 生成 Markdown 只展开 PUBLIC 仓库并隐藏本机绝对路径；PRIVATE identity/精确 clone 路径进入 ignored 私有导航 cache，provider 使用后回读 `.git` identity，cache 缺失时显式 bootstrap 或失败关闭。
- Git/GitHub 与受管 registry 是可审计事实源：generation 完整回读后原子进入 current，顶层 Markdown 只是可检 stale 的兼容投影，默认 current+previous。`refs/codex/turn-diffs/checkpoints`、unreachable objects、generation manifest 的保留/恢复先有证据，未证明不得 `gc`/`prune`。不引入数据库，未来查询 cache 仅可删除/重建且不能替代 Git/GitHub/registry。

规则在最相关位置原地重写去重；本文件只留 Git/GitHub 的真实边界，专项机制放合同或工具文档。
