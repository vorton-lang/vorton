from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CASES = Path(__file__).resolve().parent / "cases"
MANIFEST = CASES / "manifest.json"
RUNS = ROOT / "target" / "semantic-guard" / "runs"
PROBE_TEMPLATE = Path(__file__).resolve().parent / "probe.rs"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
EXPECTED_CATEGORIES = {
    "type-formation-public-boundary",
    "method-selection",
    "associated-type-evidence",
    "instantiation-generic-domain",
    "effect-consumers",
}


class GuardError(RuntimeError):
    """A missing input, tool failure, or semantic verdict mismatch."""


@dataclass(frozen=True)
class Observation:
    status: str
    returncode: int
    stdout: str
    stderr: str


def display_command(arguments: list[str]) -> str:
    return " ".join(f'"{argument}"' if " " in argument else argument for argument in arguments)


def run_command(
    arguments: list[str],
    *,
    cwd: Path,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    print(f"$ {display_command(arguments)}", flush=True)
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as error:
        raise GuardError(f"cannot execute {arguments[0]}: {error}") from error
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.stderr:
        print(
            result.stderr,
            end="" if result.stderr.endswith("\n") else "\n",
            file=sys.stderr,
            flush=True,
        )
    return result


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise GuardError(f"{label} exited with code {result.returncode}")


def exact_commit(repository: Path, revision: str) -> str:
    result = run_command(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"], cwd=repository
    )
    require_success(result, f"resolve candidate revision {revision}")
    commits = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(commits) != 1 or SHA_PATTERN.fullmatch(commits[0]) is None:
        raise GuardError(f"revision {revision!r} did not resolve to one 40-hex commit")
    return commits[0]


def guard_identity() -> tuple[str, bool]:
    sha = exact_commit(ROOT, "HEAD")
    status = run_command(["git", "status", "--porcelain=v1"], cwd=ROOT)
    require_success(status, "read guard checkout status")
    return sha, bool(status.stdout.strip())


def load_manifest() -> list[dict[str, Any]]:
    try:
        payload = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GuardError(f"cannot read semantic case manifest {MANIFEST}: {error}") from error
    cases = payload.get("cases") if isinstance(payload, dict) else None
    if not isinstance(cases, list) or not cases:
        raise GuardError("semantic case manifest has no non-empty cases array")
    identifiers: set[str] = set()
    categories: set[str] = set()
    failure_count = 0
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            raise GuardError("every semantic case needs a string id")
        if case["id"] in identifiers:
            raise GuardError(f"duplicate semantic case id {case['id']}")
        identifiers.add(case["id"])
        categories.add(case.get("category"))
        for field in ("category", "historical_sha", "source", "historical", "candidate"):
            if field not in case:
                raise GuardError(f"semantic case {case['id']} has no {field}")
        if SHA_PATTERN.fullmatch(case["historical_sha"]) is None:
            raise GuardError(f"semantic case {case['id']} has an invalid historical SHA")
        source = CASES / case["source"]
        if not source.is_file():
            raise GuardError(f"semantic case {case['id']} source does not exist: {source}")
        contract = case.get("contract")
        if contract is not None and not (CASES / contract).is_file():
            raise GuardError(f"semantic case {case['id']} contract does not exist: {contract}")
        if case.get("role") == "historical_failure":
            failure_count += 1
            if case["historical"] == case["candidate"]:
                raise GuardError(
                    f"historical failure {case['id']} does not distinguish the bad revision"
                )
        elif case.get("role") != "control":
            raise GuardError(f"semantic case {case['id']} has an unknown role")
    if categories != EXPECTED_CATEGORIES:
        raise GuardError(
            f"semantic case categories are {sorted(categories)}, expected {sorted(EXPECTED_CATEGORIES)}"
        )
    if failure_count == 0:
        raise GuardError("semantic case manifest has no historical failures")
    return cases


def _safe_extract(archive: Path, destination: Path) -> None:
    root = destination.resolve()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise GuardError(f"git archive contains an unsafe path: {member.name}")
        source.extractall(destination)


def prepare_probe(repository: Path, sha: str, label: str) -> Path:
    RUNS.mkdir(parents=True, exist_ok=True)
    run_root = Path(tempfile.mkdtemp(prefix=f"{label}-{sha[:8]}-", dir=RUNS))
    snapshot = run_root / "snapshot"
    snapshot.mkdir()
    archive = run_root / "snapshot.tar"
    archived = run_command(
        ["git", "archive", "--format=tar", "--output", str(archive), sha], cwd=repository
    )
    require_success(archived, f"archive exact commit {sha}")
    _safe_extract(archive, snapshot)

    resolved = exact_commit(repository, sha)
    if resolved != sha:
        raise GuardError(f"archived revision changed from {sha} to {resolved}")
    cargo_toml = snapshot / "Cargo.toml"
    workspace = cargo_toml.read_text(encoding="utf-8")
    old_members = 'members = ["crates/vorton-compiler"]'
    if workspace.count(old_members) != 1:
        raise GuardError(f"exact snapshot {sha} has an unexpected workspace member declaration")
    cargo_toml.write_text(
        workspace.replace(
            old_members,
            'members = ["crates/vorton-compiler", "semantic-guard-probe"]',
        ),
        encoding="utf-8",
    )
    probe = snapshot / "semantic-guard-probe"
    (probe / "src").mkdir(parents=True)
    (probe / "Cargo.toml").write_text(
        """[package]\nname = "vorton-semantic-guard-probe"\nversion = "0.0.0"\nedition = "2024"\npublish = false\n\n[dependencies]\nvorton-compiler = { path = "../crates/vorton-compiler" }\n""",
        encoding="utf-8",
    )
    shutil.copyfile(PROBE_TEMPLATE, probe / "src" / "main.rs")

    lockfile = snapshot / "Cargo.lock"
    lock = lockfile.read_text(encoding="utf-8")
    if 'name = "vorton-semantic-guard-probe"' in lock:
        raise GuardError(f"exact snapshot {sha} already contains the probe package")
    lockfile.write_text(
        lock.rstrip()
        + "\n\n[[package]]\n"
        + 'name = "vorton-semantic-guard-probe"\n'
        + 'version = "0.0.0"\n'
        + 'dependencies = [\n "vorton-compiler",\n]\n',
        encoding="utf-8",
    )
    built = run_command(["cargo", "build", "--workspace", "--locked"], cwd=snapshot)
    require_success(built, f"build exact historical compiler and public probe for {sha}")

    executable = snapshot / "target" / "debug" / "vorton-semantic-guard-probe"
    if os.name == "nt":
        executable = executable.with_suffix(".exe")
    if not executable.is_file():
        raise GuardError(f"probe executable was not produced for {sha}: {executable}")
    print(f"PROBE_SNAPSHOT={snapshot} TESTED_SHA={sha}")
    return executable


def observe_case(executable: Path, case: dict[str, Any]) -> Observation:
    arguments = [str(executable), str(CASES / case["source"])]
    if contract := case.get("contract"):
        arguments.extend(["--contract", str(CASES / contract)])
    if stack_bytes := case.get("stack_bytes"):
        arguments.extend(["--stack-bytes", str(stack_bytes)])
    result = run_command(arguments, cwd=ROOT)
    if "VERDICT=ACCEPT" in result.stdout and result.returncode == 0:
        status = "accept"
    elif "VERDICT=REJECT" in result.stdout and result.returncode == 2:
        status = "reject"
    elif "VERDICT=DECODE_ERROR" in result.stdout and result.returncode == 3:
        status = "decode_error"
    elif result.returncode != 0:
        status = "product_crash"
    else:
        status = "infrastructure_error"
    return Observation(status, result.returncode, result.stdout, result.stderr)


def require_observation(
    case: dict[str, Any], observation: Observation, expectation_field: str
) -> None:
    expectation = case[expectation_field]
    expected_status = expectation.get("status")
    if observation.status != expected_status:
        raise GuardError(
            f"case {case['id']} expected {expected_status} for {expectation_field}, "
            f"observed {observation.status} (exit {observation.returncode})"
        )
    combined = f"{observation.stdout}\n{observation.stderr}"
    if expected_kind := expectation.get("kind"):
        if f"KIND={expected_kind}" not in observation.stdout:
            raise GuardError(
                f"case {case['id']} did not report expected diagnostic kind {expected_kind}"
            )
    if expected_origin := expectation.get("origin"):
        marker = {
            "source": "PRIMARY=Some(Source(",
            "contract": "PRIMARY=Some(Contract",
        }.get(expected_origin)
        if marker is None:
            raise GuardError(f"case {case['id']} has unknown expected origin {expected_origin}")
        if marker not in observation.stdout:
            raise GuardError(
                f"case {case['id']} did not report the expected {expected_origin} origin"
            )
    if message := expectation.get("message_contains"):
        if message not in combined:
            raise GuardError(
                f"case {case['id']} output did not contain expected text {message!r}"
            )
    print(
        f"CASE={case['id']} CATEGORY={case['category']} EXPECTATION={expectation_field} "
        f"RESULT={observation.status}"
    )
