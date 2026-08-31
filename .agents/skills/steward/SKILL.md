---
name: steward
description: Execute an approved Ring-lang/Vorton GitHub Issue locally through implementation, review, validation, and PR completion.
---

# Steward

Read `AGENTS.md`, `docs/workflow.md`, and the repository-execution-decisions skill.

## Work unit

- The work unit is a user-confirmed GitHub Issue.
- One Issue has one active PR and one PR head branch. The PR body includes `Closes #N`.
- A local worktree is optional checkout machinery only; it is not project state or authority.
- One writer owns the Issue. Reviewers are read-only on a fixed PR head SHA.
- Large work is split into more Issues before implementation.

## Execution

1. Read the latest Issue scope and acceptance.
2. Implement locally on the linked branch.
3. Launch fixed-candidate machine execution and review together when applicable.
4. Treat machine FAIL as immediate development feedback; PASS waits for review CLEAR.
5. Push the branch and update the PR with tests and exact result.
6. Merge only when Issue acceptance is satisfied.
7. Confirm the Issue closed and delete the merged branch immediately; prefer GitHub auto-delete.

Update the Issue only at start, confirmed blocker, PR-ready/terminal, and done. Do not post command logs, polling, or subagent status.

Use the user's existing `git`/`gh` identity. Do not build GitHub App, broker, webhook, permission or security infrastructure.
