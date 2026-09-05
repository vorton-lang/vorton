# Vorton GitHub 工作入口

本文件只保存 GitHub 载体、模板与标签入口。Planning、Readiness、Execution、Verification、verdict、merge 和 task 归档只以 [`task-pipeline`](../.agents/skills/task-pipeline/SKILL.md) 为 authority，不在这里复制。

## 活动真值

- [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones) 保存持久目标与目标顺序；Milestone 正文只保存目标与边界，不保存执行步骤、进度清单、旧 Issue 链接或未来方案。
- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 保存当前范围、设计、验收与依赖；阶段采用的原生正文修订是 immutable execution contract，采用与变更路由只按 `task-pipeline`。
- PR 和 Git 保存实现与完成历史；Milestone 的自动 Issue 百分比不是目标完成证明。
- Worktree、Codex task、GitHub Project 与本地文件都不是平行状态 authority。Project 若启用，只作 GitHub 对象视图。
- 不建立本地 roadmap、backlog 或其它平行状态系统；工作项不使用仓库内自建编号。

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

Governance CI 在 Ubuntu 上依次运行 current-tree 结构检查、Rust format、Clippy、workspace tests 与 Git whitespace gate。精确命令以 [workflow](../.github/workflows/test.yml) 为准，不在本页复制。
