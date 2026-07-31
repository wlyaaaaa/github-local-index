# Git 与 GitHub 重大动作保护合同

owner: GitHub 总索引
状态：现行 owner 语义；受管 Codex 路径立即适用，密码学 effect adapter 的
实现状态以活动策略中的 protected owner-adapter registry 为准

## 目标

为本地与远端 Git/GitHub 对象提供稳定身份、preimage、执行和 read-back，使
`.agents` 的顶级模型智能审查与 PCConfig AuthorityHost 的一次性能力可以
保护系统项目、四基座相关仓库和其他高价值仓库。

本合同不维护固定“必须弹通行密钥”清单。受认证 `codex-root` 是最高权限主体；
当前顶级模型结合用户意图、仓库真实身份、visibility、默认分支、恢复性、
影响范围和异常证据，自主决定直接执行、通行密钥 step-up、拒绝或只读取证。

## 重大信号不是完备分类

删除/转移仓库、改变 visibility、重写远端默认分支、删除唯一历史或恢复分支、
撤销保护/备份、替换 remote owner、破坏 release/deployment 链等是强风险信号。
普通 commit、normal push、受信文档/代码修改、明确可回退分支整理和索引刷新
不能只因发生在系统项目或四基座相关仓库就被判成恶意。

最终判断由顶级模型完成；owner policy 可以拒绝身份不明、preimage 不完整、
目标歧义或 read-back 不可用的动作，但不能用关键词替模型决定通行密钥。

## 稳定目标

Git adapter 至少解析并绑定：

- 本地 canonical worktree/common-dir 与 filesystem identity；
- provider、remote URL、stable owner/repository ID、visibility；
- 实际 default branch、目标 ref/object ID、保护与恢复 refs；
- 当前远端 head、候选变更、预期现实效果和恢复路径；
- 调用的 executable/hash、API endpoint、arguments 和 credential scope class。

仓库名、目录名、窗口文本或模型自述不能单独成为目标身份。

## 精确能力

owner adapter 只接受 AuthorityHost 根签的 single-use capability，绑定
`ActionProposal`、`codex-root` runtime proof、可选 passkey receipt、stable
repository ID、preimage、expected post-state、executor/hash/arguments、
policy/trust epoch 和 expiry。

执行前重新 fetch/read、解析 remote identity 和 precondition；任何 owner、
visibility、default branch、object ID、计划或 epoch 漂移都使旧能力失效。
执行后必须从提供方和本地两侧 read-back，并写无秘密 receipt。partial 状态
不能冒充成功；能够回滚时按预签计划回滚，不能回滚时保留精确恢复证据。

普通 `gh`/Git 认证不应默认持有删除、转移或管理级 scope；需要此类能力时由
受保护 Broker 向精确 adapter 临时提供且丢弃输出。当前个人工程不承诺阻止
已经取得管理员、其他高权限 token 或提供方账号完全控制权的外部程序绕过，
但受管 Codex 路径不得绕过本合同。

## 正常变化与篡改

以下是正常变化证据，不是恶意篡改：受信 commit/push、用户或其他智能体的
正常代码/文档修改、合法 PR/merge、候选 branch、明确授权的仓库设置调整。

以下可以形成 integrity incident：remote stable owner/repository ID、
visibility、default branch、保护/恢复 refs 或受保护 adapter 在没有有效事务
的情况下被替换、回滚、伪造、重放；或无 capability 的受管重大动作已产生
现实副作用。是否属于攻击/失陷仍由顶级模型结合提供方事件和本地证据判断；
确认后交 PCConfig 以 `protected-action-integrity` 进入统一不可信流程。

## 验收

- synthetic/private 测试仓库覆盖 allow、step-up、deny 和目标漂移；
- 正常 commit/push 和文档编辑不误报；
- repo alias、remote 替换、默认分支变化、force rewrite、delete/transfer/
  visibility endpoint 直调无 capability 时拒绝；
- capability exact binding、single-use、expiry、replay 和 read-back 通过；
- 不为验收删除、公开、转移或重写任何真实生产仓库。
