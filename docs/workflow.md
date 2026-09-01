# Vorton 单人项目工作流

本文件只保存当前仍有效的执行规则。仓库已经迁移到 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)；活动范围、状态与验收只由 GitHub Issue/PR 表达，完成历史只查 Git。

日期化进展、实验过程、失败流水、命令记录和阶段总结不得写入长期文档。过程进入 Session、Issue、PR 或 Git；真值变化时直接修改当前规则，不叠加 supersede 日记。

## 当前工程路线

- 当前实现路线是在 Rust 宿主上重建 Ring 编译器，先闭合 `source → token → AST → diagnostic` 最小纵切，再按 Issue 推进 checker、IR、ownership、C11 后端、CLI 与发布。
- Rust workspace、compiler build 与测试门只有在对应实现进入仓库后才成立；当前 CI 不宣称 compiler green。
- 旧 Ring compiler、tracked C、C11 self-host/fixed point、runtime 与旧测试只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 bootstrap、CI 或发布 authority。
- Self-host 已后置；只有语言与外部宿主编译器稳定后，用户作出新决定才可恢复。

## 活动真值与唯一工作链

唯一状态链是：

```text
Issue #N → 一个 active PR → PR head branch → merge → Issue 自动关闭
```

- GitHub Issue 是 scope、status、acceptance、依赖与用户决定摘要的唯一活动真值。
- 每个 Issue 同时只能有一个 active 实现 PR。任务需要并行实现时，先拆成多个 Issue。
- PR 面向默认 branch，正文写 `Closes #N`；merge 后由 GitHub 关闭且只关闭对应 Issue。
- Branch 优先从 Issue 的 Development 入口创建以建立关联；仓库启用 Automatically delete head branches，merge 后由 GitHub 删除 head branch。
- Worktree 只是本机可选 checkout 方式，不是任务、状态、authority 或 handoff 真值。
- GitHub Project 若启用，只作 GitHub 对象的自动视图，不保存第二套状态。
- `docs/backlog.md` 与 `docs/audit-report.md` 已冻结。迁仓后的新工作不分配 B/A/D 编号，也不要求同步 Markdown 看板或本地元数据。

## GitHub 状态解释

- Open Issue 且没有 linked PR：待做。
- Linked draft PR：进行中。
- Linked ready-for-review PR：review。
- PR merge 到默认 branch：`Closes #N` 自动关闭 Issue，表示完成。
- PR 未 merge 而关闭：Issue 保持 open。
- 只有异常冻结使用 `blocked` label；普通状态由 Issue/PR 对象推导，不创建 status、wip、owner、phase、has-pr 或 passed/failed label。

## Session、Ideas 与 Issue

- Session 用于讨论、澄清、即时协作与用户拍板，不保存可执行状态。
- 用户在 Session 拍板后，root 在开始实现或 merge 前向对应 Issue 汇总一条决定摘要；用户无需重复。普通命令流水、轮询、subagent 状态与长日志不写 Issue 评论。
- [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 只保存尚不可执行的 post-0.1 想法、可能价值与升级条件，不写实现状态或验收清单。
- 想法出现真实 consumer 后，先向用户展示正式 Issue 的准确标题与正文并取得确认；创建成功后在原 Discussion 回复 Issue 链接。
- Issue 只保存已经可执行的目标、问题、范围、验收、依赖及必要用户决定。Session、Discussion 与 Issue 出现不清楚的冲突时直接问用户，不建设自动双向同步。

## Issue 创建规则

中文单一 Markdown 模板固定为以下五段，顺序不可变，不增加状态、编号或其它并列字段：

1. `目标`
2. `当前问题`
3. `范围`
4. `验收`
5. `依赖`

- 标题只写描述性名称，不加手工编号、序号前缀或 B/A/D 编号。
- 创建任何 Issue 前，必须向用户展示准确标题、正文与数量并取得明确确认；批量导入按完整固定 manifest 一次确认。
- Issue 恰好使用一个 `type:bug`、`type:feature`、`type:design`、`type:maintenance` 或 `type:audit`。
- Issue 恰好使用一个 `priority:p0`、`priority:p1`、`priority:p2` 或 `priority:p3`。
- Issue 可使用零到多个 `area:frontend`、`area:types-effects`、`area:ir-ownership`、`area:backend-runtime`、`area:tooling`、`area:docs`，以及例外 `blocked`。
- PR 不复制 Issue 的 type、priority 或 blocked label；如需 PR area label，只按 changed paths 机械生成。

## 批量导入

- 导入只消费用户确认过的固定 manifest，不在运行时扩写、重排或推断新 Issue。
- 每次创建都立即保存 GitHub 返回的 Issue URL，并核对 manifest 输入数、成功 URL 数与最终唯一 Issue 数。
- 中断恢复时先按已保存 URL 与远端 Issue 对账，只创建尚无返回 URL 的条目；禁止盲目重跑制造重复。
- 导入完成后，活动状态只查 GitHub Issue/PR；旧 Markdown 编号只留在冻结历史或已导入正文中供检索。

## 本机执行与验证

- 本机是主要 agent 执行面；GitHub 承载 Issue、PR、CI 与 Git 历史。使用用户现有 `git`/`gh` 身份完成已批准操作，不建设额外身份或常驻同步服务。
- 当前 root Session 统一负责用户沟通、Issue/PR 编排、review、验证、merge 与最终 claim；subagent 只处理 root 指定的明确 scope，不建立平行真值。
- 一个 Issue 只有一个 writer。Reviewer 只读固定 PR head SHA。
- Fixed candidate 的 machine execution 与 review 同时启动。Machine FAIL 立即作为开发反馈；Machine PASS 在 review CLEAR 前保持 quarantine，Review BLOCK 使该 PASS 失效。
- 结果绑定同一 EvidenceKey：source SHA、artifact/patch SHA、producer command/receipt、observed stage。不同 SHA 的结果不得拼接。
- 未知时长任务不得使用预测式 kill wall；资源门、输出门和用户明确 deadline 仍然有效。
- 当前 CI 只运行 `python .agents/scripts/validate_workflow.py`，验证仓库治理真值。Rust workspace 落地后，再由对应 Issue 添加真实 Cargo/compiler gate。

## 用户保留决定

以下事项由用户拍板：

- 语言公开语义、语法、ownership/effect 保证；
- breaking API/ABI 与平台支持；
- 新 P0、重大路线与显著投入；
- repository transfer/rename、外部写入、release、历史重写与不可恢复删除；
- 创建 Issue。

已确认 Issue 内的普通实现、bugfix、测试、review 与内部重构可自主推进。任何范围、依赖、优先级或验收变化都先回到对应 Issue 和用户决定，不在实现中静默扩张。

## Security 禁入

本仓库是单人项目。没有当前可复现问题或用户明确需求时，不主动规划 GitHub App、权限矩阵、CODEOWNERS、安全 ruleset、签名、供应链扫描、sandbox、secret 基础设施、untrusted-fork 模型或其它 security/hardening 工作。Compiler crash、wrong-code、UB、数据损坏和 ownership/RC 错误按普通 correctness 处理。

## 用户状态摘要

用户询问整体状态时只报告当前门、已有 durable 结果、下一门、主要风险和需要用户拍板的事项。默认不报告命令等待、subagent 状态、普通重试或原始日志。
