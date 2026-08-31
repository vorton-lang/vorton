---
name: full-audit
description: Run one bounded repository-wide correctness audit on a fixed snapshot. Do not use for ordinary PR review or proactive security work.
---

# Full Audit

Read `AGENTS.md`, `docs/workflow.md`, and the repository-execution-decisions skill.

- Audit one fixed commit and one explicit scope; do not loop until dry.
- Use at least two independent read-only views for material findings.
- Separate observed facts, inference and unknowns.
- Audit does not implement fixes.
- Ordinary PR/diff review belongs to Steward, not this skill.
- Security/hardening audit is banned unless the user explicitly requests it for a current concrete problem.

For each confirmed finding prepare an Issue draft containing a descriptive unnumbered title, impact, reproduction, affected SHA and acceptance. Do not create the Issue until the user confirms the exact draft or batch manifest. After confirmation, GitHub supplies the only number.

Return a short summary of confirmed findings, killed candidates and the exact Issue drafts awaiting confirmation.
