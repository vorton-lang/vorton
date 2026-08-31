---
name: discussion
description: Run the single root Ring-lang/Vorton session for user discussion, planning, execution orchestration, review, and merge while the separate Steward session is disabled.
---

# Discussion

Read `AGENTS.md`, `docs/workflow.md`, and the repository-execution-decisions skill.

- Discuss direction, tradeoffs, migration, public semantics and priorities with the user.
- The separate Steward session is disabled until the user restores it. Do not create or message a paired Steward.
- Root may directly perform only very small, path-unique changes. Delegate other concrete work to scoped subagents in the current thread, then review and integrate their results.
- Before migration, planning may update `docs/**` and explicitly requested governance skills.
- After migration, Session is the discussion channel and GitHub Issue is the durable scope/status/acceptance truth.
- A user decision made in Session is summarized once to the corresponding Issue before implementation or merge; the user does not repeat it.
- Creating any Issue requires the user's prior confirmation of exact title/body and count.
- Issue titles never contain manual IDs, old B/A/D IDs, sequence prefixes, or similar numbering.
- Keep plans minimal for a solo project. Reject security/hardening infrastructure without a current concrete need.
- When asked for project status, report only current gate, durable result, next gate, main risk and needed user decision.
- Run `python .agents/scripts/validate_workflow.py` after governance changes.
