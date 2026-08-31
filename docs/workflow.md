# Vorton 单人项目工作流

本文件只保存当前有效规则。完成历史、失败实验和旧流程留在Git，不在这里累积。

任何想在长期文档中记录日期化进展、实验过程、失败流水、阶段总结或“以后回来更新”的内容，都是危险信号：不要写。过程只进Git、Issue或PR；文档直接保持当前真值，不叠加supersede日记。

## 当前阶段

- 当前只做迁仓与外部宿主编译器规划，不执行merge、push、transfer、Issue创建或Rust实现。
- 计划先以normal merge commit把`codex/ownership-sprime-first`合回`main`，再把唯一main迁移到`vorton-lang/vorton`。
- 迁仓后以Rust实现compiler；先做`source → token → AST → diagnostic`最小纵切。只有真实Rust阻塞才重新讨论宿主语言。
- dc91、5d57、tracked C和历史candidate只作oracle；不再恢复Ring self-host、bridge、SCU、publicization或generated-C路线。
- #268/#269保持未完成，迁仓后继续。

## 当前Agent模式

- 独立Steward session暂时禁用，不创建、不唤醒、不传包；所有用户沟通和执行控制都留在当前root session。
- Root统一负责规划、Issue/PR编排、review、验证、merge和状态汇报。
- 非常小且路径唯一的修改可由root直接完成；其它具体工作必须拆成明确scope交给当前thread的subagent，subagent结果回root统一对账。
- 只有root向用户沟通、修改GitHub状态或形成最终claim；subagent不建立平行真值。

## 唯一工作链

迁仓后：

```text
Issue #N → 一个active PR → PR head branch → merge → Issue自动关闭
```

- GitHub Issue取代`docs/backlog.md`和`docs/audit-report.md`作为活动任务真值。
- 新工作只使用GitHub分配的Issue编号。导入时废弃B/A/D编号；旧编号不进入Issue标题，也不作为新编号保存。
- Issue和PR标题禁止手工编号、序号前缀或类似编号；只使用描述性标题和GitHub自动编号。
- 创建任何Issue前，必须向用户展示准确标题、正文和数量并取得明确确认；批量导入按完整manifest一次确认。
- 每个Issue只有一个active实现PR。大任务先拆Issue，不并行多个实现PR。
- PR正文写`Closes #N`；merge后由GitHub自动关闭Issue。
- Branch优先从Issue的Development入口创建，使GitHub自动关联；PR面向默认branch并写`Closes #N`。迁仓时启用Automatically delete head branches。
- Worktree只是本机可选checkout方式，不是任务、状态、authority或handoff真值。

迁仓前，`docs/backlog.md`和`docs/audit-report.md`仅作Issue导入源；导入核对完成后冻结，不再手工维护。

## Session与Issue

- Session用于讨论、澄清和即时协作；Issue保存scope、status和acceptance。
- 用户在Session拍板后，Discussion在开始实现或merge前向对应Issue同步一条摘要；用户无需重复。
- Agent恢复工作时先读取Issue最新正文与评论。
- 两渠道出现不清楚的冲突就直接问用户，不建设cursor、命令语法、webhook或自动双向同步。
- 普通状态不写Issue评论；linked PR和merge结果已经表达进度。Issue评论只保留用户决定和confirmed blocker，不写命令流水、subagent状态、轮询或长日志。

## 本机执行

- 本机是主要agent执行面；GitHub只承载Issue、PR、CI和Git历史。
- 直接使用用户现有`git`/`gh`身份完成已批准操作；不建设GitHub App、broker、webhook、machine user或常驻服务。
- 一个Issue只有一个写owner。Reviewer只读固定PR head SHA。
- Fixed candidate的machine execution与review同时启动。Machine FAIL优先形成开发反馈；PASS在review CLEAR前保持quarantine；Review BLOCK使PASS失效。
- 未知时长任务不得使用预测式kill wall。资源门、输出门和用户明确deadline仍有效。
- 结果绑定同一EvidenceKey：source SHA、artifact/patch SHA、producer command/receipt、observed stage。不同SHA结果不得拼接。

## 状态由GitHub推导

- Open Issue且没有linked PR：待做。
- Linked draft PR：进行中。
- Linked ready-for-review PR：review。
- PR merge到默认branch：`Closes #N`自动关闭Issue，表示完成。
- PR未merge而关闭：Issue保持open。
- 只有`blocked`需要额外label；它只冻结该Issue。
- 如果使用GitHub Project，只启用auto-add与closed/merged→Done内建自动化，Project不成为第二状态真值。

## 最小标签

- Issue恰好一个type：`type:bug|feature|design|maintenance|audit`。
- Issue恰好一个priority：`priority:p0|p1|p2|p3`。
- Issue可有多个area：`area:frontend|types-effects|ir-ownership|backend-runtime|tooling|docs`。
- 只有异常状态使用`blocked`。
- 不创建status、wip、owner、phase、has-pr、passed/failed或手工编号标签。
- PR不复制Issue标签；area标签若需要，只按changed paths机械生成。

## 用户保留决定

以下事项由用户拍板：

- 语言公开语义、语法、ownership/effect保证；
- breaking API/ABI和平台支持；
- 新P0、重大路线和显著投入；
- repository transfer/rename、外部写入、release、历史重写和不可恢复删除；
- 创建Issue。

普通实现、bugfix、测试、review和内部重构在已确认Issue范围内自主推进。

Discussion当前可直接提交纯`docs/**`规划修改；其它main mutation只有用户明确要求时执行。迁仓后所有修改统一走Issue→PR。

## Security禁入

本仓库是单人项目。不得主动规划或建设GitHub App、权限矩阵、CODEOWNERS、安全ruleset、签名、供应链扫描、sandbox、secret基础设施、untrusted-fork模型或其它security/hardening工作。

任何security提议必须先回答：

1. 是否存在当前可复现问题或用户明确需求？
2. 不做是否会阻塞当前真实consumer？

任一无证据即拒绝，不立项、不预留hook。Compiler crash、wrong-code、UB、数据损坏和ownership/RC错误按普通correctness处理，不得改名为security问题。

## 迁仓计划

当前最小计划只有四步：

1. 隔离rehearsal后用normal merge commit把authority合回main；不squash、rebase或rewrite。
2. 生成全部refs/notes/tags的bundle和迁移manifest。
3. 用户另行批准后执行GitHub transfer+rename，更新remote和最小CI。
4. 展示活动Issue导入manifest并取得用户确认；脚本逐项保存GitHub返回的Issue URL并核对输入/输出数量，中断后先对账再继续。创建完成后冻结Markdown看板；之后另行批准才开始Rust纵切。

## 迁仓验收

- authority已正常merge进唯一main；
- bundle和manifest可解析全部durable refs/notes/tags；
- `vorton-lang/vorton`保留完整ancestry，main与远端SHA一致；
- 活动Issue数量和依赖与确认manifest一致；
- Markdown看板冻结且不存在第二手工真值；
- clean clone可运行基础CI；
- 未创建未经用户确认的Issue；
- 仓库已启用Automatically delete head branches，merged PR branch由GitHub删除。

## 用户状态摘要

用户询问整体状态时只报告：当前门、已有durable结果、下一门、主要风险、需要用户拍板。默认不报告命令等待、subagent状态、普通重试或原始日志。
