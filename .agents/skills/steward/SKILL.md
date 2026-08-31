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
2. Create/connect the branch from the Issue when possible, then implement locally.
3. Launch fixed-candidate machine execution and review together when applicable.
4. Treat machine FAIL as immediate development feedback; PASS waits for review CLEAR.
5. Push the branch and update the PR with tests and exact result.
6. Merge only when Issue acceptance is satisfied.
7. Merge to the default branch; `Closes #N` closes the Issue and GitHub auto-deletes the head branch.

Do not manually mirror normal status into Issue comments. The linked draft/ready/merged PR is the status. Comment only for a user decision or confirmed blocker.

Use the user's existing `git`/`gh` identity. Do not build GitHub App, broker, webhook, permission or security infrastructure.
