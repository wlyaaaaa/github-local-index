# git.push-publication

## 产品目标
把 Git transport readiness 与实际内容 publication 判断分离，并让公开门禁关注候选结果而非命令打卡。本卡只覆盖 repo identity、visibility、transport、candidate、secret-path 事实；`public_personal_data_classification`（global public personal data grading）只作为来自 `E:\.agents` 的源拥有消费输入。

## 触发条件
triggers: `push|publication|visibility|public_repo`；只有准备产生外部写入或公开结果时才需要完整发布证据。

## owner 与权威
owner: E:\GitHub总索引
Git publication control plane 只拥有上述 Git/GitHub 事实；公开个人数据分级的 source owner 是 `E:\.agents`，本卡不得创建、改写或上调其等级。

## 权威输入
transport 可采用 admission V1 的 `-ForPublication` profile 或等价的新鲜 Git/GitHub 证据；publication 依赖当前目标 visibility、candidate commits、paths、content、项目规则与用户授权。`E:\.agents` 的 `public_personal_data_classification` 是 source-owned 输入：`below_l3_publication_default` 下 `L1/L2` 按源结果消费，不得由 Git 控制面自行上调；`project_publication_restriction_authority` 只在真实项目需要和用户对精确项目、范围、限制内容明确授权时生效。`live_checked=true` 只证明 metadata/refs 的新鲜取证完成，仍不等于内容安全或外部写入授权。敏感路径 canonical case table 位于 `tools/PublicExposurePolicy.psd1`。

## 核心机制
`push_decision=proceed` 最多表示 transport readiness，不代表公开发布授权。PUBLIC review 必须判断实际候选暴露面；`.env`、运行态 `.env.*`、`*.env*` 及同表敏感路径由 admission、Hook、`.gitignore` 共用用例验证。明确的 `.example/.sample/.template/.dist` 模板后缀只免除路径否决，仍接受内容扫描；pure delete 与移出敏感路径是修复。
未经 `project_publication_restriction_authority` 所需的用户明确授权（explicit user authorization），项目自写公开限制（project-authored public restriction）不是 Git 事实，不得阻断（cannot block L1/L2）内容资格，也不能授权外部写入；候选仍须独立通过 visibility、candidate、content、secret-path 与授权门。
`secrets`、`raw chats`、完整 `health` 资料及凭据至少归入 `L4`，或适用更高的上位边界；禁止通过模板、项目标签、路径未命中或其他隐藏例外降为 `L1/L2`。

## 输出合同
V1 `github-local-index.project-admission.v1` 不输出 publication_decision；transport 与 publication 结论不得互相冒充。完整矩阵由 `05_规则与模板/推送放行与否决规则.md` 唯一维护。

## 失败与降级
identity、visibility、目标或候选内容存在实质不确定性时停止写入/发布并补证；transport 不可用时仍允许 read-only diagnosis。

## 验证证据
`tests/Test-ProjectAdmission.ps1` 验证 transport 与 rename/delete 语义；`tests/Run-UnitTests.ps1` 让新仓 fixture 验证 policy、Hook、ignore；合同测试验证 publication 分离与唯一矩阵。

## 上下文策略
模型按风险选择最小充分证据；只有准备发布时才审查当前 visibility 与实际 candidates，不在普通读取或本地实现时加载完整矩阵。

## 已知限制
本卡不授予外部写入，不扫描候选内容，也不替具体项目决定业务发布或全局数据分级；PRIVATE 保真仍要求确认目标可见性。没有 `project_publication_restriction_authority` 的项目自写限制不能阻断 `L1/L2`，但不改变独立授权、候选内容和 secret-path 门。

## 扩展入口
新增敏感路径先扩展 canonical cases，再同步声明式 ignore；不向每仓批量注入 Hook。若未来机器化 publication，需要独立版本化接口和候选内容证据。
