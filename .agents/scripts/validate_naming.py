#!/usr/bin/env python3
"""Validate Vorton's tracked technical naming clean break."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
CURRENT_EXTENSION = ".vorton"
LEGACY_STEM = "".join(("ri", "ng"))

ALLOWED_THIRD_PARTY_REFERENCES = {
    "editor/vscode/syntaxes/vorton.tmLanguage.json": (
        "https://raw.githubusercontent.com/"
        f"martin{LEGACY_STEM}/tmlanguage/master/tmlanguage.json",
    ),
}

LEGACY_PATH = re.compile(
    rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM)}(?![A-Za-z0-9])",
    re.IGNORECASE,
)
LEGACY_CONTENT = (
    ("source extension", re.compile(re.escape("." + LEGACY_STEM))),
    ("executable", re.compile(re.escape(LEGACY_STEM + ".exe"))),
    ("runtime filename", re.compile(re.escape(LEGACY_STEM + "_runtime.cpp"))),
    ("internal ABI prefix", re.compile(re.escape("__" + LEGACY_STEM + "_"))),
    (
        "module ABI prefix",
        re.compile(rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM + 'mod_')}"),
    ),
    (
        "macro ABI prefix",
        re.compile(rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM.upper() + '_')}"),
    ),
    (
        "compiler-defined macro",
        re.compile(re.escape("-D" + LEGACY_STEM.upper() + "_")),
    ),
    (
        "C ABI prefix",
        re.compile(rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM + '_')}"),
    ),
    ("PascalCase brand", re.compile(re.escape(LEGACY_STEM.title()))),
    (
        "lower-camel brand",
        re.compile(rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM)}(?=[A-Z])"),
    ),
    (
        "standalone brand",
        re.compile(
            rf"(?<![A-Za-z0-9]){re.escape(LEGACY_STEM)}(?![A-Za-z0-9])",
            re.IGNORECASE,
        ),
    ),
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
    try:
        return [
            item.decode("utf-8")
            for item in result.stdout.split(b"\0")
            if item
        ]
    except UnicodeDecodeError as error:
        errors.append(f"tracked path is not UTF-8: {error}")
        return []


def validate_paths(paths: list[str], errors: list[str]) -> None:
    root = ROOT.resolve()
    folded: dict[str, str] = {}
    for relative in paths:
        posix = PurePosixPath(relative)
        if posix.is_absolute() or ".." in posix.parts:
            errors.append(f"tracked path escapes the repository: {relative}")
            continue
        resolved = (ROOT / Path(*posix.parts)).resolve(strict=False)
        if not resolved.is_relative_to(root):
            errors.append(f"tracked path resolves outside the repository: {relative}")
        previous = folded.setdefault(relative.casefold(), relative)
        if previous != relative:
            errors.append(
                f"case-insensitive tracked-path collision: {previous} / {relative}"
            )
        if LEGACY_PATH.search(relative):
            errors.append(f"tracked path contains the retired brand: {relative}")


def validate_contents(paths: list[str], errors: list[str]) -> None:
    allowed_counts = {
        (relative, reference): 0
        for relative, references in ALLOWED_THIRD_PARTY_REFERENCES.items()
        for reference in references
    }
    root = ROOT.resolve()
    for relative in paths:
        posix = PurePosixPath(relative)
        path = ROOT / Path(*posix.parts)
        if not path.resolve(strict=False).is_relative_to(root):
            continue
        if not path.is_file():
            errors.append(f"tracked file is missing: {relative}")
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError as error:
            errors.append(f"tracked text is not UTF-8: {relative}: {error}")
            continue

        masked = text
        for reference in ALLOWED_THIRD_PARTY_REFERENCES.get(relative, ()):
            count = masked.count(reference)
            allowed_counts[(relative, reference)] += count
            masked = masked.replace(reference, "<allowed-third-party-reference>")

        for label, pattern in LEGACY_CONTENT:
            match = pattern.search(masked)
            if match is None:
                continue
            line = masked.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line} contains retired {label}")

    for (relative, reference), count in allowed_counts.items():
        if count != 1:
            errors.append(
                f"allowed third-party reference must occur once in {relative}; "
                f"found {count}: {reference}"
            )


def validate() -> tuple[list[str], int, int]:
    errors: list[str] = []
    paths = tracked_paths(errors)
    if not paths:
        return errors, 0, 0
    validate_paths(paths, errors)
    validate_contents(paths, errors)
    source_count = sum(path.endswith(CURRENT_EXTENSION) for path in paths)
    if source_count == 0:
        errors.append(f"no tracked {CURRENT_EXTENSION} sources found")
    return errors, len(paths), source_count


def main() -> int:
    errors, path_count, source_count = validate()
    if errors:
        print("naming validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(
        "naming validation passed "
        f"({path_count} tracked paths, {source_count} {CURRENT_EXTENSION} sources)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
