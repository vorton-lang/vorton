---
name: repository-execution-decisions
description: Apply user-established execution-process decisions inside the Ring-lang repository when coordinating candidate machine runs, review, and Discussion documentation changes. Do not apply outside this repository.
---

# Ring-lang Repository Execution Decisions

本skill只记录并应用用户对**当前Ring-lang仓库**执行流程的直接决定；不是全局个人偏好，也不得外推到其他仓库。一般治理仍以`docs/workflow.md`为准；两者冲突时，以这里记录的较新用户bedrock为准并同步修正文档。

## Candidate机器执行与review同启

- 一个fixed candidate的machine execution与针对该candidate的review必须同时启动；不得让机器等待review结束后才运行。
- Machine terminal FAIL后，root立即读取exact failure作为development feedback并生成下一candidate，无需等待review；machine error优先于review finding。
- In-flight review继续，confirmed blocker不会被豁免；修复machine failure后，任何PASS支持下游artifact、merge、bookkeeping或claim前必须完成reconcile。
- Machine PASS保持quarantine直到Review CLEAR；Review BLOCK时PASS无效并丢弃，不得以已消耗机器时间为理由复用。
- 该规则只改变launch ordering，不放宽EvidenceKey、资源、安全、命令、postcondition、no-retry或root复核门。

## 未知时长任务不得使用预测式kill wall

- Point estimate、历史相似任务耗时和人工检查点只用于排程、观测与状态汇报，不得直接变成进程终止条件。
- 对尚无可靠实测上界的construction、bootstrap crossing、fixed-point或长门，不得拍脑袋设置30/60/90分钟等任意wall并在到时杀进程。
- Harness若技术上必须提供有限`wall_seconds`，只能使用用户明确给出的整体deadline或当前目标剩余窗口；没有这类deadline时应使用不构成实际约束的充分大值。
- Memory、输出、明确的安全资源门保持独立有效；不得因取消预测式wall而放宽这些门。
- 已确认live的任务不得仅为调整wall而中断。若既有错误wall已造成纯超时，必须保存terminal receipt，并以相同fixed输入、全新输出和非预测式deadline重新执行；不得拼接半产物。

## Discussion纯文档修改默认无需lease

- Discussion的变更若严格限于`docs/**`，默认可直接在main修改并正常commit，无需事前query Steward或申请main mutation lease。
- Discussion本地核对HEAD、working tree和exact diff；出现真实重叠dirty path、merge conflict或scope扩到`docs/**`之外时，才进入reconcile/lease流程。
- 完成验证与commit后通知Steward exact SHA和scope，由Steward正常吸收；通知是事后交接，不是事前批准。
- 同一连续处理窗口内连续到来的多个docs修改请求应合并处理，只在最终batch完成后向Steward发送一次合并通知，不逐请求query或通知。
- 本例外不授权push、GitHub/外部状态、history rewrite或其他非文档mutation。

## 单人项目：security默认禁入

- 本仓库当前是单人项目。不得主动建设或规划GitHub App、token broker、webhook服务、权限矩阵、CODEOWNERS、安全ruleset、签名、供应链扫描、sandbox、untrusted-fork执行模型或其它security/hardening基础设施。
- 任何以security、权限隔离、威胁模型、最小权限、secret管理或攻击面为理由的新增工作，必须先两次反问：是否存在当前可复现问题或用户明确需求；不做是否会阻塞当前真实consumer。任一回答无证据即默认拒绝，不立项、不预留hook、不扩大治理。
- 本机仍是agent主要执行面；GitHub初期只使用用户现有的`git`/`gh`身份完成已批准操作，不创建额外机器身份或常驻服务。
- 不得把compiler crash、错误诊断、wrong-code、UB、数据损坏或ownership/RC错误改称security问题来绕过本禁令；这些继续按普通correctness处理。

## 迁仓后的唯一工作链

- GitHub Issue取代`docs/backlog.md`/`docs/audit-report.md`作为活动任务真值；迁仓后新任务只使用Issue编号，不再分配B/A/D编号。旧编号仅保存在导入Issue正文中供历史检索。
- 唯一状态链为`Issue #N → 一个active PR → PR head branch`。PR正文写`Closes #N`，merge后由GitHub自动关闭Issue；大任务先拆成多个Issue，不给一个Issue并行多个实现PR。
- Worktree只是本机可选checkout方式，不是任务、状态、authority或handoff真值，不进入用户治理模型。
- Session用于讨论；Issue保存scope/status/acceptance。用户在Session拍板后只同步一条Issue摘要，用户无需重复。

## 文档禁止写日记

- 每当想把日期化进展、实验过程、失败流水、命令记录、阶段总结或“以后回来更新”的说明写进长期文档时，立即把它视为危险信号并停止。
- 长期文档只写当前仍有效的设计、规则、scope和acceptance。过程进入Git commit、Issue或PR；完成历史只查Git。
- 不创建需要未来人工回头修订的状态段落。真值变化时直接改成新真值，不在正文叠加supersede日记。

## 优先让GitHub基础设施表达不变量

- GitHub已经提供唯一编号、Issue关联branch/PR、closing keyword和merged branch自动删除时，禁止再维护手工编号、映射表、重复状态或人工清理清单。
- 工作状态直接由GitHub对象推导：open Issue且无PR=待做；linked draft PR=进行中；ready PR=review；merged PR自动关闭Issue=完成。只有`blocked`需要额外标记。
- Branch优先从Issue的Development入口创建，使GitHub自动关联；PR面向默认branch并写`Closes #N`。仓库启用Automatically delete head branches。
- Project若使用，只作GitHub对象的自动视图，启用auto-add和closed/merged→Done；不得成为第二状态真值。
- 批量Issue导入只消费用户确认过的固定manifest；创建脚本逐项保存GitHub返回的Issue URL并核对输入/输出数量。中断后先按已返回URL对账再继续，禁止盲目重跑制造重复。

## 最小标签

- Issue只使用：恰好一个`type:bug|feature|design|maintenance|audit`，恰好一个`priority:p0|p1|p2|p3`，零到多个`area:frontend|types-effects|ir-ownership|backend-runtime|tooling|docs`，以及例外`blocked`。
- 不创建status、wip、owner、phase、has-pr、passed/failed或手工编号标签；这些由Issue/PR/assignee/milestone/Checks表达。
- PR不手工复制Issue的type/priority/blocked标签；如需PR area标签，只允许根据changed paths机械生成。
