#!/usr/bin/env python3
"""Validate Vorton's repository-governance files with the Python standard library."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_URL = "https://github.com/vorton-lang/vorton"
DISCUSSION_URL = f"{REPOSITORY_URL}/discussions/1"
ISSUES_URL = f"{REPOSITORY_URL}/issues"

REQUIRED_FILES = (
    "AGENTS.md",
    "README.md",
    "docs/workflow.md",
    "docs/backlog.md",
    "docs/audit-report.md",
    ".github/workflows/test.yml",
    ".github/ISSUE_TEMPLATE/work-item.md",
    ".github/ISSUE_TEMPLATE/config.yml",
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
            errors.append(f"{relative} missing current rule: {fragment}")


def forbid_fragments(
    relative: str,
    text: str,
    fragments: tuple[str, ...],
    errors: list[str],
) -> None:
    for fragment in fragments:
        if fragment in text:
            errors.append(f"{relative} still presents a retired route: {fragment}")


def validate_current_truth(files: dict[str, str], errors: list[str]) -> None:
    readme = files["README.md"]
    require_fragments(
        "README.md",
        readme,
        (
            "# Vorton",
            REPOSITORY_URL,
            "当前工程路线是在 Rust 宿主上重建编译器",
            "只作迁移蓝本、语义 oracle 和已知缺陷复现",
            "python .agents/scripts/validate_workflow.py",
            ISSUES_URL,
            DISCUSSION_URL,
        ),
        errors,
    )
    forbid_fragments(
        "README.md",
        readme,
        (
            "编译器已经用 Ring 自举",
            "从 tracked C bootstrap anchor 构建编译器",
            "tests/run_tests.py",
            "全部默认门禁",
        ),
        errors,
    )

    agents = files["AGENTS.md"]
    require_fragments(
        "AGENTS.md",
        agents,
        (
            "# Vorton Agent Entry",
            REPOSITORY_URL,
            "Vorton 当前以 Rust 实现 Ring 编译器",
            "它们不是当前 bootstrap、CI 或发布 authority",
            "Issue #N → 一个 active PR → PR head branch → merge",
            "Ideas Discussion #1",
            "已冻结，只供迁仓前历史检索",
        ),
        errors,
    )
    forbid_fragments(
        "AGENTS.md",
        agents,
        (
            "# Ring-lang Agent Entry",
            "当前只规划Vorton迁仓",
            "从tracked C anchor构建本地compiler",
        ),
        errors,
    )

    workflow = files["docs/workflow.md"]
    require_fragments(
        "docs/workflow.md",
        workflow,
        (
            "仓库已经迁移到",
            REPOSITORY_URL,
            "Issue #N → 一个 active PR → PR head branch → merge → Issue 自动关闭",
            "PR 未 merge 而关闭：Issue 保持 open",
            "Linked draft PR：进行中",
            "Linked ready-for-review PR：review",
            "Session 用于讨论",
            "Ideas Discussion #1",
            "目标`",
            "当前问题`",
            "范围`",
            "验收`",
            "依赖`",
            "manifest 输入数、成功 URL 数与最终唯一 Issue 数",
            "中断恢复时先按已保存 URL 与远端 Issue 对账",
            "当前 CI 只运行 `python .agents/scripts/validate_workflow.py`",
            "Automatically delete head branches",
        ),
        errors,
    )
    forbid_fragments(
        "docs/workflow.md",
        workflow,
        (
            "当前只做迁仓",
            "迁仓计划",
            "迁仓验收",
            "迁仓前，",
        ),
        errors,
    )

    mentioned_labels = set(
        re.findall(
            r"`((?:type|priority|area):[a-z0-9-]+|blocked)`",
            workflow,
        )
    )
    missing_labels = sorted(ALLOWED_LABELS - mentioned_labels)
    extra_labels = sorted(mentioned_labels - ALLOWED_LABELS)
    if missing_labels:
        errors.append(
            "docs/workflow.md missing allowed labels: " + ", ".join(missing_labels)
        )
    if extra_labels:
        errors.append(
            "docs/workflow.md contains unsupported labels: " + ", ".join(extra_labels)
        )


def validate_ci(ci: str, errors: list[str]) -> None:
    require_fragments(
        ".github/workflows/test.yml",
        ci,
        (
            "name: Governance",
            "jobs:\n  governance:",
            "run: python .agents/scripts/validate_workflow.py",
        ),
        errors,
    )
    jobs_marker = "\njobs:\n"
    if jobs_marker in ci:
        jobs = ci.split(jobs_marker, 1)[1]
        job_ids = set(re.findall(r"(?m)^  ([A-Za-z][A-Za-z0-9_-]*):\s*$", jobs))
        if job_ids != {"governance"}:
            errors.append(
                ".github/workflows/test.yml must define only the governance job; "
                f"found: {', '.join(sorted(job_ids)) or 'none'}"
            )

    run_commands = re.findall(r"(?m)^\s+run:\s*(\S.*)$", ci)
    if run_commands != ["python .agents/scripts/validate_workflow.py"]:
        errors.append(
            ".github/workflows/test.yml must run only the repository validator"
        )
    forbid_fragments(
        ".github/workflows/test.yml",
        ci,
        ("tests/run_tests.py", "cargo ", "self-compile", "bootstrap"),
        errors,
    )


def validate_issue_template(template: str, errors: list[str]) -> None:
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", template, re.DOTALL)
    if match is None:
        errors.append("work-item.md must use Markdown issue-template front matter")
        return

    front_matter, body = match.groups()
    require_fragments(
        ".github/ISSUE_TEMPLATE/work-item.md front matter",
        front_matter,
        (
            "name: 可执行工作",
            "about:",
            "title: ''",
            "labels: ''",
            "assignees: ''",
        ),
        errors,
    )

    rendered_body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    headings = re.findall(r"(?m)^(#{1,6})\s+(.+?)\s*$", rendered_body)
    expected = [
        ("##", "目标"),
        ("##", "当前问题"),
        ("##", "范围"),
        ("##", "验收"),
        ("##", "依赖"),
    ]
    if headings != expected:
        errors.append(
            "work-item.md visible body must contain exactly these five sections: "
            "目标, 当前问题, 范围, 验收, 依赖"
        )
    if re.search(r"(?m)^\s*(?:状态|编号|优先级)\s*[:：]", rendered_body):
        errors.append("work-item.md must not create manual status or numbering fields")

    template_dir = ROOT / ".github" / "ISSUE_TEMPLATE"
    markdown_templates = sorted(path.name for path in template_dir.glob("*.md"))
    if markdown_templates != ["work-item.md"]:
        errors.append(
            "ISSUE_TEMPLATE must contain one Markdown template; found: "
            + ", ".join(markdown_templates)
        )
    issue_forms = sorted(
        path.name
        for pattern in ("*.yml", "*.yaml")
        for path in template_dir.glob(pattern)
        if path.name != "config.yml"
    )
    if issue_forms:
        errors.append("Issue Forms are not part of the current workflow: " + ", ".join(issue_forms))


def validate_template_config(config: str, errors: list[str]) -> None:
    top_level_keys = set(re.findall(r"(?m)^([a-z_]+):", config))
    if top_level_keys != {"blank_issues_enabled", "contact_links"}:
        errors.append(
            "config.yml may only configure blank issues and the Ideas contact link"
        )
    if config.count("blank_issues_enabled: false") != 1:
        errors.append("config.yml must disable blank issues")
    urls = re.findall(r"(?m)^\s+url:\s*(\S+)\s*$", config)
    if urls != [DISCUSSION_URL]:
        errors.append("config.yml must link only to Ideas Discussion #1")
    if not re.search(r"(?m)^\s+- name:\s*\S", config):
        errors.append("config.yml Ideas link must have a name")
    if not re.search(r"(?m)^\s+about:\s*\S", config):
        errors.append("config.yml Ideas link must explain its purpose")


def validate_frozen_headers(files: dict[str, str], errors: list[str]) -> None:
    for relative, title in (
        ("docs/backlog.md", "# Backlog"),
        ("docs/audit-report.md", "# Audit Report"),
    ):
        text = files[relative]
        first_lines = "\n".join(text.splitlines()[:8])
        if not text.startswith(f"{title}\n"):
            errors.append(f"{relative} must retain its historical title")
        for fragment in ("[!IMPORTANT]", "已冻结（迁仓后）", ISSUES_URL, "B/A/D 编号"):
            if fragment not in first_lines:
                errors.append(f"{relative} frozen header missing: {fragment}")


def validate() -> list[str]:
    errors: list[str] = []
    files = {relative: read(relative, errors) for relative in REQUIRED_FILES}
    if errors:
        return errors

    validate_current_truth(files, errors)
    validate_ci(files[".github/workflows/test.yml"], errors)
    validate_issue_template(files[".github/ISSUE_TEMPLATE/work-item.md"], errors)
    validate_template_config(files[".github/ISSUE_TEMPLATE/config.yml"], errors)
    validate_frozen_headers(files, errors)
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
