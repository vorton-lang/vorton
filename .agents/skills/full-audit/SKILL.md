---
name: full-audit
description: Run one bounded repository-wide correctness audit on a fixed snapshot. Do not use for ordinary PR verification or proactive security work.
---

# Full Audit

先读取 `AGENTS.md` 与 [`task-pipeline`](../task-pipeline/SKILL.md)。本 skill 只规定显式 repository-wide audit 的调查方法；Issue 创建与后续任务 lifecycle 仍完全由 `task-pipeline` 路由。

- 只审查一个 fixed default-branch commit 与一个显式 scope，不循环到 dry，也不实现修复。
- 对 material finding 使用至少两个独立只读视角，并分开 observed fact、inference 与 unknown。
- 普通 PR/diff verification 使用 `task-pipeline` 的 fresh Verifier，不使用本 skill。
- 除非用户针对当前具体问题明确要求，不执行 security/hardening audit。
- 每个 confirmed finding 只准备一个使用当前 Issue 模板的草案，包含影响、复现、affected SHA 与 acceptance；Planning 在用户确认准确草案或 batch manifest 后才可创建 Issue。

最终只报告 confirmed findings、被证伪候选及等待确认的 exact Issue drafts。
