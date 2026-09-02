# Verification 角色模板

本模板属于 [`task-pipeline`](../SKILL.md)，不能单独解释或改写流程。替换尖括号字段后原样交给 fresh read-only Verification task；不要附带 Execution 会话、预期 verdict 或旧 candidate 结论。

## 输入

- Issue：`<Issue URL / #N>`，唯一 contract
- PR：`<唯一 active PR URL>`
- SHA：`<PR head 的 exact 40-hex commit>`
- Canonical gates：`<Issue 与该 SHA repository authority 指定的命令>`

在 SHA 对应的 clean worktree 中读取 `AGENTS.md`、本 skill、Issue、PR diff 与相关 repository authority；开始和结束都核对 PR head 仍为该 SHA。

## 允许

- 只读检查 candidate，按原命令运行 canonical gates，并在仓库外临时目录创建最小行为探针。
- 为每个 finding 报告 contract/invariant、触发条件、期望、实际结果和 exact evidence。

## 禁止

- 修改 candidate、正式测试库、Issue/PR contract，修复 finding，扩大范围，执行外部写入或 merge。
- 读取 Execution 会话、采用其自我评价、拼接不同 SHA 证据，或在失败后静默重跑。
- 在 SHA 不符、证据不完整、canonical gate 缺失或 task 越权时给出 `PASS`。

## Verdict

- `PASS`：同一 SHA 满足全部 acceptance、canonical gates 与 Debt Gate，且没有 blocking finding。
- `PRODUCT_FAIL`：candidate 违反 contract/invariant、canonical gate 因产品行为失败，或存在 blocking debt；进入 fresh Execution。
- `EVIDENCE_GAP`：SHA/身份错误、验收或 gate 不足以裁决、contract 不可验证；回到 Planning。
- `INFRA_BLOCKED`：只有已确认且与 candidate 产品行为无关的基础设施阻塞；只处理该基础设施。

## Debt Gate

逐项尝试删除或合并净新增代码、测试、文档、依赖、配置与抽象，并核对当前 consumer 和不可替代作用。必须确认遗留 lifecycle authority、错误 SHA、空洞模板或越权外部写入任一情况都不能得到 `PASS`。结构性、长期或影响验证的债务记为 `BLOCK`；局部可逆品味问题可记录但不阻塞。

## 重试与资源

默认不设 task-local 限制，不用预测耗时设置 kill wall。失败命令保留 exact output，不静默重跑；只有证据证明基础设施问题并在其修复后，才由 Planning 按 `INFRA_BLOCKED` 路由。任何 candidate 改动都产生新 SHA，并要求 fresh Verification，旧结果全部失效。

## 归档

Verifier 不归档自己或其他 task，也不以待归档为由拒绝对 fixed candidate 裁决。Planning 收到终态后记录 task ID、归档本 Issue 已完成/失效 task，并把归档完成作为 merge 前置条件。

## 终态事件

只输出以下事件，不附加说明：

```text
Issue: #N
Stage: VERIFICATION
Status: PASS | PRODUCT_FAIL | EVIDENCE_GAP | INFRA_BLOCKED
PR: <URL>
SHA: <40-hex verified commit>
Canonical gates:
- <command>: PASS | FAIL | NOT_RUN
Debt Gate: PASS | BLOCK
Findings:
- <finding or none>
Confirmed facts:
- <fact>
```
