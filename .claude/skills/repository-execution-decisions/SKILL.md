---
name: repository-execution-decisions
description: Apply user-established execution-process decisions inside the Ring-lang repository when coordinating candidate machine runs, review, and Discussion documentation changes. Do not apply outside this repository.
---

# Ring-lang Repository Execution Decisions

本skill只记录并应用用户对**当前Ring-lang仓库**执行流程的直接决定；不是全局个人偏好，也不得外推到其他仓库。一般治理仍以`docs/workflow.md`为准；两者冲突时，以这里记录的较新用户bedrock为准并同步修正文档。

## Candidate机器执行与review同启

- 一个fixed candidate的machine execution与针对该candidate的review必须同时启动；不得让机器等待review结束后才运行。
- Review未CLEAR前，机器结果保持quarantine，不得支持claim、下一命令、merge、bookkeeping或后续artifact。
- Review BLOCK时无论machine exit为何都丢弃该结果；不得以已消耗机器时间为理由复用。
- 该规则只改变launch ordering，不放宽EvidenceKey、资源、安全、命令、postcondition、no-retry或root复核门。

## Discussion纯文档修改默认无需lease

- Discussion的变更若严格限于`docs/**`，默认可直接在main修改并正常commit，无需事前query Steward或申请main mutation lease。
- Discussion本地核对HEAD、working tree和exact diff；出现真实重叠dirty path、merge conflict或scope扩到`docs/**`之外时，才进入reconcile/lease流程。
- 完成验证与commit后通知Steward exact SHA和scope，由Steward正常吸收；通知是事后交接，不是事前批准。
- 同一连续处理窗口内连续到来的多个docs修改请求应合并处理，只在最终batch完成后向Steward发送一次合并通知，不逐请求query或通知。
- 本例外不授权push、GitHub/外部状态、history rewrite或其他非文档mutation。
