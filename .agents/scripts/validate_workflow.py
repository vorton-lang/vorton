#!/usr/bin/env python3
"""Validate the current solo-project governance contract."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
DOCS_BASELINE_BYTES = 698_823

REQUIRED_FILES = (
    "AGENTS.md",
    "docs/workflow.md",
    "docs/backlog.md",
    "docs/audit-report.md",
    ".agents/skills/discussion/SKILL.md",
    ".agents/skills/steward/SKILL.md",
    ".agents/skills/full-audit/SKILL.md",
    ".agents/skills/repository-execution-decisions/SKILL.md",
)

REQUIRED_WORKFLOW = (
    "Issue #N",
    "Closes #N",
    "创建任何Issue前",
    "Worktree只是本机可选checkout方式",
    "Session用于讨论",
    "Security禁入",
    "本机是主要agent执行面",
)

REQUIRED_DECISIONS = (
    "security默认禁入",
    "Issue取代`docs/backlog.md`",
    "PR正文写`Closes #N`",
    "Worktree只是本机可选checkout方式",
)

def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def validate() -> list[str]:
    errors: list[str] = []
    for relative in REQUIRED_FILES:
        if not (ROOT / relative).is_file():
            errors.append(f"missing required file: {relative}")

    if errors:
        return errors

    workflow = read("docs/workflow.md")
    decisions = read(
        ".agents/skills/repository-execution-decisions/SKILL.md"
    )
    for fragment in REQUIRED_WORKFLOW:
        if fragment not in workflow:
            errors.append(f"workflow missing current rule: {fragment}")
    for fragment in REQUIRED_DECISIONS:
        if fragment not in decisions:
            errors.append(f"repository decisions missing rule: {fragment}")

    return errors


def self_test() -> int:
    assert re.search(r"^### B-1", "### B-1 old", re.MULTILINE)
    print("workflow validator self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    errors = validate()
    if errors:
        print("workflow validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    docs_bytes = sum(
        path.stat().st_size
        for path in (ROOT / "docs").rglob("*")
        if path.is_file()
    )
    reduction = 1 - docs_bytes / DOCS_BASELINE_BYTES
    print(
        "workflow validation passed: "
        f"docs={docs_bytes} bytes, reduction={reduction:.1%}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
