#!/usr/bin/env python3
"""Tiny finite trust-root bootstrap for outer one-shot evidence.

Invoke only with an exact pinned CPython and ``-I -S -B -u``.  The OS launch,
that interpreter, these bytes, and argv delivery are the accepted finite root.
This script writes the outer attempt/raw files before it reads any plan, repo,
or real-launcher bytes; all rich validation then runs from the hash-pinned
external launcher source compiled after the attempt.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
import time
import traceback
import types
from pathlib import Path


OUTER_CONTRACT_VERSION = 1
OUTER_ATTEMPT_SCHEMA = "vorton.one-shot.outer-attempt.v1"
OUTER_VERDICT_SCHEMA = "vorton.one-shot.outer-verdict.v1"
OUTER_ATTEMPT_NAME = "outer-attempt.json"
OUTER_VERDICT_NAME = "outer-verdict.json"
OUTER_STDOUT_NAME = "outer-stdout.raw"
OUTER_STDERR_NAME = "outer-stderr.raw"
HEX_64_RE = re.compile(r"^[0-9a-f]{64}$")


class OuterEntryError(RuntimeError):
    pass


def _json_bytes(value) -> bytes:
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
        raise OuterEntryError(f"cannot encode canonical JSON: {exc}") from exc


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise OuterEntryError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value: str):
    raise OuterEntryError(f"non-finite JSON constant is forbidden: {value}")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def _fsync_directory(path: Path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    offset = 0
    while offset < len(view):
        written = os.write(fd, view[offset:])
        if written <= 0:
            raise OSError(f"write made no progress: {written}")
        offset += written


def _exclusive_write(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        _write_all(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)


def _open_outer_raw(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags, 0o600)
    os.fsync(descriptor)
    _fsync_directory(path.parent)
    return descriptor


def _parse_delivery(argv: list[str]) -> dict[str, str | int]:
    names = (
        "--evidence-root",
        "--plan",
        "--plan-size",
        "--plan-sha256",
        "--python",
        "--python-size",
        "--python-sha256",
        "--python-version",
        "--entry",
        "--entry-size",
        "--entry-sha256",
        "--outer-cwd",
        "--outer-env-sha256",
        "--outer-wall-seconds",
        "--outer-output-cap",
    )
    if len(argv) != len(names) * 2:
        raise OuterEntryError("outer entry argv has wrong arity")
    result: dict[str, str | int] = {}
    for index, expected in enumerate(names):
        if argv[index * 2] != expected:
            raise OuterEntryError(f"outer entry expected {expected}")
        value = argv[index * 2 + 1]
        if not value or "\x00" in value:
            raise OuterEntryError(f"outer entry {expected} value is invalid")
        result[expected[2:].replace("-", "_")] = value
    for name in ("plan_size", "python_size", "entry_size"):
        try:
            result[name] = int(str(result[name]))
        except ValueError as exc:
            raise OuterEntryError(f"outer entry {name} is not an integer") from exc
        if result[name] < 0:
            raise OuterEntryError(f"outer entry {name} is negative")
    try:
        result["outer_wall_seconds"] = float(str(result["outer_wall_seconds"]))
        result["outer_output_cap"] = int(str(result["outer_output_cap"]))
    except ValueError as exc:
        raise OuterEntryError("outer wall/output bound is invalid") from exc
    if (
        not math.isfinite(float(result["outer_wall_seconds"]))
        or result["outer_wall_seconds"] <= 0
        or type(result["outer_output_cap"]) is not int
        or result["outer_output_cap"] <= 0
    ):
        raise OuterEntryError("outer wall/output bound must be finite and positive")
    for name in (
        "plan_sha256",
        "python_sha256",
        "entry_sha256",
        "outer_env_sha256",
    ):
        if HEX_64_RE.fullmatch(str(result[name])) is None:
            raise OuterEntryError(f"outer entry {name} is invalid")
    return result


def _outer_env() -> tuple[list[dict[str, str]], str]:
    normalized = {
        (name.upper() if os.name == "nt" else name): value
        for name, value in os.environ.items()
    }
    if len(normalized) != len(os.environ):
        raise OuterEntryError("outer environment has case-colliding names")
    entries = []
    for name, value in sorted(normalized.items()):
        if not name or "\x00" in name or "\x00" in value:
            raise OuterEntryError("outer environment contains invalid name/value")
        upper = name.upper()
        if any(
            fragment in upper
            for fragment in (
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
        ):
            raise OuterEntryError("secret-like outer environment is forbidden")
        entries.append({"name": name, "value": value})
    return entries, _sha256_bytes(_json_bytes(entries))


def _attempt(delivery: dict[str, str | int], root: Path) -> dict:
    environment, env_hash = _outer_env()
    cwd = Path(str(delivery["outer_cwd"]))
    if not cwd.is_absolute() or cwd.resolve(strict=True) != Path.cwd():
        raise OuterEntryError("outer cwd differs from delivery")
    if env_hash != delivery["outer_env_sha256"]:
        raise OuterEntryError("outer environment differs from delivery")
    return {
        "schema": OUTER_ATTEMPT_SCHEMA,
        "contract_version": OUTER_CONTRACT_VERSION,
        "attempt_id": os.urandom(32).hex().upper(),
        "created_unix_ns": time.time_ns(),
        "state": "attempt-created",
        "evidence_root": os.fspath(root),
        "delivery": {
            "required_interpreter_flags": ["-I", "-S", "-B", "-u"],
            "python": {
                "path": str(delivery["python"]),
                "size": int(delivery["python_size"]),
                "sha256": str(delivery["python_sha256"]),
                "version": str(delivery["python_version"]),
            },
            "entry": {
                "path": str(delivery["entry"]),
                "size": int(delivery["entry_size"]),
                "sha256": str(delivery["entry_sha256"]),
            },
            "plan": {
                "path": str(delivery["plan"]),
                "size": int(delivery["plan_size"]),
                "sha256": str(delivery["plan_sha256"]),
            },
            "cwd": os.fspath(cwd),
            "env": environment,
            "env_sha256": env_hash,
            "limits": {
                "wall_seconds": delivery["outer_wall_seconds"],
                "output_cap_bytes": delivery["outer_output_cap"],
            },
        },
        "observed": {
            "python_path": os.fspath(Path(sys.executable).resolve()),
            "python_version": sys.version,
            "python_implementation": sys.implementation.name,
            "entry_path": os.fspath(Path(__file__).resolve()),
            "isolated": sys.flags.isolated,
            "no_site": sys.flags.no_site,
            "dont_write_bytecode": sys.flags.dont_write_bytecode,
            "stdout_write_through": bool(getattr(sys.stdout, "write_through", False)),
            "stderr_write_through": bool(getattr(sys.stderr, "write_through", False)),
            "argv": list(sys.argv),
        },
    }


def _read_exact(path_value: str, size: int, digest: str, label: str) -> bytes:
    path = Path(path_value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise OuterEntryError(f"{label} path is not absolute regular non-link")
    before = path.stat()
    data = path.read_bytes()
    after = path.stat()
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or len(data) != size
        or _sha256_bytes(data) != digest
    ):
        raise OuterEntryError(f"{label} identity differs from delivery")
    return data


def _launcher_from_plan(plan_bytes: bytes) -> tuple[dict, bytes, dict]:
    plan = json.loads(
        plan_bytes.decode("ascii"),
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=_reject_json_constant,
    )
    if not isinstance(plan, dict) or set(plan) != {
        "schema",
        "contract_version",
        "gate_id",
        "launcher",
        "inner",
    }:
        raise OuterEntryError("plan top-level shape is invalid")
    launcher = plan["launcher"]
    if not isinstance(launcher, dict) or set(launcher) != {
        "path",
        "size",
        "sha256",
        "windows_adapter",
    }:
        raise OuterEntryError("plan launcher shape is invalid")
    if (
        not isinstance(launcher["path"], str)
        or type(launcher["size"]) is not int
        or not isinstance(launcher["sha256"], str)
        or HEX_64_RE.fullmatch(launcher["sha256"]) is None
    ):
        raise OuterEntryError("plan launcher identity is invalid")
    source = _read_exact(
        launcher["path"], launcher["size"], launcher["sha256"], "launcher"
    )
    windows_adapter = launcher["windows_adapter"]
    if not isinstance(windows_adapter, dict) or set(windows_adapter) != {
        "path",
        "size",
        "sha256",
    }:
        raise OuterEntryError("plan Windows adapter identity is invalid")
    if (
        not isinstance(windows_adapter["path"], str)
        or type(windows_adapter["size"]) is not int
        or not isinstance(windows_adapter["sha256"], str)
        or HEX_64_RE.fullmatch(windows_adapter["sha256"]) is None
    ):
        raise OuterEntryError("plan Windows adapter identity types are invalid")
    _read_exact(
        windows_adapter["path"],
        windows_adapter["size"],
        windows_adapter["sha256"],
        "Windows adapter",
    )
    return plan, source, dict(launcher)


def _raw_record(path: Path, cap: int) -> dict:
    with path.open("r+b") as stream:
        stream.flush()
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


def _failure_verdict(
    root: Path, attempt: dict, delivery: dict[str, str | int], stage: str,
    error: str, bound_reason: str | None
) -> None:
    _detach_outer_streams()
    cap = int(delivery["outer_output_cap"])
    stdout = _raw_record(root / OUTER_STDOUT_NAME, cap)
    stderr = _raw_record(root / OUTER_STDERR_NAME, cap)
    truncated = stdout["truncated_at_cap"] or stderr["truncated_at_cap"]
    verdict = {
        "schema": OUTER_VERDICT_SCHEMA,
        "contract_version": OUTER_CONTRACT_VERSION,
        "attempt_id": attempt["attempt_id"],
        "attempt_sha256": _sha256_file(root / OUTER_ATTEMPT_NAME),
        "plan_sha256": str(delivery["plan_sha256"]),
        "status": "failure",
        "classification": (
            "outer_timeout"
            if bound_reason == "timeout"
            else "outer_output_limit"
            if bound_reason == "output" or truncated
            else f"{stage}_failure"
        ),
        "stage": stage,
        "error": error,
        "identities": {},
        "cleanup_handshakes": [],
        "inner": None,
        "measurements": {
            "outer_wall_ns": 0,
            "cleanup_handshake_count": 0,
            "platform": sys.platform,
        },
        "streams": {"stdout": stdout, "stderr": stderr},
        "created_unix_ns": time.time_ns(),
    }
    _exclusive_write(root / OUTER_VERDICT_NAME, _json_bytes(verdict))


def _run(delivery: dict[str, str | int]) -> int:
    root = Path(str(delivery["evidence_root"]))
    if not root.is_absolute() or not root.is_dir() or root.is_symlink():
        raise OuterEntryError("outer evidence root must be absolute existing non-link dir")
    if list(os.scandir(root)):
        raise OuterEntryError("outer evidence root is not fresh; retry is forbidden")
    attempt = _attempt(delivery, root)
    attempt_path = root / OUTER_ATTEMPT_NAME
    _exclusive_write(attempt_path, _json_bytes(attempt))
    stdout_fd = _open_outer_raw(root / OUTER_STDOUT_NAME)
    try:
        stderr_fd = _open_outer_raw(root / OUTER_STDERR_NAME)
    except BaseException:
        os.close(stdout_fd)
        raise
    os.dup2(stdout_fd, 1)
    os.dup2(stderr_fd, 2)
    os.close(stdout_fd)
    os.close(stderr_fd)

    stage = "identity"
    started_ns = time.perf_counter_ns()
    bound_reason = {"value": None}
    monitor_stop = None
    monitor_thread = None
    try:
        import _thread
        import threading

        monitor_stop = threading.Event()

        def monitor_launcher() -> None:
            deadline = time.monotonic() + float(delivery["outer_wall_seconds"])
            cap = int(delivery["outer_output_cap"])
            while not monitor_stop.wait(0.01):
                reason = None
                if time.monotonic() >= deadline:
                    reason = "timeout"
                else:
                    try:
                        if (
                            (root / OUTER_STDOUT_NAME).stat().st_size > cap
                            or (root / OUTER_STDERR_NAME).stat().st_size > cap
                        ):
                            reason = "output"
                    except OSError:
                        reason = "output"
                if reason is not None:
                    bound_reason["value"] = reason
                    _thread.interrupt_main()
                    if not monitor_stop.wait(2):
                        os._exit(124)
                    return

        monitor_thread = threading.Thread(
            name="outer-launcher-bound",
            target=monitor_launcher,
            daemon=True,
        )
        monitor_thread.start()
        _read_exact(
            str(delivery["python"]),
            int(delivery["python_size"]),
            str(delivery["python_sha256"]),
            "python",
        )
        _read_exact(
            str(delivery["entry"]),
            int(delivery["entry_size"]),
            str(delivery["entry_sha256"]),
            "entry",
        )
        if (
            Path(sys.executable).resolve(strict=True) != Path(str(delivery["python"]))
            or Path(__file__).resolve(strict=True) != Path(str(delivery["entry"]))
            or sys.version != delivery["python_version"]
            or not (
                sys.flags.isolated
                and sys.flags.no_site
                and sys.flags.dont_write_bytecode
                and attempt["observed"]["stdout_write_through"]
                and attempt["observed"]["stderr_write_through"]
            )
        ):
            raise OuterEntryError("observed trust-root identity differs from delivery")
        stage = "plan"
        plan_bytes = _read_exact(
            str(delivery["plan"]),
            int(delivery["plan_size"]),
            str(delivery["plan_sha256"]),
            "plan",
        )
        plan, launcher_source, launcher_identity = _launcher_from_plan(plan_bytes)
        stage = "launcher-compile-exec"
        launcher_path = launcher_identity["path"]
        module_name = "vorton_one_shot_dynamic_launcher"
        module = types.ModuleType(module_name)
        module.__file__ = launcher_path
        module.__package__ = None
        sys.modules[module_name] = module
        code = compile(
            launcher_source.decode("utf-8", errors="strict"),
            launcher_path,
            "exec",
            dont_inherit=True,
        )
        exec(code, module.__dict__)
        run_outer = getattr(module, "run_outer_entry", None)
        if not callable(run_outer):
            raise OuterEntryError("dynamic launcher lacks run_outer_entry protocol")
        stage = "outer-launcher"
        result_code = int(
            run_outer(
                plan,
                delivery=dict(delivery),
                attempt=attempt,
                outer_evidence_dir=os.fspath(root),
                identities={
                    "python": attempt["delivery"]["python"],
                    "entry": attempt["delivery"]["entry"],
                    "plan": attempt["delivery"]["plan"],
                    "launcher": launcher_identity,
                },
                started_ns=started_ns,
                outer_bound_state=lambda: bound_reason["value"],
            )
        )
        monitor_stop.set()
        monitor_thread.join(timeout=3)
        return result_code
    except BaseException as exc:
        if monitor_stop is not None:
            monitor_stop.set()
        if monitor_thread is not None:
            monitor_thread.join(timeout=3)
        error = f"{type(exc).__name__}: {exc}"
        try:
            traceback.print_exc()
        except BaseException:
            pass
        try:
            _failure_verdict(
                root, attempt, delivery, stage, error, bound_reason["value"]
            )
        except FileExistsError:
            pass
        return 1


def main(argv: list[str] | None = None) -> int:
    return _run(_parse_delivery(list(sys.argv[1:] if argv is None else argv)))


if __name__ == "__main__":
    raise SystemExit(main())
