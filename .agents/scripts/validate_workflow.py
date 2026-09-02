#!/usr/bin/env python3
"""Validate Vorton's current repository workflow with the Python standard library."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_URL = "https://github.com/vorton-lang/vorton"
DISCUSSION_URL = f"{REPOSITORY_URL}/discussions/1"

REQUIRED_FILES = (
    "AGENTS.md",
    "README.md",
    "docs/workflow.md",
    "docs/design.md",
    "docs/competitive-analysis.md",
    ".github/workflows/test.yml",
    ".github/ISSUE_TEMPLATE/work-item.md",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/pull_request_template.md",
    ".agents/skills/task-pipeline/SKILL.md",
    ".agents/skills/task-pipeline/references/executor.md",
    ".agents/skills/task-pipeline/references/verifier.md",
    ".agents/skills/full-audit/SKILL.md",
    ".agents/scripts/validate_naming.py",
    ".codex/config.toml",
    ".gitattributes",
)

ALLOWED_LABELS = {
    "type:bug",
    "type:feature",
    "type:design",
    "type:maintenance",
    "type:audit",
    "priority:p0",
    "priority:p1",
    "priority:p2",
    "priority:p3",
    "area:frontend",
    "area:types-effects",
    "area:ir-ownership",
    "area:backend-runtime",
    "area:tooling",
    "area:docs",
    "blocked",
}


def read(relative: str, errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing required file: {relative}")
        return ""
    try:
        return path.read_text(encoding="utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as error:
        errors.append(f"{relative} is not UTF-8: {error}")
        return ""


def require_fragments(
    relative: str,
    text: str,
    fragments: tuple[str, ...],
    errors: list[str],
) -> None:
    for fragment in fragments:
        if fragment not in text:
            errors.append(f"{relative} missing current truth: {fragment}")


def front_matter(
    relative: str, text: str, errors: list[str]
) -> tuple[dict[str, str], str]:
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.DOTALL)
    if match is None:
        errors.append(f"{relative} must have YAML front matter")
        return {}, ""
    raw, body = match.groups()
    values: dict[str, str] = {}
    for line in raw.splitlines():
        if not line.strip() or line.startswith((" ", "\t")) or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values, body


def visible_lines(markdown: str) -> list[str]:
    without_comments = re.sub(r"<!--.*?-->", "", markdown, flags=re.DOTALL)
    return [line.strip() for line in without_comments.splitlines() if line.strip()]


def nonempty_comments(relative: str, text: str, minimum: int, errors: list[str]) -> None:
    comments = re.findall(r"<!--(.*?)-->", text, flags=re.DOTALL)
    if len(comments) < minimum or any(not comment.strip() for comment in comments):
        errors.append(
            f"{relative} must provide at least {minimum} non-empty guidance comments"
        )


def validate_repository_layout(errors: list[str]) -> None:
    script_names = {
        path.name for path in (ROOT / ".agents" / "scripts").glob("*.py")
    }
    if script_names != {"validate_naming.py", "validate_workflow.py"}:
        errors.append(
            ".agents/scripts must contain only the two current validators; found: "
            + ", ".join(sorted(script_names))
        )

    skill_names = {
        path.parent.name
        for path in (ROOT / ".agents" / "skills").glob("*/SKILL.md")
    }
    if skill_names != {"full-audit", "task-pipeline"}:
        errors.append(
            ".agents/skills must contain only full-audit and task-pipeline; found: "
            + ", ".join(sorted(skill_names))
        )

    role_files = sorted((ROOT / ".codex" / "agents").glob("*.toml"))
    if role_files:
        errors.append(
            ".codex/agents must not retain repository lifecycle roles: "
            + ", ".join(path.name for path in role_files)
        )

    for relative in ("docs/backlog.md", "docs/audit-report.md"):
        if (ROOT / relative).exists():
            errors.append(f"retired Markdown authority must remain absent: {relative}")


def validate_entry_docs(files: dict[str, str], errors: list[str]) -> None:
    require_fragments(
        "AGENTS.md",
        files["AGENTS.md"],
        (
            "# Vorton Agent Entry",
            REPOSITORY_URL,
            ".agents/skills/task-pipeline/SKILL.md",
            "唯一任务 lifecycle authority",
            "Vorton 当前以 Rust 重建编译器",
            "用户保留决定",
            "Security 边界",
        ),
        errors,
    )
    require_fragments(
        "README.md",
        files["README.md"],
        (
            "# Vorton",
            REPOSITORY_URL,
            "当前工程路线是在 Rust 宿主上重建 Vorton 编译器",
            "python .agents/scripts/validate_naming.py",
            "python .agents/scripts/validate_workflow.py",
            ".agents/skills/task-pipeline/SKILL.md",
            "迁仓前 Markdown 看板保持删除",
        ),
        errors,
    )

    workflow = files["docs/workflow.md"]
    require_fragments(
        "docs/workflow.md",
        workflow,
        (
            "../.agents/skills/task-pipeline/SKILL.md",
            "../.github/ISSUE_TEMPLATE/work-item.md",
            "../.github/pull_request_template.md",
            DISCUSSION_URL,
            "python .agents/scripts/validate_naming.py",
            "python .agents/scripts/validate_workflow.py",
        ),
        errors,
    )
    duplicated_field = re.search(
        r"(?m)^(?:#{1,6}\s+|[-*]\s+|\d+\.\s+)"
        r"(?:问题|结果|方案|范围|设计|验收|开工条件)\s*$",
        workflow,
    )
    if duplicated_field is not None:
        errors.append("docs/workflow.md must link templates without copying fields")

    mentioned_labels = set(
        re.findall(r"`((?:type|priority|area):[a-z0-9-]+|blocked)`", workflow)
    )
    if mentioned_labels != ALLOWED_LABELS:
        errors.append(
            "docs/workflow.md label set differs from the repository label contract"
        )


def validate_task_pipeline(files: dict[str, str], errors: list[str]) -> None:
    skill_path = ".agents/skills/task-pipeline/SKILL.md"
    metadata, body = front_matter(skill_path, files[skill_path], errors)
    if metadata.get("name") != "task-pipeline" or not metadata.get("description"):
        errors.append("task-pipeline must have a name and discriminating description")

    reference_links = set(
        re.findall(r"\]\((references/(?:executor|verifier)\.md)\)", body)
    )
    if reference_links != {"references/executor.md", "references/verifier.md"}:
        errors.append("task-pipeline must route to exactly its Executor and Verifier references")

    executor_path = ".agents/skills/task-pipeline/references/executor.md"
    executor = files[executor_path]
    if executor.startswith("---") or "[`task-pipeline`](../SKILL.md)" not in executor:
        errors.append("Executor reference must be a routed template, not another skill")

    verifier_path = ".agents/skills/task-pipeline/references/verifier.md"
    verifier = files[verifier_path]
    if verifier.startswith("---") or "[`task-pipeline`](../SKILL.md)" not in verifier:
        errors.append("Verifier reference must be a routed template, not another skill")


def validate_templates(files: dict[str, str], errors: list[str]) -> None:
    issue_path = ".github/ISSUE_TEMPLATE/work-item.md"
    metadata, body = front_matter(issue_path, files[issue_path], errors)
    if set(metadata) != {"name", "about", "title", "labels", "assignees"}:
        errors.append("work-item.md front matter has unsupported fields")
    if metadata.get("name") != "可执行工作":
        errors.append("work-item.md must remain the single executable-work template")
    expected_issue_lines = [
        "> **问题**：",
        "> **结果**：",
        "> **方案**：",
        "## 范围",
        "## 设计",
        "## 验收",
        "## 开工条件",
    ]
    if visible_lines(body) != expected_issue_lines:
        errors.append("work-item.md visible body does not match the single Issue format")
    nonempty_comments(issue_path, body, 8, errors)

    template_dir = ROOT / ".github" / "ISSUE_TEMPLATE"
    markdown_templates = sorted(path.name for path in template_dir.glob("*.md"))
    if markdown_templates != ["work-item.md"]:
        errors.append("ISSUE_TEMPLATE must contain exactly one Markdown template")
    issue_forms = sorted(
        path.name
        for pattern in ("*.yml", "*.yaml")
        for path in template_dir.glob(pattern)
        if path.name != "config.yml"
    )
    if issue_forms:
        errors.append("Issue Forms are not part of the current workflow")

    pr_path = ".github/pull_request_template.md"
    pr = files[pr_path]
    if visible_lines(pr) != ["Closes #N", "## 摘要", "## 验证"]:
        errors.append("pull_request_template.md must expose only Closes, 摘要 and 验证")
    nonempty_comments(pr_path, pr, 3, errors)


def validate_github_config(files: dict[str, str], errors: list[str]) -> None:
    config = files[".github/ISSUE_TEMPLATE/config.yml"]
    top_level_keys = set(re.findall(r"(?m)^([a-z_]+):", config))
    urls = re.findall(r"(?m)^\s+url:\s*(\S+)\s*$", config)
    if top_level_keys != {"blank_issues_enabled", "contact_links"}:
        errors.append("Issue template config has unsupported top-level keys")
    if config.count("blank_issues_enabled: false") != 1 or urls != [DISCUSSION_URL]:
        errors.append("Issue template config must disable blanks and link only Ideas Discussion")

    codex = files[".codex/config.toml"]
    if re.search(r"(?m)^\[agents\.[^]]+\]$", codex) or "config_file" in codex:
        errors.append(".codex/config.toml must not reference repository lifecycle roles")


def validate_ci(ci: str, errors: list[str]) -> None:
    require_fragments(
        ".github/workflows/test.yml",
        ci,
        (
            "name: Governance",
            "jobs:\n  governance:",
            "run: python .agents/scripts/validate_naming.py",
            "run: python .agents/scripts/validate_workflow.py",
        ),
        errors,
    )
    jobs_marker = "\njobs:\n"
    if jobs_marker in ci:
        jobs = ci.split(jobs_marker, 1)[1]
        job_ids = set(re.findall(r"(?m)^  ([A-Za-z][A-Za-z0-9_-]*):\s*$", jobs))
        if job_ids != {"governance"}:
            errors.append("test.yml must define only the governance job")
    commands = re.findall(r"(?m)^\s+run:\s*(\S.*)$", ci)
    if commands != [
        "python .agents/scripts/validate_naming.py",
        "python .agents/scripts/validate_workflow.py",
    ]:
        errors.append("test.yml must run only the two current validators")


def validate_other_authorities(files: dict[str, str], errors: list[str]) -> None:
    require_fragments(
        ".agents/skills/full-audit/SKILL.md",
        files[".agents/skills/full-audit/SKILL.md"],
        (
            "../task-pipeline/SKILL.md",
            "fixed default-branch commit",
            "普通 PR/diff verification 使用 `task-pipeline`",
        ),
        errors,
    )
    require_fragments(
        "docs/design.md",
        files["docs/design.md"],
        (
            "当前技术入口以 `AGENTS.md` 为准",
            "活动依赖、范围与验收只查 GitHub Issues",
            "完成历史、被否决方案和逐轮调查只查 Git",
        ),
        errors,
    )
    competitive = files["docs/competitive-analysis.md"]
    radar_lines = [line for line in competitive.splitlines() if "Star List" in line]
    if any("授权" in line or "无需" in line for line in radar_lines):
        errors.append("competitive-analysis must not grant external-write authorization")

    attributes = files[".gitattributes"]
    for line in attributes.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        pattern = stripped.split()[0]
        if not any(character in pattern for character in "*?[{"):
            if not (ROOT / pattern).exists():
                errors.append(f".gitattributes targets missing path: {pattern}")


def validate() -> list[str]:
    errors: list[str] = []
    validate_repository_layout(errors)
    files = {relative: read(relative, errors) for relative in REQUIRED_FILES}
    if errors:
        return errors
    validate_entry_docs(files, errors)
    validate_task_pipeline(files, errors)
    validate_templates(files, errors)
    validate_github_config(files, errors)
    validate_ci(files[".github/workflows/test.yml"], errors)
    validate_other_authorities(files, errors)
    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("workflow validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print("workflow validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
