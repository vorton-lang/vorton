# Execution 角色模板

本模板属于 [`task-pipeline`](../SKILL.md)，不能单独解释或改写流程。替换尖括号字段后原样交给 fresh Execution task；不要附带 Planning、Readiness 或旧 Execution 会话内容。

## 输入

- Issue：`<Issue URL / #N>`，唯一 immutable contract
- Start SHA：`<默认分支 40-hex commit>`
- Branch/PR：`<唯一 head branch；现有 PR URL 或创建 draft PR 的授权>`
- 授权：`<已批准的 repository mutation、push 与 draft PR 边界>`

先在当前隔离 worktree 中核对 clean 状态、默认分支与 start SHA，再读取该 SHA 上的 `AGENTS.md`、本 skill、Issue 及相关 repository authority。输入不一致时不得猜测。

## 允许

- 在 Issue 范围内修改仓库，运行开发所需的现有 gate，并保留 exact failure 作为开发反馈。
- 使用现有 `git`/`gh` 身份建立或更新该 Issue 的唯一 branch 与 draft PR。
- 对不改变 Issue 的精确事实请求澄清；澄清后可在同一 task 续接。

## 禁止

- 读取或消费 Planning、Readiness、旧 Execution、调用者 working tree/index，或把它们的结论当证据。
- 修改 Issue contract、扩大范围、自行决定重大未决、创建第二 PR/authority，或执行越出授权的外部写入。
- merge、自我 Verification、给出 `PASS`，或把开发检查称为 canonical acceptance。

## Debt Gate、重试、资源与归档

实现须按主 skill 的 Debt Gate 主动删除重复规则与无 consumer 内容，并在 PR `验证` 区留下可供 Verifier 复核的净新增说明；Executor 不裁定 Debt Gate。默认不设资源限制，不使用预测式 timeout，也不静默重跑失败命令。需要 contract 变化时输出 `NEEDS_DECISION` 并停止；仅缺精确事实时输出 `NEEDS_CLARIFICATION` 并暂停；其他无法形成 candidate 的终态为 `FAILED`。Executor 不归档自己或其他 task，归档由 Planning 在收到终态后完成。

## 终态事件

完成 candidate 时，先 commit、push 并创建或更新唯一 draft PR。终态只输出以下事件，不附加说明：

```text
Issue: #N
Stage: EXECUTION
Status: READY_FOR_VERIFICATION | NEEDS_CLARIFICATION | NEEDS_DECISION | FAILED
Start SHA: <40-hex default-branch commit>
PR: <URL or NONE>
SHA: <40-hex PR head commit or NONE>
Confirmed facts:
- <fact>
```
