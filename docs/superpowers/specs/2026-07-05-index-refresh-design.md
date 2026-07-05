# GitHub 总索引自动刷新设计

更新时间：2026-07-05

用户已批准执行此前提出的 1/2/3：增加自动刷新脚本、稳定未发现本地 clone 清单、复查计划任务异常。

## 目标

把 `E:\GitHub总索引` 从一次性人工审计文档升级为可重复刷新的公开诊断台。刷新过程必须能重新读取 GitHub 远端仓库、本地 clone、ahead/behind、脏工作区和 Windows 计划任务摘要，并写回本仓库的公开 Markdown 文档。

## 边界

- 本仓库是公开仓库，只写入可公开的索引、诊断摘要和推送决策。
- 不写入 token、私钥、完整 `.env`、OAuth JSON、计划任务 XML、完整 Action 命令或原始日志。
- 刷新脚本不自动提交或推送业务仓库，不自动修改计划任务。
- 私有仓库可以在结论中标注为私有备份用途，但不复制私有内容。

## 架构

新增两个只读采集脚本：

- `tools/Update-GitHubIndex.ps1` 负责 GitHub 仓库和本地 clone 状态。
- `tools/Update-ScheduledTaskHealth.ps1` 负责计划任务健康摘要。

两个脚本都把采集结果转换为公开 Markdown，写入现有目录结构。脚本内部保留纯函数，用于单元测试关键解析和分类逻辑。

## 数据流

1. `Update-GitHubIndex.ps1` 调用 `gh repo list` 获取远端仓库清单。
2. 脚本扫描固定根目录下的 `.git/config`，从 remote URL 反解 `owner/repo`。
3. 对存在本地 clone 的仓库执行 `git fetch --prune origin`、`git status`、`git rev-list --left-right --count`。
4. 脚本生成仓库索引、本地 clone 索引、未发现 clone、未推送队列、分支诊断和脏工作区摘要。
5. `Update-ScheduledTaskHealth.ps1` 读取匹配的计划任务，按返回码分类为正常、警告或异常。
6. 计划任务脚本只输出任务名、状态、上次运行、下次运行、返回码和公开判断。

## 错误处理

- `gh` 不存在或未登录时，脚本失败并提示需要先修复 GitHub CLI。
- 无 upstream 的本地仓库列入需人工确认，不猜测推送目标。
- 本地 clone 扫描失败时跳过不可读路径，不中断整个刷新。
- 计划任务读取失败时生成一条可公开错误摘要，不写出敏感异常堆栈。

## 测试

使用 `tests/Run-UnitTests.ps1` 做轻量 PowerShell 自测，不依赖 Pester。测试覆盖：

- GitHub remote URL 到 `owner/repo` 的标准化。
- 仓库索引 Markdown 生成时能正确区分本地 clone 与未发现 clone。
- 计划任务返回码分类，特别是 `0xC000013A` 中断退出。

