"""B-176-only AB/BA gate for the disabled compiler phase-timing path."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import math
import os
import platform
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

import run as harness
import windows_job
from windows_job import preflight_job_support, run_in_job


BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parents[1]
DEFAULT_SCHEMA = BENCH_DIR / "disabled_path_gate.schema.json"
EVIDENCE_SCHEMA = "vorton.check-benchmark.disabled-path-gate.v2"
SCHEMA_ID = "vorton.check-benchmark.disabled-path-gate.schema.v2"
SCHEMA_CANONICAL_SHA256 = "e869d99a4d5b61a991c650664c58efdf38ccb4df1932063e2f176b62c6d4ce54"

SUBJECTS = ("base", "candidate")
WARMUP_PAIRS = 5
MEASURED_PAIRS = 41
MEDIAN_RATIO_MAX = 1.02
MEDIAN_DELTA_NS_MAX = 2_000_000
EXPECTED_STDOUT = b"OK\r\n"
EXPECTED_STDERR = b""
PHASE_ENV_PREFIX = "VORTON_PHASE_"
ANCHOR_PATH = "compiler/dist-c/main.c"
RUNTIME_PATH = "vorton_runtime.cpp"
FIXTURE_PATH = "tests/cases/hello.vorton"
GATE_PATH = "bench/check/disabled_path_gate.py"
SCHEMA_PATH = "bench/check/disabled_path_gate.schema.json"
HARNESS_PATH = "bench/check/run.py"
WINDOWS_JOB_PATH = "bench/check/windows_job.py"
STD_PATHS = (
    "std/io.vorton",
    "std/iterator.vorton",
    "std/list.vorton",
    "std/map.vorton",
    "std/set.vorton",
    "std/str.vorton",
    "std/num.vorton",
    "std/result.vorton",
    "std/fs.vorton",
    "std/path.vorton",
    "std/process.vorton",
)
BUILD_TIMEOUT_SECONDS = 1200
INVOCATION_TIMEOUT_SECONDS = 60
COMMIT_RE = re.compile(r"[0-9a-f]{40}")

COMPILER_FLAGS = ("-std=c11", "-O3", "-flto=thin")
RUNTIME_FLAGS = (
    "-std=c++17",
    "-D_CRT_SECURE_NO_WARNINGS",
    "-O3",
    "-flto=thin",
)
LINK_FLAGS = (
    "-lmsvcrt",
    "-Wl,/STACK:536870912",
    "-Wl,/MANIFEST:EMBED",
    "-Wl,/MANIFESTUAC:level='asInvoker'",
    "-flto=thin",
    "-fuse-ld=lld",
)
LTO_CACHE_POLICY = (
    "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:"
    "cache_size_files=4096:prune_after=168h"
)

GateError = harness.HarnessError


def _canonical_schema_sha(schema: Mapping[str, Any]) -> str:
    data = json.dumps(
        schema,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return harness._sha256_bytes(data)


def _load_schema(path: Path = DEFAULT_SCHEMA) -> Mapping[str, Any]:
    schema = harness._load_json(path)
    if not isinstance(schema, dict) or schema.get("$id") != SCHEMA_ID:
        raise GateError(f"gate schema $id must be {SCHEMA_ID!r}")
    actual = _canonical_schema_sha(schema)
    if actual != SCHEMA_CANONICAL_SHA256:
        raise GateError(
            "disabled-path schema differs from the canonical contract: "
            f"expected {SCHEMA_CANONICAL_SHA256}, got {actual}"
        )
    return schema


def _relative_file_record(path: Path, root: Path) -> dict[str, Any]:
    record = harness._file_record(path)
    record["path"] = path.resolve().relative_to(root.resolve()).as_posix()
    return record


def _input_record(path: str, data: bytes) -> dict[str, Any]:
    return {"path": path, "bytes": len(data), "sha256": harness._sha256_bytes(data)}


def _expected_order(index: int) -> list[str]:
    return ["base", "candidate"] if index % 2 == 0 else ["candidate", "base"]


def _contract() -> dict[str, Any]:
    return {
        "warmup_pairs": WARMUP_PAIRS,
        "measured_pairs": MEASURED_PAIRS,
        "even_order": ["base", "candidate"],
        "odd_order": ["candidate", "base"],
        "delta_definition": "candidate_minus_base",
        "median_ratio_max": MEDIAN_RATIO_MAX,
        "median_delta_ns_max": MEDIAN_DELTA_NS_MAX,
        "expected_exit_code": 0,
        "expected_stdout_base64": base64.b64encode(EXPECTED_STDOUT).decode("ascii"),
        "expected_stderr_base64": "",
        "phase_environment_prefix": PHASE_ENV_PREFIX,
        "git_archive_core_autocrlf": "false",
        "prelude_paths": list(STD_PATHS),
    }


def _require_contract(value: Mapping[str, Any]) -> None:
    if value != _contract():
        raise GateError("evidence budget/execution contract drifted")


def _flags() -> dict[str, Any]:
    return {
        "compiler": list(COMPILER_FLAGS),
        "runtime": list(RUNTIME_FLAGS),
        "link": [*LINK_FLAGS, "-Wl,/lldltocache:{stage_cache}", LTO_CACHE_POLICY],
    }


def _metric_stats(values: Sequence[int]) -> dict[str, Any]:
    ordered = sorted(values)
    if not ordered:
        raise GateError("cannot summarize an empty metric")
    median = statistics.median(ordered)
    return {
        "count": len(ordered),
        "median": median,
        "mad": statistics.median(abs(value - median) for value in ordered),
        "empirical_p95": ordered[math.ceil(0.95 * len(ordered)) - 1],
        "range": [ordered[0], ordered[-1]],
    }


def _recompute_summary(pairs: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    base: list[int] = []
    candidate: list[int] = []
    deltas: list[int] = []
    ratios: list[float] = []
    for pair in pairs:
        by_subject = {row["subject"]: row for row in pair["invocations"]}
        base_ns = by_subject["base"]["wall_ns"]
        candidate_ns = by_subject["candidate"]["wall_ns"]
        if base_ns <= 0 or candidate_ns <= 0:
            raise GateError("formal wall_ns values must be positive")
        base.append(base_ns)
        candidate.append(candidate_ns)
        deltas.append(candidate_ns - base_ns)
        ratios.append(candidate_ns / base_ns)
    median_ratio = statistics.median(ratios)
    median_delta = statistics.median(deltas)
    passed = median_ratio <= MEDIAN_RATIO_MAX and median_delta <= MEDIAN_DELTA_NS_MAX
    return {
        "base_wall_ns": _metric_stats(base),
        "candidate_wall_ns": _metric_stats(candidate),
        "candidate_minus_base_wall_ns": _metric_stats(deltas),
        "candidate_over_base_ratio": {"count": len(ratios), "median": median_ratio},
        "threshold_evaluation": {
            "median_ratio_at_most": median_ratio <= MEDIAN_RATIO_MAX,
            "median_delta_ns_at_most": median_delta <= MEDIAN_DELTA_NS_MAX,
        },
        "passed": passed,
    }


def _stage_layout(evidence_root: Path) -> dict[str, str]:
    stage = (evidence_root / "stage").resolve()
    return {
        "root": str(stage),
        "source": str(stage / "source"),
        "build": str(stage / "build"),
        "thinlto_cache": str(stage / "thinlto-cache"),
        "subject_base": str(stage / "subjects" / "base" / "vorton.exe"),
        "subject_candidate": str(stage / "subjects" / "candidate" / "vorton.exe"),
        "invocation_binary": str(stage / "invoke" / "vorton.exe"),
        "fixture": str(stage / "fixture" / "hello.vorton"),
        "std": str(stage / "std"),
        "cwd": str(stage / "cwd"),
    }


def _within(child: Path, parent: Path, label: str) -> Path:
    resolved = child.resolve()
    try:
        resolved.relative_to(parent.resolve())
    except ValueError as exc:
        raise GateError(f"{label} escapes its bounded parent") from exc
    if resolved == parent.resolve():
        raise GateError(f"{label} equals its bounded parent")
    return resolved


def _clear_stage_child(path: Path, stage_root: Path) -> None:
    resolved = _within(path, stage_root, "stage cleanup target")
    if resolved.exists():
        shutil.rmtree(resolved)


def _sidecar(root: Path, record: Mapping[str, Any], label: str) -> Path:
    relative = PurePosixPath(record["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise GateError(f"{label} escapes the evidence bundle")
    path = (root / Path(*relative.parts)).resolve()
    _within(path, root, label)
    if path.is_symlink() or not path.is_file():
        raise GateError(f"{label} is absent or not a regular file")
    actual = harness._file_record(path)
    if actual["bytes"] != record["bytes"] or actual["sha256"] != record["sha256"]:
        raise GateError(f"{label} hash/length differs from raw evidence")
    return path


def _coff_identity(path: Path) -> dict[str, Any]:
    data = bytearray(path.read_bytes())
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise GateError("built artifact is not PE/COFF")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    offset = pe_offset + 8
    if offset + 4 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise GateError("built artifact has an invalid PE header")
    timestamp = struct.unpack_from("<I", data, offset)[0]
    raw_hash = harness._sha256_bytes(bytes(data))
    data[offset : offset + 4] = b"\0\0\0\0"
    return {
        "bytes": len(data),
        "raw_sha256": raw_hash,
        "coff_normalized_sha256": harness._sha256_bytes(bytes(data)),
        "coff_timestamp_offset": offset,
        "coff_timestamp_value": timestamp,
    }


def _git_show(repo: Path, git_path: str, commit: str, path: str) -> bytes:
    if COMMIT_RE.fullmatch(commit) is None:
        raise GateError("subject commit is not one exact lowercase SHA")
    try:
        result = subprocess.run(
            [git_path, "-C", str(repo), "show", f"{commit}:{path}"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GateError(f"cannot read Git object {commit}:{path}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise GateError(f"Git object {commit}:{path} is unavailable: {detail}")
    return result.stdout


def _verify_source(
    repo: Path,
    git_path: str,
    commit: str,
    record: Mapping[str, Any],
    expected_path: str,
) -> bytes:
    if record["path"] != expected_path:
        raise GateError(f"source path must be {expected_path!r}")
    data = _git_show(repo, git_path, commit, expected_path)
    if _input_record(expected_path, data) != record:
        raise GateError(f"{commit}:{expected_path} hash/length differs")
    return data


def _require_current_contract_bytes(
    repo: Path, git_path: str, candidate_commit: str
) -> None:
    for path, current in (
        (GATE_PATH, Path(__file__).resolve()),
        (SCHEMA_PATH, DEFAULT_SCHEMA.resolve()),
        (HARNESS_PATH, Path(harness.__file__).resolve()),
        (WINDOWS_JOB_PATH, Path(windows_job.__file__).resolve()),
    ):
        if current.read_bytes() != _git_show(repo, git_path, candidate_commit, path):
            raise GateError(f"current {path} bytes differ from candidate ref")


def _require_archive_member_identity(
    repo: Path,
    git_path: str,
    commit: str,
    subject: str,
    inputs: Mapping[str, bytes],
) -> None:
    paths = [ANCHOR_PATH, RUNTIME_PATH, FIXTURE_PATH]
    paths.extend(STD_PATHS)
    if subject == "candidate":
        paths.extend((GATE_PATH, SCHEMA_PATH, HARNESS_PATH, WINDOWS_JOB_PATH))
    for path in paths:
        if path not in inputs or inputs[path] != _git_show(repo, git_path, commit, path):
            raise GateError(
                f"{subject} archive member bytes differ from Git object {commit}:{path}"
            )


def _verify_subjects(
    repo: Path, tools: Mapping[str, Any], subjects: Sequence[Mapping[str, Any]]
) -> None:
    if [row["subject"] for row in subjects] != list(SUBJECTS):
        raise GateError("subjects must be ordered base then candidate")
    _require_archive_symmetry(subjects)
    fixture_bytes: list[bytes] = []
    prelude_records: list[list[Mapping[str, Any]]] = []
    for index, subject in enumerate(subjects):
        commit = subject["commit"]
        git_path = tools["git"]["path"]
        _verify_source(repo, git_path, commit, subject["anchor"], ANCHOR_PATH)
        _verify_source(repo, git_path, commit, subject["runtime"], RUNTIME_PATH)
        fixture_bytes.append(
            _verify_source(repo, git_path, commit, subject["fixture"], FIXTURE_PATH)
        )
        prelude = subject["prelude_files"]
        if [record["path"] for record in prelude] != list(STD_PATHS):
            raise GateError("subject prelude inventory path/order drifted")
        for path, record in zip(STD_PATHS, prelude, strict=True):
            _verify_source(repo, git_path, commit, record, path)
        prelude_records.append(prelude)
        if index == 0:
            if any(
                subject[name] is not None
                for name in ("gate", "schema_contract", "harness", "windows_job")
            ):
                raise GateError("base must not claim candidate execution-closure bytes")
        else:
            gate = _verify_source(repo, git_path, commit, subject["gate"], GATE_PATH)
            schema = _verify_source(
                repo, git_path, commit, subject["schema_contract"], SCHEMA_PATH
            )
            harness_bytes = _verify_source(
                repo, git_path, commit, subject["harness"], HARNESS_PATH
            )
            windows_job_bytes = _verify_source(
                repo, git_path, commit, subject["windows_job"], WINDOWS_JOB_PATH
            )
            if Path(__file__).resolve().read_bytes() != gate:
                raise GateError("current gate bytes differ from candidate ref")
            if DEFAULT_SCHEMA.resolve().read_bytes() != schema:
                raise GateError("current schema bytes differ from candidate ref")
            if Path(harness.__file__).resolve().read_bytes() != harness_bytes:
                raise GateError("current harness bytes differ from candidate ref")
            if (
                Path(windows_job.__file__).resolve().read_bytes()
                != windows_job_bytes
            ):
                raise GateError("current windows_job bytes differ from candidate ref")
    if fixture_bytes[0] != fixture_bytes[1]:
        raise GateError("base/candidate fixture archive bytes differ")
    if prelude_records[0] != prelude_records[1]:
        raise GateError("base/candidate prelude archive bytes differ")


def _require_archive_symmetry(subjects: Sequence[Mapping[str, Any]]) -> None:
    if len(subjects) != 2 or subjects[0]["fixture"] != subjects[1]["fixture"]:
        raise GateError("base/candidate fixture archive bytes differ")
    if subjects[0]["prelude_files"] != subjects[1]["prelude_files"]:
        raise GateError("base/candidate prelude archive bytes differ")


def _tool_record(path: str, version: str) -> dict[str, Any]:
    record = harness._file_record(Path(path))
    record["version"] = version
    return record


def _verify_tools(tools: Mapping[str, Any]) -> None:
    if set(tools) != {"git", "clang", "clangxx", "lld_link", "python"}:
        raise GateError("tool records differ from the fixed tool set")
    for name, record in tools.items():
        actual = harness._file_record(Path(record["path"]))
        if any(actual[field] != record[field] for field in ("path", "sha256", "bytes")):
            raise GateError(f"recorded {name} executable identity changed")
        if not record["version"]:
            raise GateError(f"recorded {name} version is empty")


def _expected_build_commands(
    stage: Mapping[str, str], tools: Mapping[str, Any]
) -> list[tuple[str, list[str]]]:
    source, build = Path(stage["source"]), Path(stage["build"])
    compiler_object, runtime_object = (
        build / "vorton_compiler_lto.o",
        build / "vorton_runtime_lto.o",
    )
    return [
        (
            "anchor_compile",
            [
                tools["clang"]["path"], "-c", str(source / ANCHOR_PATH),
                "-o", str(compiler_object), *COMPILER_FLAGS,
            ],
        ),
        (
            "runtime_compile",
            [
                tools["clangxx"]["path"], "-c", str(source / RUNTIME_PATH),
                "-o", str(runtime_object), *RUNTIME_FLAGS,
            ],
        ),
        (
            "link",
            [
                tools["clang"]["path"], str(compiler_object), str(runtime_object),
                "-o", str(build / "vorton.exe"), *LINK_FLAGS[:-1],
                f"-B{Path(tools['lld_link']['path']).resolve().parent}",
                LINK_FLAGS[-1],
                f"-Wl,/lldltocache:{stage['thinlto_cache']}", LTO_CACHE_POLICY,
            ],
        ),
    ]


def _selected_lld_link(stderr: str) -> Path | None:
    for line in stderr.splitlines():
        match = re.match(r'^\s*("(?:\\.|[^"])*")', line)
        if match is None:
            continue
        try:
            token = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        candidate = Path(token)
        if candidate.name.lower() not in {"lld-link", "lld-link.exe"}:
            continue
        if candidate.suffix.lower() != ".exe":
            candidate = Path(str(candidate) + ".exe")
        return candidate.resolve()
    return None


def _expected_linker_binding(
    argv: Sequence[str], cwd: Path, lld_link: Path
) -> dict[str, Any]:
    claimed = str(lld_link.resolve())
    return {
        "schema": harness.LINKER_BINDING_SCHEMA,
        "probe_argv": [argv[0], "-###", *argv[1:]],
        "cwd": str(cwd.resolve()),
        "claimed_path": claimed,
        "selected_path": claimed,
        "exit_code": 0,
    }


def _probe_linker_binding(
    argv: Sequence[str], cwd: Path, lld_link: Path,
    environment: Mapping[str, str],
    *,
    root: Path,
    stem: str,
) -> dict[str, Any]:
    expected = _expected_linker_binding(argv, cwd, lld_link)
    try:
        completed = subprocess.run(
            expected["probe_argv"], cwd=cwd, env=environment,
            capture_output=True,
            timeout=60, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GateError(f"cannot probe clang linker binding: {exc}") from exc
    stdout = root / "raw" / f"{stem}.stdout"
    stderr = root / "raw" / f"{stem}.stderr"
    stdout.parent.mkdir(parents=True, exist_ok=True)
    stdout.write_bytes(completed.stdout)
    stderr.write_bytes(completed.stderr)
    selected = _selected_lld_link(
        completed.stderr.decode("utf-8", errors="replace")
    )
    if completed.returncode != 0 or selected != lld_link.resolve():
        raise GateError(
            "clang linker binding probe did not select the claimed lld-link: "
            f"claimed={lld_link.resolve()}, selected={selected}, "
            f"exit={completed.returncode}"
        )
    return {
        **expected,
        "stdout": _relative_file_record(stdout, root),
        "stderr": _relative_file_record(stderr, root),
    }


def _verify_linker_binding(
    root: Path,
    binding: Mapping[str, Any],
    expected: Mapping[str, Any],
    seen: set[str],
    label: str,
) -> None:
    if set(binding) != {*expected, "stdout", "stderr"} or any(
        binding.get(name) != value for name, value in expected.items()
    ):
        raise GateError(f"{label} linker binding provenance drifted")
    sidecars: dict[str, Path] = {}
    for stream in ("stdout", "stderr"):
        record = binding[stream]
        if record["path"] in seen:
            raise GateError("linker probe sidecar path is reused")
        seen.add(record["path"])
        sidecars[stream] = _sidecar(root, record, f"{label}.linker_probe.{stream}")
    selected = _selected_lld_link(
        sidecars["stderr"].read_bytes().decode("utf-8", errors="replace")
    )
    if selected != Path(expected["claimed_path"]).resolve():
        raise GateError(
            f"{label} raw linker probe did not select the claimed lld-link"
        )


def _verify_builds(
    root: Path,
    stage: Mapping[str, str],
    tools: Mapping[str, Any],
    subjects: Sequence[Mapping[str, Any]],
) -> None:
    expected = _expected_build_commands(stage, tools)
    seen: set[str] = set()
    for sequence, subject in enumerate(subjects):
        if subject["build_sequence"] != sequence or len(subject["build"]) != 3:
            raise GateError("build sequence/count drifted")
        for record, (phase, argv) in zip(subject["build"], expected, strict=True):
            if (
                record["phase"] != phase
                or record["argv"] != argv
                or record["cwd"] != stage["source"]
                or record["timeout_seconds"] != BUILD_TIMEOUT_SECONDS
                or record["exit_code"] != 0
                or record["timed_out"]
                or record["measurement_errors"]
            ):
                raise GateError(f"{subject['subject']} {phase} raw contract drifted")
            for stream in ("stdout", "stderr"):
                if record[stream]["path"] in seen:
                    raise GateError("build sidecar path is reused")
                seen.add(record[stream]["path"])
                _sidecar(root, record[stream], f"build.{subject['subject']}.{phase}.{stream}")
        expected_binding = _expected_linker_binding(
            expected[-1][1], Path(stage["source"]), Path(tools["lld_link"]["path"])
        )
        _verify_linker_binding(
            root,
            subject["linker_binding"],
            expected_binding,
            seen,
            str(subject["subject"]),
        )


def _verify_rows(
    root: Path,
    stage: Mapping[str, str],
    subjects: Sequence[Mapping[str, Any]],
    warmups: Sequence[Mapping[str, Any]],
    pairs: Sequence[Mapping[str, Any]],
) -> None:
    if len(warmups) != WARMUP_PAIRS or len(pairs) != MEASURED_PAIRS:
        raise GateError("warm-up/formal pair count drifted")
    hashes = {row["subject"]: row["binary"]["raw_sha256"] for row in subjects}
    expected_argv = [stage["invocation_binary"], "check", stage["fixture"]]
    ordinal, seen = 0, set()
    for kind, rows in (("warmup", warmups), ("pair", pairs)):
        for index, pair in enumerate(rows):
            order = _expected_order(index)
            if (
                pair["index"] != index
                or pair["order"] != order
                or [row["subject"] for row in pair["invocations"]] != order
            ):
                raise GateError(f"{kind} pair/order/index drifted")
            for row in pair["invocations"]:
                if (
                    row["ordinal"] != ordinal
                    or row["binary_raw_sha256"] != hashes[row["subject"]]
                    or row["argv"] != expected_argv
                    or row["cwd"] != stage["cwd"]
                    or row["timeout_seconds"] != INVOCATION_TIMEOUT_SECONDS
                    or row["wall_ns"] <= 0
                    or row["exit_code"] != 0
                    or row["timed_out"]
                    or row["measurement_errors"]
                ):
                    raise GateError(f"{kind} invocation raw contract drifted")
                ordinal += 1
                for stream, expected in (
                    ("stdout", EXPECTED_STDOUT), ("stderr", EXPECTED_STDERR)
                ):
                    if row[stream]["path"] in seen:
                        raise GateError("invocation sidecar path is reused")
                    seen.add(row[stream]["path"])
                    if _sidecar(root, row[stream], f"{kind}.{stream}").read_bytes() != expected:
                        raise GateError(f"{kind} {stream} bytes violate the exact contract")


def verify_evidence(
    evidence_path: Path,
    *,
    schema_path: Path = DEFAULT_SCHEMA,
    repo: Path = REPO_ROOT,
) -> dict[str, Any]:
    schema = _load_schema(schema_path)
    evidence = harness._load_json(evidence_path)
    harness.validate_json(evidence, schema)
    if evidence["schema"] != EVIDENCE_SCHEMA:
        raise GateError("evidence schema drifted")
    _require_contract(evidence["contract"])
    if evidence["flags"] != _flags():
        raise GateError("build flags drifted")
    root, repo = evidence_path.resolve().parent, repo.resolve()
    if evidence["stage"] != _stage_layout(root):
        raise GateError("stage layout is not the one bounded layout")
    repository = evidence["repository"]
    if Path(repository["path"]).resolve() != repo or repository["base_commit"] == repository["candidate_commit"]:
        raise GateError("repository/commit identity is inconsistent")
    _verify_tools(evidence["tools"])
    subjects = evidence["subjects"]
    if [row["commit"] for row in subjects] != [
        repository["base_commit"], repository["candidate_commit"]
    ]:
        raise GateError("subject commits differ from repository identity")
    _verify_subjects(repo, evidence["tools"], subjects)
    _verify_builds(root, evidence["stage"], evidence["tools"], subjects)
    _verify_rows(root, evidence["stage"], subjects, evidence["warmups"], evidence["pairs"])
    environment = evidence["environment"]
    if (
        environment["power_before"]["active_scheme"]
        != environment["power_after"]["active_scheme"]
        or environment["power_before"]["ac_line_status"]
        != environment["power_after"]["ac_line_status"]
        or any(not name.upper().startswith(PHASE_ENV_PREFIX) for name in environment["removed_phase_environment"])
    ):
        raise GateError("power state or cleared phase environment record is inconsistent")
    summary = _verify_claimed_result(
        evidence["pairs"], evidence["claimed_summary"], evidence["claimed_verdict"]
    )
    if not summary["passed"]:
        raise GateError("disabled-default-path budget thresholds failed")
    return summary


def _verify_claimed_result(
    pairs: Sequence[Mapping[str, Any]],
    claimed_summary: Mapping[str, Any],
    claimed_verdict: str,
) -> dict[str, Any]:
    summary = _recompute_summary(pairs)
    if claimed_summary != summary:
        raise GateError("stored summary differs from raw pair statistics")
    verdict = "PASS" if summary["passed"] else "FAIL"
    if claimed_verdict != verdict:
        raise GateError("stored PASS/FAIL differs from the raw threshold result")
    return summary


def _job_command(
    argv: Sequence[str],
    *,
    cwd: Path,
    environment: Mapping[str, str],
    root: Path,
    stem: str,
    timeout: int,
    phase: str,
) -> dict[str, Any]:
    stdout, stderr = root / "raw" / f"{stem}.stdout", root / "raw" / f"{stem}.stderr"
    measurement = run_in_job(
        list(argv), cwd=cwd, env=environment, stdout_path=stdout,
        stderr_path=stderr, timeout_seconds=timeout,
    )
    return {
        "phase": phase,
        "argv": list(argv),
        "cwd": str(cwd.resolve()),
        "timeout_seconds": timeout,
        "wall_ns": measurement["wall_ns"],
        "exit_code": measurement["exit_code"],
        "timed_out": measurement["timed_out"],
        "measurement_errors": measurement["measurement_errors"],
        "stdout": _relative_file_record(stdout, root),
        "stderr": _relative_file_record(stderr, root),
    }


def _require_command(record: Mapping[str, Any], label: str) -> None:
    if record["exit_code"] != 0 or record["timed_out"] or record["measurement_errors"]:
        raise GateError(f"{label} did not finish cleanly")


def _capture(
    argv: Sequence[str], *, cwd: Path, environment: Mapping[str, str], root: Path, stem: str
) -> bytes:
    record = _job_command(
        argv, cwd=cwd, environment=environment, root=root, stem=stem,
        timeout=120, phase="preflight",
    )
    _require_command(record, stem)
    return _sidecar(root, record["stdout"], stem).read_bytes()


def _archive_argv(
    git: str, repo: Path, archive: Path, commit: str
) -> list[str]:
    return [
        git,
        "-c",
        "core.autocrlf=false",
        "-C",
        str(repo),
        "archive",
        "--format=tar",
        f"--output={archive}",
        commit,
    ]


def _require_clean_candidate(
    base_ref: str,
    candidate_ref: str,
    head: str,
    base: str,
    candidate: str,
    status: bytes,
) -> None:
    if COMMIT_RE.fullmatch(base_ref) is None or COMMIT_RE.fullmatch(candidate_ref) is None:
        raise GateError("run accepts only exact lowercase 40-character commit SHAs")
    if base_ref != base or candidate_ref != candidate or head != candidate:
        raise GateError("candidate ref/head or exact ref resolution mismatched")
    if base == candidate or status:
        raise GateError("candidate must differ from base and have a clean worktree")


def _extract_archive(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    root = destination.resolve()
    with tarfile.open(archive_path, "r:") as archive:
        for member in archive.getmembers():
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts or not (member.isdir() or member.isfile()):
                raise GateError(f"unsafe archive member {member.name!r}")
            target = (root / Path(*relative.parts)).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise GateError(f"archive member escapes stage: {member.name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(member)
                if stream is None:
                    raise GateError(f"cannot extract {member.name}")
                with target.open("wb") as output:
                    shutil.copyfileobj(stream, output)


def _archive_inputs(archive_path: Path, commit: str) -> dict[str, bytes]:
    required = {ANCHOR_PATH, RUNTIME_PATH, FIXTURE_PATH, *STD_PATHS}
    wanted = {
        GATE_PATH, SCHEMA_PATH, HARNESS_PATH, WINDOWS_JOB_PATH, *required,
    }
    result: dict[str, bytes] = {}
    with tarfile.open(archive_path, "r:") as archive:
        if archive.pax_headers.get("comment") != commit:
            raise GateError("Git archive commit marker mismatched")
        for member in archive.getmembers():
            name = PurePosixPath(member.name).as_posix().lstrip("./")
            if name in wanted:
                if not member.isfile():
                    raise GateError(f"archive input {name} is not a file")
                stream = archive.extractfile(member)
                if stream is None:
                    raise GateError(f"cannot read archive input {name}")
                result[name] = stream.read()
    missing = required - result.keys()
    if missing:
        raise GateError(f"archive lacks inputs {sorted(missing)}")
    return result


def _collect_tools() -> dict[str, Any]:
    names = {"git": "git", "clang": "clang", "clangxx": "clang++", "lld_link": "lld-link"}
    result: dict[str, Any] = {}
    for key, name in names.items():
        path = harness._tool_path(name)
        version = harness._tool_version(path)
        if path is None or not version:
            raise GateError(f"required tool/version unavailable: {name}")
        result[key] = _tool_record(path, version)
    result["python"] = _tool_record(str(Path(sys.executable).resolve()), sys.version)
    return result


def _build_subject(
    subject: str,
    sequence: int,
    commit: str,
    archive: Path,
    inputs: Mapping[str, bytes],
    stage: Mapping[str, str],
    tools: Mapping[str, Any],
    environment: Mapping[str, str],
    root: Path,
) -> dict[str, Any]:
    stage_root, source, build = Path(stage["root"]), Path(stage["source"]), Path(stage["build"])
    _clear_stage_child(source, stage_root)
    _clear_stage_child(build, stage_root)
    _extract_archive(archive, source)
    build.mkdir(parents=True)
    Path(stage["thinlto_cache"]).mkdir(parents=True, exist_ok=True)
    for path, data in inputs.items():
        if (source / path).read_bytes() != data:
            raise GateError(f"extracted {subject} bytes differ for {path}")
    commands = []
    linker_binding: dict[str, Any] | None = None
    for phase, argv in _expected_build_commands(stage, tools):
        if phase == "link":
            linker_binding = _probe_linker_binding(
                argv,
                source,
                Path(tools["lld_link"]["path"]),
                environment,
                root=root,
                stem=f"build-{subject}-linker-probe",
            )
        record = _job_command(
            argv, cwd=source, environment=environment, root=root,
            stem=f"build-{subject}-{phase}", timeout=BUILD_TIMEOUT_SECONDS, phase=phase,
        )
        _require_command(record, f"{subject} {phase}")
        commands.append(record)
    built = build / "vorton.exe"
    binary = _coff_identity(built)
    slot = Path(stage[f"subject_{subject}"])
    slot.parent.mkdir(parents=True)
    shutil.copy2(built, slot)
    if harness._sha256_file(slot) != binary["raw_sha256"]:
        raise GateError("subject slot copy changed binary bytes")
    gate = schema = harness_record = windows_job_record = None
    if subject == "candidate":
        required_contract = {GATE_PATH, SCHEMA_PATH, HARNESS_PATH, WINDOWS_JOB_PATH}
        if not required_contract.issubset(inputs):
            raise GateError("candidate archive lacks the gate execution closure")
        if (
            Path(__file__).resolve().read_bytes() != inputs[GATE_PATH]
            or DEFAULT_SCHEMA.read_bytes() != inputs[SCHEMA_PATH]
            or Path(harness.__file__).resolve().read_bytes() != inputs[HARNESS_PATH]
            or Path(windows_job.__file__).resolve().read_bytes() != inputs[WINDOWS_JOB_PATH]
        ):
            raise GateError("current gate execution closure differs from candidate ref")
        gate, schema = _input_record(GATE_PATH, inputs[GATE_PATH]), _input_record(SCHEMA_PATH, inputs[SCHEMA_PATH])
        harness_record = _input_record(HARNESS_PATH, inputs[HARNESS_PATH])
        windows_job_record = _input_record(WINDOWS_JOB_PATH, inputs[WINDOWS_JOB_PATH])
    if linker_binding is None:
        raise GateError(f"{subject} build omitted the linker binding probe")
    return {
        "subject": subject,
        "commit": commit,
        "build_sequence": sequence,
        "anchor": _input_record(ANCHOR_PATH, inputs[ANCHOR_PATH]),
        "runtime": _input_record(RUNTIME_PATH, inputs[RUNTIME_PATH]),
        "fixture": _input_record(FIXTURE_PATH, inputs[FIXTURE_PATH]),
        "prelude_files": [_input_record(path, inputs[path]) for path in STD_PATHS],
        "gate": gate,
        "schema_contract": schema,
        "harness": harness_record,
        "windows_job": windows_job_record,
        "binary": binary,
        "build": commands,
        "linker_binding": linker_binding,
    }


def _measure(
    ordinal: int,
    subject: Mapping[str, Any],
    stage: Mapping[str, str],
    environment: Mapping[str, str],
    root: Path,
    stem: str,
) -> dict[str, Any]:
    invocation_binary = Path(stage["invocation_binary"])
    invocation_binary.parent.mkdir(parents=True, exist_ok=True)
    if invocation_binary.exists():
        invocation_binary.unlink()
    shutil.copy2(Path(stage[f"subject_{subject['subject']}"]), invocation_binary)
    if harness._sha256_file(invocation_binary) != subject["binary"]["raw_sha256"]:
        raise GateError("invocation binary copy changed bytes")
    record = _job_command(
        [str(invocation_binary), "check", stage["fixture"]],
        cwd=Path(stage["cwd"]), environment=environment, root=root, stem=stem,
        timeout=INVOCATION_TIMEOUT_SECONDS, phase="check",
    )
    row = {
        "ordinal": ordinal,
        "subject": subject["subject"],
        "binary_raw_sha256": subject["binary"]["raw_sha256"],
        **{key: record[key] for key in (
            "argv", "cwd", "timeout_seconds", "wall_ns", "exit_code",
            "timed_out", "measurement_errors", "stdout", "stderr",
        )},
    }
    if row["exit_code"] != 0 or row["timed_out"] or row["measurement_errors"]:
        raise GateError(f"{stem} invocation failed")
    if _sidecar(root, row["stdout"], stem).read_bytes() != EXPECTED_STDOUT or _sidecar(root, row["stderr"], stem).read_bytes() != EXPECTED_STDERR:
        raise GateError(f"{stem} stdout/stderr contract failed")
    return row


def _record_pairs(
    kind: str,
    count: int,
    ordinal: int,
    subjects: Sequence[Mapping[str, Any]],
    stage: Mapping[str, str],
    environment: Mapping[str, str],
    root: Path,
) -> tuple[list[dict[str, Any]], int]:
    by_name = {row["subject"]: row for row in subjects}
    pairs = []
    for index in range(count):
        order, invocations = _expected_order(index), []
        for position, name in enumerate(order):
            invocations.append(
                _measure(
                    ordinal, by_name[name], stage, environment, root,
                    f"{kind}-{index:02d}-{position}-{name}",
                )
            )
            ordinal += 1
        pairs.append({"index": index, "order": order, "invocations": invocations})
    return pairs, ordinal


def _write_neutral_std(stage: Mapping[str, str], inputs: Mapping[str, bytes]) -> None:
    std_dir = Path(stage["std"])
    std_dir.mkdir(parents=True, exist_ok=False)
    for path in STD_PATHS:
        if path not in inputs:
            raise GateError(f"neutral prelude input is missing: {path}")
        target = std_dir / PurePosixPath(path).name
        target.write_bytes(inputs[path])
        if target.read_bytes() != inputs[path]:
            raise GateError(f"neutral prelude copy changed bytes: {path}")


def _prepare_output(output: Path, repo: Path) -> Path:
    root = output.resolve()
    _within(root, repo / "bench" / "check" / "results", "gate output")
    if root.exists():
        raise GateError("gate output must not already exist")
    (root / "raw").mkdir(parents=True)
    (root / "stage").mkdir()
    return root


def _commit(value: bytes, label: str) -> str:
    try:
        result = value.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise GateError(f"{label} is not ASCII") from exc
    if COMMIT_RE.fullmatch(result) is None:
        raise GateError(f"{label} is not one exact commit")
    return result


def run_gate(base_ref: str, candidate_ref: str, output: Path, repo: Path = REPO_ROOT) -> Path:
    if os.name != "nt":
        raise GateError("disabled-path gate is Windows-only")
    repo, root = repo.resolve(), _prepare_output(output, repo.resolve())
    stage = _stage_layout(root)
    environment, removed = dict(os.environ), []
    for name in list(environment):
        if name.upper().startswith(PHASE_ENV_PREFIX):
            removed.append(name)
            del environment[name]
    removed.sort()
    preflight_job_support()
    tools = _collect_tools()
    git = tools["git"]["path"]
    git_argv = lambda *args: [git, "-C", str(repo), *args]
    status = _capture(git_argv("status", "--porcelain=v1", "--untracked-files=all"), cwd=repo, environment=environment, root=root, stem="preflight-status")
    head = _commit(_capture(git_argv("rev-parse", "--verify", "HEAD^{commit}"), cwd=repo, environment=environment, root=root, stem="preflight-head"), "HEAD")
    base = _commit(_capture(git_argv("rev-parse", "--verify", f"{base_ref}^{{commit}}"), cwd=repo, environment=environment, root=root, stem="preflight-base"), "base")
    candidate = _commit(_capture(git_argv("rev-parse", "--verify", f"{candidate_ref}^{{commit}}"), cwd=repo, environment=environment, root=root, stem="preflight-candidate"), "candidate")
    _require_clean_candidate(base_ref, candidate_ref, head, base, candidate, status)
    _require_current_contract_bytes(repo, git, candidate)

    archive_dir = Path(stage["root"]) / "archives"
    archive_dir.mkdir()
    archived: list[tuple[str, str, Path, dict[str, bytes]]] = []
    for sequence, (name, commit) in enumerate(zip(SUBJECTS, (base, candidate), strict=True)):
        archive = archive_dir / f"{name}.tar"
        command = _job_command(
            _archive_argv(git, repo, archive, commit),
            cwd=repo, environment=environment, root=root, stem=f"archive-{name}",
            timeout=300, phase="git_archive",
        )
        _require_command(command, f"archive {name}")
        inputs = _archive_inputs(archive, commit)
        _require_archive_member_identity(repo, git, commit, name, inputs)
        archived.append((name, commit, archive, inputs))
    if archived[0][3][FIXTURE_PATH] != archived[1][3][FIXTURE_PATH]:
        raise GateError("base/candidate fixture archive bytes differ")
    for path in STD_PATHS:
        if archived[0][3][path] != archived[1][3][path]:
            raise GateError(f"base/candidate prelude archive bytes differ: {path}")

    subjects = [
        _build_subject(
            name,
            sequence,
            commit,
            archive,
            inputs,
            stage,
            tools,
            environment,
            root,
        )
        for sequence, (name, commit, archive, inputs) in enumerate(archived)
    ]
    _require_archive_symmetry(subjects)
    fixture = Path(stage["fixture"])
    fixture.parent.mkdir(parents=True)
    fixture.write_bytes(archived[1][3][FIXTURE_PATH])
    _write_neutral_std(stage, archived[1][3])
    Path(stage["cwd"]).mkdir()

    power_before = harness._windows_power()
    warmups, ordinal = _record_pairs("warmup", WARMUP_PAIRS, 0, subjects, stage, environment, root)
    pairs, ordinal = _record_pairs("pair", MEASURED_PAIRS, ordinal, subjects, stage, environment, root)
    if ordinal != 92:
        raise GateError("invocation count drifted")
    power_after = harness._windows_power()
    if power_before["active_scheme"] != power_after["active_scheme"] or power_before["ac_line_status"] != power_after["ac_line_status"]:
        raise GateError("power scheme/AC state changed during gate")
    machine = {
        "os_system": platform.system(),
        "os_release": platform.release(),
        "os_version": platform.version(),
        "machine": platform.machine(),
        "cpu": harness._windows_cpu_model(),
        "logical_cores": os.cpu_count(),
        "total_memory_bytes": harness._windows_memory_bytes(),
    }
    if any(value is None or value == "" for value in machine.values()):
        raise GateError("machine identity is incomplete")
    summary = _recompute_summary(pairs)
    evidence = {
        "schema": EVIDENCE_SCHEMA,
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "contract": _contract(),
        "repository": {"path": str(repo), "base_commit": base, "candidate_commit": candidate},
        "stage": stage,
        "tools": tools,
        "flags": _flags(),
        "environment": {
            "machine": machine,
            "power_before": power_before,
            "power_after": power_after,
            "removed_phase_environment": removed,
        },
        "subjects": subjects,
        "warmups": warmups,
        "pairs": pairs,
        "claimed_summary": summary,
        "claimed_verdict": "PASS" if summary["passed"] else "FAIL",
    }
    target = root / ("evidence.pending.json" if summary["passed"] else "evidence.failed.json")
    harness._json_dump(target, evidence)
    if not summary["passed"]:
        verify_evidence(target, repo=repo)
    try:
        verify_evidence(target, repo=repo)
    except BaseException:
        if target.name == "evidence.pending.json" and target.is_file():
            target.unlink()
        raise
    _clear_stage_child(Path(stage["root"]), root)
    if Path(stage["root"]).exists():
        raise GateError("verified stage cleanup was incomplete")
    final = root / "evidence.json"
    target.replace(final)
    return final


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--base-ref", required=True)
    run.add_argument("--candidate-ref", required=True)
    run.add_argument("--output", required=True, type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("--evidence", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        evidence = (
            run_gate(args.base_ref, args.candidate_ref, args.output)
            if args.command == "run"
            else args.evidence
        )
        summary = verify_evidence(evidence)
    except GateError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({
        "evidence": str(evidence.resolve()),
        "median_delta_ns": summary["candidate_minus_base_wall_ns"]["median"],
        "median_ratio": summary["candidate_over_base_ratio"]["median"],
        "verdict": "PASS",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
