# git.push-publication

## 产品目标
把 Git transport readiness 与内容公开发布授权分成两个独立门禁。

## 触发条件
triggers: `push|publication|visibility|public_repo`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
transport 使用 admission V1 的 `decision`、`push_decision`、`push_strategy` 与 visibility；发布审查读取目标项目规则和候选内容。

## 核心机制
`push_decision=proceed` 只表示 transport conditions ready，不代表公开发布授权；PUBLIC always requires separate target-project/content exposure review。

## 输出合同
V1 `github-local-index.project-admission.v1` 不输出 publication_decision；transport 结论与发布复审结果不得互相冒充。

## 失败与降级
`decision=block` 禁止写入与推送；transport 未放行时仅可只读诊断；PUBLIC 复审不清楚时停止发布。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 admission/transport，`tests/Test-ControlPlaneContracts.ps1` 验证 publication 分离措辞。

## 上下文策略
普通入口读取单项目 admission；只有准备发布时才加载目标规则、visibility、提交、路径和内容证据。

## 已知限制
本卡不扫描候选内容，也不替具体项目授予发布权限；transport readiness 不是安全证明。

## 扩展入口
若未来需要机器化发布授权，必须另行设计版本化接口，不能把字段暗加进 admission V1。
