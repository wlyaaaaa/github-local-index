# 私人伴生文档发现

`tools/Get-ProjectPrivateCompanion.ps1 -Repo owner/name -Json` 读取本机已登记的唯一目标，以及该目标的 catalog、项目 manifest。可传 `-RepoPath` 指定本地来源；否则使用现有私人导航并回读 origin。`-IndexRoot` 支持隔离环境。入口不访问网络、不修改配置、不输出文档正文，也不扫描其他项目文件。

`Get-ProjectAdmission.ps1` 的 `private_companion` 附加相同事实，不改变普通 Git 准入结论。已登记但尚未映射的项目返回 `registered_unmapped` 和目标，供准备公开时规划。没有 registry 返回 `unregistered`；指针冲突或 identity 不符返回 `conflict`。这些事实不授予写入，目标的 PRIVATE 登记不等于实时可写。

元数据只存本机 ignored `99_private/registries/public-project-private-companion.json` 与私人目标，真实目标地址、来源映射和机器路径不得复制进公开文档。registry 使用 `repository`、`local_path`、`target_id`、`catalog`；catalog 的 `sources` 项使用 `source_repository`、`prefix`、`manifest`（相对目标库根）。manifest 的 `target_relative_path` 相对项目 `prefix`，`source_relative_path` 相对来源库根，`sha256` 用于发现迁移后内容漂移。

已存在的 catalog 映射优先于缺失的本机 Git 配置；配置存在但冲突会显式报告。文件事实包含源链接/缺失状态、目标路径和 manifest 哈希状态，目标另报 dirty。正常编辑经链接修改私人文档时，应把实际变更的私人仓库纳入本任务 Git 收口；后续写入仍现场核验目标身份、可见性和授权。

验证：`pwsh -NoProfile -File tests/Test-ProjectPrivateCompanion.ps1`。
