#!/usr/bin/env python3
"""Verify the production generic core, real entry properties, and guard sensitivity."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import sys
import tempfile

from common import (
    GuardError,
    ROOT,
    RUNS,
    guard_identity,
    load_manifest,
    require_success,
    run_command,
)


CORE = ROOT / "crates" / "vorton-compiler" / "src" / "checker" / "formal_merge.rs"
CHECKER = ROOT / "crates" / "vorton-compiler" / "src" / "checker.rs"
PROOF = ROOT / "tools" / "semantic_guard" / "formal_merge_proof.rs"
VALIDATION = ROOT / "tools" / "validation" / "run.py"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--install",
        action="store_true",
        help="install the pinned Verus release if it is missing",
    )
    return parser.parse_args()


def replace_once(path: Path, before: str, after: str) -> None:
    text = path.read_text(encoding="utf-8")
    if text.count(before) != 1:
        raise GuardError(f"mutation anchor is not unique in {path}")
    path.write_text(text.replace(before, after), encoding="utf-8")


def mutant_source(name: str) -> Path:
    RUNS.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=f"mutant-{name}-", dir=RUNS)) / "source"
    shutil.copytree(
        ROOT,
        root,
        ignore=shutil.ignore_patterns(".git", "target", "__pycache__", "*.pyc"),
    )
    return root


def require_test_kills_mutant(name: str, source: Path, arguments: list[str]) -> None:
    environment = os.environ.copy()
    environment["CARGO_TARGET_DIR"] = str(RUNS / "mutant-build")
    result = run_command(arguments, cwd=source, environment=environment)
    output = f"{result.stdout}\n{result.stderr}"
    if result.returncode == 0:
        raise GuardError(f"semantic guard did not reject the {name} mutant")
    if "test result: FAILED" not in output or "1 failed" not in output:
        raise GuardError(
            f"{name} mutant failed outside the intended test assertion (exit {result.returncode})"
        )
    print(f"MUTANT={name} VERDICT=EXPECTED_REJECT")


def require_verus_kills_core_mutant(source: Path) -> None:
    result = run_command(
        [
            sys.executable,
            str(VALIDATION),
            "verus",
            "--file",
            str(source / PROOF.relative_to(ROOT)),
            "--proof-source",
            str(source / CORE.relative_to(ROOT)),
            "--expect-function",
            "formal_merge_allowed",
            "--expect-function",
            "merge_label",
            "--expect-function",
            "merge_classes",
        ],
        cwd=ROOT,
    )
    output = f"{result.stdout}\n{result.stderr}"
    if result.returncode == 0:
        raise GuardError("Verus did not reject the core-bypass mutant")
    if "postcondition not satisfied" not in output or "formal_merge" not in output:
        raise GuardError("core-bypass mutant failed outside the intended Verus postcondition")
    print("MUTANT=core-bypass LAYER=Verus VERDICT=EXPECTED_REJECT")


def run_mutants() -> None:
    core_mutant = mutant_source("core-bypass")
    replace_once(
        core_mutant / CORE.relative_to(ROOT),
        """        if first_class == left_class && second_class == right_class
            || first_class == right_class && second_class == left_class
        {
            return false;
        }
""",
        """        if first_class == left_class && second_class == right_class
            || first_class == right_class && second_class == left_class
        {
            return true;
        }
""",
    )
    require_verus_kills_core_mutant(core_mutant)
    require_test_kills_mutant(
        "core-bypass-proptest",
        core_mutant,
        [
            "cargo",
            "test",
            "--workspace",
            "--locked",
            "--offline",
            "--lib",
            "semantic_guard_core_merge_preserves_declared_independence",
            "--",
            "--nocapture",
        ],
    )

    registration_mutant = mutant_source("missing-registration")
    replace_once(
        registration_mutant / CHECKER.relative_to(ROOT),
        "    inference.register_independent_formals(&declared_formals);\n",
        "",
    )
    require_test_kills_mutant(
        "missing-registration",
        registration_mutant,
        [
            "cargo",
            "test",
            "--workspace",
            "--locked",
            "--offline",
            "--test",
            "checker",
            "semantic_guard_real_entry_preserves_declared_formal_domains",
            "--",
            "--nocapture",
        ],
    )

    wiring_mutant = mutant_source("disconnected-core")
    replace_once(
        wiring_mutant / CHECKER.relative_to(ROOT),
        "        formal_merge::merge_classes(&mut self.classes, &self.independent, left, right)\n",
        "        true\n",
    )
    require_test_kills_mutant(
        "disconnected-core",
        wiring_mutant,
        [
            "cargo",
            "test",
            "--workspace",
            "--locked",
            "--offline",
            "--test",
            "checker",
            "semantic_guard_real_entry_preserves_declared_formal_domains",
            "--",
            "--nocapture",
        ],
    )


def main() -> int:
    arguments = parse_arguments()
    baseline, dirty = guard_identity()
    print(f"GUARD_BASELINE={baseline} DIRTY={str(dirty).lower()} PURPOSE=self-test")
    cases = load_manifest()
    print(
        f"PROTECTED_ISSUE65_CASES=NOT_APPLICABLE CASES={len(cases)} "
        f"REASON=current-main-support-boundary"
    )
    proof_command = [
        sys.executable,
        str(VALIDATION),
        "verus",
        "--file",
        str(PROOF),
        "--proof-source",
        str(CORE),
        "--expect-function",
        "formal_merge_allowed",
        "--expect-function",
        "merge_label",
        "--expect-function",
        "merge_classes",
    ]
    if arguments.install:
        proof_command.append("--install")
    proof = run_command(proof_command, cwd=ROOT)
    require_success(proof, "production formal-merge proof")

    properties = run_command(
        [
            "cargo",
            "test",
            "--workspace",
            "--locked",
            "semantic_guard_",
            "--",
            "--nocapture",
        ],
        cwd=ROOT,
    )
    require_success(properties, "semantic guard production properties")
    run_mutants()
    print(f"SEMANTIC_GUARD_SELF_TEST=COMPLETED BASELINE={baseline}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GuardError as error:
        print(f"INFRASTRUCTURE_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
