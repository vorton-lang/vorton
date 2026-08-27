#!/usr/bin/env python3
"""Manifest-driven runner for the Ring 0.1 ownership vertical fixtures.

This module owns fixture planning and verdicts.  Toolchain construction,
compiler invocation, native linking, and result collection stay in
``run_tests.py`` and are supplied through ``RunnerContext`` callbacks.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple


SUITE = "ownership-vertical"
DEFAULT_MANIFEST = (
    Path(__file__).resolve().parent / "cases" / "ownership_vertical" /
    "manifest.json"
)
_ORDINARY_CRASH_MARKERS = (
    "ring panic:",
    "internal compiler error",
    "compiler panicked",
    "access violation",
    "traceback",
)
_ACCESS_VIOLATION_CODES = (0xC0000005, -0x3FFFFFFB)


class ManifestError(ValueError):
    """The ownership fixture manifest is incomplete or inconsistent."""


@dataclass(frozen=True)
class Fixture:
    id: str
    path: str
    support_paths: Tuple[str, ...]
    phase: str
    status: str
    stdout: Optional[str]
    diagnostic_code: Optional[str]
    diagnostic_contains: Tuple[str, ...]
    diagnostic_forbidden: Tuple[str, ...]
    diagnostic_line: Optional[int]
    diagnostic_column: Optional[int]
    parity_group: Optional[str]
    same_stdout_as: Optional[str]

    @property
    def is_project(self) -> bool:
        return bool(self.support_paths)

    @property
    def label(self) -> str:
        return f"{self.id}:{self.path}"


@dataclass(frozen=True)
class InternalCanary:
    id: str
    requirement: str
    input_fixture_id: str
    input_path: str
    mutation: str
    expected_panic_exact: str


@dataclass(frozen=True)
class ExactPanicObservation:
    """Raw process channels for an internal canary whose panic is the oracle."""

    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class ManifestPlan:
    path: Path
    fixtures: Tuple[Fixture, ...]
    internal_canaries: Tuple[InternalCanary, ...]


CheckCallback = Callable[[Path, str], subprocess.CompletedProcess]
NativeCallback = Callable[[Path, Path, str], Tuple[bool, str, str]]
ResultCallback = Callable[[str, str, str], None]
MatchCallback = Callable[[str, Optional[str]], bool]
InternalCanaryCallback = Callable[
    [InternalCanary, str], ExactPanicObservation
]


@dataclass(frozen=True)
class RunnerContext:
    """Dependencies retained by the aggregate runner.

    ``check`` invokes the current aggregate compiler. ``native`` reuses the
    aggregate build/link/run helper and receives a case-unique output folder.
    ``internal_canary`` is mandatory for an acceptance run. A context may pass
    ``None`` only to obtain a counted FAIL for a missing integration callback.
    """

    manifest_path: Path
    check: CheckCallback
    native: NativeCallback
    add_result: ResultCallback
    matches_filter: MatchCallback
    internal_canary: Optional[InternalCanaryCallback]


def _require_dict(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must be an object")
    return value


def _require_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ManifestError(f"{label} must be a non-empty string")
    return value


def _guard_fixture_path(root: Path, value: object, label: str) -> str:
    relative = _require_text(value, label)
    candidate_path = Path(relative)
    if candidate_path.is_absolute() or ".." in candidate_path.parts:
        raise ManifestError(f"{label} must stay below the fixture root")
    candidate = (root / candidate_path).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as exc:
        raise ManifestError(f"{label} escapes the fixture root") from exc
    if candidate.suffix != ".ring" or not candidate.is_file():
        raise ManifestError(f"{label} is not an existing .ring fixture: {relative}")
    return candidate.relative_to(root.resolve()).as_posix()


def load_manifest(path: Path = DEFAULT_MANIFEST) -> ManifestPlan:
    """Load and validate the exact manifest-owned source corpus."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read {path}: {exc}") from exc

    root_doc = _require_dict(document, "manifest")
    if root_doc.get("schema_version") != 1:
        raise ManifestError("manifest.schema_version must be 1")
    scope = _require_dict(root_doc.get("scope"), "manifest.scope")
    if scope.get("source_string_oracle") is not False:
        raise ManifestError("manifest must keep source_string_oracle=false")
    if scope.get("real_consumers_only") is not True:
        raise ManifestError("manifest must keep real_consumers_only=true")

    root = path.resolve().parent
    raw_fixtures = root_doc.get("fixtures")
    if not isinstance(raw_fixtures, list) or not raw_fixtures:
        raise ManifestError("manifest.fixtures must be a non-empty list")

    fixtures: List[Fixture] = []
    ids: set[str] = set()
    entry_paths: set[str] = set()
    support_paths: set[str] = set()
    for index, raw_value in enumerate(raw_fixtures):
        raw = _require_dict(raw_value, f"fixtures[{index}]")
        case_id = _require_text(raw.get("id"), f"fixtures[{index}].id")
        if case_id in ids:
            raise ManifestError(f"duplicate case id {case_id}")
        ids.add(case_id)

        entry = _guard_fixture_path(
            root, raw.get("path"), f"fixtures[{index}].path")
        if entry in entry_paths:
            raise ManifestError(f"duplicate fixture entry {entry}")
        entry_paths.add(entry)

        raw_support = raw.get("support_paths", [])
        if not isinstance(raw_support, list):
            raise ManifestError(f"{case_id}.support_paths must be a list")
        case_support = tuple(
            _guard_fixture_path(root, value, f"{case_id}.support_paths[{offset}]")
            for offset, value in enumerate(raw_support)
        )
        if len(set(case_support)) != len(case_support):
            raise ManifestError(f"{case_id}.support_paths contains duplicates")
        support_paths.update(case_support)

        expected = _require_dict(raw.get("expected"), f"{case_id}.expected")
        phase = _require_text(expected.get("phase"), f"{case_id}.expected.phase")
        status = _require_text(expected.get("status"), f"{case_id}.expected.status")
        stdout: Optional[str] = None
        diagnostic_code: Optional[str] = None
        diagnostic_contains: Tuple[str, ...] = ()
        diagnostic_forbidden: Tuple[str, ...] = ()
        diagnostic_line: Optional[int] = None
        diagnostic_column: Optional[int] = None
        if phase == "native" and status == "pass":
            stdout_value = expected.get("stdout")
            if not isinstance(stdout_value, str):
                raise ManifestError(f"{case_id}.expected.stdout must be a string")
            stdout = stdout_value
        elif phase == "check" and status == "fail":
            diagnostic_code = _require_text(
                expected.get("diagnostic_code"),
                f"{case_id}.expected.diagnostic_code",
            )
            raw_contains_all = expected.get("diagnostic_contains_all")
            if raw_contains_all is None:
                diagnostic_contains = (_require_text(
                    expected.get("diagnostic_contains"),
                    f"{case_id}.expected.diagnostic_contains",
                ),)
            else:
                if not isinstance(raw_contains_all, list) or not raw_contains_all:
                    raise ManifestError(
                        f"{case_id}.expected.diagnostic_contains_all must be "
                        "a non-empty list"
                    )
                diagnostic_contains = tuple(
                    _require_text(value, (
                        f"{case_id}.expected.diagnostic_contains_all[{offset}]"))
                    for offset, value in enumerate(raw_contains_all)
                )
            raw_forbidden = expected.get("diagnostic_forbidden", [])
            if not isinstance(raw_forbidden, list):
                raise ManifestError(
                    f"{case_id}.expected.diagnostic_forbidden must be a list")
            diagnostic_forbidden = tuple(
                _require_text(value, (
                    f"{case_id}.expected.diagnostic_forbidden[{offset}]"))
                for offset, value in enumerate(raw_forbidden)
            )
            raw_line = expected.get("diagnostic_line")
            raw_column = expected.get("diagnostic_column")
            if (raw_line is None) != (raw_column is None):
                raise ManifestError(
                    f"{case_id}.expected diagnostic line/column must be paired")
            if raw_line is not None:
                if (not isinstance(raw_line, int) or raw_line <= 0 or
                        not isinstance(raw_column, int) or raw_column <= 0):
                    raise ManifestError(
                        f"{case_id}.expected diagnostic location must be positive")
                diagnostic_line = raw_line
                diagnostic_column = raw_column
        else:
            raise ManifestError(
                f"{case_id} has unsupported expected phase/status {phase}/{status}"
            )

        parity_group = raw.get("parity_group")
        if parity_group is not None:
            parity_group = _require_text(parity_group, f"{case_id}.parity_group")
        same_stdout_as = expected.get("same_stdout_as")
        if same_stdout_as is not None:
            same_stdout_as = _require_text(
                same_stdout_as, f"{case_id}.expected.same_stdout_as")

        fixtures.append(Fixture(
            id=case_id,
            path=entry,
            support_paths=case_support,
            phase=phase,
            status=status,
            stdout=stdout,
            diagnostic_code=diagnostic_code,
            diagnostic_contains=diagnostic_contains,
            diagnostic_forbidden=diagnostic_forbidden,
            diagnostic_line=diagnostic_line,
            diagnostic_column=diagnostic_column,
            parity_group=parity_group,
            same_stdout_as=same_stdout_as,
        ))

    overlap = entry_paths & support_paths
    if overlap:
        raise ManifestError(
            "support modules must not be standalone cases: " +
            ", ".join(sorted(overlap))
        )
    actual_sources = {
        source.resolve().relative_to(root).as_posix()
        for source in root.rglob("*.ring")
    }
    declared_sources = entry_paths | support_paths
    if actual_sources != declared_sources:
        missing = sorted(actual_sources - declared_sources)
        absent = sorted(declared_sources - actual_sources)
        raise ManifestError(
            f"manifest/source census mismatch; unlisted={missing}; absent={absent}"
        )

    fixtures_by_id = {fixture.id: fixture for fixture in fixtures}
    groups: Dict[str, List[Fixture]] = {}
    for fixture in fixtures:
        if fixture.parity_group:
            groups.setdefault(fixture.parity_group, []).append(fixture)
        if fixture.same_stdout_as:
            peer = fixtures_by_id.get(fixture.same_stdout_as)
            if peer is None:
                raise ManifestError(
                    f"{fixture.id}.same_stdout_as names unknown case "
                    f"{fixture.same_stdout_as}"
                )
            if (
                fixture.phase != "native" or peer.phase != "native" or
                fixture.stdout != peer.stdout or
                fixture.parity_group != peer.parity_group
            ):
                raise ManifestError(
                    f"{fixture.id}.same_stdout_as does not share one native "
                    "literal/parity group"
                )
    for group, members in groups.items():
        if len(members) < 2:
            raise ManifestError(f"parity group {group} has fewer than two members")

    raw_canaries = root_doc.get("internal_negative_canaries", [])
    if not isinstance(raw_canaries, list):
        raise ManifestError("manifest.internal_negative_canaries must be a list")
    canaries: List[InternalCanary] = []
    for index, raw_value in enumerate(raw_canaries):
        raw = _require_dict(raw_value, f"internal_negative_canaries[{index}]")
        canary_id = _require_text(
            raw.get("id"), f"internal_negative_canaries[{index}].id")
        if canary_id in ids:
            raise ManifestError(f"duplicate fixture/canary id {canary_id}")
        ids.add(canary_id)
        if raw.get("source_fixture") is not None:
            raise ManifestError(
                f"{canary_id} must remain an internal Ring canary, not a source fixture"
            )
        canaries.append(InternalCanary(
            id=canary_id,
            requirement=_require_text(raw.get("requirement"), f"{canary_id}.requirement"),
            input_fixture_id=_require_text(
                raw.get("input_fixture_id"), f"{canary_id}.input_fixture_id"),
            input_path="",
            mutation=_require_text(raw.get("mutation"), f"{canary_id}.mutation"),
            expected_panic_exact=_require_text(
                raw.get("expected_panic_exact"), f"{canary_id}.expected_panic_exact"),
        ))
    resolved_canaries: List[InternalCanary] = []
    for canary in canaries:
        seed = fixtures_by_id.get(canary.input_fixture_id)
        if seed is None:
            raise ManifestError(
                f"{canary.id}.input_fixture_id names unknown case "
                f"{canary.input_fixture_id}"
            )
        resolved_canaries.append(InternalCanary(
            id=canary.id,
            requirement=canary.requirement,
            input_fixture_id=canary.input_fixture_id,
            input_path=seed.path,
            mutation=canary.mutation,
            expected_panic_exact=canary.expected_panic_exact,
        ))
    return ManifestPlan(path=path.resolve(), fixtures=tuple(fixtures),
                        internal_canaries=tuple(resolved_canaries))


def _normalized(text: str) -> str:
    return text.replace("\r\n", "\n")


def _process_output(result: subprocess.CompletedProcess) -> str:
    return _normalized((result.stdout or "") + (result.stderr or ""))


def normal_diagnostic_contract_failure(
    result: subprocess.CompletedProcess,
    diagnostic_failure: Optional[str],
) -> Optional[str]:
    """Require the compiler's normal diagnostic process contract.

    A matching diagnostic is accepted only when ``ring check`` terminates via
    its ordinary diagnostic exit. Signals and platform exception statuses are
    failures even if they happened to flush matching text first.
    """
    if result.returncode != 1:
        return f"expected normal diagnostic exit 1, got {result.returncode}"
    return diagnostic_failure


def _has_internal_failure(output: str) -> bool:
    lowered = output.lower()
    return any(marker in lowered for marker in _ORDINARY_CRASH_MARKERS)


def _has_abnormal_termination(result: subprocess.CompletedProcess) -> bool:
    return result.returncode < 0 or result.returncode in _ACCESS_VIOLATION_CODES


def _selected(
    fixture: Fixture, name_filter: Optional[str], matches: MatchCallback,
) -> bool:
    identities = [fixture.id, fixture.label, fixture.path]
    if fixture.parity_group:
        identities.append(fixture.parity_group)
    return any(matches(identity, name_filter) for identity in identities)


def _run_fixture(
    context: RunnerContext,
    fixture: Fixture,
    fixture_root: Path,
    output_root: Path,
) -> Optional[str]:
    entry = fixture_root / fixture.path
    label = fixture.label
    try:
        checked = context.check(entry, label)
    except subprocess.TimeoutExpired:
        context.add_result("FAIL", label, "check timed out")
        return None
    except OSError as exc:
        context.add_result("FAIL", label, f"check could not start: {exc}")
        return None

    check_output = _process_output(checked)
    if _has_internal_failure(check_output) or _has_abnormal_termination(checked):
        context.add_result(
            "FAIL", label,
            f"compiler internal failure during check (exit {checked.returncode}): "
            f"{check_output[:300]!r}")
        return None

    if fixture.phase == "check":
        assert fixture.diagnostic_code is not None
        lowered = check_output.lower()
        missing = [
            required for required in (
                fixture.diagnostic_code, *fixture.diagnostic_contains,
            )
            if required.lower() not in lowered
        ]
        forbidden = [
            pattern for pattern in fixture.diagnostic_forbidden
            if pattern.lower() in lowered
        ]
        location_missing = False
        if fixture.diagnostic_line is not None:
            assert fixture.diagnostic_column is not None
            location_missing = (
                f":{fixture.diagnostic_line}:{fixture.diagnostic_column}"
                not in check_output
            )
        diagnostic_failure = None
        if missing or forbidden or location_missing:
            diagnostic_failure = (
                f"missing diagnostic {missing!r}; forbidden diagnostic "
                f"{forbidden!r}; location_missing={location_missing}; "
                f"output={check_output[:300]!r}"
            )
        failure = normal_diagnostic_contract_failure(
            checked, diagnostic_failure)
        if failure is None:
            context.add_result("PASS", label, "expected diagnostic observed")
        else:
            context.add_result("FAIL", label, failure)
        return None

    if checked.returncode != 0:
        context.add_result(
            "FAIL", label,
            f"positive check failed (exit {checked.returncode}): {check_output[:300]!r}",
        )
        return None

    case_output = output_root / fixture.id
    case_output.mkdir(parents=True, exist_ok=False)
    try:
        ok, stdout, detail = context.native(entry, case_output, label)
    except OSError as exc:
        context.add_result("FAIL", label, f"native path could not start: {exc}")
        return None
    if not ok:
        context.add_result("FAIL", label, detail or "native path failed")
        return None

    actual = _normalized(stdout)
    assert fixture.stdout is not None
    expected = _normalized(fixture.stdout)
    if actual != expected:
        context.add_result(
            "FAIL", label,
            f"expected literal stdout {expected!r}, got {actual!r}",
        )
    else:
        lane = "project" if fixture.is_project else "single"
        context.add_result("PASS", label, f"{lane} check/build/link/run")
    return actual


def _run_internal_canary(
    context: RunnerContext, canary: InternalCanary,
) -> None:
    label = f"{canary.id}:internal"
    if context.internal_canary is None:
        context.add_result(
            "FAIL", label,
            "required Ring internal constructor/mutation callback is absent",
        )
        return
    try:
        observation = context.internal_canary(canary, label)
    except subprocess.TimeoutExpired:
        context.add_result("FAIL", label, "internal canary timed out")
        return
    except OSError as exc:
        context.add_result("FAIL", label, f"internal canary could not start: {exc}")
        return
    output = _normalized(observation.stdout + observation.stderr)
    expected = _normalized(canary.expected_panic_exact)
    if observation.returncode == 0:
        context.add_result("FAIL", label, "internal invalid state did not fail closed")
    elif output != expected:
        context.add_result(
            "FAIL", label,
            f"expected exact internal panic {expected!r}, got {output[:300]!r}",
        )
    else:
        context.add_result("PASS", label, "exact Ring internal panic observed")


def run_ownership_vertical(
    context: RunnerContext, *, name_filter: Optional[str] = None,
) -> None:
    """Execute the manifest against callbacks for the current compiler/runtime."""
    try:
        plan = load_manifest(context.manifest_path)
    except ManifestError as exc:
        context.add_result("FAIL", "manifest", str(exc))
        return

    selected = [
        fixture for fixture in plan.fixtures
        if _selected(fixture, name_filter, context.matches_filter)
    ]
    selected_ids = {fixture.id for fixture in selected}
    observed_stdout: Dict[str, str] = {}
    fixture_root = plan.path.parent
    with tempfile.TemporaryDirectory(prefix="ring_ownership_vertical_") as tmpdir:
        output_root = Path(tmpdir)
        for fixture in selected:
            actual = _run_fixture(context, fixture, fixture_root, output_root)
            if actual is not None:
                observed_stdout[fixture.id] = actual

    groups: Dict[str, List[Fixture]] = {}
    for fixture in plan.fixtures:
        if fixture.parity_group:
            groups.setdefault(fixture.parity_group, []).append(fixture)
    for group, members in groups.items():
        member_ids = {member.id for member in members}
        if not member_ids.issubset(selected_ids):
            continue
        missing = sorted(member_ids - observed_stdout.keys())
        label = f"parity:{group}"
        if missing:
            context.add_result(
                "FAIL", label, f"runtime parity blocked by failed members {missing}")
            continue
        outputs = {observed_stdout[member.id] for member in members}
        if len(outputs) != 1:
            details = {member.id: observed_stdout[member.id] for member in members}
            context.add_result("FAIL", label, f"literal stdout differs: {details!r}")
        else:
            context.add_result("PASS", label, "single/project literal stdout identical")

    for canary in plan.internal_canaries:
        identities = (canary.id, f"{canary.id}:internal", canary.requirement)
        if any(context.matches_filter(value, name_filter) for value in identities):
            _run_internal_canary(context, canary)


def _local_matches(name: str, name_filter: Optional[str]) -> bool:
    if not name_filter:
        return True
    return name_filter.replace("\\", "/").lower() in name.replace("\\", "/").lower()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="List or dry-run the ownership vertical manifest")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--filter", dest="name_filter", default=None)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--list", action="store_true",
                         help="List exact manifest entries (default).")
    actions.add_argument("--dry-run", action="store_true",
                         help="List the execution stages without invoking tools.")
    args = parser.parse_args(argv)
    try:
        plan = load_manifest(args.manifest)
    except ManifestError as exc:
        parser.error(str(exc))

    for fixture in plan.fixtures:
        if not _selected(fixture, args.name_filter, _local_matches):
            continue
        lane = "project" if fixture.is_project else "single"
        if args.dry_run:
            stages = "check -> diagnostic" if fixture.phase == "check" else (
                "check -> build -> link -> run -> literal stdout")
            print(f"{fixture.id}\t{lane}\t{stages}\t{fixture.path}")
        else:
            print(
                f"{fixture.id}\t{lane}\t{fixture.phase}/{fixture.status}\t"
                f"{fixture.path}\tsupport={len(fixture.support_paths)}"
            )
    for canary in plan.internal_canaries:
        identities = (canary.id, f"{canary.id}:internal", canary.requirement)
        if not any(_local_matches(value, args.name_filter) for value in identities):
            continue
        action = "callback -> exact fail-closed panic" if args.dry_run else "required callback"
        print(f"{canary.id}\tinternal\t{action}\t{canary.requirement}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
