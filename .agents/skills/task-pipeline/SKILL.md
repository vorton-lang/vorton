---
name: task-pipeline
description: Plan and advance Vorton repository goals through GitHub Milestones, Issue Planning, fresh Execution, and fresh Verification. Use when a request may become executable repository work, or for PR verification and merge routing; do not use for project status or unrelated read-only discussion.
---

# Vorton Task Pipeline

这是 Vorton 仓库唯一的任务 lifecycle authority。先读取根目录 `AGENTS.md`、全部 open GitHub Milestone 描述、当前 GitHub Issue 和任务涉及的仓库 authority；持久目标与目标顺序只认 Milestone，当前范围、设计、验收与依赖只认 Issue，完成历史只查 PR 与 Git。角色 prompt 是本 skill 的一部分，不是独立 authority：Execution 使用 [Executor 模板](references/executor.md)，Verification 使用 [Verifier 模板](references/verifier.md)。

## 工作单元与授权

- 一个用户确认的 Issue 是一个工作单元，同时只允许一个 active PR、一个 PR head branch 和一个 writer；PR 面向默认分支并使用 `Closes #N`。Issue 必须归入其验收首先依赖的最早目标。
- Planning 只可讨论、只读调查、创建或更新经用户确认的 Issue、机械路由 fresh task，以及在已有预授权下执行 merge；关闭或重新打开 Milestone 必须另有用户明确授权；不得修改仓库。
- 经用户确认的 Issue body 是 Execution 与 Verification 的 immutable contract；Issue 评论、PR、handoff 或 task 输出都不能追加或覆盖合同。范围、验收、依赖、优先级或重大设计需要改变时，当前 Readiness、Execution 与 candidate 立即失效，必须回到 Planning，由用户决定并更新 Issue body 后重开 fresh Readiness。
- Worktree 只是隔离 checkout；不得把调用会话的 working tree、index、未提交改动、摘要或结论当作输入。
- Milestone/Issue/PR 的描述与活动状态以及 PR/default-branch 的 exact remote head 必须直接从 GitHub 读取；仓库文件、diff 和 authority 应从本阶段 clean worktree 或已有本地 Git object 批量读取。只有缺少所需 object 或 contract 明确指向其它外部 authority 时，才联网取得 repository 内容，禁止逐文件远程抓取。
- 默认不读取 state reason 为 `not_planned` 的 closed Issue；只有用户明确要求历史调查时才可读取。
- 创建 fresh task 时，只有 `threadId` 可用于后续编排；`clientThreadId` 只表示 worktree setup pending，不得传给 thread tools，也不得用 `list_threads` 忙轮询。工具尚未提供 `threadId` 时等待 setup 完成或报告可见性阻塞。

## Milestone 与 Issue 路由

- 正常推进只允许 `Milestone → 当前 Issue → fresh Readiness → fresh Execution → fresh Verification` 的单向路由；失败或 contract 变化只按本 skill 的固定终态返回 Planning，不得把后阶段摘要变成前阶段输入。
- Planning 在选择工作前必须读取全部 open Milestone 描述，并按已确认的 `1/5 → 5/5` 顺序选择最早未关闭目标。多个未来 Milestone 可以同时 open，但前一 Milestone 未关闭时，不得为后一 Milestone 启动 Issue。
- Issue 归入其验收首先依赖的最早目标，文件修改位置不决定归属。后序工作发现前序 contract 缺陷时，立即暂停后序；由 Planning 取得用户确认后重新打开前序目标，不得在后序 Issue 中静默修补或让两个目标并行。
- 同一 Milestone 默认只推进一个 active Issue。只有各 Issue 的 fresh Readiness 均已 `CLEAR`、修改面相互独立且用户明确批准时才允许并行。
- Milestone 的自动 Issue 百分比不构成目标完成证明。最后一个已知 Issue 合并后，Planning 必须对目标结果做一次整体只读核对；只有用户确认目标完成并授权写入后，Planning 才可关闭 Milestone。
- Milestone 正文只保存目标与边界，不保存执行步骤、进度清单、旧 Issue 链接或未来实现方案；不得用本地 roadmap 或其它载体建立第二状态系统。

## Canonical reset 与历史污染红线

`a09ec8db5ffb673007d5ebc8a4509393fbeec18e` 是本仓库新规范的 canonical reset baseline。该 snapshot 中由 `AGENTS.md` 指定的 current authority、其 default-branch 后继版本，以及 reset 后新产生的当前 Milestone、Issue、PR 与 Git 事实可以在正常上下文直接读取。

Reset 前的 Issue、PR、commit revision、task、chat、评论、摘要与过程结论，以及 current authority 明确标为 legacy、迁移 oracle、superseded 或历史证据的载荷，即使仍被 tracked，也一律属于污染区。Planning、Readiness、Execution 与 Verification 不得把污染区内容直接读入、搜索进、摘录到或转述给其工作上下文。

确有必要检查污染区时，必须在不传入当前会话上下文的隔离 fresh fork/task 中进行；只可提供 repository full name、对象 stable identifier 与精确检查问题。隔离上下文的事实、引用、代码、路径、diff、方案、摘要和 agent 结论均不得回传。唯一允许穿过隔离边界的是用户在该隔离会话中明确确认的规范性决议，并且必须同时写明适用范围、排除项与是否授权执行；接收会话仍须从 current authority 独立取得一切当前事实。隔离检查不能充当 Readiness、Verification 或 merge 证据。

污染区内容一旦进入某个 lifecycle task 的工作上下文，该 task 立即失去继续承担 Planning、Readiness、Execution 或 Verification 的资格；不得靠忽略、总结或再次转述恢复，必须从 current authority 启动 clean replacement。

## 范围防火墙

Issue 只冻结可观察结果、必要边界与最小充分 gate，不预先加入没有当前失败证据的证明工程、通用验证设施或未来 hook。Readiness `CLEAR` 后，执行中发现的新事实只按以下路由处理，不得让合同随实现增长：

- 原合同内的局部实现缺陷保持验收不变，由当前 Execution 修复并只增加能独立杀死该缺陷的最小回归；若来自 Verification，则按既有 `PRODUCT_FAIL` 路由 fresh Execution。
- 实现路线失败但合同不变时，删除或废弃失败实现并对同一合同启动 fresh Execution；不得建立 compatibility bridge、双实现或临时第二 authority。
- 发现规范、公开语义、保证、依赖、抽象边界或验收需要改变时，第一次即停止并返回 Planning；不得边实现边编辑 Issue 或用评论追加条款。
- CLI、renderer、fuzz、LSP、benchmark 等相邻能力没有当前 consumer 时只报告并从当前工作丢弃；不得顺便实现、预留 hook 或自动建立未来 Issue。

## 三阶段

### Planning 与 Readiness

Planning 把当前 Milestone 的现实缺口收敛为 Issue。Planning 只向 fresh Readiness 提供 repository full name、当前 Milestone 编号或 URL、当前 Issue 编号或 URL、默认分支名称这些稳定标识符；不得提供或转述 Milestone/Issue body、评论、PR 状态、default-branch SHA、repository 内容、diff、摘要、旧任务结论或其它事实 snapshot。

Readiness 必须是以 Full access（`danger-full-access` 或宿主等价模式）启动的 fresh、只读 task。Full access 只提供独立访问 GitHub、网络与本机 Git objects 的能力，不扩大角色授权；任何 repository、GitHub 或外部状态写入都会使该 Readiness 无效。

Readiness 必须自行从 GitHub 读取当前 Milestone、Issue、关联 PR 与 remote default-branch head，并从 clean local checkout 或对应 Git object 批量读取 repository authority。它可以直接使用经核对 clean 且位于 remote default-branch head 的 main checkout；fresh 性来自独立任务与独立取证，不要求为只读阶段额外建立 worktree。Execution 与 Verification 仍必须使用各自的 clean worktree 和 exact SHA 隔离。

Full access 或独立 GitHub 读取不可用时，Readiness 必须 fail closed 并报告可见性或基础设施阻塞；不得接受 Planning snapshot、调用者 working tree 内容或离线转述作为 fallback。Readiness 输出 `CLEAR`、`REWRITE` 或 `BLOCKED`：`CLEAR` 只授权从其独立确定并报告的 start SHA 开始 Execution，不是 Verification 或 merge 证据；`REWRITE` 回到 Planning，更新 contract 后必须重开 fresh Readiness；`BLOCKED` 只表示上述访问能力不足。

Readiness 输出 `CLEAR` 后，Planning 必须按其报告的 start SHA 自动启动 fresh Execution；这里没有新的用户确认点。`REWRITE` 或 `BLOCKED` 才停止自动推进并返回 Planning。

任务进入 Readiness 前，Planning 使用实际可发现的 `grilling` skill 压测目标与 contract；已安装的 `grill-me` 只可作为调用入口，不能成为替代 authority。找不到 `grilling` 时 fail closed，不自行模拟。

Readiness 只输出：

```text
Issue: #N
Stage: READINESS
Status: CLEAR | REWRITE | BLOCKED
Start SHA: <40-hex default-branch commit or NONE when BLOCKED>
Confirmed facts:
- <fact, rewrite reason, or blocking reason>
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
- 归档可能清理 task worktree；Planning 只有确认 task 不可能再被合法恢复时才可归档。Executor 与 Verifier 的 exact 可恢复边界分别见对应角色模板。
- 归档不是 merge 前置条件。只有未变化 SHA 的 canonical gates、Debt Gate `PASS`、Verifier `PASS` 和已有 merge 预授权同时成立时，Planning 才可 merge。
- Merge 后，Planning 归档该 Issue 剩余的 Executor 与后台 task。只有用户能决定重置 Planning 会话，agent 只能凭具体证据建议。
