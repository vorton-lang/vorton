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
