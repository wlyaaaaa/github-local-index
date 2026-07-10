# git.refresh-consistency

## 产品目标
区分单仓库快查、一致性检查与公开摘要重建的成本和写入语义。

## 触发条件
triggers: `refresh|consistency|index_drift`

## owner 与权威
owner: E:\GitHub总索引

## 权威输入
现有 refresh wrapper、GitHub 索引生成器和 consistency checker 是行为入口。

## 核心机制
Fast avoids tracked Markdown rebuild but may write private log；CheckOnly uses system temp 生成后比较并清理临时材料。

## 输出合同
Fast 返回单仓库 admission 结果；CheckOnly 返回漂移诊断；完整刷新才重建 tracked Markdown。

## 失败与降级
refresh 或比较失败时保留失败状态，不把缺失证据解释为一致，也不自动提交生成结果。

## 验证证据
`tests/Run-UnitTests.ps1` 验证快路径、system temp 和仓库树内只读边界。

## 上下文策略
普通开工/收尾优先 admission 或 Fast；只有一致性问题才加载生成器和差异证据。

## 已知限制
Fast 与 CheckOnly neither is `zero_write`：前者可能写 private log，后者使用并删除 system temp。

## 扩展入口
若新增刷新模式，必须先声明 tracked、private、temporary 和 external 四类写入效果。
