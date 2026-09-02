# Vorton GitHub 工作入口

本文件只保存 GitHub 载体、模板与标签入口。Planning、Readiness、Execution、Verification、verdict、merge 和 task 归档只以 [`task-pipeline`](../.agents/skills/task-pipeline/SKILL.md) 为 authority，不在这里复制。

## 活动真值

- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 保存活动范围、状态、验收、依赖与用户决定；PR 和 Git 保存实现与完成历史。
- Worktree、Codex task、GitHub Project 与本地文件都不是平行状态 authority。Project 若启用，只作 GitHub 对象视图。
- 迁仓前 Markdown backlog/audit 保持删除；新工作不分配 B/A/D 编号。

## 模板

- 可执行工作使用唯一 [Issue 模板](../.github/ISSUE_TEMPLATE/work-item.md)。
- 实现提交使用唯一 [PR 模板](../.github/pull_request_template.md)。
- 空白 Issue 已关闭；尚不可执行的 post-0.1 想法进入 [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1)，出现真实 consumer 后再由 Planning 请求用户确认 Issue。

## 标签

Issue 恰好选择一个 type、一个 priority，并可选择零到多个 area；`blocked` 只表示异常冻结：

- type：`type:bug`、`type:feature`、`type:design`、`type:maintenance`、`type:audit`
- priority：`priority:p0`、`priority:p1`、`priority:p2`、`priority:p3`
- area：`area:frontend`、`area:types-effects`、`area:ir-ownership`、`area:backend-runtime`、`area:tooling`、`area:docs`
- exception：`blocked`

不创建 status、wip、owner、phase、has-pr 或 passed/failed 标签。PR 不复制 Issue 标签；如需 area 标签，只按 changed paths 机械生成。

## 当前 CI

当前 CI 只运行 `python .agents/scripts/validate_naming.py` 与 `python .agents/scripts/validate_workflow.py`。Rust workspace 与 compiler gate 只有在对应 Issue 实现后才成立。
