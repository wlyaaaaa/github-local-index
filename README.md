# GitHub 总索引

> 面向用户｜非执行规则、非动态事实权威、非 AI 默认上下文｜更新：2026-08-22（中国时间 UTC+8）
>
> AI 仅在用户明确要求解释、入门、维护本文档，或具名验收确实需要时按需读取。执行时以 `AGENTS.md`、owner-local 合同、当前 Git/GitHub 证据和实际候选差异为准。

这是本机 GitHub 仓库的公开安全索引、同步诊断和发布边界仓库，远端为 `wlyaaaaa/github-local-index`。它帮助人查清仓库在哪里、远端和可见性是什么、分支/worktree 是否同步，以及公开发布前要注意什么，但不要求每个 Git 任务执行固定命令链。

完整的人类说明见 [我的 GitHub 项目管理指南](./我的%20GitHub%20项目管理指南.md)。

## 谁负责什么

| 负责方 | 负责内容 |
|---|---|
| `E:\.agents` | Agent 行为、skills/plugins 和能力路由 |
| `E:\GitHub总索引` | 仓库身份、远端、可见性、同步诊断和公开发布边界 |
| `E:\PCConfig` | 路径迁移、计划任务、端口、运行时、本机数据和恢复 |
| 具体项目 | 业务语义、源码、项目规则、测试和部署 |

三个控制面按当前问题组合，不是每个 Git 任务都要走完的审批链。普通项目提交也不需要为了形式同步三个控制面。

## 主要入口

- [GitHub 总览](00_总览/GitHub总览.md)
- [当前同步看板](00_总览/当前同步看板.md)
- [GitHub 仓库索引](01_仓库索引/GitHub仓库索引.md)
- [分支与远端诊断](02_同步诊断/分支与远端诊断.md)
- [未推送队列](02_同步诊断/未推送队列.md)
- [推送放行与否决规则](05_规则与模板/推送放行与否决规则.md)
- [owner-local Git 合同](docs/contracts/)

公开 Markdown 只展开公开安全信息；PRIVATE identity 和本机绝对路径保存在 ignored 私有导航 cache，使用时仍要核对真实 `.git` origin。

## 常用工具

```powershell
# 单仓库结构化事实；只有身份、同步或发布条件不清楚时才需要
pwsh -NoProfile -File tools\Get-ProjectAdmission.ps1 -Repo <owner/name> -LiveMetadata -Json

# 预览索引刷新，不写入
pwsh -NoProfile -File tools\Update-GitHubIndex.ps1 -SkipFetch -NoWrite

# 诊断当前公开投影是否漂移
pwsh -NoProfile -File tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch
```

`-LiveMetadata` 是无 fetch 的只读查询；`-RefreshRefs` 才刷新 refs，旧 `-Fetch` 保持兼容。Admission 只提供 Git 事实，不授予写入或公开发布权限。

完整 refresh 使用原子 generation 并只保留 current+previous；实现细节和故障边界由 owner-local 合同与工具测试负责，不在 README 复制。

## 公开与私有边界

本仓库是 `PUBLIC`。不得提交真实 API key/token/private key、完整 `.env` 或 OAuth JSON、原始日志/数据库/聊天/健康资料、私密截图、机器快照、完整任务 XML 或可直接滥用的运维细节。

Git transport readiness 与内容 publication 是两件事：能 push 不等于适合公开。准备发布时必须重新确认当前 visibility、实际候选 commits/paths/content、项目规则和用户授权。

确认仍为 `PRIVATE` 的备份或恢复目标可以按任务需要保持精确内容，但不得把它复制到本公开索引。`wlyaaaaa/Key` 的 checkout 只保留密文和公开安全说明，解密明文、口令与 keyfile 不得进入仓库。

## 什么时候更新总索引

只有 owner 事实变化时更新，例如仓库新增/删除/改名、remote 或 visibility 改变、clone 路径迁移、默认分支或长期同步策略变化、公开门禁升级，或用户要求记录重要里程碑。

普通功能、bugfix、文档 commit 和项目业务内容变化留在目标项目；不为每次 push 写流水账，也不为收尾仪式重复刷新索引。
