# git.project-admission

## 产品目标
用稳定合同解释 Git 项目身份、远端和只读进入门禁，不保存动态 Git 快照。

## 触发条件
triggers: `git_project|repo_identity|project_entry`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
运行时权威来自 `tools/Get-ProjectAdmission.ps1 -Json` 的 `github-local-index.project-admission.v1` 记录。

## 核心机制
`decision` is read-only admission：`block` 禁止写入与推送，`warn` 允许受限进入；cached evidence remains `warn`。

## 输出合同
输出项目身份、定位和门禁结论；结构化 provider 记录用于机器判断。

## 失败与降级
provider、schema、仓库身份或路径不明确时停止写入，保留错误类别供只读诊断。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 schema、CLI 退出语义和稳定字段集合。

## 上下文策略
普通任务只查询当前项目记录；合同卡不复制记录正文或历史快照。

## 已知限制
Markdown is not machine authority；本卡不能替代当前 provider 证据或目标项目规则。

## 扩展入口
只有新的长期准入语义无法由 V1 表达时，才另行设计兼容版本。
