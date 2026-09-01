#!/usr/bin/env python3
"""Durable, non-retryable execution receipts for one-shot repository gates.

This module is the schema and lifecycle authority.  Platform adapters may
launch and measure a child, but only this module creates attempts, classifies
outcomes, writes verdicts, audits recovery state, and archives evidence.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import importlib.util
import json
import math
import os
import re
import secrets
import select
import signal
import subprocess
import sys
import tarfile
import threading
import time
import traceback
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Mapping, Sequence


CONTRACT_VERSION = 1
ATTEMPT_SCHEMA = "vorton.one-shot.attempt.v1"
VERDICT_SCHEMA = "vorton.one-shot.verdict.v1"
CHAINED_CONTRACT_VERSION = 2
CHAINED_ATTEMPT_SCHEMA = "vorton.one-shot.attempt.v2"
CHAINED_VERDICT_SCHEMA = "vorton.one-shot.verdict.v2"
CHAIN_SCHEMA = "vorton.one-shot.chain.v1"
AUDIT_SCHEMA = "vorton.one-shot.audit.v1"
ARCHIVE_SCHEMA = "vorton.one-shot.archive.v1"

ATTEMPT_NAME = "attempt.json"
VERDICT_NAME = "verdict.json"
STDOUT_NAME = "stdout.raw"
STDERR_NAME = "stderr.raw"
RAW_NAMES = (STDOUT_NAME, STDERR_NAME)
COMPLETE_NAMES = tuple(sorted((ATTEMPT_NAME, VERDICT_NAME, *RAW_NAMES)))

GATE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HEX_64_RE = re.compile(r"^[0-9a-f]{64}$")
ATTEMPT_ID_RE = re.compile(r"^[0-9A-F]{64}$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_()]*$")
SECRET_ENV_FRAGMENTS = (
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
    "COOKIE",
    "PRIVATE_KEY",
    "API_KEY",
    "AUTHORIZATION",
)


class OneShotError(RuntimeError):
    """Base failure for the one-shot contract."""


class ContractError(OneShotError):
    """Static request or packet state violates the contract."""


class ResultSchemaError(OneShotError):
    """A post-child result failed its gate-specific schema."""


class AdapterError(OneShotError):
    """A platform adapter failed after producing a structured outcome."""

    def __init__(self, message: str, outcome: Mapping[str, Any]):
        super().__init__(message)
        self.outcome = dict(outcome)


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read JSON {path}: {exc}") from exc


def _json_bytes(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                ensure_ascii=True,
                indent=2,
                sort_keys=True,
                allow_nan=False,
            )
            + "\n"
        ).encode("ascii")
    except (TypeError, ValueError) as exc:
        raise ContractError(f"cannot encode canonical JSON: {exc}") from exc


def _reject_json_constant(value: str):
    raise ContractError(f"non-finite JSON constant is forbidden: {value}")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        raise ContractError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def _fsync_directory(path: Path) -> None:
    if os.name == "nt":
        return
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def exclusive_write_bytes(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        raise ContractError(f"exclusive create failed for {path}: {exc}") from exc
    try:
        view = memoryview(data)
        offset = 0
        while offset < len(view):
            written = os.write(descriptor, view[offset:])
            if written <= 0:
                raise OSError(f"write made no progress: {written}")
            offset += written
        os.fsync(descriptor)
    except BaseException as exc:
        raise ContractError(f"durable write failed for {path}: {exc}") from exc
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)


def exclusive_write_json(path: Path, value: Any) -> None:
    exclusive_write_bytes(path, _json_bytes(value))


def _strict_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} is not an object")
    if set(value) != expected:
        raise ContractError(
            f"{label} keys differ: {sorted(value)} != {sorted(expected)}"
        )
    return value


def _json_safe(value: Any, label: str = "value") -> None:
    if value is None or isinstance(value, (str, bool)):
        return
    if type(value) is int:
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise ContractError(f"{label} is non-finite")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _json_safe(item, f"{label}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ContractError(f"{label} has a non-string key")
            _json_safe(item, f"{label}.{key}")
        return
    raise ContractError(f"{label} is not JSON-safe: {type(value).__name__}")


@dataclass(frozen=True)
class Limits:
    wall_seconds: float
    stdout_cap_bytes: int
    stderr_cap_bytes: int
    job_memory_bytes: int | None = None
    active_process_limit: int | None = None
    poll_ms: int = 10

    def validate(self) -> None:
        if (
            type(self.wall_seconds) not in (int, float)
            or not math.isfinite(float(self.wall_seconds))
            or self.wall_seconds <= 0
        ):
            raise ContractError("wall_seconds must be positive")
        for label, value in (
            ("stdout_cap_bytes", self.stdout_cap_bytes),
            ("stderr_cap_bytes", self.stderr_cap_bytes),
        ):
            if type(value) is not int or value < 0:
                raise ContractError(f"{label} must be a non-negative integer")
        if self.job_memory_bytes is not None and (
            type(self.job_memory_bytes) is not int or self.job_memory_bytes <= 0
        ):
            raise ContractError("job_memory_bytes must be positive when requested")
        if self.active_process_limit is not None and (
            type(self.active_process_limit) is not int
            or self.active_process_limit <= 0
        ):
            raise ContractError("active_process_limit must be positive when requested")
        if self.poll_ms != 10:
            raise ContractError("one-shot process sampling interval is fixed at 10 ms")

    def receipt(self) -> dict[str, Any]:
        return {
            "wall_seconds": float(self.wall_seconds),
            "stdout_cap_bytes": self.stdout_cap_bytes,
            "stderr_cap_bytes": self.stderr_cap_bytes,
            "job_memory_bytes": self.job_memory_bytes,
            "active_process_limit": self.active_process_limit,
            "poll_ms": self.poll_ms,
        }


@dataclass(frozen=True)
class AttemptChain:
    outer_attempt_id: str
    outer_attempt_sha256: str
    plan_sha256: str

    def receipt(self) -> dict[str, Any]:
        value = {
            "schema": CHAIN_SCHEMA,
            "outer_attempt_id": self.outer_attempt_id,
            "outer_attempt_sha256": self.outer_attempt_sha256,
            "plan_sha256": self.plan_sha256,
        }
        _validate_chain_receipt(value, "chain")
        return value


@dataclass(frozen=True)
class OneShotSpec:
    evidence_dir: Path
    gate_id: str
    argv: tuple[str, ...]
    reviewed_argv: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str]
    reviewed_env: tuple[tuple[str, str], ...]
    limits: Limits
    success_exit_codes: tuple[int, ...] = (0,)
    chain: AttemptChain | None = None


def _validate_platform_support(limits: Limits) -> None:
    if os.name == "nt":
        return
    unsupported: list[str] = []
    if limits.job_memory_bytes is not None:
        unsupported.append("job_memory_bytes")
    if limits.active_process_limit is not None:
        unsupported.append("active_process_limit")
    if unsupported:
        raise ContractError(
            "non-Windows adapter cannot prove requested process-tree limits: "
            + ", ".join(unsupported)
        )


def _validate_spec(spec: OneShotSpec) -> tuple[dict[str, Any], dict[str, str]]:
    spec.limits.validate()
    _validate_platform_support(spec.limits)
    root = spec.evidence_dir
    if not root.is_absolute() or not root.is_dir():
        raise ContractError("evidence_dir must be an existing absolute directory")
    if root.is_symlink():
        raise ContractError("evidence_dir must not be a symlink")
    try:
        inventory = list(os.scandir(root))
    except OSError as exc:
        raise ContractError(f"cannot inventory evidence_dir: {exc}") from exc
    if inventory:
        raise ContractError(
            "fresh evidence_dir is not empty; retry/overwrite is forbidden"
        )
    if GATE_ID_RE.fullmatch(spec.gate_id) is None:
        raise ContractError("gate_id has invalid characters or length")
    if not spec.argv or not all(
        isinstance(part, str) and part and "\x00" not in part for part in spec.argv
    ):
        raise ContractError("argv must be non-empty strings without NUL")
    if spec.argv != spec.reviewed_argv:
        raise ContractError("actual argv differs from explicitly reviewed argv")
    if not spec.cwd.is_absolute() or not spec.cwd.is_dir():
        raise ContractError("cwd must be an existing absolute directory")
    if not spec.success_exit_codes or not all(
        type(code) is int for code in spec.success_exit_codes
    ):
        raise ContractError("success_exit_codes must be non-empty integers")
    if spec.chain is not None:
        if not isinstance(spec.chain, AttemptChain):
            raise ContractError("chain must be an AttemptChain")
        spec.chain.receipt()

    env = dict(spec.env)
    reviewed_pairs = list(spec.reviewed_env)
    if not all(
        isinstance(pair, tuple)
        and len(pair) == 2
        and isinstance(pair[0], str)
        and isinstance(pair[1], str)
        for pair in reviewed_pairs
    ):
        raise ContractError("reviewed_env must contain exact (name, value) pairs")
    reviewed = [pair[0] for pair in reviewed_pairs]
    if (
        len(reviewed) != len(set(reviewed))
        or reviewed_pairs != sorted(reviewed_pairs, key=lambda pair: pair[0])
    ):
        raise ContractError("reviewed_env pairs must have unique sorted names")
    reviewed_env = dict(reviewed_pairs)
    if env != reviewed_env:
        raise ContractError("child env differs from the exact reviewed env values")
    for key, value in env.items():
        if ENV_NAME_RE.fullmatch(key) is None:
            raise ContractError(f"environment name is invalid: {key!r}")
        upper = key.upper()
        if any(fragment in upper for fragment in SECRET_ENV_FRAGMENTS):
            raise ContractError(
                f"secret-like environment name cannot enter a receipt: {key!r}"
            )
        if not isinstance(value, str) or "\x00" in value:
            raise ContractError(f"environment value for {key!r} is invalid")

    tool = Path(spec.argv[0])
    if not tool.is_absolute() or tool.is_symlink() or not tool.is_file():
        raise ContractError("argv[0] must be an absolute regular non-link tool")
    try:
        tool_size = tool.stat().st_size
    except OSError as exc:
        raise ContractError(f"cannot stat tool {tool}: {exc}") from exc
    execution = {
        "argv": list(spec.reviewed_argv),
        "cwd": os.fspath(spec.cwd),
        "tool": {
            "path": os.fspath(tool),
            "size": tool_size,
            "sha256": _sha256_file(tool),
        },
        "env": [
            {"name": key, "value": env[key]} for key in reviewed
        ],
    }
    return execution, env


def _attempt_record(
    spec: OneShotSpec, execution: Mapping[str, Any], attempt_id: str
) -> dict[str, Any]:
    record = {
        "schema": (
            CHAINED_ATTEMPT_SCHEMA if spec.chain is not None else ATTEMPT_SCHEMA
        ),
        "contract_version": (
            CHAINED_CONTRACT_VERSION if spec.chain is not None else CONTRACT_VERSION
        ),
        "attempt_id": attempt_id,
        "gate_id": spec.gate_id,
        "created_unix_ns": time.time_ns(),
        "execution": dict(execution),
        "limits": spec.limits.receipt(),
        "success_exit_codes": list(spec.success_exit_codes),
        "state": "attempt-created",
    }
    if spec.chain is not None:
        record["chain"] = spec.chain.receipt()
    return record


ATTEMPT_KEYS = {
    "schema",
    "contract_version",
    "attempt_id",
    "gate_id",
    "created_unix_ns",
    "execution",
    "limits",
    "success_exit_codes",
    "state",
}
CHAINED_ATTEMPT_KEYS = ATTEMPT_KEYS | {"chain"}
CHAIN_KEYS = {
    "schema",
    "outer_attempt_id",
    "outer_attempt_sha256",
    "plan_sha256",
}


EXECUTION_KEYS = {"argv", "cwd", "tool", "env"}
TOOL_KEYS = {"path", "size", "sha256"}
ENV_ENTRY_KEYS = {"name", "value"}
LIMIT_KEYS = {
    "wall_seconds",
    "stdout_cap_bytes",
    "stderr_cap_bytes",
    "job_memory_bytes",
    "active_process_limit",
    "poll_ms",
}


def _validate_chain_receipt(value: Any, label: str) -> dict[str, Any]:
    chain = _strict_keys(value, CHAIN_KEYS, label)
    if chain["schema"] != CHAIN_SCHEMA:
        raise ContractError(f"{label}.schema mismatch")
    if not isinstance(chain["outer_attempt_id"], str) or ATTEMPT_ID_RE.fullmatch(
        chain["outer_attempt_id"]
    ) is None:
        raise ContractError(f"{label}.outer_attempt_id is invalid")
    for key in ("outer_attempt_sha256", "plan_sha256"):
        if not isinstance(chain[key], str) or HEX_64_RE.fullmatch(chain[key]) is None:
            raise ContractError(f"{label}.{key} is invalid")
    return chain


def _validate_execution_receipt(value: Any, label: str) -> dict[str, Any]:
    execution = _strict_keys(value, EXECUTION_KEYS, label)
    argv = execution["argv"]
    if not isinstance(argv, list) or not argv or not all(
        isinstance(part, str) and part and "\x00" not in part for part in argv
    ):
        raise ContractError(f"{label}.argv is invalid")
    if not isinstance(execution["cwd"], str) or not execution["cwd"]:
        raise ContractError(f"{label}.cwd is invalid")
    tool = _strict_keys(execution["tool"], TOOL_KEYS, f"{label}.tool")
    if not isinstance(tool["path"], str) or not tool["path"]:
        raise ContractError(f"{label}.tool.path is invalid")
    if type(tool["size"]) is not int or tool["size"] < 0:
        raise ContractError(f"{label}.tool.size is invalid")
    if not isinstance(tool["sha256"], str) or HEX_64_RE.fullmatch(
        tool["sha256"]
    ) is None:
        raise ContractError(f"{label}.tool.sha256 is invalid")
    env = execution["env"]
    if not isinstance(env, list):
        raise ContractError(f"{label}.env is not a list")
    names: list[str] = []
    for index, entry_value in enumerate(env):
        entry = _strict_keys(
            entry_value, ENV_ENTRY_KEYS, f"{label}.env[{index}]"
        )
        name = entry["name"]
        value = entry["value"]
        if not isinstance(name, str) or ENV_NAME_RE.fullmatch(name) is None:
            raise ContractError(f"{label}.env[{index}].name is invalid")
        if any(fragment in name.upper() for fragment in SECRET_ENV_FRAGMENTS):
            raise ContractError(f"{label}.env contains a secret-like name")
        if not isinstance(value, str) or "\x00" in value:
            raise ContractError(f"{label}.env[{index}].value is invalid")
        names.append(name)
    if names != sorted(set(names)):
        raise ContractError(f"{label}.env names are not unique/sorted")
    return execution


def _validate_limits_receipt(value: Any, label: str) -> dict[str, Any]:
    limits = _strict_keys(value, LIMIT_KEYS, label)
    if (
        type(limits["wall_seconds"]) not in (int, float)
        or not math.isfinite(float(limits["wall_seconds"]))
        or limits["wall_seconds"] <= 0
    ):
        raise ContractError(f"{label}.wall_seconds is invalid")
    for key in ("stdout_cap_bytes", "stderr_cap_bytes"):
        if type(limits[key]) is not int or limits[key] < 0:
            raise ContractError(f"{label}.{key} is invalid")
    for key in ("job_memory_bytes", "active_process_limit"):
        if limits[key] is not None and (
            type(limits[key]) is not int or limits[key] <= 0
        ):
            raise ContractError(f"{label}.{key} is invalid")
    if limits["poll_ms"] != 10:
        raise ContractError(f"{label}.poll_ms is invalid")
    return limits


def _validate_attempt(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError("attempt is not an object")
    schema = value.get("schema")
    chained = schema == CHAINED_ATTEMPT_SCHEMA
    expected_keys = CHAINED_ATTEMPT_KEYS if chained else ATTEMPT_KEYS
    attempt = _strict_keys(value, expected_keys, "attempt")
    expected_schema = CHAINED_ATTEMPT_SCHEMA if chained else ATTEMPT_SCHEMA
    expected_version = CHAINED_CONTRACT_VERSION if chained else CONTRACT_VERSION
    if attempt["schema"] != expected_schema:
        raise ContractError("attempt schema mismatch")
    if attempt["contract_version"] != expected_version:
        raise ContractError("attempt contract version mismatch")
    if not isinstance(attempt["attempt_id"], str) or ATTEMPT_ID_RE.fullmatch(
        attempt["attempt_id"]
    ) is None:
        raise ContractError("attempt_id is invalid")
    if not isinstance(attempt["gate_id"], str) or GATE_ID_RE.fullmatch(
        attempt["gate_id"]
    ) is None:
        raise ContractError("attempt gate_id is invalid")
    if type(attempt["created_unix_ns"]) is not int or attempt["created_unix_ns"] <= 0:
        raise ContractError("attempt timestamp is invalid")
    if attempt["state"] != "attempt-created":
        raise ContractError("attempt state mismatch")
    _validate_execution_receipt(attempt["execution"], "attempt.execution")
    _validate_limits_receipt(attempt["limits"], "attempt.limits")
    if not isinstance(attempt["success_exit_codes"], list) or not (
        attempt["success_exit_codes"]
        and all(type(code) is int for code in attempt["success_exit_codes"])
    ):
        raise ContractError("attempt success_exit_codes are invalid")
    if chained:
        _validate_chain_receipt(attempt["chain"], "attempt.chain")
    return attempt


STREAM_KEYS = {
    "path",
    "captured_size",
    "sha256",
    "bytes_seen",
    "cap_bytes",
    "truncated_at_cap",
    "fsynced",
    "error",
}


OUTCOME_KEYS = {
    "adapter",
    "support",
    "stage",
    "exit_code",
    "timed_out",
    "memory_limit_hit",
    "process_limit_hit",
    "output_limit_hit",
    "launch_error",
    "pipe_error",
    "thread_error",
    "infrastructure_error",
    "measurements",
    "streams",
}


def _validate_stream_record(
    value: Any, stream: str, expected_path: str, expected_cap: int
) -> dict[str, Any]:
    record = _strict_keys(value, STREAM_KEYS, f"stream.{stream}")
    if record["path"] != expected_path:
        raise ContractError(f"stream.{stream} path mismatch")
    for key in ("captured_size", "bytes_seen", "cap_bytes"):
        if type(record[key]) is not int or record[key] < 0:
            raise ContractError(f"stream.{stream}.{key} is invalid")
    if record["cap_bytes"] != expected_cap:
        raise ContractError(f"stream.{stream} cap mismatch")
    if not isinstance(record["sha256"], str) or HEX_64_RE.fullmatch(
        record["sha256"]
    ) is None:
        raise ContractError(f"stream.{stream} sha256 is invalid")
    for key in ("truncated_at_cap", "fsynced"):
        if type(record[key]) is not bool:
            raise ContractError(f"stream.{stream}.{key} is not boolean")
    if record["error"] is not None and not isinstance(record["error"], str):
        raise ContractError(f"stream.{stream}.error is invalid")
    if record["captured_size"] > record["cap_bytes"]:
        raise ContractError(f"stream.{stream} exceeds its cap")
    if record["truncated_at_cap"]:
        if record["captured_size"] != record["cap_bytes"]:
            raise ContractError(f"stream.{stream} truncated prefix is not exact cap")
        if record["bytes_seen"] < record["captured_size"]:
            raise ContractError(f"stream.{stream} bytes_seen is inconsistent")
    elif record["bytes_seen"] != record["captured_size"]:
        raise ContractError(f"stream.{stream} lost uncapped bytes")
    return record


def _validate_adapter_outcome(
    value: Any, limits: Limits
) -> dict[str, Any]:
    outcome = _strict_keys(value, OUTCOME_KEYS, "adapter outcome")
    if not isinstance(outcome["adapter"], str) or not outcome["adapter"]:
        raise ContractError("adapter name is invalid")
    support = _strict_keys(outcome["support"], SUPPORT_KEYS, "adapter support")
    if not all(isinstance(value, str) and value for value in support.values()):
        raise ContractError("adapter support has invalid values")
    if outcome["stage"] != "child-sealed":
        raise ContractError("adapter did not seal the child evidence")
    if outcome["exit_code"] is not None and type(outcome["exit_code"]) is not int:
        raise ContractError("adapter exit_code is invalid")
    for key in (
        "timed_out",
        "memory_limit_hit",
        "process_limit_hit",
        "output_limit_hit",
    ):
        if type(outcome[key]) is not bool:
            raise ContractError(f"adapter {key} is not boolean")
    for key in (
        "launch_error",
        "pipe_error",
        "thread_error",
        "infrastructure_error",
    ):
        if outcome[key] is not None and not isinstance(outcome[key], str):
            raise ContractError(f"adapter {key} is invalid")
    if not isinstance(outcome["measurements"], dict):
        raise ContractError("adapter measurements are not an object")
    streams = _strict_keys(outcome["streams"], {"stdout", "stderr"}, "streams")
    _validate_stream_record(
        streams["stdout"], "stdout", STDOUT_NAME, limits.stdout_cap_bytes
    )
    _validate_stream_record(
        streams["stderr"], "stderr", STDERR_NAME, limits.stderr_cap_bytes
    )
    if not streams["stdout"]["fsynced"] or not streams["stderr"]["fsynced"]:
        raise ContractError("adapter returned before raw streams were fsynced")
    expected_output_hit = bool(
        streams["stdout"]["truncated_at_cap"]
        or streams["stderr"]["truncated_at_cap"]
    )
    if outcome["output_limit_hit"] != expected_output_hit:
        raise ContractError("adapter output-limit classification mismatches raw streams")
    _json_safe(outcome["measurements"], "adapter.measurements")
    return outcome


def _verify_raw_identity(root: Path, streams: Mapping[str, Any]) -> None:
    for stream, expected_name in (("stdout", STDOUT_NAME), ("stderr", STDERR_NAME)):
        record = streams[stream]
        path = root / expected_name
        if path.is_symlink() or not path.is_file():
            raise ContractError(f"{stream} raw file is missing/non-regular")
        try:
            size = path.stat().st_size
        except OSError as exc:
            raise ContractError(f"cannot stat {stream} raw: {exc}") from exc
        if size != record["captured_size"]:
            raise ContractError(f"{stream} raw size changed before verdict")
        if _sha256_file(path) != record["sha256"]:
            raise ContractError(f"{stream} raw hash changed before verdict")


def _verify_tool_identity(execution: Mapping[str, Any]) -> None:
    tool = execution["tool"]
    path = Path(tool["path"])
    if path.is_symlink() or not path.is_file():
        raise ContractError("execution tool disappeared or became non-regular")
    if path.stat().st_size != tool["size"]:
        raise ContractError("execution tool size changed during the attempt")
    if _sha256_file(path) != tool["sha256"]:
        raise ContractError("execution tool hash changed during the attempt")


def _classify_outcome(
    outcome: Mapping[str, Any], success_codes: Sequence[int]
) -> tuple[str, str | None]:
    if outcome["launch_error"] is not None:
        return "launch_error", outcome["launch_error"]
    if outcome["pipe_error"] is not None:
        return "pipe_error", outcome["pipe_error"]
    if outcome["thread_error"] is not None:
        return "thread_error", outcome["thread_error"]
    if outcome["infrastructure_error"] is not None:
        return "infrastructure_error", outcome["infrastructure_error"]
    if outcome["process_limit_hit"]:
        return "process_limit", "active process limit was reached"
    if outcome["memory_limit_hit"]:
        return "memory_limit", "job memory limit was reached"
    if outcome["timed_out"]:
        return "timeout", "wall-time limit was reached"
    if outcome["output_limit_hit"]:
        return "output_limit", "one or more output streams reached their cap"
    if outcome["exit_code"] not in success_codes:
        return "child_nonzero", f"child exited {outcome['exit_code']}"
    return "success", None


VERDICT_KEYS = {
    "schema",
    "contract_version",
    "attempt_id",
    "attempt_sha256",
    "gate_id",
    "status",
    "classification",
    "stage",
    "execution",
    "limits",
    "success_exit_codes",
    "child",
    "measurements",
    "streams",
    "error",
    "created_unix_ns",
}
CHAINED_VERDICT_KEYS = VERDICT_KEYS | {"chain"}


CHILD_KEYS = {
    "adapter",
    "support",
    "exit_code",
    "timed_out",
    "memory_limit_hit",
    "process_limit_hit",
    "output_limit_hit",
    "launch_error",
    "pipe_error",
    "thread_error",
    "infrastructure_error",
}
SUPPORT_KEYS = {"wall", "output", "job_memory", "active_process"}


def _validate_child_receipt(value: Any, label: str) -> dict[str, Any]:
    child = _strict_keys(value, CHILD_KEYS, label)
    if not isinstance(child["adapter"], str) or not child["adapter"]:
        raise ContractError(f"{label}.adapter is invalid")
    support = _strict_keys(child["support"], SUPPORT_KEYS, f"{label}.support")
    if not all(isinstance(value, str) and value for value in support.values()):
        raise ContractError(f"{label}.support has invalid values")
    if child["exit_code"] is not None and type(child["exit_code"]) is not int:
        raise ContractError(f"{label}.exit_code is invalid")
    for key in (
        "timed_out",
        "memory_limit_hit",
        "process_limit_hit",
        "output_limit_hit",
    ):
        if type(child[key]) is not bool:
            raise ContractError(f"{label}.{key} is not boolean")
    for key in (
        "launch_error",
        "pipe_error",
        "thread_error",
        "infrastructure_error",
    ):
        if child[key] is not None and not isinstance(child[key], str):
            raise ContractError(f"{label}.{key} is invalid")
    return child


def _validate_verdict(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError("verdict is not an object")
    schema = value.get("schema")
    chained = schema == CHAINED_VERDICT_SCHEMA
    expected_keys = CHAINED_VERDICT_KEYS if chained else VERDICT_KEYS
    verdict = _strict_keys(value, expected_keys, "verdict")
    expected_schema = CHAINED_VERDICT_SCHEMA if chained else VERDICT_SCHEMA
    expected_version = CHAINED_CONTRACT_VERSION if chained else CONTRACT_VERSION
    if verdict["schema"] != expected_schema:
        raise ContractError("verdict schema mismatch")
    if verdict["contract_version"] != expected_version:
        raise ContractError("verdict contract version mismatch")
    if not isinstance(verdict["attempt_id"], str) or ATTEMPT_ID_RE.fullmatch(
        verdict["attempt_id"]
    ) is None:
        raise ContractError("verdict attempt_id is invalid")
    if not isinstance(verdict["attempt_sha256"], str) or HEX_64_RE.fullmatch(
        verdict["attempt_sha256"]
    ) is None:
        raise ContractError("verdict attempt hash is invalid")
    if verdict["status"] not in {"success", "failure"}:
        raise ContractError("verdict status is invalid")
    if not isinstance(verdict["classification"], str):
        raise ContractError("verdict classification is invalid")
    if not isinstance(verdict["stage"], str):
        raise ContractError("verdict stage is invalid")
    if verdict["error"] is not None and not isinstance(verdict["error"], str):
        raise ContractError("verdict error is invalid")
    if type(verdict["created_unix_ns"]) is not int:
        raise ContractError("verdict timestamp is invalid")
    _validate_execution_receipt(verdict["execution"], "verdict.execution")
    limits = _validate_limits_receipt(verdict["limits"], "verdict.limits")
    if not isinstance(verdict["success_exit_codes"], list) or not (
        verdict["success_exit_codes"]
        and all(type(code) is int for code in verdict["success_exit_codes"])
    ):
        raise ContractError("verdict success_exit_codes are invalid")
    _validate_child_receipt(verdict["child"], "verdict.child")
    _json_safe(verdict["measurements"], "verdict.measurements")
    streams = _strict_keys(
        verdict["streams"], {"stdout", "stderr"}, "verdict.streams"
    )
    _validate_stream_record(
        streams["stdout"],
        "stdout",
        STDOUT_NAME,
        limits["stdout_cap_bytes"],
    )
    _validate_stream_record(
        streams["stderr"],
        "stderr",
        STDERR_NAME,
        limits["stderr_cap_bytes"],
    )
    if not streams["stdout"]["fsynced"] or not streams["stderr"]["fsynced"]:
        raise ContractError("verdict cannot precede fsynced raw streams")
    if chained:
        _validate_chain_receipt(verdict["chain"], "verdict.chain")
    return verdict


def _load_windows_adapter() -> Callable[..., dict[str, Any]]:
    global _WINDOWS_ADAPTER
    repo_root = Path(__file__).resolve().parents[2]
    path = repo_root / "bench" / "check" / "windows_job.py"
    if _CHAIN_WINDOWS_ADAPTER_IDENTITY is not None:
        expected = _CHAIN_WINDOWS_ADAPTER_IDENTITY
        if (
            os.fspath(path.resolve(strict=True)) != expected["path"]
            or path.stat().st_size != expected["size"]
            or _sha256_file(path) != expected["sha256"]
        ):
            raise ContractError("Windows adapter changed after chained plan validation")
    if _WINDOWS_ADAPTER is not None:
        return _WINDOWS_ADAPTER
    spec = importlib.util.spec_from_file_location("vorton_windows_job", path)
    if spec is None or spec.loader is None:
        raise ContractError(f"cannot import Windows adapter {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    adapter = getattr(module, "run_one_shot_job", None)
    if not callable(adapter):
        raise ContractError("windows_job.py lacks run_one_shot_job")
    _WINDOWS_ADAPTER = adapter
    return _WINDOWS_ADAPTER


_WINDOWS_ADAPTER: Callable[..., dict[str, Any]] | None = None
_CHAIN_WINDOWS_ADAPTER_IDENTITY: dict[str, Any] | None = None


class _PrefixSink:
    """Non-Windows simultaneous stream sink with the shared raw schema."""

    def __init__(self, path: Path, relative_path: str, cap: int) -> None:
        self.path = path
        self.relative_path = relative_path
        self.cap = cap
        self.captured = 0
        self.seen = 0
        self.truncated = False
        self.error: str | None = None
        self.digest = hashlib.sha256()
        self._fd: int | None = None

    def open(self) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        self._fd = os.open(self.path, flags, 0o600)

    def consume(self, chunk: bytes) -> None:
        self.seen += len(chunk)
        remaining = self.cap - self.captured
        prefix = chunk[: max(0, remaining)]
        if prefix and self._fd is not None:
            view = memoryview(prefix)
            offset = 0
            while offset < len(view):
                written = os.write(self._fd, view[offset:])
                if written <= 0:
                    raise OSError(f"stream write made no progress: {written}")
                self.digest.update(view[offset : offset + written])
                offset += written
            self.captured += len(prefix)
        if len(chunk) > len(prefix):
            self.truncated = True

    def seal(self) -> None:
        if self._fd is not None:
            os.fsync(self._fd)
            os.close(self._fd)
            self._fd = None
        _fsync_directory(self.path.parent)

    def record(self) -> dict[str, Any]:
        return {
            "path": self.relative_path,
            "captured_size": self.captured,
            "sha256": self.digest.hexdigest(),
            "bytes_seen": self.seen,
            "cap_bytes": self.cap,
            "truncated_at_cap": self.truncated,
            "fsynced": self._fd is None,
            "error": self.error,
        }


def _posix_group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


_POSIX_TARGET_GUARD_SOURCE = r'''import json,os,sys
def read_all(fd):
    chunks=[]
    while True:
        chunk=os.read(fd,65536)
        if not chunk: break
        chunks.append(chunk)
    return b"".join(chunks)
config_fd=int(sys.argv[1]); release_fd=int(sys.argv[2]); ready_fd=int(sys.argv[3])
config=json.loads(read_all(config_fd).decode("ascii"),parse_constant=lambda value: (_ for _ in ()).throw(ValueError("non-finite JSON")))
os.write(ready_fd,b"R")
token=os.read(release_fd,1)
if token != b"G": os._exit(125)
for fd in (config_fd,release_fd,ready_fd):
    try: os.close(fd)
    except OSError: pass
os.chdir(config["cwd"])
os.execve(config["argv"][0],config["argv"],config["env"])
'''

_POSIX_WATCHDOG_SOURCE = r'''import os,signal,sys,time
def read_all(fd):
    chunks=[]
    while True:
        chunk=os.read(fd,128)
        if not chunk: break
        chunks.append(chunk)
    return b"".join(chunks)
config_fd=int(sys.argv[1]); live_fd=int(sys.argv[2]); ack_fd=int(sys.argv[3])
raw=read_all(config_fd).strip()
if not raw: os._exit(120)
pgid=int(raw.decode("ascii"))
os.killpg(pgid,0)
os.write(ack_fd,b"A")
for fd in (config_fd,ack_fd):
    try: os.close(fd)
    except OSError: pass
token=os.read(live_fd,1)
if token == b"D": os._exit(0)
try: os.killpg(pgid,signal.SIGKILL)
except ProcessLookupError: pass
deadline=time.monotonic()+5
while time.monotonic()<deadline:
    try: os.killpg(pgid,0)
    except ProcessLookupError: os._exit(0)
    time.sleep(0.01)
os._exit(121)
'''


def _write_all_fd(fd: int, data: bytes) -> None:
    view = memoryview(data)
    offset = 0
    while offset < len(view):
        written = os.write(fd, view[offset:])
        if written <= 0:
            raise OSError(f"pipe write made no progress: {written}")
        offset += written


def _read_handshake_byte(
    fd: int, expected: bytes, deadline: float, label: str
) -> None:
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ContractError(f"{label} handshake timed out")
        readable, _, _ = select.select([fd], [], [], min(remaining, 0.05))
        if not readable:
            continue
        value = os.read(fd, 1)
        if value != expected:
            raise ContractError(
                f"{label} handshake byte {value!r} != {expected!r}"
            )
        return


def _run_non_windows_guarded_job(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    stdout_path: Path,
    stderr_path: Path,
    limits: Limits,
    cleanup_armed_callback: Callable[[Mapping[str, Any]], None],
) -> dict[str, Any]:
    """Run a POSIX target behind a release guard and an outer-EOF watchdog."""

    _validate_platform_support(limits)
    if os.name == "nt":
        raise ContractError("guarded process-group adapter requires POSIX")
    stdout_sink = _PrefixSink(stdout_path, STDOUT_NAME, limits.stdout_cap_bytes)
    stderr_sink = _PrefixSink(stderr_path, STDERR_NAME, limits.stderr_cap_bytes)
    stdout_sink.open()
    try:
        stderr_sink.open()
    except BaseException:
        stdout_sink.seal()
        raise

    process: subprocess.Popen[bytes] | None = None
    watchdog: subprocess.Popen[bytes] | None = None
    stop = threading.Event()
    threads: list[threading.Thread] = []
    thread_errors: list[str] = []
    infrastructure_errors: list[str] = []
    launch_error: str | None = None
    pgid: int | None = None
    group_kill_reason: str | None = None
    group_quiesced = False
    descendant_leak = False
    timed_out = False
    cleanup_armed = False
    target_released = False
    watchdog_disarmed = False
    started_ns = time.perf_counter_ns()
    deadline = time.monotonic() + limits.wall_seconds
    open_fds: set[int] = set()
    live_write: int | None = None

    guard_sha = _sha256_bytes(_POSIX_TARGET_GUARD_SOURCE.encode("ascii"))
    watchdog_sha = _sha256_bytes(_POSIX_WATCHDOG_SOURCE.encode("ascii"))

    def make_pipe() -> tuple[int, int]:
        read_fd, write_fd = os.pipe()
        open_fds.update((read_fd, write_fd))
        return read_fd, write_fd

    def close_fd(fd: int | None) -> None:
        if fd is None or fd not in open_fds:
            return
        try:
            os.close(fd)
        finally:
            open_fds.discard(fd)

    def kill_group(reason: str) -> None:
        nonlocal group_kill_reason
        if pgid is None:
            return
        if pgid == os.getpgrp():
            infrastructure_errors.append("refused to signal the parent process group")
            return
        if group_kill_reason is None:
            group_kill_reason = reason
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            infrastructure_errors.append(
                f"killpg({reason}): {type(exc).__name__}: {exc}"
            )

    def wait_group_quiescence() -> bool:
        if pgid is None:
            return True
        quiesce_deadline = time.monotonic() + 5
        while _posix_group_exists(pgid):
            if time.monotonic() >= quiesce_deadline:
                infrastructure_errors.append(
                    "guarded process group did not quiesce within 5 seconds"
                )
                return False
            time.sleep(limits.poll_ms / 1000)
        return True

    def reader(stream, sink: _PrefixSink, label: str) -> None:
        try:
            while True:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    break
                sink.consume(chunk)
                if sink.truncated:
                    stop.set()
                    break
        except BaseException as exc:
            message = f"{label}: {type(exc).__name__}: {exc}"
            sink.error = message
            thread_errors.append(message)
            stop.set()

    try:
        watchdog_config_read, watchdog_config_write = make_pipe()
        live_read, live_write_local = make_pipe()
        live_write = live_write_local
        watchdog_ack_read, watchdog_ack_write = make_pipe()
        watchdog = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                "-u",
                "-c",
                _POSIX_WATCHDOG_SOURCE,
                str(watchdog_config_read),
                str(live_read),
                str(watchdog_ack_write),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            pass_fds=(watchdog_config_read, live_read, watchdog_ack_write),
            start_new_session=True,
        )
        close_fd(watchdog_config_read)
        close_fd(live_read)
        close_fd(watchdog_ack_write)

        guard_config_read, guard_config_write = make_pipe()
        release_read, release_write = make_pipe()
        guard_ready_read, guard_ready_write = make_pipe()
        process = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                "-u",
                "-c",
                _POSIX_TARGET_GUARD_SOURCE,
                str(guard_config_read),
                str(release_read),
                str(guard_ready_write),
            ],
            cwd=cwd,
            env=dict(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            pass_fds=(guard_config_read, release_read, guard_ready_write),
            start_new_session=True,
        )
        pgid = process.pid
        observed_pgid = os.getpgid(process.pid)
        if observed_pgid != pgid:
            raise ContractError(
                f"guard new-session pgid mismatch {observed_pgid} != {pgid}"
            )
        close_fd(guard_config_read)
        close_fd(release_read)
        close_fd(guard_ready_write)

        assert process.stdout is not None and process.stderr is not None
        threads = [
            threading.Thread(
                target=reader,
                args=(process.stdout, stdout_sink, "stdout"),
                daemon=True,
            ),
            threading.Thread(
                target=reader,
                args=(process.stderr, stderr_sink, "stderr"),
                daemon=True,
            ),
        ]
        for thread in threads:
            thread.start()

        config_bytes = _json_bytes(
            {"argv": list(argv), "cwd": os.fspath(cwd), "env": dict(env)}
        )
        _write_all_fd(guard_config_write, config_bytes)
        close_fd(guard_config_write)
        _read_handshake_byte(guard_ready_read, b"R", deadline, "target guard")
        close_fd(guard_ready_read)
        if process.poll() is not None:
            raise ContractError("target guard exited before cleanup handshake")

        _write_all_fd(watchdog_config_write, f"{pgid}\n".encode("ascii"))
        close_fd(watchdog_config_write)
        _read_handshake_byte(watchdog_ack_read, b"A", deadline, "watchdog")
        close_fd(watchdog_ack_read)
        if watchdog.poll() is not None:
            raise ContractError("watchdog exited before cleanup handshake")

        cleanup_armed_callback(
            {
                "adapter": "subprocess-watchdog-v1",
                "cleanup": "outer-eof-killpg",
                "root_pid": process.pid,
                "process_group_id": pgid,
                "target_resumed": False,
                "guard_source_sha256": guard_sha,
                "watchdog_source_sha256": watchdog_sha,
            }
        )
        cleanup_armed = True
        _write_all_fd(release_write, b"G")
        close_fd(release_write)
        target_released = True

        while process.poll() is None:
            if watchdog.poll() is not None:
                infrastructure_errors.append(
                    "cleanup watchdog exited while target group was active"
                )
                stop.set()
            if stop.is_set():
                kill_group(
                    "output-cap"
                    if stdout_sink.truncated or stderr_sink.truncated
                    else "stream-stop"
                )
                break
            if time.monotonic() >= deadline:
                timed_out = True
                kill_group("timeout")
                break
            time.sleep(limits.poll_ms / 1000)
        process.wait(timeout=5)
        if _posix_group_exists(pgid):
            if group_kill_reason is None:
                descendant_leak = True
                infrastructure_errors.append(
                    "root exited while descendants survived in its guarded group"
                )
                kill_group("surviving-descendants")
            group_quiesced = wait_group_quiescence()
        else:
            group_quiesced = True
    except BaseException as exc:
        message = f"{type(exc).__name__}: {exc}"
        if process is None:
            launch_error = message
        else:
            infrastructure_errors.append(message)
            kill_group("guarded-adapter-exception")
            try:
                process.wait(timeout=5)
            except BaseException as wait_exc:
                infrastructure_errors.append(
                    f"root wait: {type(wait_exc).__name__}: {wait_exc}"
                )
            group_quiesced = wait_group_quiescence()
    finally:
        if process is not None and pgid is not None and _posix_group_exists(pgid):
            kill_group("guarded-final-cleanup")
            if process.poll() is None:
                try:
                    process.wait(timeout=5)
                except BaseException as exc:
                    infrastructure_errors.append(
                        f"final root wait: {type(exc).__name__}: {exc}"
                    )
            group_quiesced = wait_group_quiescence()

        close_fd(release_write if "release_write" in locals() else None)
        if live_write is not None and live_write in open_fds:
            try:
                if pgid is None or group_quiesced:
                    _write_all_fd(live_write, b"D")
                    watchdog_disarmed = True
            except BaseException as exc:
                infrastructure_errors.append(
                    f"watchdog disarm: {type(exc).__name__}: {exc}"
                )
            close_fd(live_write)

        for fd in tuple(open_fds):
            close_fd(fd)
        if watchdog is not None:
            try:
                watchdog.wait(timeout=5)
            except BaseException as exc:
                infrastructure_errors.append(
                    f"watchdog wait: {type(exc).__name__}: {exc}"
                )
                try:
                    watchdog.kill()
                    watchdog.wait(timeout=5)
                except BaseException as kill_exc:
                    infrastructure_errors.append(
                        f"watchdog kill: {type(kill_exc).__name__}: {kill_exc}"
                    )
            if watchdog.returncode not in (0, None):
                infrastructure_errors.append(
                    f"cleanup watchdog exited {watchdog.returncode}"
                )

        for thread in threads:
            thread.join(timeout=5)
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError as exc:
                        thread_errors.append(
                            f"pipe-close: {type(exc).__name__}: {exc}"
                        )
        for sink in (stdout_sink, stderr_sink):
            try:
                sink.seal()
            except BaseException as exc:
                message = f"final-seal: {type(exc).__name__}: {exc}"
                sink.error = message
                thread_errors.append(message)

    alive = [thread.name for thread in threads if thread.is_alive()]
    thread_error = (
        "; ".join(thread_errors)
        if thread_errors
        else (f"threads did not quiesce: {alive}" if alive else None)
    )
    return {
        "adapter": "subprocess-watchdog-v1",
        "support": {
            "wall": "enforced",
            "output": "enforced",
            "job_memory": "unsupported-not-requested",
            "active_process": "unsupported-not-requested",
        },
        "stage": "child-sealed",
        "exit_code": process.returncode if process is not None else None,
        "timed_out": timed_out,
        "memory_limit_hit": False,
        "process_limit_hit": False,
        "output_limit_hit": stdout_sink.truncated or stderr_sink.truncated,
        "launch_error": launch_error,
        "pipe_error": next(
            (sink.error for sink in (stdout_sink, stderr_sink) if sink.error), None
        ),
        "thread_error": thread_error,
        "infrastructure_error": (
            "; ".join(dict.fromkeys(infrastructure_errors))
            if infrastructure_errors
            else None
        ),
        "measurements": {
            "wall_ns": time.perf_counter_ns() - started_ns,
            "process_count": None,
            "peak_job_memory_bytes": None,
            "thread_count": len(threads),
            "process_group_id": pgid,
            "process_group_quiesced": group_quiesced,
            "process_group_kill_reason": group_kill_reason,
            "surviving_descendant_detected": descendant_leak,
            "cleanup_armed": cleanup_armed,
            "target_released": target_released,
            "watchdog_disarmed": watchdog_disarmed,
            "guard_source_sha256": guard_sha,
            "watchdog_source_sha256": watchdog_sha,
            "watchdog_pid": watchdog.pid if watchdog is not None else None,
        },
        "streams": {
            "stdout": stdout_sink.record(),
            "stderr": stderr_sink.record(),
        },
    }


def _run_non_windows_job(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    stdout_path: Path,
    stderr_path: Path,
    limits: Limits,
    cleanup_armed_callback=None,
) -> dict[str, Any]:
    if cleanup_armed_callback is not None:
        return _run_non_windows_guarded_job(
            argv,
            cwd=cwd,
            env=env,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            limits=limits,
            cleanup_armed_callback=cleanup_armed_callback,
        )
    _validate_platform_support(limits)
    if os.name == "nt":
        raise ContractError("portable process-group adapter requires POSIX")
    stdout_sink = _PrefixSink(stdout_path, STDOUT_NAME, limits.stdout_cap_bytes)
    stderr_sink = _PrefixSink(stderr_path, STDERR_NAME, limits.stderr_cap_bytes)
    stdout_sink.open()
    try:
        stderr_sink.open()
    except BaseException:
        stdout_sink.seal()
        raise
    process: subprocess.Popen[bytes] | None = None
    stop = threading.Event()
    thread_errors: list[str] = []
    threads: list[threading.Thread] = []
    timed_out = False
    launch_error: str | None = None
    infrastructure_errors: list[str] = []
    pgid: int | None = None
    group_kill_reason: str | None = None
    group_quiesced = False
    descendant_leak = False
    started_ns = time.perf_counter_ns()

    def kill_group(reason: str) -> None:
        nonlocal group_kill_reason
        if pgid is None:
            return
        if pgid == os.getpgrp():
            infrastructure_errors.append(
                "refused to signal the parent process group"
            )
            return
        if group_kill_reason is None:
            group_kill_reason = reason
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            infrastructure_errors.append(
                f"killpg({reason}): {type(exc).__name__}: {exc}"
            )

    def wait_group_quiescence() -> bool:
        if pgid is None:
            return True
        deadline = time.monotonic() + 5
        while _posix_group_exists(pgid):
            if time.monotonic() >= deadline:
                infrastructure_errors.append(
                    "process group did not quiesce within 5 seconds"
                )
                return False
            time.sleep(limits.poll_ms / 1000)
        return True

    def reader(stream, sink: _PrefixSink, label: str) -> None:
        try:
            while True:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    break
                sink.consume(chunk)
                if sink.truncated:
                    stop.set()
                    break
        except BaseException as exc:
            message = f"{label}: {type(exc).__name__}: {exc}"
            sink.error = message
            thread_errors.append(message)
            stop.set()

    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            env=dict(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
        )
        pgid = process.pid
        try:
            observed_pgid = os.getpgid(process.pid)
            if observed_pgid != pgid:
                raise ContractError(
                    f"new-session pgid mismatch {observed_pgid} != {pgid}"
                )
        except ProcessLookupError:
            # A very short root may already be a zombie; its session/group ID
            # remains the root PID for descendant cleanup.
            pass
        assert process.stdout is not None and process.stderr is not None
        threads = [
            threading.Thread(
                target=reader,
                args=(process.stdout, stdout_sink, "stdout"),
                daemon=True,
            ),
            threading.Thread(
                target=reader,
                args=(process.stderr, stderr_sink, "stderr"),
                daemon=True,
            ),
        ]
        for thread in threads:
            thread.start()
        deadline = time.monotonic() + limits.wall_seconds
        while process.poll() is None:
            if stop.is_set():
                kill_group(
                    "output-cap"
                    if stdout_sink.truncated or stderr_sink.truncated
                    else "stream-stop"
                )
                break
            if time.monotonic() >= deadline:
                timed_out = True
                kill_group("timeout")
                break
            time.sleep(limits.poll_ms / 1000)
        process.wait(timeout=5)
        if _posix_group_exists(pgid):
            if group_kill_reason is None:
                descendant_leak = True
                infrastructure_errors.append(
                    "root exited while descendants survived in its process group"
                )
                kill_group("surviving-descendants")
            group_quiesced = wait_group_quiescence()
        else:
            group_quiesced = True
    except BaseException as exc:
        message = f"{type(exc).__name__}: {exc}"
        if process is None:
            launch_error = message
        else:
            infrastructure_errors.append(message)
            kill_group("adapter-exception")
            try:
                process.wait(timeout=5)
            except BaseException as wait_exc:
                infrastructure_errors.append(
                    f"root wait: {type(wait_exc).__name__}: {wait_exc}"
                )
            group_quiesced = wait_group_quiescence()
    finally:
        if process is not None and pgid is not None and _posix_group_exists(pgid):
            if group_kill_reason is None:
                descendant_leak = True
                infrastructure_errors.append(
                    "cleanup found surviving descendants in the process group"
                )
            kill_group("final-cleanup")
            if process.poll() is None:
                try:
                    process.wait(timeout=5)
                except BaseException as exc:
                    infrastructure_errors.append(
                        f"final root wait: {type(exc).__name__}: {exc}"
                    )
            group_quiesced = wait_group_quiescence()
        for thread in threads:
            thread.join(timeout=5)
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError as exc:
                        thread_errors.append(
                            f"pipe-close: {type(exc).__name__}: {exc}"
                        )
            for thread in threads:
                if thread.is_alive():
                    thread.join(timeout=1)
        if not threads:
            for sink in (stdout_sink, stderr_sink):
                try:
                    sink.seal()
                except BaseException as exc:
                    thread_errors.append(f"seal: {type(exc).__name__}: {exc}")
        for sink in (stdout_sink, stderr_sink):
            try:
                sink.seal()
            except BaseException as exc:
                message = f"final-seal: {type(exc).__name__}: {exc}"
                sink.error = message
                thread_errors.append(message)
    alive = [thread.name for thread in threads if thread.is_alive()]
    thread_error = (
        "; ".join(thread_errors)
        if thread_errors
        else (f"threads did not quiesce: {alive}" if alive else None)
    )
    return {
        "adapter": "subprocess-v1",
        "support": {
            "wall": "enforced",
            "output": "enforced",
            "job_memory": "unsupported-not-requested",
            "active_process": "unsupported-not-requested",
        },
        "stage": "child-sealed",
        "exit_code": process.returncode if process is not None else None,
        "timed_out": timed_out,
        "memory_limit_hit": False,
        "process_limit_hit": False,
        "output_limit_hit": stdout_sink.truncated or stderr_sink.truncated,
        "launch_error": launch_error,
        "pipe_error": next(
            (sink.error for sink in (stdout_sink, stderr_sink) if sink.error), None
        ),
        "thread_error": thread_error,
        "infrastructure_error": (
            "; ".join(dict.fromkeys(infrastructure_errors))
            if infrastructure_errors
            else None
        ),
        "measurements": {
            "wall_ns": time.perf_counter_ns() - started_ns,
            "process_count": None,
            "peak_job_memory_bytes": None,
            "thread_count": len(threads),
            "process_group_id": pgid,
            "process_group_quiesced": group_quiesced,
            "process_group_kill_reason": group_kill_reason,
            "surviving_descendant_detected": descendant_leak,
        },
        "streams": {
            "stdout": stdout_sink.record(),
            "stderr": stderr_sink.record(),
        },
    }


def _select_adapter() -> Callable[..., dict[str, Any]]:
    return _load_windows_adapter() if os.name == "nt" else _run_non_windows_job


@dataclass
class PreparedAttempt:
    spec: OneShotSpec
    attempt: dict[str, Any]
    env: dict[str, str]
    _executed: bool = False

    def execute(
        self,
        *,
        result_validator: Callable[[Mapping[str, Any]], None] | None = None,
        _adapter: Callable[..., dict[str, Any]] | None = None,
        _cleanup_armed: Callable[[Mapping[str, Any]], None] | None = None,
    ) -> dict[str, Any]:
        if self._executed:
            raise ContractError("prepared attempt has already executed")
        self._executed = True
        root = self.spec.evidence_dir
        if (root / VERDICT_NAME).exists() or any(
            (root / name).exists() for name in RAW_NAMES
        ):
            raise ContractError("attempt contains prior raw/verdict; retry is forbidden")
        adapter = _select_adapter() if _adapter is None else _adapter
        outcome: dict[str, Any]
        adapter_exception: str | None = None
        try:
            adapter_kwargs: dict[str, Any] = {
                "cwd": self.spec.cwd,
                "env": self.env,
                "stdout_path": root / STDOUT_NAME,
                "stderr_path": root / STDERR_NAME,
                "limits": self.spec.limits,
            }
            if _cleanup_armed is not None:
                adapter_kwargs["cleanup_armed_callback"] = _cleanup_armed
            outcome = adapter(self.spec.argv, **adapter_kwargs)
        except AdapterError as exc:
            adapter_exception = str(exc)
            outcome = dict(exc.outcome)
        except BaseException as exc:
            adapter_exception = f"{type(exc).__name__}: {exc}"
            outcome = _outcome_from_existing_raw(
                root, self.spec.limits, adapter_exception
            )
        try:
            outcome = _validate_adapter_outcome(outcome, self.spec.limits)
            _verify_raw_identity(root, outcome["streams"])
        except ContractError as exc:
            adapter_exception = f"adapter schema: {exc}"
            outcome = _validate_adapter_outcome(
                _outcome_from_existing_raw(
                    root, self.spec.limits, adapter_exception
                ),
                self.spec.limits,
            )
            _verify_raw_identity(root, outcome["streams"])
        try:
            _verify_tool_identity(self.attempt["execution"])
        except ContractError as exc:
            adapter_exception = f"execution identity: {exc}"
            outcome = dict(outcome)
            outcome["infrastructure_error"] = adapter_exception
        if adapter_exception is not None and outcome["infrastructure_error"] is None:
            outcome = dict(outcome)
            outcome["infrastructure_error"] = adapter_exception
        classification, error = _classify_outcome(
            outcome, self.spec.success_exit_codes
        )
        stage = "child"
        if classification == "success" and result_validator is not None:
            stage = "result-schema"
            try:
                result_validator(outcome)
            except ResultSchemaError as exc:
                classification = "schema_error"
                error = str(exc)
            except BaseException as exc:
                classification = "schema_error"
                error = f"{type(exc).__name__}: {exc}"
        status = "success" if classification == "success" else "failure"
        attempt_path = root / ATTEMPT_NAME
        verdict = {
            "schema": (
                CHAINED_VERDICT_SCHEMA
                if self.spec.chain is not None
                else VERDICT_SCHEMA
            ),
            "contract_version": (
                CHAINED_CONTRACT_VERSION
                if self.spec.chain is not None
                else CONTRACT_VERSION
            ),
            "attempt_id": self.attempt["attempt_id"],
            "attempt_sha256": _sha256_file(attempt_path),
            "gate_id": self.spec.gate_id,
            "status": status,
            "classification": classification,
            "stage": stage,
            "execution": self.attempt["execution"],
            "limits": self.attempt["limits"],
            "success_exit_codes": self.attempt["success_exit_codes"],
            "child": {
                "adapter": outcome["adapter"],
                "support": outcome["support"],
                "exit_code": outcome["exit_code"],
                "timed_out": outcome["timed_out"],
                "memory_limit_hit": outcome["memory_limit_hit"],
                "process_limit_hit": outcome["process_limit_hit"],
                "output_limit_hit": outcome["output_limit_hit"],
                "launch_error": outcome["launch_error"],
                "pipe_error": outcome["pipe_error"],
                "thread_error": outcome["thread_error"],
                "infrastructure_error": outcome["infrastructure_error"],
            },
            "measurements": outcome["measurements"],
            "streams": outcome["streams"],
            "error": error,
            "created_unix_ns": time.time_ns(),
        }
        if self.spec.chain is not None:
            verdict["chain"] = self.spec.chain.receipt()
        _validate_verdict(verdict)
        exclusive_write_json(root / VERDICT_NAME, verdict)
        return verdict


def _outcome_from_existing_raw(
    root: Path, limits: Limits, error: str
) -> dict[str, Any]:
    streams: dict[str, Any] = {}
    for stream, name, cap in (
        ("stdout", STDOUT_NAME, limits.stdout_cap_bytes),
        ("stderr", STDERR_NAME, limits.stderr_cap_bytes),
    ):
        path = root / name
        if path.is_file() and not path.is_symlink():
            size = path.stat().st_size
            try:
                descriptor = os.open(path, os.O_RDWR)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                fsynced = True
            except OSError:
                fsynced = False
            streams[stream] = {
                "path": name,
                "captured_size": size,
                "sha256": _sha256_file(path),
                "bytes_seen": size,
                "cap_bytes": cap,
                "truncated_at_cap": size == cap and cap > 0,
                "fsynced": fsynced,
                "error": error,
            }
        else:
            exclusive_write_bytes(path, b"")
            streams[stream] = {
                "path": name,
                "captured_size": 0,
                "sha256": _sha256_bytes(b""),
                "bytes_seen": 0,
                "cap_bytes": cap,
                "truncated_at_cap": False,
                "fsynced": True,
                "error": error,
            }
    return {
        "adapter": "unknown-adapter-v1",
        "support": {
            "wall": "unknown",
            "output": "unknown",
            "job_memory": "unknown",
            "active_process": "unknown",
        },
        "stage": "child-sealed",
        "exit_code": None,
        "timed_out": False,
        "memory_limit_hit": False,
        "process_limit_hit": False,
        "output_limit_hit": any(
            record["truncated_at_cap"] for record in streams.values()
        ),
        "launch_error": None,
        "pipe_error": None,
        "thread_error": None,
        "infrastructure_error": error,
        "measurements": {},
        "streams": streams,
    }


def prepare_attempt(spec: OneShotSpec) -> PreparedAttempt:
    execution, env = _validate_spec(spec)
    attempt_id = secrets.token_hex(32).upper()
    attempt = _attempt_record(spec, execution, attempt_id)
    _validate_attempt(attempt)
    exclusive_write_json(spec.evidence_dir / ATTEMPT_NAME, attempt)
    return PreparedAttempt(spec=spec, attempt=attempt, env=env)


def run_one_shot(
    spec: OneShotSpec,
    *,
    result_validator: Callable[[Mapping[str, Any]], None] | None = None,
    _adapter: Callable[..., dict[str, Any]] | None = None,
    _cleanup_armed: Callable[[Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    return prepare_attempt(spec).execute(
        result_validator=result_validator,
        _adapter=_adapter,
        _cleanup_armed=_cleanup_armed,
    )


ENTRY_PLAN_SCHEMA = "vorton.one-shot.entry-plan.v1"
ENTRY_PLAN_KEYS = {"schema", "contract_version", "gate_id", "launcher", "inner"}
ENTRY_LAUNCHER_KEYS = {"path", "size", "sha256", "windows_adapter"}
ENTRY_INNER_KEYS = {
    "evidence_dir",
    "argv",
    "cwd",
    "env",
    "limits",
    "success_exit_codes",
}
OUTER_ATTEMPT_SCHEMA = "vorton.one-shot.outer-attempt.v1"
OUTER_VERDICT_SCHEMA = "vorton.one-shot.outer-verdict.v1"
OUTER_AUDIT_SCHEMA = "vorton.one-shot.outer-audit.v1"
OUTER_ATTEMPT_NAME = "outer-attempt.json"
OUTER_VERDICT_NAME = "outer-verdict.json"
OUTER_STDOUT_NAME = "outer-stdout.raw"
OUTER_STDERR_NAME = "outer-stderr.raw"


def _validate_entry_plan(plan_value: Any) -> tuple[dict[str, Any], OneShotSpec]:
    plan = _strict_keys(plan_value, ENTRY_PLAN_KEYS, "entry plan")
    if plan["schema"] != ENTRY_PLAN_SCHEMA or plan["contract_version"] != 1:
        raise ContractError("entry plan schema/version mismatch")
    if not isinstance(plan["gate_id"], str) or GATE_ID_RE.fullmatch(
        plan["gate_id"]
    ) is None:
        raise ContractError("entry plan gate_id is invalid")
    launcher = _strict_keys(
        plan["launcher"], ENTRY_LAUNCHER_KEYS, "entry plan.launcher"
    )
    launcher_path = Path(launcher["path"]) if isinstance(launcher["path"], str) else Path()
    if (
        not launcher_path.is_absolute()
        or launcher_path.is_symlink()
        or not launcher_path.is_file()
        or type(launcher["size"]) is not int
        or launcher["size"] < 0
        or not isinstance(launcher["sha256"], str)
        or HEX_64_RE.fullmatch(launcher["sha256"]) is None
    ):
        raise ContractError("entry plan launcher identity is invalid")
    actual_launcher = Path(__file__).resolve(strict=True)
    if launcher_path.resolve(strict=True) != actual_launcher:
        raise ContractError("entry plan launcher path differs from executing source")
    if actual_launcher.stat().st_size != launcher["size"] or _sha256_file(
        actual_launcher
    ) != launcher["sha256"]:
        raise ContractError("entry plan launcher bytes differ from reviewed identity")
    windows_identity = _strict_keys(
        launcher["windows_adapter"], TOOL_KEYS, "entry plan.launcher.windows_adapter"
    )
    windows_path = (
        Path(windows_identity["path"])
        if isinstance(windows_identity["path"], str)
        else Path()
    )
    expected_windows = actual_launcher.parents[2] / "bench" / "check" / "windows_job.py"
    if (
        not windows_path.is_absolute()
        or windows_path.is_symlink()
        or windows_path.resolve(strict=True) != expected_windows.resolve(strict=True)
        or type(windows_identity["size"]) is not int
        or windows_identity["size"] != windows_path.stat().st_size
        or not isinstance(windows_identity["sha256"], str)
        or HEX_64_RE.fullmatch(windows_identity["sha256"]) is None
        or windows_identity["sha256"] != _sha256_file(windows_path)
    ):
        raise ContractError("entry plan Windows adapter identity is invalid")

    inner = _strict_keys(plan["inner"], ENTRY_INNER_KEYS, "entry plan.inner")
    if inner["evidence_dir"] != "inner":
        raise ContractError("entry plan inner evidence_dir must be exactly 'inner'")
    argv = inner["argv"]
    if not isinstance(argv, list) or not argv or not all(
        isinstance(part, str) and part and "\x00" not in part for part in argv
    ):
        raise ContractError("entry plan inner argv is invalid")
    cwd = Path(inner["cwd"]) if isinstance(inner["cwd"], str) else Path()
    if not cwd.is_absolute() or not cwd.is_dir():
        raise ContractError("entry plan inner cwd is invalid")
    env_entries = inner["env"]
    if not isinstance(env_entries, list):
        raise ContractError("entry plan inner env is not a list")
    env_pairs: list[tuple[str, str]] = []
    for index, entry_value in enumerate(env_entries):
        entry = _strict_keys(
            entry_value, ENV_ENTRY_KEYS, f"entry plan.inner.env[{index}]"
        )
        if not isinstance(entry["name"], str) or not isinstance(entry["value"], str):
            raise ContractError("entry plan inner env entry is invalid")
        env_pairs.append((entry["name"], entry["value"]))
    env_names = [name for name, _value in env_pairs]
    if env_names != sorted(set(env_names)):
        raise ContractError("entry plan inner env is not unique/sorted")
    limits_value = _validate_limits_receipt(
        inner["limits"], "entry plan.inner.limits"
    )
    success_exit_codes = inner["success_exit_codes"]
    if not isinstance(success_exit_codes, list) or not success_exit_codes or not all(
        type(code) is int for code in success_exit_codes
    ):
        raise ContractError("entry plan inner success_exit_codes are invalid")
    placeholder_root = Path("/")
    spec = OneShotSpec(
        evidence_dir=placeholder_root,
        gate_id=plan["gate_id"],
        argv=tuple(argv),
        reviewed_argv=tuple(argv),
        cwd=cwd,
        env=dict(env_pairs),
        reviewed_env=tuple(env_pairs),
        limits=Limits(**limits_value),
        success_exit_codes=tuple(success_exit_codes),
    )
    return plan, spec


def run_chained_plan(
    plan_value: Any,
    *,
    outer_evidence_dir: str,
    outer_attempt_id: str,
    outer_attempt_sha256: str,
    plan_sha256: str,
    cleanup_armed_callback: Callable[[Mapping[str, Any]], None],
) -> dict[str, Any]:
    """Run the exact fixed inner gate as one child of an outer transaction."""

    global _CHAIN_WINDOWS_ADAPTER_IDENTITY
    plan, template = _validate_entry_plan(plan_value)
    outer_root = Path(outer_evidence_dir)
    if not outer_root.is_absolute() or not outer_root.is_dir() or outer_root.is_symlink():
        raise ContractError("outer evidence root is invalid")
    outer_attempt = outer_root / "outer-attempt.json"
    if outer_attempt.is_symlink() or not outer_attempt.is_file():
        raise ContractError("outer attempt is missing/non-regular")
    if _sha256_file(outer_attempt) != outer_attempt_sha256:
        raise ContractError("outer attempt hash changed before inner attempt")
    outer_value = _load_json(outer_attempt)
    if not isinstance(outer_value, dict):
        raise ContractError("outer attempt is not an object")
    try:
        delivered_plan_hash = outer_value["delivery"]["plan"]["sha256"]
        delivered_root = outer_value["evidence_root"]
        delivered_attempt_id = outer_value["attempt_id"]
    except (KeyError, TypeError) as exc:
        raise ContractError("outer attempt lacks chain authority fields") from exc
    if (
        outer_value.get("schema") != "vorton.one-shot.outer-attempt.v1"
        or delivered_plan_hash != plan_sha256
        or delivered_root != os.fspath(outer_root)
        or delivered_attempt_id != outer_attempt_id
    ):
        raise ContractError("outer attempt chain authority mismatch")
    chain = AttemptChain(
        outer_attempt_id=outer_attempt_id,
        outer_attempt_sha256=outer_attempt_sha256,
        plan_sha256=plan_sha256,
    )
    chain.receipt()
    inner_root = outer_root / plan["inner"]["evidence_dir"]
    try:
        inner_root.mkdir(parents=False, exist_ok=False)
    except OSError as exc:
        raise ContractError(f"cannot create exclusive inner evidence root: {exc}") from exc
    spec = OneShotSpec(
        **{
            **template.__dict__,
            "evidence_dir": inner_root,
            "chain": chain,
        }
    )
    windows_value = plan["launcher"]["windows_adapter"]
    previous_windows_identity = _CHAIN_WINDOWS_ADAPTER_IDENTITY
    _CHAIN_WINDOWS_ADAPTER_IDENTITY = {
        "path": os.fspath(Path(windows_value["path"]).resolve(strict=True)),
        "size": windows_value["size"],
        "sha256": windows_value["sha256"],
    }
    try:
        verdict = run_one_shot(spec, _cleanup_armed=cleanup_armed_callback)
    finally:
        _CHAIN_WINDOWS_ADAPTER_IDENTITY = previous_windows_identity
    audit = audit_attempt(inner_root)
    return {
        "inner_evidence_dir": "inner",
        "verdict": verdict,
        "audit": audit,
    }


def _outer_file_receipt(path: Path) -> dict[str, Any] | None:
    if path.is_symlink() or not path.is_file():
        return None
    return {"path": path.name, "size": path.stat().st_size, "sha256": _sha256_file(path)}


def _outer_raw_record(path: Path, cap: int) -> dict[str, Any]:
    with path.open("r+b") as stream:
        os.fsync(stream.fileno())
        seen = path.stat().st_size
        if seen > cap:
            stream.truncate(cap)
            stream.flush()
            os.fsync(stream.fileno())
    _fsync_directory(path.parent)
    captured = path.stat().st_size
    return {
        "path": path.name,
        "captured_size": captured,
        "bytes_seen": seen,
        "cap_bytes": cap,
        "truncated_at_cap": seen > cap,
        "sha256": _sha256_file(path),
        "fsynced": True,
    }


def _detach_outer_streams() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except BaseException:
            pass
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
    finally:
        os.close(devnull)


def _outer_inner_summary(root: Path) -> dict[str, Any] | None:
    inner = root / "inner"
    if not inner.is_dir() or inner.is_symlink():
        return None
    audit = audit_attempt(inner)
    return {
        "evidence_dir": "inner",
        "attempt": _outer_file_receipt(inner / ATTEMPT_NAME),
        "verdict": _outer_file_receipt(inner / VERDICT_NAME),
        "stdout": _outer_file_receipt(inner / STDOUT_NAME),
        "stderr": _outer_file_receipt(inner / STDERR_NAME),
        "audit": audit,
        "audit_sha256": _sha256_bytes(_json_bytes(audit)),
    }


def _validate_outer_attempt(value: Any) -> dict[str, Any]:
    attempt = _strict_keys(
        value,
        {
            "schema",
            "contract_version",
            "attempt_id",
            "created_unix_ns",
            "state",
            "evidence_root",
            "delivery",
            "observed",
        },
        "outer attempt",
    )
    if (
        attempt["schema"] != OUTER_ATTEMPT_SCHEMA
        or attempt["contract_version"] != 1
        or not isinstance(attempt["attempt_id"], str)
        or ATTEMPT_ID_RE.fullmatch(attempt["attempt_id"]) is None
        or attempt["state"] != "attempt-created"
        or type(attempt["created_unix_ns"]) is not int
        or not isinstance(attempt["evidence_root"], str)
        or not Path(attempt["evidence_root"]).is_absolute()
    ):
        raise ContractError("outer attempt identity is invalid")
    delivery = _strict_keys(
        attempt["delivery"],
        {
            "required_interpreter_flags",
            "python",
            "entry",
            "plan",
            "cwd",
            "env",
            "env_sha256",
            "limits",
        },
        "outer attempt.delivery",
    )
    if delivery["required_interpreter_flags"] != ["-I", "-S", "-B", "-u"]:
        raise ContractError("outer interpreter flags mismatch")
    outer_limits = _strict_keys(
        delivery["limits"],
        {"wall_seconds", "output_cap_bytes"},
        "outer attempt.delivery.limits",
    )
    if (
        type(outer_limits["wall_seconds"]) not in (int, float)
        or not math.isfinite(float(outer_limits["wall_seconds"]))
        or outer_limits["wall_seconds"] <= 0
        or type(outer_limits["output_cap_bytes"]) is not int
        or outer_limits["output_cap_bytes"] <= 0
    ):
        raise ContractError("outer wall/output limits are invalid")
    for label in ("python", "entry", "plan"):
        keys = {"path", "size", "sha256"} | ({"version"} if label == "python" else set())
        identity = _strict_keys(delivery[label], keys, f"outer delivery.{label}")
        if (
            not isinstance(identity["path"], str)
            or not Path(identity["path"]).is_absolute()
            or type(identity["size"]) is not int
            or identity["size"] < 0
            or not isinstance(identity["sha256"], str)
            or HEX_64_RE.fullmatch(identity["sha256"]) is None
        ):
            raise ContractError(f"outer {label} identity is invalid")
    environment = delivery["env"]
    if not isinstance(environment, list) or delivery["env_sha256"] != _sha256_bytes(
        _json_bytes(environment)
    ):
        raise ContractError("outer environment identity is invalid")
    names: list[str] = []
    for index, entry in enumerate(environment):
        item = _strict_keys(entry, ENV_ENTRY_KEYS, f"outer env[{index}]")
        if not isinstance(item["name"], str) or not isinstance(item["value"], str):
            raise ContractError("outer environment entry is invalid")
        names.append(item["name"])
    if names != sorted(set(names)):
        raise ContractError("outer environment names are not unique/sorted")
    observed = _strict_keys(
        attempt["observed"],
        {
            "python_path",
            "python_version",
            "python_implementation",
            "entry_path",
            "isolated",
            "no_site",
            "dont_write_bytecode",
            "stdout_write_through",
            "stderr_write_through",
            "argv",
        },
        "outer attempt.observed",
    )
    if (
        observed["python_path"] != delivery["python"]["path"]
        or observed["entry_path"] != delivery["entry"]["path"]
        or observed["python_version"] != delivery["python"]["version"]
        or observed["python_implementation"] != "cpython"
        or observed["isolated"] != 1
        or observed["no_site"] != 1
        or observed["dont_write_bytecode"] != 1
        or observed["stdout_write_through"] is not True
        or observed["stderr_write_through"] is not True
        or not isinstance(observed["argv"], list)
    ):
        raise ContractError("outer observed trust-root identity is invalid")
    return attempt


def run_outer_entry(
    plan_value: Any,
    *,
    delivery: Mapping[str, Any],
    attempt: Mapping[str, Any],
    outer_evidence_dir: str,
    identities: Mapping[str, Any],
    started_ns: int,
    outer_bound_state: Callable[[], str | None],
) -> int:
    """Execute and seal the rich outer transaction after bootstrap first-write."""

    root = Path(outer_evidence_dir)
    checked_attempt = _validate_outer_attempt(dict(attempt))
    if checked_attempt["evidence_root"] != os.fspath(root):
        raise ContractError("outer attempt root differs from executing root")
    stage = "inner"
    status = "failure"
    classification = "infrastructure_error"
    error: str | None = None
    handshakes: list[dict[str, Any]] = []
    try:
        def cleanup_armed(value: Mapping[str, Any]) -> None:
            if handshakes:
                raise ContractError("cleanup handshake occurred more than once")
            if not isinstance(value, Mapping) or value.get("target_resumed") is not False:
                raise ContractError("cleanup handshake is malformed/late")
            handshakes.append(dict(value))

        result = run_chained_plan(
            plan_value,
            outer_evidence_dir=os.fspath(root),
            outer_attempt_id=checked_attempt["attempt_id"],
            outer_attempt_sha256=_sha256_file(root / OUTER_ATTEMPT_NAME),
            plan_sha256=str(delivery["plan_sha256"]),
            cleanup_armed_callback=cleanup_armed,
        )
        result = _strict_keys(
            result, {"inner_evidence_dir", "verdict", "audit"}, "launcher result"
        )
        if result["inner_evidence_dir"] != "inner":
            raise ContractError("launcher returned a different inner root")
        inner_verdict = result["verdict"]
        if not isinstance(inner_verdict, dict) or inner_verdict.get("status") not in {
            "success",
            "failure",
        }:
            raise ContractError("launcher returned an invalid inner verdict")
        if not handshakes:
            raise ContractError("target completed without cleanup handshake")
        status = inner_verdict["status"]
        classification = "success" if status == "success" else "inner_failure"
        error = inner_verdict.get("error")
    except BaseException as exc:
        error = f"{type(exc).__name__}: {exc}"
        classification = f"{stage}_failure"
        try:
            traceback.print_exc()
        except BaseException:
            pass
    _detach_outer_streams()
    cap = int(checked_attempt["delivery"]["limits"]["output_cap_bytes"])
    stdout = _outer_raw_record(root / OUTER_STDOUT_NAME, cap)
    stderr = _outer_raw_record(root / OUTER_STDERR_NAME, cap)
    bound_reason = outer_bound_state()
    if bound_reason == "timeout":
        status = "failure"
        classification = "outer_timeout"
        error = error or "outer launcher reached its wall bound"
    elif (
        bound_reason == "output"
        or stdout["truncated_at_cap"]
        or stderr["truncated_at_cap"]
    ):
        status = "failure"
        classification = "outer_output_limit"
        error = error or "outer launcher output reached its cap"
    verdict = {
        "schema": OUTER_VERDICT_SCHEMA,
        "contract_version": 1,
        "attempt_id": checked_attempt["attempt_id"],
        "attempt_sha256": _sha256_file(root / OUTER_ATTEMPT_NAME),
        "plan_sha256": str(delivery["plan_sha256"]),
        "status": status,
        "classification": classification,
        "stage": stage,
        "error": error,
        "identities": dict(identities),
        "cleanup_handshakes": handshakes,
        "inner": _outer_inner_summary(root),
        "measurements": {
            "outer_wall_ns": time.perf_counter_ns() - started_ns,
            "cleanup_handshake_count": len(handshakes),
            "platform": sys.platform,
        },
        "streams": {"stdout": stdout, "stderr": stderr},
        "created_unix_ns": time.time_ns(),
    }
    exclusive_write_json(root / OUTER_VERDICT_NAME, verdict)
    return 0 if status == "success" else 1


def audit_outer(evidence_dir: Path) -> dict[str, Any]:
    root = evidence_dir.resolve()
    result = {
        "schema": OUTER_AUDIT_SCHEMA,
        "contract_version": 1,
        "evidence_root": os.fspath(root),
        "consumed": False,
        "state": "absent",
        "status": "unknown",
        "classification": "unknown",
        "errors": [],
    }
    attempt_path = root / OUTER_ATTEMPT_NAME
    if attempt_path.is_symlink() or not attempt_path.is_file():
        if root.exists() and any(root.iterdir()):
            result["state"] = "incomplete"
            result["errors"].append("outer evidence exists without regular attempt")
        return result
    result["consumed"] = True
    try:
        attempt = _validate_outer_attempt(_load_json(attempt_path))
    except ContractError as exc:
        result["state"] = "incomplete"
        result["errors"].append(str(exc))
        return result
    verdict_path = root / OUTER_VERDICT_NAME
    if verdict_path.is_symlink() or not verdict_path.is_file():
        result["state"] = "incomplete"
        result["errors"].append("outer attempt has no verdict (crash/unknown)")
        return result
    try:
        verdict = _strict_keys(
            _load_json(verdict_path),
            {
                "schema",
                "contract_version",
                "attempt_id",
                "attempt_sha256",
                "plan_sha256",
                "status",
                "classification",
                "stage",
                "error",
                "identities",
                "cleanup_handshakes",
                "inner",
                "measurements",
                "streams",
                "created_unix_ns",
            },
            "outer verdict",
        )
        if (
            verdict["schema"] != OUTER_VERDICT_SCHEMA
            or verdict["contract_version"] != 1
            or verdict["attempt_id"] != attempt["attempt_id"]
            or verdict["attempt_sha256"] != _sha256_file(attempt_path)
            or verdict["plan_sha256"] != attempt["delivery"]["plan"]["sha256"]
            or verdict["status"] not in {"success", "failure"}
        ):
            raise ContractError("outer attempt/verdict identity mismatch")
        if verdict["status"] == "success" and (
            verdict["classification"] != "success"
            or verdict["error"] is not None
            or len(verdict["cleanup_handshakes"]) != 1
        ):
            raise ContractError("successful outer verdict has invalid state")
        if verdict["status"] == "failure" and verdict["classification"] == "success":
            raise ContractError("failed outer verdict claims success")
        if not isinstance(verdict["measurements"], dict) or type(
            verdict["measurements"].get("outer_wall_ns")
        ) is not int:
            raise ContractError("outer measurements are invalid")
        for stream, name in (
            ("stdout", OUTER_STDOUT_NAME),
            ("stderr", OUTER_STDERR_NAME),
        ):
            record = _strict_keys(
                verdict["streams"][stream],
                {
                    "path",
                    "captured_size",
                    "bytes_seen",
                    "cap_bytes",
                    "truncated_at_cap",
                    "sha256",
                    "fsynced",
                },
                f"outer verdict.streams.{stream}",
            )
            path = root / name
            outer_cap = attempt["delivery"]["limits"]["output_cap_bytes"]
            if (
                path.is_symlink()
                or not path.is_file()
                or record["path"] != name
                or record["captured_size"] != path.stat().st_size
                or record["sha256"] != _sha256_file(path)
                or not record["fsynced"]
                or record["cap_bytes"] != outer_cap
                or type(record["bytes_seen"]) is not int
                or record["bytes_seen"] < record["captured_size"]
                or record["captured_size"]
                != min(record["bytes_seen"], outer_cap)
                or record["truncated_at_cap"]
                != (record["bytes_seen"] > outer_cap)
            ):
                raise ContractError(f"outer {stream} raw identity mismatch")
        expected = {
            OUTER_ATTEMPT_NAME,
            OUTER_VERDICT_NAME,
            OUTER_STDOUT_NAME,
            OUTER_STDERR_NAME,
        }
        inner_record = verdict["inner"]
        if inner_record is not None:
            expected.add("inner")
            inner_record = _strict_keys(
                inner_record,
                {
                    "evidence_dir",
                    "attempt",
                    "verdict",
                    "stdout",
                    "stderr",
                    "audit",
                    "audit_sha256",
                },
                "outer verdict.inner",
            )
            if inner_record["evidence_dir"] != "inner":
                raise ContractError("outer verdict references a different inner root")
            inner_root = root / "inner"
            actual_inner_audit = audit_attempt(inner_root)
            for label, name in (
                ("attempt", ATTEMPT_NAME),
                ("verdict", VERDICT_NAME),
                ("stdout", STDOUT_NAME),
                ("stderr", STDERR_NAME),
            ):
                if inner_record[label] != _outer_file_receipt(inner_root / name):
                    raise ContractError(f"inner {label} receipt/hash mismatch")
            if inner_record["audit_sha256"] != _sha256_bytes(
                _json_bytes(inner_record["audit"])
            ):
                raise ContractError("inner audit hash mismatch")
            if inner_record["audit"] != actual_inner_audit:
                raise ContractError("stored inner audit differs from current audit")
            if inner_record["attempt"] is not None:
                inner_attempt = _load_json(inner_root / ATTEMPT_NAME)
                chain = inner_attempt.get("chain")
                if (
                    inner_attempt.get("schema") != CHAINED_ATTEMPT_SCHEMA
                    or not isinstance(chain, dict)
                    or chain.get("outer_attempt_id") != attempt["attempt_id"]
                    or chain.get("outer_attempt_sha256") != _sha256_file(attempt_path)
                    or chain.get("plan_sha256")
                    != attempt["delivery"]["plan"]["sha256"]
                ):
                    raise ContractError("inner attempt chain mismatch")
                if inner_record["verdict"] is not None:
                    inner_verdict = _load_json(inner_root / VERDICT_NAME)
                    if (
                        inner_verdict.get("schema") != CHAINED_VERDICT_SCHEMA
                        or inner_verdict.get("chain") != chain
                    ):
                        raise ContractError("inner attempt/verdict chain mismatch")
            if actual_inner_audit["state"] == "complete":
                if actual_inner_audit["status"] == "failure" and (
                    verdict["status"] != "failure"
                    or verdict["classification"] != "inner_failure"
                ):
                    raise ContractError("outer status hides actual inner failure")
                if actual_inner_audit["status"] == "success" and verdict[
                    "status"
                ] == "success" and verdict["classification"] != "success":
                    raise ContractError("outer success differs from actual inner success")
            elif verdict["status"] == "success":
                raise ContractError("outer success lacks a complete inner result")
        elif verdict["status"] == "success":
            raise ContractError("outer success lacks inner evidence")
        if {path.name for path in root.iterdir()} != expected:
            raise ContractError("outer evidence inventory mismatch")
    except (ContractError, OSError, KeyError, TypeError) as exc:
        result["state"] = "incomplete"
        result["errors"].append(str(exc))
        return result
    result["state"] = "complete"
    result["status"] = verdict["status"]
    result["classification"] = verdict["classification"]
    return result


def audit_attempt(evidence_dir: Path) -> dict[str, Any]:
    root = evidence_dir.resolve()
    result = {
        "schema": AUDIT_SCHEMA,
        "contract_version": CONTRACT_VERSION,
        "evidence_dir": os.fspath(root),
        "consumed": False,
        "state": "absent",
        "status": "unknown",
        "classification": "unknown",
        "errors": [],
    }
    attempt_path = root / ATTEMPT_NAME
    if not os.path.lexists(attempt_path):
        if root.exists() and any(root.iterdir()):
            result["state"] = "incomplete"
            result["errors"].append("evidence exists without an attempt marker")
        return result
    result["consumed"] = True
    if attempt_path.is_symlink() or not attempt_path.is_file():
        result["state"] = "incomplete"
        result["errors"].append("attempt marker is not a regular non-link file")
        return result
    try:
        attempt = _validate_attempt(_load_json(attempt_path))
    except ContractError as exc:
        result["state"] = "incomplete"
        result["errors"].append(str(exc))
        return result
    verdict_path = root / VERDICT_NAME
    if verdict_path.is_symlink() or not verdict_path.is_file():
        result["state"] = "incomplete"
        result["errors"].append("attempt has no verdict (parent crash/unknown)")
        return result
    try:
        verdict = _validate_verdict(_load_json(verdict_path))
    except ContractError as exc:
        result["state"] = "incomplete"
        result["errors"].append(str(exc))
        return result
    if verdict["attempt_id"] != attempt["attempt_id"]:
        result["errors"].append("attempt/verdict id mismatch")
    if verdict["attempt_sha256"] != _sha256_file(attempt_path):
        result["errors"].append("attempt bytes changed after verdict")
    if verdict["gate_id"] != attempt["gate_id"]:
        result["errors"].append("attempt/verdict gate mismatch")
    if verdict["execution"] != attempt["execution"]:
        result["errors"].append("attempt/verdict execution identity mismatch")
    if verdict["limits"] != attempt["limits"]:
        result["errors"].append("attempt/verdict limits mismatch")
    if verdict["success_exit_codes"] != attempt["success_exit_codes"]:
        result["errors"].append("attempt/verdict success exit codes mismatch")
    if ("chain" in verdict) != ("chain" in attempt) or verdict.get(
        "chain"
    ) != attempt.get("chain"):
        result["errors"].append("attempt/verdict chain mismatch")
    child = verdict["child"]
    preliminary, _preliminary_error = _classify_outcome(
        child, attempt["success_exit_codes"]
    )
    if verdict["classification"] == "schema_error":
        if preliminary != "success" or verdict["stage"] != "result-schema":
            result["errors"].append("schema_error lacks a successful child/schema stage")
    elif verdict["classification"] == "success" and verdict["stage"] == "result-schema":
        if preliminary != "success":
            result["errors"].append(
                "successful result-schema verdict lacks a successful child"
            )
    else:
        if verdict["classification"] != preliminary:
            result["errors"].append("verdict classification contradicts child facts")
        if verdict["stage"] != "child":
            result["errors"].append("non-schema verdict stage is not child")
    expected_status = (
        "success" if verdict["classification"] == "success" else "failure"
    )
    if verdict["status"] != expected_status:
        result["errors"].append("verdict status contradicts classification")
    if expected_status == "success" and verdict["error"] is not None:
        result["errors"].append("successful verdict unexpectedly has an error")
    if expected_status == "failure" and verdict["error"] is None:
        result["errors"].append("failed verdict lacks an error class/message")
    try:
        inventory = sorted(entry.name for entry in os.scandir(root))
        if inventory != list(COMPLETE_NAMES):
            result["errors"].append(
                f"complete inventory mismatch: {inventory} != {list(COMPLETE_NAMES)}"
            )
    except OSError as exc:
        result["errors"].append(f"cannot inventory evidence: {exc}")
    for stream, expected_name in (("stdout", STDOUT_NAME), ("stderr", STDERR_NAME)):
        record = verdict["streams"].get(stream)
        try:
            cap = attempt["limits"][f"{stream}_cap_bytes"]
            validated = _validate_stream_record(record, stream, expected_name, cap)
            raw_path = root / expected_name
            if raw_path.is_symlink() or not raw_path.is_file():
                raise ContractError(f"{stream} raw file is missing/non-regular")
            actual_size = raw_path.stat().st_size
            actual_hash = _sha256_file(raw_path)
            if actual_size != validated["captured_size"]:
                raise ContractError(f"{stream} raw size mismatch")
            if actual_hash != validated["sha256"]:
                raise ContractError(f"{stream} raw hash mismatch")
            if not validated["fsynced"]:
                raise ContractError(f"{stream} was not sealed before verdict")
        except (ContractError, OSError, KeyError) as exc:
            result["errors"].append(str(exc))
    stream_limit_hit = bool(
        verdict["streams"]["stdout"]["truncated_at_cap"]
        or verdict["streams"]["stderr"]["truncated_at_cap"]
    )
    if child["output_limit_hit"] != stream_limit_hit:
        result["errors"].append("child output-limit flag contradicts raw streams")
    if result["errors"]:
        result["state"] = "incomplete"
        result["status"] = "unknown"
        result["classification"] = "unknown"
    else:
        result["state"] = "complete"
        result["status"] = verdict["status"]
        result["classification"] = verdict["classification"]
    return result


def _archive_inventory(evidence_dir: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in sorted(evidence_dir.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise ContractError(f"archive evidence contains symlink: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ContractError(f"archive evidence contains non-file: {path}")
        relative = path.relative_to(evidence_dir).as_posix()
        records.append(
            {
                "path": relative,
                "size": path.stat().st_size,
                "sha256": _sha256_file(path),
            }
        )
    return records


def create_archive(evidence_dir: Path, archive_path: Path) -> dict[str, Any]:
    root = evidence_dir.resolve()
    target = archive_path.resolve()
    if root == target or root in target.parents:
        raise ContractError("archive must be outside the evidence directory")
    records = _archive_inventory(root)
    manifest = {
        "schema": ARCHIVE_SCHEMA,
        "contract_version": CONTRACT_VERSION,
        "file_count": len(records),
        "files": records,
    }
    manifest_bytes = _json_bytes(manifest)
    try:
        with tarfile.open(target, mode="x") as archive:
            for record in records:
                source = root / record["path"]
                archive.add(source, arcname=f"evidence/{record['path']}", recursive=False)
            info = tarfile.TarInfo("archive-manifest.json")
            info.size = len(manifest_bytes)
            info.mtime = 0
            import io

            archive.addfile(info, io.BytesIO(manifest_bytes))
    except (OSError, tarfile.TarError) as exc:
        raise ContractError(f"cannot create exclusive archive {target}: {exc}") from exc
    verified = verify_archive(target)
    if verified != manifest:
        raise ContractError("archive round-trip manifest differs")
    return manifest


def verify_archive(archive_path: Path) -> dict[str, Any]:
    path = archive_path.resolve()
    try:
        with tarfile.open(path, mode="r:") as archive:
            members = archive.getmembers()
            by_name = {member.name: member for member in members}
            if len(by_name) != len(members):
                raise ContractError("archive contains duplicate member names")
            manifest_member = by_name.get("archive-manifest.json")
            if manifest_member is None or not manifest_member.isfile():
                raise ContractError("archive manifest member is missing")
            manifest_stream = archive.extractfile(manifest_member)
            if manifest_stream is None:
                raise ContractError("cannot read archive manifest member")
            manifest = json.loads(
                manifest_stream.read().decode("utf-8"),
                object_pairs_hook=_reject_duplicate_keys,
                parse_constant=_reject_json_constant,
            )
            _strict_keys(
                manifest,
                {"schema", "contract_version", "file_count", "files"},
                "archive manifest",
            )
            if manifest["schema"] != ARCHIVE_SCHEMA:
                raise ContractError("archive schema mismatch")
            if manifest["contract_version"] != CONTRACT_VERSION:
                raise ContractError("archive contract version mismatch")
            files = manifest["files"]
            if (
                type(manifest["file_count"]) is not int
                or not isinstance(files, list)
                or manifest["file_count"] != len(files)
            ):
                raise ContractError("archive file count mismatch")
            expected_names = {"archive-manifest.json"}
            seen_relative_paths: set[str] = set()
            for record in files:
                _strict_keys(record, {"path", "size", "sha256"}, "archive file")
                relative = record["path"]
                posix_relative = (
                    PurePosixPath(relative) if isinstance(relative, str) else None
                )
                if (
                    not isinstance(relative, str)
                    or not relative
                    or "\\" in relative
                    or posix_relative is None
                    or posix_relative.is_absolute()
                    or ".." in posix_relative.parts
                    or ":" in relative
                ):
                    raise ContractError("archive path is unsafe")
                if relative in seen_relative_paths:
                    raise ContractError("archive manifest repeats a file path")
                seen_relative_paths.add(relative)
                if type(record["size"]) is not int or record["size"] < 0:
                    raise ContractError("archive member size is invalid")
                if not isinstance(record["sha256"], str) or HEX_64_RE.fullmatch(
                    record["sha256"]
                ) is None:
                    raise ContractError("archive member SHA-256 is invalid")
                member_name = f"evidence/{relative}"
                expected_names.add(member_name)
                member = by_name.get(member_name)
                if member is None or not member.isfile():
                    raise ContractError(f"archive member missing: {member_name}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ContractError(f"cannot read archive member: {member_name}")
                data = stream.read()
                if len(data) != record["size"] or _sha256_bytes(data) != record["sha256"]:
                    raise ContractError(f"archive member identity mismatch: {member_name}")
            if set(by_name) != expected_names:
                raise ContractError("archive member count/name inventory mismatch")
            return manifest
    except (OSError, UnicodeError, json.JSONDecodeError, tarfile.TarError) as exc:
        if isinstance(exc, ContractError):
            raise
        raise ContractError(f"cannot verify archive {path}: {exc}") from exc


def _main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("evidence_dir", type=Path)
    archive_parser = subparsers.add_parser("archive")
    archive_parser.add_argument("evidence_dir", type=Path)
    archive_parser.add_argument("archive_path", type=Path)
    verify_parser = subparsers.add_parser("verify-archive")
    verify_parser.add_argument("archive_path", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "audit":
            output = audit_attempt(args.evidence_dir)
        elif args.command == "archive":
            output = create_archive(args.evidence_dir, args.archive_path)
        else:
            output = verify_archive(args.archive_path)
        print(
            json.dumps(
                output,
                ensure_ascii=True,
                sort_keys=True,
                allow_nan=False,
            )
        )
        return 0
    except OneShotError as exc:
        print(f"one-shot gate: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
