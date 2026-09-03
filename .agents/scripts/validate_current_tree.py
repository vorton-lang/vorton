#!/usr/bin/env python3
"""Validate the minimal structural contract of Vorton's current tree."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
import subprocess


ROOT = Path(__file__).resolve().parents[2]

FORBIDDEN_ROOTS = frozenset({"compiler", "editor", "examples", "std", "tests"})
FORBIDDEN_PATHS = frozenset(
    {
        ".agents/scripts/validate_naming.py",
        ".agents/scripts/validate_workflow.py",
        ".gitattributes",
        "docs/competitive-analysis.md",
        "docs/lang-spec/stdlib.md",
        "loc.py",
        "test_chain.vorton",
        "vorton_runtime.cpp",
    }
)


def tracked_paths(errors: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        errors.append(
            "git ls-files failed: "
            + result.stderr.decode("utf-8", errors="replace").strip()
        )
        return []

    paths: list[str] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        try:
            paths.append(raw.decode("utf-8"))
        except UnicodeDecodeError as error:
            errors.append(f"tracked path is not UTF-8: {error}")
    return paths


def validate() -> tuple[list[str], int, int]:
    errors: list[str] = []
    paths = tracked_paths(errors)
    root = ROOT.resolve()
    folded: dict[str, str] = {}
    text_count = 0

    for relative in paths:
        posix = PurePosixPath(relative)
        if posix.is_absolute() or ".." in posix.parts:
            errors.append(f"tracked path escapes the repository: {relative}")
            continue

        normalized = posix.as_posix()
        resolved = (ROOT / Path(*posix.parts)).resolve(strict=False)
        if not resolved.is_relative_to(root):
            errors.append(f"tracked path resolves outside the repository: {relative}")
            continue

        previous = folded.setdefault(normalized.casefold(), normalized)
        if previous != normalized:
            errors.append(
                f"case-insensitive tracked-path collision: {previous} / {normalized}"
            )

        if posix.parts and posix.parts[0].casefold() in FORBIDDEN_ROOTS:
            errors.append(f"removed tree must remain absent: {normalized}")
        if normalized.casefold() in FORBIDDEN_PATHS:
            errors.append(f"removed path must remain absent: {normalized}")

        if not resolved.is_file():
            errors.append(f"tracked file is missing: {normalized}")
            continue
        data = resolved.read_bytes()
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as error:
            errors.append(f"tracked text is not UTF-8: {normalized}: {error}")
        else:
            text_count += 1

    return errors, len(paths), text_count


def main() -> int:
    errors, path_count, text_count = validate()
    if errors:
        print("current-tree validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(
        "current-tree validation passed "
        f"({path_count} tracked paths, {text_count} UTF-8 text files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
