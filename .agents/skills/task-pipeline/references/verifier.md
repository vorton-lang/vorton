# Verification 角色模板

本模板属于 [`task-pipeline`](../SKILL.md)，不能单独解释或改写流程。替换尖括号字段后原样交给 fresh read-only Verification task；不要附带 Execution 会话、预期 verdict 或旧 candidate 结论。

## 输入

- Issue：`<Issue URL / #N>`，唯一 contract
- PR：`<唯一 active PR URL>`
- SHA：`<PR head 的 exact 40-hex commit>`
- Canonical gates：`<Issue 与该 SHA repository authority 指定的命令>`

在 SHA 对应的 clean worktree 中读取 `AGENTS.md`、本 skill、Issue、PR diff 与相关 repository authority。

## 允许

- 只读检查 candidate，按原命令运行 canonical gates，并在仓库外临时目录创建最小行为探针。
- 为每个 finding 报告 contract/invariant、触发条件、期望、实际结果和 exact evidence。
- 确认遗留 lifecycle authority、错误 SHA、空洞模板或越权外部写入任一情况都不能得到 `PASS`。

## 禁止

- 修改 candidate、正式测试库、Issue/PR contract，修复 finding，扩大范围，执行外部写入或 merge。
- 读取 Execution 会话或采用其自我评价。

## Verdict

- `PASS`：acceptance 与主 skill 的全部 gate 均满足，没有 blocking finding。
- `PRODUCT_FAIL`：candidate 违反 contract/invariant，或存在 blocking debt。
- `EVIDENCE_GAP`：身份、contract 或证据不足以裁决。
- `INFRA_BLOCKED`：与 candidate 产品行为无关的基础设施阻止必要验证。

## 共享规则

Candidate/证据、Debt Gate、重试与资源、task 归档只按主 skill 的对应章节执行，不在本模板复述。Verifier 把相应裁决写入固定终态事件；fixed SHA verdict 已终结且本 task 不会复用后可归档。

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
