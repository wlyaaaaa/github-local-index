# Git 与 GitHub 重大动作保护合同

owner: GitHub 总索引

adapter: `github.protected-major-actions.v1`

实现：`tools/Invoke-ProtectedGitHubMajorAction.ps1`

生产激活状态：只认 PCConfig AuthorityHost 发布的活动策略，不由本仓源码自证

## 产品语义

系统项目、三控制面相关仓库和其他高价值仓库的重大动作，同时经过硬边界与最高权限
智能体语义判断。已登记的最高权限智能体 `codex-root` 按真实用户意图、精确目标、
范围、可恢复性和异常证据给出
`allow|step_up|deny|needs_evidence|suspected_tamper`。只有 `allow` 与 `step_up`
会形成可执行 proposal：`allow` 冻结为 `runtime_allowed`，`step_up` 冻结为
`human_required`；其余判断在读取 broker 或执行 effect 前失败关闭。

adapter 可以机械验证 typed effect、preimage、身份、参数与漂移，但不能按 effect
family、operation、仓库可见性、critical surface、executor 或 epoch 自行派生、提高
或降低 `human_required`。删除、转移、公开性与默认分支等动作都没有独立的机械人类
因子矩阵；是否需要人类因子只来自上述最高权限智能体的真实语义判断。普通 commit、
normal push、受信代码或文档修改也不能只因位于受保护仓库就被判为恶意篡改。

最高权限人类因子固定四类：Passkey、TOTP、Recovery、Account。Google 与
Microsoft 只是 `Account provider`，不是第五、第六类因子；选择 Account 时必须同时
指定一个已登记 provider。`AuthorityFactor=Auto` 在 proposal 冻结后解析：
`step_up`/`human_required` → `Passkey`，`allow`/`runtime_allowed` → `Runtime`。
显式人类因子可提高 `allow` 请求的验证强度；显式 `Runtime` 不能降低 `step_up`，
adapter 必须在 broker 和 effect 之前返回
`highest_authority_verification_required`。四类全部丢失或不可验证时没有 Runtime、
管理员或其他自动化 fallback。

## 两阶段接口

`Prepare` 读取实时 project admission 与 GitHub provider metadata，接收一个只有
操作所需字段的 JSON 参数对象，生成
`github-local-index.protected-major-action-proposal.v1`。提案内嵌
`pcconfig.major-action-authorization-request.v1`，并绑定：

- GitHub database ID、node ID、规范 `owner/repo`、remote URL；
- canonical worktree、git common-dir、visibility、default branch 和资源；
- 类型化 effect family、operation、完整 argv 与参数；
- `execution_mode=execute|dry_run`，演练能力不能升级为现实执行；
- 最高权限智能体的语义判断，以及只由 `allow|step_up` 映射并冻结的
  `authorization_requirement=runtime_allowed|human_required`；
- 实时 admission、provider metadata、ref/remote 等 precondition；
- adapter 脚本与 native git/gh 的 SHA-256、模型 decision/reason/user intent、
  30 秒能力 TTL。

`Execute` 只读取上述提案，按以下顺序运行：

1. 以 `RepoPath` 作为精确 target worktree 重新取得 admission、provider metadata、
   precondition、adapter 与 native executor hash；其他无关历史分支仍保留为证据，
   但不污染这次精确目标的 effect 判定；
2. 调用固定入口
   `C:\ProgramData\PCConfig\AuthorityHost\tools\Invoke-SecretBroker.ps1`
   的 `AuthorizeMajorAction`；adapter 把冻结后解析出的单一因子传给 broker，
   Runtime 使用 `codex-root`，人类下限使用已登记的四类因子之一；Account 另传
   已登记的 Google 或 Microsoft provider；
3. 再次取证后，以 `pcconfig.major-action-consume-request.v1` 调用
   `ConsumeMajorActionCapability`，且 consume 模式必须与已签
   `execution_mode` 精确一致；
4. 非 dry-run 在能力已验证且 single-use consume 成功后最后一次取证，再执行
   精确 argv，并 read-back 实际状态。native 返回非零也必须先回读：owner 已观察
   到目标效果则按已执行收敛，否则明确保留 `state_unknown`，不能谎报零变更。

任何 target、executor、参数、precondition、assessment、user intent、
`authorization_requirement` 或
AuthorityHost epoch binding 漂移都使旧能力失效。`-DryRun` 仍完成 AuthorityHost
授权与 capability 验证，但要求 `execute_allowed=false`、
`capability_consumed=false`，不会调用 effect executor。

authorization 的 `executor_sha256` 绑定 adapter 脚本自身；native git/gh hash
另以 `parameters.native_executor_sha256` 精确绑定。发送给 broker 的 authorization
与 capability 临时文件仅放在关闭继承的私有 ACL 目录中，只允许当前用户、
SYSTEM 与 Administrators 访问。

## 类型化 effect

adapter 只接受两类固定 effect，不接受 shell string 或 executable 参数：

- `git-local`：`delete-local-ref`、`force-update-local-ref`、
  `replace-remote-url`；
- `github-api`：`create-repository`、`set-visibility`、
  `rename-repository`、`set-default-branch`、`delete-repository`、
  `transfer-repository`。

Git 本地 effect 只调用固定 Git for Windows 路径，以
`ProcessStartInfo.ArgumentList` 逐参数执行；清除 Git 目录、exec、SSH、askpass、
redirect 等环境覆盖，禁用 system/global config，并用
`core.hooksPath=NUL`、空 credential helper 隔离 hook/helper。GitHub effect 只调
固定 `gh api` 与固定 GitHub REST endpoint/method；不存在通用命令、别名、扩展、
重定向或任意 API endpoint 通道。

### `github-api/create-repository`

这是“先安全建立私有远端”的专用通道，只能在当前已认证 GitHub 登录名自己名下
创建一个空的 PRIVATE 仓库。参数对象必须精确且仅包含：

- `expected_absent=true`；
- `visibility="PRIVATE"`；
- `expected_local_branch` 与 `expected_head_oid`。

Prepare 不复用要求远端已存在的普通 project admission。它以固定 `gh api` GET
读取 `repos/<owner>/<repo>`，只接受可识别的 404/absent；再固定 GET `user`，要求
返回的 `login` 与 repository slug 的 owner 严格相等。随后固定 Git 逐项确认
`RepoPath` 正是 canonical worktree、worktree clean、当前 branch 与 HEAD OID 精确
匹配 typed 参数。提案目标使用 `repository-slug:<owner>/<repo>`，在创建前绝不伪造
database ID 或 node ID。

effect 的 argv 是封闭的：`gh api --method POST user/repos`，payload 只能是
`name=<repo>`、`private=true`、`auto_init=false`。没有 owner、visibility、模板、
description、任意 endpoint 或任意 payload 的透传字段。Authorize/Consume 后仍会重新
执行上述 preimage；目标若在最终 effect 前出现，必须失败关闭。POST 后以固定 GET
read-back 只在 POST 成功并返回合法 `full_name`、PRIVATE、database ID 与 node ID
后成立，固定 GET 的同名字段还必须与 POST 响应精确一致；POST 非零不得认领随后
出现的同名仓库。

创建成功后，初始 remote 配置和 push 仍是普通 Git 收敛，不由本操作替代。若以后要
公开，必须使用既有 typed `set-visibility`，并先完成 PUBLIC 内容审查；不得以 direct
create 绕过该边界。

### `github-api/rename-repository`

这是“同一 GitHub repository identity 原地改名”的专用通道。参数对象必须精确且
仅包含 `expected_name`、`new_name`、`expected_visibility`、
`expected_default_branch`、`expected_target_absent=true`。Prepare 与每次 effect
前复核旧 slug 的 database ID、node ID、visibility、default branch，并以固定 GET
确认同 owner 下的新 slug 不存在；effect 只能对旧 slug 固定 `PATCH name=<new_name>`。
read-back 必须从新 slug 观察到相同 database ID、node ID、visibility 与 default
branch。它不允许改 owner、公开性或默认分支，也不接受任意 endpoint 或 payload。
仓库分支很多时，全量 admission 可能超过 30 秒 capability TTL；因此授权后、consume
前的复核使用 rename 专用快速 preimage，仍精确复核 adapter/native hash、固定 argv、
source/target provider identity、目标缺失、canonical worktree、branch、origin、clean
状态与本地 `HEAD=origin/<default>`。授权前及 consume 后的最终 effect gate 仍运行完整
admission，快速复核不成为其他 operation 的通用旁路。

### Schema 与内部执行器边界

adapter schema 规定可授权的 typed effect、preimage 和 read-back；内部执行器只把
已绑定的 closed argv 交给已哈希的固定 `gh` 路径与 `ProcessStartInfo.ArgumentList`。
本机 `gh` 是 adapter 的内部实现，不需要也不依赖 GitHub plugin。某个 GitHub 操作
尚未被闭合 schema 与固定 executor 表达时，属于
`protected_executor_extension_required` 的 adapter 扩展缺口，不是要求安装 plugin、
开放任意 endpoint 或退回 shell 的理由。

## 正常变化、事件与边界

受信 commit/push、正常代码或文档修改、合法 PR/merge、候选 branch 和明确授权
的仓库设置调整都是正常变化。stable repository ID、visibility、default branch、
保护/恢复 ref 或 adapter 在没有有效事务时被替换、回滚、伪造或重放，可以形成
integrity incident；是否失陷仍由最高权限智能体结合 provider 与本地证据确认。adapter
本身不改变设备信任，也不直接触发 BitLocker containment。

本实现保护受管 Codex 路径，不承诺拦截已经取得系统管理员、其他高权限 token
或 GitHub 账号完全控制权的外部程序。本仓不读取或治理业务仓库的私有数据。

## 无破坏验收

- synthetic 状态覆盖 Prepare、DryRun、Execute/read-back；
- `step_up` 所需人类因子缺失时返回
  `highest_authority_verification_required` 且零 effect；
- target drift 在 broker 调用或 effect 前失败关闭；
- 多余字段与 shell string 被类型化 schema 拒绝；
- 测试不删除、公开、转移或重写任何真实生产仓库。
