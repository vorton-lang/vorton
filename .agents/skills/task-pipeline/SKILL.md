---
name: task-pipeline
description: Plan and advance Vorton repository changes through GitHub Issue Planning, fresh Execution, and fresh Verification. Use when a request may become executable repository work, or for PR verification and merge routing; do not use for project status or unrelated read-only discussion.
---

# Vorton Task Pipeline

这是 Vorton 仓库唯一的任务 lifecycle authority。先读取根目录 `AGENTS.md`、最新 GitHub Issue 和任务涉及的仓库 authority；活动范围、状态与验收只认 Issue/PR，完成历史只查 PR 与 Git。角色 prompt 是本 skill 的一部分，不是独立 authority：Execution 使用 [Executor 模板](references/executor.md)，Verification 使用 [Verifier 模板](references/verifier.md)。

## 工作单元与授权

- 一个用户确认的 Issue 是一个工作单元，同时只允许一个 active PR、一个 PR head branch 和一个 writer；PR 面向默认分支并使用 `Closes #N`。
- Planning 只可讨论、只读调查、创建或更新经用户确认的 Issue、机械路由 fresh task，以及在已有预授权下执行 merge；不得修改仓库。
- Issue 是 Execution 与 Verification 的 immutable contract。范围、验收、依赖、优先级或重大设计需要改变时，必须回到 Planning，由用户决定并更新 Issue。
- Worktree 只是隔离 checkout；不得把调用会话的 working tree、index、未提交改动、摘要或结论当作输入。

## 三阶段

### Planning 与 Readiness

Planning 把原始目标收敛为 Issue。Readiness 必须是 fresh、只读 task，只接收原始目标、最新 Issue 和默认分支事实，不接收 Planning 结论或旧 task 内容；它输出 `CLEAR` 或 `REWRITE`。`CLEAR` 只授权从所报 start SHA 开始 Execution，不是 Verification 或 merge 证据；`REWRITE` 回到 Planning，更新 contract 后必须重开 fresh Readiness。

任务进入 Readiness 前，Planning 使用实际可发现的 `grilling` skill 压测目标与 contract；已安装的 `grill-me` 只可作为调用入口，不能成为替代 authority。找不到 `grilling` 时 fail closed，不自行模拟。

Readiness 只输出：

```text
Issue: #N
Stage: READINESS
Status: CLEAR | REWRITE
Start SHA: <40-hex default-branch commit>
Confirmed facts:
- <fact or rewrite reason>
```

### Execution

Execution 必须是 fresh task，在 start SHA 对应的 clean worktree 中由唯一 writer 完成 Issue 范围内的修改、开发反馈门、commit、push 与唯一 draft PR。它不得读取 Planning、Readiness、旧 Execution 或调用者 worktree/index，不得修改 contract、替用户解决重大未决、merge，或把自己的开发检查称为 Verification/PASS。输入、权限、停止条件与固定终态见 [Executor 模板](references/executor.md)。

### Verification

Verification 必须是 fresh、read-only task，在 PR head SHA 对应的 clean worktree 上独立核对 Issue、canonical gates 与 Debt Gate。它不得读取 Execution 会话、修改 candidate/测试库/Issue、修复 finding、扩大 contract、merge 或静默重跑。允许在仓库外临时目录编写和运行行为探针。输入、判定与固定终态见 [Verifier 模板](references/verifier.md)。

## Candidate 与证据

- Candidate 只认 PR head 的 exact 40-hex commit SHA。Verifier 开始与结束都核对 PR head；任何 repository 内容变化都必须产生新 commit，并使旧 Verification、canonical gate 与 Debt Gate 证据失效。
- 所有 gate 结果必须绑定同一 SHA、命令、环境和 observed stage；不得拼接不同 candidate 的输出，也不得把 static inspection 升级为 behavior claim。
- SHA 错误、candidate 不可重现、缺 canonical gate 或证据身份不完整都不能得到 `PASS`。

## Debt Gate

对净新增代码、测试、文档、依赖、配置和抽象逐项说明当前 consumer、不可替代作用及更小替代为何不足。Verifier 必须实际尝试删除或合并净新增内容：结构性、长期或影响验证的债务为 `BLOCK`；局部、可逆且不削弱 contract 的品味问题只记录，不阻塞。Finding 必须给出 contract/invariant、触发条件、期望与实际结果。

## 重试与资源

- 默认不设置 task-local 资源限制。只有实测失败、实测超时或相同且已记录的 case 才能按证据设置限制；未知时长不能用预测式 wall timeout。
- 不静默重跑失败命令。先保留 exact failure，再按终态路由：Execution 的事实澄清可在 Issue 不变时用同一 task 续接；重大决策必须更新 Issue 并重开 fresh Execution。
- `PRODUCT_FAIL` 进入 fresh Execution；`EVIDENCE_GAP` 回到 Planning；`INFRA_BLOCKED` 只处理已确认的基础设施阻塞。任一修复产生新 SHA 后重开 fresh Verification。

## Merge 与归档

- Readiness、Execution、Verification 的 task ID 都记录在 PR 的 `验证` 区；普通命令流水不写 Issue 评论。
- Verifier 可先对 fixed candidate 给出 verdict，其 `PASS` 不依赖该 Verifier task 自己尚未发生的归档。
- Planning 收到终态后查询并归档本 Issue 所有已完成或已失效后台 task；归档完成是 merge 的机械前置条件。只有用户能决定重置 Planning 会话，agent 只能凭具体证据建议。
- 只有未变化 SHA 的 canonical gates、Debt Gate `PASS`、Verifier `PASS`、task 归档完成以及已有 merge 预授权同时成立时，Planning 才可 merge。
