# git.push-publication

## 产品目标
把 Git transport readiness 与实际内容 publication 判断分离，并让公开门禁关注候选结果而非命令打卡。

## 触发条件
triggers: `push|publication|visibility|public_repo`；只有准备产生外部写入或公开结果时才需要完整发布证据。

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
transport 可采用 admission V1 的 `-ForPublication` profile 或等价的新鲜 Git/GitHub 证据；publication 依赖当前目标 visibility、candidate commits、paths、content、项目规则与用户授权。`live_checked=true` 只证明 metadata/refs 的新鲜取证完成，仍不等于内容安全或外部写入授权。敏感路径 canonical case table 位于 `tools/PublicExposurePolicy.psd1`。

## 核心机制
`push_decision=proceed` 最多表示 transport readiness，不代表公开发布授权。PUBLIC review 必须判断实际候选暴露面；`.env`、运行态 `.env.*`、`*.env*` 及同表敏感路径由 admission、Hook、`.gitignore` 共用用例验证。明确的 `.example/.sample/.template/.dist` 模板后缀只免除路径否决，仍接受内容扫描；pure delete 与移出敏感路径是修复。

## 输出合同
V1 `github-local-index.project-admission.v1` 不输出 publication_decision；transport 与 publication 结论不得互相冒充。完整矩阵由 `05_规则与模板/推送放行与否决规则.md` 唯一维护。

## 失败与降级
identity、visibility、目标或候选内容存在实质不确定性时停止写入/发布并补证；transport 不可用时仍允许 read-only diagnosis。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 transport 与 rename/delete 语义；`tests/Run-UnitTests.ps1` 让新仓 fixture 验证 policy、Hook、ignore；合同测试验证 publication 分离与唯一矩阵。

## 上下文策略
模型按风险选择最小充分证据；只有准备发布时才审查当前 visibility 与实际 candidates，不在普通读取或本地实现时加载完整矩阵。

## 已知限制
本卡不授予外部写入，不扫描候选内容，也不替具体项目决定业务发布；PRIVATE 保真仍要求确认目标可见性。

## 扩展入口
新增敏感路径先扩展 canonical cases，再同步声明式 ignore；不向每仓批量注入 Hook。若未来机器化 publication，需要独立版本化接口和候选内容证据。
